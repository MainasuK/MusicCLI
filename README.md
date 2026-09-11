# MusicCLI

[![Platform](https://img.shields.io/badge/platform-macOS%2010.13%2B-blue)](#requirements)
[![Language](https://img.shields.io/badge/language-Objective--C-orange)](#)

A command-line interface to the macOS Music.app library: **native reads + one hardened write path**.

## Why this exists

Driving the Music library with AppleScript (`osascript`) is fragile in practice:

- **Unreliable queries** — `whose album is "..."` works one moment and fails the next; while the
  library is busy or reindexing it returns `-1728` ("can't get").
- **Bulk operations hang** — looping over hundreds of deletions can stall indefinitely, with no
  timeout protection.
- **`add` reports asynchronously** — `return "added " & (count of added)` can come back as
  `added 0` even though the tracks *were* imported, which is easy to misread as a failure.

The catch: **Apple ships no official write API.**

| Route | Status |
|---|---|
| `iTunesLibrary.framework` | Only `libraryWithAPIVersion:error:`, `artworkForMediaFile:`, `reloadData`, `unloadData` — **no add / remove** |
| `MediaLibrary.framework` | Read-only as well |
| `Music Library.musiclibrary/Library.musicdb` | Private `hfma` format (not SQLite) — can't be edited directly |

So this tool is deliberately split:

- **Reads** — everything goes through `iTunesLibrary.framework`: native, fast, stable, no AppleScript.
- **Writes** — `add` / `delete` have exactly one available route (AppleScript), so it is **confined to
  this single place** and hardened with: exact persistent-ID matching, batching, timeouts, preview by
  default (`--yes` required), and a verify step afterwards.

> If you automate this library: **read with this tool, and keep deletions inside this tool.**
> Don't scatter AppleScript through your application code.

## Requirements

- macOS 10.13 or later (needs `iTunesLibrary.framework`)
- Music.app installed and launched at least once
- Xcode Command Line Tools to build (`xcode-select --install`)

## Build

```bash
make            # produces build/music-cli
make install    # installs to /usr/local/bin/music-cli (override with PREFIX=...)
make test       # read-only self-check (never modifies the library)
```

Or compile directly:

```bash
clang -fobjc-arc -framework Foundation -framework iTunesLibrary \
      -o build/music-cli Sources/main.m
```

## Commands

### Reads (native, safe)

```bash
# Export the whole library as JSONL (one media item per line)
music-cli dump library.jsonl

# Fuzzy search across album / title / artist
music-cli find "Hatsune Miku"
music-cli find "Hatsune Miku" --json     # JSON output

# Look up a single item by persistent ID
music-cli info 12345678901234567890

# Inspect one album: track count, file paths, and whether each file exists
music-cli check "Some Album"

# Post-import gate: count "recorded but file is gone" ghosts; exits 3 if any
music-cli verify
```

`check` and `verify` **verify the files on disk**, not just the database. The Music library can hold
*ghost* entries — rows whose files were deleted — so trusting the database alone makes an album look
"already present" when it isn't.

### Writes (preview by default; `--yes` to execute)

```bash
# Add audio files to the library
music-cli add /path/to/01\ track.m4a /path/to/02\ track.m4a

# Delete by persistent ID (preferred — cannot hit a same-named album by accident)
music-cli delete --pid 12345678901234567890 98765432109876543210 --yes

# Delete by album name (review the preview first!)
music-cli delete --album "Some Album"          # preview
music-cli delete --album "Some Album" --yes    # execute

# Delete every ghost entry (recorded but file missing)
music-cli delete --missing                     # preview
music-cli delete --missing --yes               # execute
```

**Why `--yes` is required for deletion**: deleting is destructive and hard to undo. Without `--yes`
the command only prints what it *would* delete, so you can review it first.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | General error (library won't open, deleted count mismatch, timeout, …) |
| 2 | Usage error |
| 3 | `verify` found ghost entries |

## Known limitations

- **Writes depend on AppleScript.** Because Apple exposes no public write API, this is the only
  viable route. The tool hardens it as much as possible (timeouts, batching, persistent-ID matching,
  preview), but it remains the one part that has to talk to Music.app.
- **`add`'s return value is not trustworthy.** Music reports asynchronously and may return
  `added 0` while the tracks did land. Verify with `music-cli check <album>` instead of trusting
  the count.
- **Automation permission may be required.** The first write can trigger a macOS automation consent
  prompt (System Settings → Privacy & Security → Automation).
- **Persistent IDs come in two formats.** `iTunesLibrary.framework` reports them as *decimal*
  (`unsignedLongLongValue`), while AppleScript's `persistent ID` property is a *16-digit hex string*.
  Passing decimal straight to AppleScript matches nothing and — worse — fails silently by deleting
  zero rows. `delete --pid` normalizes automatically (and accepts either form), and its preview
  prints both representations so you can confirm before executing.

## License

MIT
