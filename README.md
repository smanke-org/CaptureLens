# CaptureLens

Screenshots pile up on the Desktop with names like "Screenshot 2026-10-24 at 13.05.12", and finding the one you
need means opening them one by one. CaptureLens keeps every capture in a library instead. Each capture is
named from what's in it ("Quarterly Revenue Chart", "Xcode Build Error") by Apple Intelligence on your Mac, and
you can find it again by its name, the date, its tags or notes, or any text that appears in the picture.

CaptureLens also:
- **Captures** the whole screen, one window (even where others cover it), an area you drag out, or a frame of an
  exact size, now or after a countdown, each from its own preset and shortcut.
- **Keeps the pointer separate**, so you can show, hide, move or resize it after the capture.
- **Lets you select and copy text** right in the picture, with macOS's own Live Text.
- **Organizes** with tags, favorites and notes ("More Info"), and filters by date, type, tag, app or website in
  one click.
- **Remembers where a capture came from**: the app, the window, and in a browser, the web page.
- **Keeps the library private**: encrypted on your Mac, optionally locked behind Touch ID, and synced between
  your Macs end-to-end encrypted through iCloud.

## Download

**[⬇ Download CaptureLens.dmg](https://github.com/smanke-org/CaptureLens/releases/latest/download/CaptureLens.dmg)**

1. Open the disk image and drag **CaptureLens** to **Applications**.
2. Open CaptureLens. Its icon appears in the menu bar.
3. Allow **Screen Recording** when asked (System Settings › Privacy & Security › Screen & System Audio Recording).
   CaptureLens needs it to capture the screen.

Requires macOS 26 or later. Automatic names need Apple Intelligence turned on.

## Use it

| Shortcut | What it does |
|---|---|
| ⌥⇧⌘4 | Capture: click a window, or drag over an area (Return for the whole screen) |
| ⌥⇧⌘3 | Capture the whole screen |
| ⌥⇧⌘5 | Capture a window |
| ⌥⇧⌘L | Open the library |

Every capture goes into the library, and onto the clipboard if you like. A preview slides into the corner:
click it to open the capture, or drag it straight into another app. To open every capture in the library right
away, choose Open Captures in Library in the menu bar menu; hold ⌥ while clicking or dragging to open just one.

Presets are saved ways to capture, each with its own shortcut: what to capture, a countdown, an exact size, and
whether to copy. Make and change them in Settings › Presets.

In the library, search finds words in names, tags, notes and the text in the pictures. It also understands
`tag:work`, `app:safari`, `site:example.com` and dates such as `yesterday` or `March 3`.

Actions can also be run from a URL, for ToolHUD, Shortcuts or scripts: `capturelens://capture`, `screen`,
`window`, `area`, `recapture`, `library` and `preset/<name>` (for example `open capturelens://screen`).

## Privacy

Naming captures and reading their text run entirely on your Mac. CaptureLens has no account, analytics or
tracking, and nothing is ever sent to the developer. The only connection it makes on its own is to GitHub, to
check for updates.

The library is encrypted on your Mac with AES-256, using a key kept in your keychain, and can require Touch ID
or your password to open. Sync is end-to-end encrypted: with "Sync settings with your other Macs" on, your
settings and library are sealed on your Mac before they reach iCloud, using a key that only your sync
passphrase unlocks. Neither Apple nor the developer can read what's synced.

## Updates

CaptureLens checks for new versions once a day, or as often as you choose in Settings. In Settings › General you
choose whether it installs them automatically when you're not using it, asks first, or doesn't check.

## Build from source

The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen).
Sync uses CloudKit, so builds are signed with a provisioning profile (Xcode signed in to the developer account).

```bash
xcodegen generate   # CaptureLens.xcodeproj: Debug, Release (GitHub) and AppStore (sandboxed) builds
./build_app.sh      # universal, Developer ID–signed .build/app/CaptureLens.app
./install.sh        # copy to /Applications and launch
swift test          # library, search, naming, encryption and sync tests
```

Release: `./release.sh X.Y.Z` (notarizes, makes the DMG, tags and publishes the GitHub release).

## License

© 2026 Steve Manke. All rights reserved.
