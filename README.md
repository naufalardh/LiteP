# Mornye Lite

A minimal native UIKit client for iOS 12+ (built for the iPad mini 2), using the
[Mornye](https://github.com/mornyeapp/Mornye) Rust backend for repository
extensions, search and downloads.

Features:
- **Extensions**: add repository URLs, install/update/enable/remove extensions.
- **Search**: search all metadata providers or one extension.
- **Downloads**: download a result with any enabled download extension, with a quality picker.
- **Library**: lists audio files in `Documents/Music` (also visible in the Files app / iTunes file sharing).
- **Player**: background playback with lock-screen controls.

Not included: FFmpeg (format conversion), lyrics, widgets, casting, Discord.

## Install

1. Download `MornyeLite-unsigned.ipa` from the latest GitHub Actions run (artifact) or Release.
2. Sideload it with [Sideloadly](https://sideloadly.io) using your Apple ID.

## Build

On macOS with Xcode 16 and rustup:

```sh
git submodule update --init
bash scripts/build_backend.sh
brew install xcodegen && xcodegen generate
xcodebuild -project MornyeLite.xcodeproj -scheme MornyeLite -sdk iphoneos CODE_SIGNING_ALLOWED=NO build
```

`App/Sources/CoreBackend.swift` is adapted from Mornye's `ios/Runner/CoreBackend.swift`
(Flutter, CryptoKit and FFmpegKit removed).

## License

GPL-3.0, same as Mornye (see `COPYING`).
