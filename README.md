# LiteP — iOS 12 Backported Lite-Mornye

LiteP is a lightweight, native UIKit music app for **iOS 12** (built for the iPad mini 2).
It is a fork of [**Mornye**](https://github.com/mornyeapp/Mornye) by the Mornye developers: it
reuses Mornye's Rust backend for repository extensions, search and downloads, and replaces the
Flutter UI with a small native one so it runs on devices Mornye no longer supports.

All credit for the backend, the extension system and the extension ecosystem goes to the
[Mornye project](https://github.com/mornyeapp/Mornye). LiteP is an unofficial fork; please don't
report LiteP issues to Mornye.

## Features

- **Extensions**: add Mornye repository URLs; install, update, enable and delete extensions.
- **Search**: Songs / Artists / Albums, artist pages with popular songs and discography, full album tracklists.
- **Downloads**: one-tap downloads with a default extension and quality, multi-select delete,
  tags and cover written into every file, Opus/WebM converted to AAC `.m4a` automatically.
- **Library**: Playlists, Artists, Albums and Songs; playlists with reorder; edit song info; multi-select delete.
- **Player**: mini player, full player with shuffle and repeat, Up Next queue (Play next / Add to queue),
  crossfade (1–8 s) or gapless playback, lock-screen controls.
- Dark, Spotify-style look without blur or heavy animation, to stay light on 1 GB devices.

Not included: lyrics, widgets, casting, Discord, browser verification. FFmpeg is an audio-only build that only remuxes and decrypts (`-c copy`); it does not re-encode.

## Install

1. Download `LiteP-0.5.2-unsigned.ipa` from [Releases](../../releases).
2. Jailbroken with AppSync Unified: fake-sign (`ldid -S`) and install, e.g. with `ideviceinstaller`.
   Otherwise sideload with [Sideloadly](https://sideloadly.io) using your Apple ID.

## Build

On macOS with Xcode 16 and rustup:

```sh
git submodule update --init
bash scripts/build_backend.sh
bash scripts/build_opus.sh
brew install xcodegen && xcodegen generate
xcodebuild -project MornyeLite.xcodeproj -scheme MornyeLite -sdk iphoneos CODE_SIGNING_ALLOWED=NO build
```

The app reports itself to extensions as Mornye 5.4.5 (`MornyeCompatVersion` in `App/Info.plist`),
the vendored backend version. `App/Sources/CoreBackend.swift` is adapted from Mornye's
`ios/Runner/CoreBackend.swift` (Flutter, CryptoKit and FFmpegKit removed).

## License

GPL-3.0, same as Mornye (see `COPYING`). Mornye is © its contributors; LiteP changes are © naufalardh.
