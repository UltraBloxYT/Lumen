# Lumen

A lightweight macOS overlay and recorder (replay buffer, recording, screenshots). It uses ScreenCaptureKit
and never injects into games. Black and white UI. Supports macOS 13+, Apple Silicon and Intel.

## Build
    ./build.sh

Needs the Xcode Command Line Tools (`xcode-select --install`). Output: `build/Lumen.app` (universal, ad-hoc signed).

## Layout
- `Sources/main.swift`  the whole app
- `Tools/make-icon.swift`  draws the icon (white moon on black) into an .iconset
- `build.sh`  builds the universal app bundle

Captures save to `~/Movies/Lumen` and `~/Pictures/Lumen`.
