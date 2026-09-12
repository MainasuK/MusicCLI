// main.m — MusicCLI
//
// Command-line access to the macOS Music.app library: **native reads + one hardened write path**.
//
// Why this exists: driving the library with AppleScript is fragile in practice —
//   * `whose album is` queries are unreliable (same query works then fails; returns -1728
//     while the library is busy or reindexing)
//   * bulk deletions hang, with no timeout protection
//   * `add` reports asynchronously (observed rc=0 while printing `added 0`, easy to misread
//     as a failure even though the tracks were imported)
// The catch: **Apple ships no write API at all** —
//   * iTunesLibrary.framework exposes only libraryWithAPIVersion / artworkForMediaFile /
//     reloadData / unloadData — **no add/remove**
//   * MediaLibrary.framework is read-only as well
//   * the library file `Music Library.musiclibrary/Library.musicdb` uses a private `hfma`
//     format (not SQLite) and cannot be edited directly
// So this tool is deliberately split:
//   * **reads** go entirely through iTunesLibrary.framework (native, fast, stable, no AppleScript)
//   * **writes** (add/delete) have exactly one available route — AppleScript — so it is
//     **confined to this single place**, hardened with exact persistent-ID matching, batching,
//     timeouts, preview by default (--yes required), and verification afterwards
//
// Requirements: macOS 10.13+ with Music.app installed (depends on iTunesLibrary.framework)
//
// Usage:
//   music-cli dump    <out.jsonl>          export the whole library as JSONL (native)
//   music-cli find    <query> [--json]     fuzzy search album / title / artist (native)
//   music-cli info    <pid>                look up one item by persistent ID (native)
//   music-cli check   <album>              track count, file paths, and whether files exist (native)
//   music-cli verify  [--json]             count ghost entries; exits 3 if any (post-import gate)
//   music-cli add     <file>...            add files to the library (write)
//   music-cli delete  --pid <pid>...       delete by exact persistent ID (write; preview by default)
//   music-cli delete  --album <album>      delete by album name (write; preview by default)
//   music-cli delete  --missing            delete every ghost entry (write; preview by default)
//   Pass --yes to actually run a previewed operation.
//
// Build: see the Makefile, or
//   clang -fobjc-arc -framework Foundation -framework iTunesLibrary \
//         -o build/music-cli Sources/main.m
//
// Exit codes: 0 success; 1 general error; 2 usage error; 3 verify found anomalies
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

// Convert one media item into a dictionary. Field names match the legacy dump-library
// output so downstream consumers need no changes.
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

// ---------- Writes: the one and only AppleScript path ----------
// Apple exposes no write API, so add/delete can only go through AppleScript.
// This section centralises three things: (1) exact persistent-ID matching rather than
// album names, to avoid deleting the wrong items; (2) batching plus timeouts, so a
// library-wide scan cannot hang forever; (3) returning the real deleted count so callers
// can verify the result.
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
    // Timeout guard: AppleScript can hang while the library is busy, so never wait forever.
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

/// Normalise a persistent ID into the form AppleScript expects.
///
/// **This is the easiest trap in this tool.** iTunesLibrary.framework reports persistentID
/// as a **decimal** number (`unsignedLongLongValue`, e.g. `14996906945997447858`), while
/// AppleScript's `persistent ID` property takes and returns a **16-digit hex string**
/// (e.g. `D01FB7690DC422B2`). Feeding the decimal straight to AppleScript matches nothing
/// and does not error out — it silently deletes zero rows.
/// Both forms are accepted here: a long all-digit value is converted to 16-digit uppercase
/// hex; anything already hexadecimal is passed through.
static NSString *normalizePersistentID(NSString *raw) {
    NSString *s = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSString *upper = s.uppercaseString;
    // Already a valid hex string (1-16 chars, may contain A-F): use as-is, zero-padded.
    NSCharacterSet *hexSet = [NSCharacterSet characterSetWithCharactersInString:@"0123456789ABCDEF"];
    BOOL allHex = s.length > 0 && s.length <= 16;
    if (allHex) {
        for (NSUInteger i = 0; i < upper.length; i++) {
            if (![hexSet characterIsMember:[upper characterAtIndex:i]]) { allHex = NO; break; }
        }
    }
    // A long all-digit value (>16 chars) must be decimal: convert it to hex.
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
        value = strtoull(s.UTF8String, NULL, 10);   // short all-digit value: treat as decimal
    } else {
        return upper;                                // fallback: pass through and let AppleScript complain
    }
    return [NSString stringWithFormat:@"%016llX", value];
}

/// Re-open the live library after deleting and confirm the items are really gone.
///
/// Why this is required: Music persists deletions **asynchronously**. The count returned by
/// AppleScript only means the script finished, not that the library write landed. This bit
/// us once already: re-checking straight after a delete against a **stale dump** made it look
/// like the items were still present when they had in fact been removed. The reverse is also
/// possible — the script reports success while the library keeps the rows.
/// So the only trustworthy check is: delete -> reopen the library -> see whether they remain.
static NSInteger countStillPresent(NSArray<NSString *> *hexIDs) {
    ITLibrary *lib = [ITLibrary libraryWithAPIVersion:@"1.0" error:nil];
    if (!lib) return -1;                       // -1 means undeterminable; the caller warns
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
    // De-duplicate: passing the same ID twice triggers a bogus "deleted fewer than requested".
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
    // Batch 10 at a time so a single AppleScript invocation cannot grow large enough to hang.
    //
    // Lookup uses the persistent ID: `iTunesLibrary.framework` **exposes only persistentID**
    // (ITLibMediaEntity has no databaseID), so AppleScript's `database ID` is not reachable
    // from here. The persistent ID lookup itself is reliable — an earlier suspicion that it
    // "fails silently" turned out to be a **stale dump** read during verification; the
    // deletions had actually succeeded.
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

    // Re-read the live library to confirm (writes are async, so give it a beat first).
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

// Delete "ghost" entries: recorded in the library but whose files are gone.
static int cmdDeleteMissing(BOOL apply) {
    ITLibrary *lib = openLibrary();
    if (!lib) return 1;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *pids = [NSMutableArray array];
    NSMutableArray *desc = [NSMutableArray array];
    for (ITLibMediaItem *item in lib.allMediaItems) {
        NSString *path = item.location.path;
        if (path.length == 0) continue;              // no location (e.g. streaming) is not a ghost
        if ([fm fileExistsAtPath:path]) continue;    // file present: fine
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

// ---------- Reads ----------
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

// Replaces AppleScript's `whose album is`, which is unreliable.
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

// Post-import gate: count ghost entries.
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
