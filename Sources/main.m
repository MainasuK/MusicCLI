// main.m — MusicCLI
//
// macOS「音乐」(Music.app) 资料库的命令行访问层：**原生读取 + 收敛的写入路径**。
//
// 为什么需要它：直接用 AppleScript 操作资料库很容易出问题 ——
//   * `whose album is` 查询不稳定（同一句查询时好时坏；库忙/重建索引时报 -1728）
//   * 大批量删除会挂死，且没有超时保护
//   * `add` 的返回值是异步上报的（实测 rc=0 却报 `added 0`，容易被误判为失败）
// 但现实是：**Apple 没有提供任何写入 API** ——
//   * iTunesLibrary.framework：仅 libraryWithAPIVersion / artworkForMediaFile /
//     reloadData / unloadData，**没有 add/remove**
//   * MediaLibrary.framework：同样只读
//   * 库文件 `Music Library.musiclibrary/Library.musicdb` 是私有 `hfma` 格式（非 SQLite），
//     不能直接改
// 所以本工具的定位是：
//   * **读**：全部走 iTunesLibrary.framework（原生、快、稳定，不依赖 AppleScript）
//   * **写**：add / delete 只有 AppleScript 一条路，但**收敛到本项目唯一一处**，
//     统一提供：pid 精确匹配、分批执行、超时保护、默认预览（需 --yes）、执行后可复验
//
// 环境要求：macOS 10.13+ 且已安装 Music.app（依赖 iTunesLibrary.framework）
//
// 用法：
//   music-cli dump    <out.jsonl>          全库导出为 JSONL（原生）
//   music-cli find    <关键词> [--json]     按 专辑/曲名/艺人 模糊查（原生）
//   music-cli info    <pid>                按 persistent ID 查一条（原生）
//   music-cli check   <专辑名>              该专辑的轨数/路径/文件是否存在（原生）
//   music-cli verify  [--json]             统计幽灵条目；有则 exit 3（后置门禁）
//   music-cli add     <文件...>             把文件加入资料库（写）
//   music-cli delete  --pid <pid>...        按 persistent ID 精确删除（写；默认预览）
//   music-cli delete  --album <专辑名>       按专辑名删除（写；默认预览）
//   music-cli delete  --missing             删除全部幽灵条目（写；默认预览）
//   预览操作加 --yes 才真正执行。
//
// 编译：见 Makefile，或
//   clang -fobjc-arc -framework Foundation -framework iTunesLibrary \
//         -o build/music-cli Sources/main.m
//
// 退出码：0 成功；1 一般错误；2 用法错误；3 verify 发现异常
#import <Foundation/Foundation.h>
#import <iTunesLibrary/iTunesLibrary.h>

static NSString *kindName(ITLibMediaItemMediaKind k) {
    switch (k) {
        case ITLibMediaItemMediaKindSong: return @"Song";
        case ITLibMediaItemMediaKindMovie: return @"Movie";
        case ITLibMediaItemMediaKindPodcast: return @"Podcast";
        case ITLibMediaItemMediaKindAudiobook: return @"Audiobook";
        case ITLibMediaItemMediaKindPDFBooklet: return @"PDFBooklet";
        case ITLibMediaItemMediaKindMusicVideo: return @"MusicVideo";
        case ITLibMediaItemMediaKindTVShow: return @"TVShow";
        case ITLibMediaItemMediaKindHomeVideo: return @"HomeVideo";
        case ITLibMediaItemMediaKindVoiceMemo: return @"VoiceMemo";
        default: return @"Other";
    }
}

static ITLibrary *openLibrary(void) {
    NSError *err = nil;
    ITLibrary *lib = [ITLibrary libraryWithAPIVersion:@"1.0" error:&err];
    if (!lib) {
        fprintf(stderr, "ERR: cannot open library: %s\n", err.localizedDescription.UTF8String);
    }
    return lib;
}

// 把一条 media item 转成 dict（字段与旧 dump-library 保持一致，下游无需改动）
static NSDictionary *itemDict(ITLibMediaItem *item, NSISO8601DateFormatter *iso) {
    ITLibAlbum *album = item.album;
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"pid"] = [NSString stringWithFormat:@"%llu", item.persistentID.unsignedLongLongValue];
    d[@"kind"] = @(item.mediaKind);
    d[@"kindName"] = kindName(item.mediaKind);
    if (item.title) d[@"title"] = item.title;
    if (item.artist.name) d[@"artist"] = item.artist.name;
    if (album.title) d[@"album"] = album.title;
    if (album.albumArtist) d[@"albumArtist"] = album.albumArtist;
    if (album.isCompilation) d[@"compilation"] = @YES;
    if (item.trackNumber > 0) d[@"trackNumber"] = @(item.trackNumber);
    if (album.discNumber > 0) d[@"discNumber"] = @(album.discNumber);
    if (album.discCount > 0) d[@"discCount"] = @(album.discCount);
    if (album.trackCount > 0) d[@"albumTrackCount"] = @(album.trackCount);
    if (item.year > 0) d[@"year"] = @(item.year);
    if (item.genre) d[@"genre"] = item.genre;
    d[@"playCount"] = @(item.playCount);
    d[@"rating"] = @(item.rating);
    if (item.lastPlayedDate) d[@"lastPlayed"] = [iso stringFromDate:item.lastPlayedDate];
    if (item.location) {
        d[@"location"] = item.location.path;
        d[@"ext"] = item.location.pathExtension.lowercaseString;
    }
    return d;
}

// ---------- 写操作：唯一那条 AppleScript 路径 ----------
// 说明：苹果未提供写入 API，add/delete 只能用 AppleScript。
// 这里集中做三件事：(1) 用 persistent ID 精确匹配（不用专辑名，避免误删）；
// (2) 分批 + 超时，避免整库扫描挂死；(3) 返回真实删除条数供上层复验。
static int runAppleScript(NSString *src, NSTimeInterval timeout, NSString **outText) {
    NSTask *task = [NSTask new];
    task.launchPath = @"/usr/bin/osascript";
    task.arguments = @[@"-e", src];
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;
    NSError *err = nil;
    if (![task launchAndReturnError:&err]) {
        fprintf(stderr, "ERR: failed to launch osascript: %s\n", err.localizedDescription.UTF8String);
        return 1;
    }
    // 超时保护：AppleScript 在库忙时会挂死，不能无限等
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (task.isRunning && [deadline timeIntervalSinceNow] > 0) {
        [NSThread sleepForTimeInterval:0.2];
    }
    if (task.isRunning) {
        [task terminate];
        fprintf(stderr, "ERR: osascript timed out after %.0fs; terminated\n", timeout);
        return 1;
    }
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    if (outText) *outText = text;
    return task.terminationStatus;
}

static NSString *escapeForAppleScript(NSString *s) {
    return [s stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
}

static int cmdAdd(NSArray<NSString *> *paths) {
    if (paths.count == 0) { fprintf(stderr, "usage: music-cli add <file>...\n"); return 2; }
    NSMutableString *src = [NSMutableString stringWithString:@"tell application \"Music\"\n  set fs to {}\n"];
    for (NSString *p in paths) {
        NSString *abs = [p isAbsolutePath] ? p : [[[NSFileManager defaultManager] currentDirectoryPath]
                                                  stringByAppendingPathComponent:p];
        [src appendFormat:@"  set end of fs to POSIX file \"%@\"\n", escapeForAppleScript(abs)];
    }
    [src appendString:@"  set added to add fs\n  return \"added \" & (count of added)\nend tell"];
    NSString *out = nil;
    int rc = runAppleScript(src, 600, &out);
    printf("%s\n", out.length ? out.UTF8String : "(no output)");
    return rc;
}

/// 把 persistent ID 归一成 AppleScript 需要的形式。
///
/// **这是本工具最容易踩的坑**：iTunesLibrary.framework 读出来的 persistentID 是
/// **十进制**（`unsignedLongLongValue`，如 `14996906945997447858`），而 AppleScript 的
/// `persistent ID` 属性返回/接受的是 **16 位十六进制串**（如 `D01FB7690DC422B2`）。
/// 直接把十进制喂给 AppleScript 会**一条都匹配不上**，且不报错（静默删 0 条）。
/// 这里统一接受两种输入：纯十进制数字 → 转 16 位大写十六进制；已是十六进制则原样保留。
static NSString *normalizePersistentID(NSString *raw) {
    NSString *s = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSString *upper = s.uppercaseString;
    // 已经是合法十六进制串（1~16 位，含 A-F）→ 补零到 16 位直接用
    NSCharacterSet *hexSet = [NSCharacterSet characterSetWithCharactersInString:@"0123456789ABCDEF"];
    BOOL allHex = s.length > 0 && s.length <= 16;
    if (allHex) {
        for (NSUInteger i = 0; i < upper.length; i++) {
            if (![hexSet characterIsMember:[upper characterAtIndex:i]]) { allHex = NO; break; }
        }
    }
    // 纯数字且位数较长（>16 位）必然是十进制 → 转十六进制
    BOOL allDigits = s.length > 0;
    for (NSUInteger i = 0; i < s.length; i++) {
        if (!isdigit((unsigned char)[s characterAtIndex:i])) { allDigits = NO; break; }
    }
    unsigned long long value = 0;
    if (allDigits && s.length > 16) {
        value = strtoull(s.UTF8String, NULL, 10);
    } else if (allHex) {
        value = strtoull(upper.UTF8String, NULL, 16);
    } else if (allDigits) {
        value = strtoull(s.UTF8String, NULL, 10);   // 短纯数字：按十进制理解
    } else {
        return upper;                                // 兜底：原样（含非法字符时交给 AppleScript 报错）
    }
    return [NSString stringWithFormat:@"%016llX", value];
}

/// 删除后**回读实时库**确认是否真的消失。
///
/// 为什么必须回读：Music 的删除是**异步落库**的，AppleScript 返回的计数只代表脚本执行完，
/// 不代表库已经写完。曾经踩过：删完立刻用**旧快照**复查，以为"删了但还在"，
/// 实际是快照过期（真删成功了）；反过来也可能出现脚本报成功、库却没删。
/// 因此唯一可信的判定是「删完 → 重新打开库 → 看还在不在」。
static NSInteger countStillPresent(NSArray<NSString *> *hexIDs) {
    ITLibrary *lib = [ITLibrary libraryWithAPIVersion:@"1.0" error:nil];
    if (!lib) return -1;                       // -1 表示无法判定，交由调用方提示
    NSMutableSet<NSString *> *want = [NSMutableSet setWithArray:hexIDs];
    NSInteger still = 0;
    for (ITLibMediaItem *item in lib.allMediaItems) {
        NSString *hex = [NSString stringWithFormat:@"%016llX", item.persistentID.unsignedLongLongValue];
        if ([want containsObject:hex]) still++;
    }
    return still;
}

static int cmdDeletePids(NSArray<NSString *> *pids, BOOL apply) {
    if (pids.count == 0) { fprintf(stderr, "usage: music-cli delete --pid <pid>...\n"); return 2; }
    NSMutableArray<NSString *> *norm = [NSMutableArray arrayWithCapacity:pids.count];
    for (NSString *p in pids) [norm addObject:normalizePersistentID(p)];
    // 去重：同一个 ID 传两次会让"删除数不符"误报
    NSMutableArray<NSString *> *uniq = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSString *h in norm) if (![seen containsObject:h]) { [seen addObject:h]; [uniq addObject:h]; }
    if (uniq.count != norm.count)
        printf("note: %lu duplicate ID(s) removed from request\n", (unsigned long)(norm.count - uniq.count));
    norm = uniq;

    if (!apply) {
        printf("[preview] would delete %lu item(s) by persistent ID:\n", (unsigned long)norm.count);
        for (NSUInteger i = 0; i < norm.count; i++)
            printf("   %s → %s\n", pids[i].UTF8String, norm[i].UTF8String);
        printf("pass --yes to actually run\n");
        return 0;
    }
    // 分批（每批 10 条），避免单条 AppleScript 过长导致挂死。
    //
    // 定位方式用 persistent ID：`iTunesLibrary.framework` **只暴露 persistentID**
    // （ITLibMediaEntity 上除此之外没有 databaseID），所以无法从这里拿到 AppleScript 的
    // `database ID`。persistent ID 查询本身是可靠的 —— 之前怀疑它"静默失败"，
    // 真正的原因是复查时读了**过期快照**（删除其实成功了）。
    NSInteger total = 0;
    for (NSUInteger i = 0; i < norm.count; i += 10) {
        NSUInteger n = MIN((NSUInteger)10, norm.count - i);
        NSMutableString *src = [NSMutableString stringWithString:@"tell application \"Music\"\n  set n to 0\n"];
        for (NSUInteger j = i; j < i + n; j++) {
            [src appendFormat:@"  try\n    set tr to (some track of library playlist 1 whose persistent ID is \"%@\")\n"
                              @"    delete tr\n    set n to n + 1\n  end try\n", escapeForAppleScript(norm[j])];
        }
        [src appendString:@"  return n\nend tell"];
        NSString *out = nil;
        if (runAppleScript(src, 300, &out) != 0) return 1;
        NSInteger got = out.integerValue;
        total += got;
        printf("  batch %lu: deleted %ld\n", (unsigned long)(i / 10 + 1), (long)got);
    }

    // 回读实时库确认（异步落库，必须等一拍再看）
    [NSThread sleepForTimeInterval:2.0];
    NSInteger still = countStillPresent(norm);
    printf("deleted %ld / %lu\n", (long)total, (unsigned long)norm.count);
    if (still < 0) {
        fprintf(stderr, "WARN: could not reopen the library to verify; treat the result as unconfirmed\n");
        return total == (NSInteger)norm.count ? 0 : 1;
    }
    if (still == 0) {
        printf("verified: none of the requested IDs remain in the library\n");
        return total == (NSInteger)norm.count ? 0 : 1;
    }
    fprintf(stderr, "ERROR: %ld requested ID(s) still present after delete — not removed\n", (long)still);
    return 1;
}

static int cmdDeleteAlbum(NSString *album, BOOL apply) {
    ITLibrary *lib = openLibrary();
    if (!lib) return 1;
    NSMutableArray *pids = [NSMutableArray array];
    for (ITLibMediaItem *item in lib.allMediaItems) {
        if ([item.album.title isEqualToString:album]) {
            [pids addObject:[NSString stringWithFormat:@"%llu", item.persistentID.unsignedLongLongValue]];
        }
    }
    printf("album %s: %lu item(s) in library\n", album.UTF8String, (unsigned long)pids.count);
    if (pids.count == 0) return 0;
    if (!apply) {
        printf("[preview] pass --yes to actually delete\n");
        return 0;
    }
    return cmdDeletePids(pids, YES);
}

// 删除"记录在册但文件已删"的幽灵条目（本次会话反复需要的操作）
static int cmdDeleteMissing(BOOL apply) {
    ITLibrary *lib = openLibrary();
    if (!lib) return 1;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *pids = [NSMutableArray array];
    NSMutableArray *desc = [NSMutableArray array];
    for (ITLibMediaItem *item in lib.allMediaItems) {
        NSString *path = item.location.path;
        if (path.length == 0) continue;              // 无 location 的条目（如 Apple Music 串流）不算幽灵
        if ([fm fileExistsAtPath:path]) continue;    // 文件在，正常
        [pids addObject:[NSString stringWithFormat:@"%llu", item.persistentID.unsignedLongLongValue]];
        [desc addObject:[NSString stringWithFormat:@"%@ / %@ / %@",
                         item.album.title ?: @"?", item.artist.name ?: @"?", item.title ?: @"?"]];
    }
    printf("ghost entries (recorded but file missing): %lu\n", (unsigned long)pids.count);
    for (NSUInteger i = 0; i < MIN((NSUInteger)20, desc.count); i++)
        printf("   %s\n", [desc[i] UTF8String]);
    if (pids.count > 20) printf("   ... and %lu more\n", (unsigned long)(pids.count - 20));
    if (!apply) { printf("[preview] pass --yes to actually delete\n"); return 0; }
    return cmdDeletePids(pids, YES);
}

// ---------- 读操作 ----------
static int cmdDump(NSString *outPath) {
    ITLibrary *lib = openLibrary();
    if (!lib) return 1;
    NSArray *items = lib.allMediaItems;
    NSISO8601DateFormatter *iso = [NSISO8601DateFormatter new];
    NSMutableString *sb = [NSMutableString stringWithCapacity:items.count * 256];
    for (ITLibMediaItem *item in items) {
        NSDictionary *d = itemDict(item, iso);
        NSError *jerr = nil;
        NSData *json = [NSJSONSerialization dataWithJSONObject:d options:0 error:&jerr];
        if (!json) continue;
        [sb appendString:[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]];
        [sb appendString:@"\n"];
    }
    NSError *werr = nil;
    if (![sb writeToFile:outPath atomically:YES encoding:NSUTF8StringEncoding error:&werr]) {
        fprintf(stderr, "ERR: write failed: %s\n", werr.localizedDescription.UTF8String);
        return 1;
    }
    NSInteger songs = 0;
    for (ITLibMediaItem *item in items) if (item.mediaKind == ITLibMediaItemMediaKindSong) songs++;
    printf("library appVersion=%s items=%lu songs=%ld\n-> %s\n",
           lib.applicationVersion.UTF8String, (unsigned long)items.count, (long)songs, outPath.UTF8String);
    return 0;
}

static int cmdFind(NSString *kw, BOOL asJson) {
    ITLibrary *lib = openLibrary();
    if (!lib) return 1;
    NSISO8601DateFormatter *iso = [NSISO8601DateFormatter new];
    NSMutableArray *hits = [NSMutableArray array];
    for (ITLibMediaItem *item in lib.allMediaItems) {
        NSString *alb = item.album.title ?: @"";
        NSString *tit = item.title ?: @"";
        NSString *art = item.artist.name ?: @"";
        if ([alb containsString:kw] || [tit containsString:kw] || [art containsString:kw]) {
            [hits addObject:itemDict(item, iso)];
        }
    }
    if (asJson) {
        NSData *json = [NSJSONSerialization dataWithJSONObject:hits
                                                       options:NSJSONWritingPrettyPrinted error:nil];
        printf("%s\n", [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
    } else {
        printf("%lu match(es):\n", (unsigned long)hits.count);
        for (NSDictionary *d in hits) {
            printf("  %-20s | %-34s | %s\n",
                   [d[@"pid"] UTF8String],
                   [(d[@"album"] ?: @"?") UTF8String],
                   [(d[@"title"] ?: @"?") UTF8String]);
        }
    }
    return 0;
}

static int cmdInfo(NSString *pidStr) {
    ITLibrary *lib = openLibrary();
    if (!lib) return 1;
    unsigned long long want = strtoull(pidStr.UTF8String, NULL, 10);
    for (ITLibMediaItem *item in lib.allMediaItems) {
        if (item.persistentID.unsignedLongLongValue == want) {
            NSDictionary *d = itemDict(item, [NSISO8601DateFormatter new]);
            NSData *json = [NSJSONSerialization dataWithJSONObject:d
                                                           options:NSJSONWritingPrettyPrinted error:nil];
            printf("%s\n", [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
            return 0;
        }
    }
    fprintf(stderr, "no item found for pid=%s\n", pidStr.UTF8String);
    return 1;
}

// 替代 AppleScript `whose album is`（那个查询不稳定，本次会话被坑多次）
static int cmdCheck(NSString *album) {
    ITLibrary *lib = openLibrary();
    if (!lib) return 1;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *rows = [NSMutableArray array];
    for (ITLibMediaItem *item in lib.allMediaItems) {
        if (![item.album.title isEqualToString:album]) continue;
        NSString *p = item.location.path;
        [rows addObject:@{@"pid": [NSString stringWithFormat:@"%llu", item.persistentID.unsignedLongLongValue],
                          @"title": item.title ?: @"",
                          @"artist": item.artist.name ?: @"",
                          @"path": p ?: @"",
                          @"exists": @(p.length && [fm fileExistsAtPath:p])}];
    }
    NSInteger alive = 0;
    for (NSDictionary *r in rows) if ([r[@"exists"] boolValue]) alive++;
    NSDictionary *out = @{@"album": album,
                          @"tracks": @(rows.count),
                          @"files_present": @(alive),
                          @"tracks_detail": rows};
    NSData *json = [NSJSONSerialization dataWithJSONObject:out
                                                   options:NSJSONWritingPrettyPrinted error:nil];
    printf("%s\n", [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
    return 0;
}

// 后置门禁：统计幽灵条目 + 同名专辑重复
static int cmdVerify(BOOL asJson) {
    ITLibrary *lib = openLibrary();
    if (!lib) return 1;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableDictionary<NSString *, NSNumber *> *byAlbum = [NSMutableDictionary dictionary];
    NSInteger ghosts = 0, songs = 0, withLoc = 0;
    NSMutableArray *ghostSample = [NSMutableArray array];
    for (ITLibMediaItem *item in lib.allMediaItems) {
        if (item.mediaKind != ITLibMediaItemMediaKindSong) continue;
        songs++;
        NSString *alb = item.album.title ?: @"";
        byAlbum[alb] = @(byAlbum[alb].integerValue + 1);
        NSString *p = item.location.path;
        if (p.length == 0) continue;
        withLoc++;
        if (![fm fileExistsAtPath:p]) {
            ghosts++;
            if (ghostSample.count < 10)
                [ghostSample addObject:[NSString stringWithFormat:@"%@ / %@", alb, item.title ?: @""]];
        }
    }
    printf("tracks: %ld (with location: %ld)\n", (long)songs, (long)withLoc);
    printf("ghost entries (file missing): %ld\n", (long)ghosts);
    for (NSString *s in ghostSample) printf("   %s\n", s.UTF8String);
    int rc = ghosts > 0 ? 3 : 0;
    if (asJson) {
        NSData *json = [NSJSONSerialization dataWithJSONObject:
                        @{@"songs": @(songs), @"with_location": @(withLoc), @"ghosts": @(ghosts)}
                                                       options:NSJSONWritingPrettyPrinted error:nil];
        printf("%s\n", [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
    }
    return rc;
}

static void usage(void) {
    fprintf(stderr,
        "music-cli — Music.app library access layer (reads = native iTunesLibrary, writes = one AppleScript path)\n\n"
        "  dump   <out.jsonl>          Export the whole library as JSONL (native)\n"
        "  find   <query> [--json]     Fuzzy search album / title / artist (native)\n"
        "  info   <pid>                Look up one item by persistent ID (native)\n"
        "  check  <album>              Track count, file paths, and whether files exist (native)\n"
        "  verify [--json]             Count ghost entries; exits 3 if any (post-import gate)\n"
        "  add    <file>...            Add files to the library (write)\n"
        "  delete --pid <pid>...       Delete by exact persistent ID (write; preview, --yes to run)\n"
        "  delete --album <album>      Delete by album name (write; preview, --yes to run)\n"
        "  delete --missing            Delete every ghost entry (write; preview, --yes to run)\n");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) { usage(); return 2; }
        NSString *cmd = [NSString stringWithUTF8String:argv[1]];
        NSMutableArray<NSString *> *args = [NSMutableArray array];
        BOOL yes = NO, asJson = NO;
        for (int i = 2; i < argc; i++) {
            NSString *a = [NSString stringWithUTF8String:argv[i]];
            if ([a isEqualToString:@"--yes"]) { yes = YES; continue; }
            if ([a isEqualToString:@"--json"]) { asJson = YES; continue; }
            [args addObject:a];
        }
        if ([cmd isEqualToString:@"dump"]) {
            if (args.count < 1) { usage(); return 2; }
            return cmdDump(args[0]);
        }
        if ([cmd isEqualToString:@"find"]) {
            if (args.count < 1) { usage(); return 2; }
            return cmdFind(args[0], asJson);
        }
        if ([cmd isEqualToString:@"info"]) {
            if (args.count < 1) { usage(); return 2; }
            return cmdInfo(args[0]);
        }
        if ([cmd isEqualToString:@"check"]) {
            if (args.count < 1) { usage(); return 2; }
            return cmdCheck(args[0]);
        }
        if ([cmd isEqualToString:@"verify"]) return cmdVerify(asJson);
        if ([cmd isEqualToString:@"add"]) return cmdAdd(args);
        if ([cmd isEqualToString:@"delete"]) {
            if (args.count == 0) { usage(); return 2; }
            if ([args[0] isEqualToString:@"--missing"]) return cmdDeleteMissing(yes);
            if ([args[0] isEqualToString:@"--album"]) {
                if (args.count < 2) { usage(); return 2; }
                return cmdDeleteAlbum(args[1], yes);
            }
            if ([args[0] isEqualToString:@"--pid"]) {
                NSArray *pids = [args subarrayWithRange:NSMakeRange(1, args.count - 1)];
                return cmdDeletePids(pids, yes);
            }
            usage(); return 2;
        }
        usage(); return 2;
    }
}
