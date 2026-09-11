# MusicCLI

[![Platform](https://img.shields.io/badge/platform-macOS%2010.13%2B-blue)](#requirements)
[![Language](https://img.shields.io/badge/language-Objective--C-orange)](#)

macOS「音乐」(Music.app) 资料库的命令行访问层：**原生读取 + 收敛的写入路径**。

## 为什么需要它

直接用 AppleScript（`osascript`）操作 Music 资料库很容易出问题：

- **查询不稳定** —— `whose album is "..."` 同一句查询时好时坏；资料库忙或重建索引期间会报
  `-1728 不能获得`。
- **大批量操作会挂死** —— 循环删除几百条时会卡住，而且没有超时保护。
- **`add` 的返回值是异步的** —— 实测 `return "added " & (count of added)` 会返回
  `added 0`，但曲目其实已经入库，容易误判。

但现实是 **Apple 没有提供任何官方写入 API**：

| 途径 | 结论 |
|---|---|
| `iTunesLibrary.framework` | 只有 `libraryWithAPIVersion:error:` / `artworkForMediaFile:` / `reloadData` / `unloadData`，**没有 add / remove** |
| `MediaLibrary.framework` | 同样只读 |
| `Music Library.musiclibrary/Library.musicdb` | 私有 `hfma` 格式（非 SQLite），不能直接改 |

因此本工具的定位是：

- **读** —— 全部走 `iTunesLibrary.framework`：原生、快速、稳定，不依赖 AppleScript
- **写** —— `add` / `delete` 只有 AppleScript 一条路，但**收敛到本项目唯一一处**，
  并统一提供：persistent ID 精确匹配、分批执行、超时保护、默认预览（需 `--yes`）、执行后可复验

> 如果你正在做资料库相关的自动化，建议：**读取一律用本工具，删除集中到本工具**，
> 不要在业务脚本里散落 AppleScript。

## 环境要求

- macOS 10.13 或更高（依赖 `iTunesLibrary.framework`）
- 已安装并至少启动过一次 Music.app
- 编译需要 Xcode Command Line Tools（`xcode-select --install`）

## 构建

```bash
make            # 产物在 build/music-cli
make install    # 安装到 /usr/local/bin/music-cli（可用 PREFIX=... 改路径）
make test       # 只读自检（不改资料库）
```

也可以直接编译：

```bash
clang -fobjc-arc -framework Foundation -framework iTunesLibrary \
      -o build/music-cli Sources/main.m
```

## 命令

### 读取（原生，安全）

```bash
# 全库导出为 JSONL（每行一条 media item）
music-cli dump library.jsonl

# 按 专辑 / 曲名 / 艺人 模糊查
music-cli find "初音ミク"
music-cli find "初音ミク" --json        # 输出 JSON

# 按 persistent ID 查单条
music-cli info 12345678901234567890

# 查某个专辑：轨数、每个文件的路径、文件是否真的存在（JSON 输出）
music-cli check "Some Album"

# 后置门禁：统计「记录在册但文件已删」的幽灵条目；有则 exit 3
music-cli verify
```

`check` 与 `verify` 会**同时核对磁盘文件是否存在** —— 因为 Music 的资料库里可能残留
「有记录、无文件」的幽灵条目，只看数据库会误判为「本地已有」。

### 写入（默认预览，需 `--yes` 才执行）

```bash
# 把音频文件加入资料库
music-cli add /path/to/01\ track.m4a /path/to/02\ track.m4a

# 按 persistent ID 精确删除（推荐；不会误删同名专辑）
music-cli delete --pid 12345678901234567890 98765432109876543210 --yes

# 按专辑名删除（先预览确认！）
music-cli delete --album "Some Album"          # 预览
music-cli delete --album "Some Album" --yes    # 执行

# 删除全部幽灵条目（记录在册但文件已删）
music-cli delete --missing                     # 预览
music-cli delete --missing --yes               # 执行
```

**为什么删除默认要 `--yes`**：删除是破坏性且难以撤销的操作。
不加 `--yes` 时只打印将要删除的条目，便于先核对。

## 退出码

| 码 | 含义 |
|---|---|
| 0 | 成功 |
| 1 | 一般错误（打不开资料库、删除数不匹配、超时等） |
| 2 | 用法错误 |
| 3 | `verify` 发现幽灵条目 |

## 已知限制

- **写入依赖 AppleScript**：因为 Apple 没有公开写入 API，这是唯一可行路径。本工具已尽可能
  加固（超时、分批、pid 匹配、预览），但它仍是整个工具里唯一需要调用 Music.app 的部分。
- **`add` 的返回值不可信**：Music 是异步上报的，可能返回 `added 0` 而实际已入库。
  导入后请用 `music-cli check <专辑>` 复验，而不是只看返回值。
- **需要 Music.app 运行环境的权限**：首次调用可能触发自动化权限授权
  （系统设置 → 隐私与安全性 → 自动化）。

## 许可

MIT
