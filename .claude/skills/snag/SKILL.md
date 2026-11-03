---
name: snag
description: Drive SnagAnything, the screen capture app on this Mac, from the shell with the `snag` command: search the capture library, read the text in captures, export them as PNG files, rename, tag, pin and favorite them, import pictures, and start captures. Use when the user asks about their screenshots or captures, wants one found, exported, tagged or taken, or names SnagAnything.
---

# SnagAnything

`snag` runs commands in the SnagAnything app. Changes show in its library window at once.
If the app is closed, the command opens it in the background. If `snag` isn't on PATH, use
`/Applications/SnagAnything.app/Contents/MacOS/SnagAnything` the same way.

## Rules

- Always add `--json` and read the JSON. Exit 0 is ok; otherwise read `error.code` and
  `error.message`, and do what the message says.
- `locked`: the library lock is on. Only the person can unlock it (Touch ID or password).
  Tell them, offer `snag library open`, and never try to get around it.
- Find ids with `snag captures list --search ...`. An id is 8 characters; any unique start works.
- `captures delete` only reports what it would delete. Show the user that report and ask
  before you run it again with `--yes`: it can't be undone and removes it on every synced Mac.
- Capturing records the person's screen. Only run `capture start` when they asked for a capture.
  Most modes wait for them to pick a window or drag an area; `screen` and `again` capture at once.
- Paths may be relative in the shell; over MCP they must be absolute.
- To try something without real data, run a Debug build with `APP_STORE=/tmp/snag-test` in front.

## Main commands

| Command | Does |
| --- | --- |
| `snag status --json` | Version, library locked or not, capture count, capture under way |
| `snag captures list [--search T] [--kind K] [--tag T] [--app A] [--date today] [--limit N] --json` | Find captures (search also reads the text in pictures) |
| `snag captures show <id> --json` / `snag captures text <id> --json` | One capture's details / the text read from it |
| `snag captures export <id> --to <file-or-folder> [--original] --json` | Save as PNG (video as MP4), markup drawn in |
| `snag captures update <id> [--name N] [--notes T] [--add-tags a,b] [--remove-tags c] [--favorite] [--pinned] --json` | Change one |
| `snag capture start [--mode screen] [--preset NAME] [--delay 3] --json` | Start a capture; then `snag captures list --limit 1` |

Everything else: `snag help`, and `snag help <command>` for its options.
