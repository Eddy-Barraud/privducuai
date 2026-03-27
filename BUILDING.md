# Building Privducai

This document explains the available build options for Privducai.

## Using Shell Scripts

### Build Only
```bash
./scripts/build.sh [Configuration]
```
- `Configuration`: `Debug` (default) or `Release`
- Example: `./scripts/build.sh Release`

### Build and Run
```bash
./scripts/build-and-run.sh [Configuration]
```
- Builds the project and launches the app automatically
- Example: `./scripts/build-and-run.sh Debug`

## Using VS Code Tasks

Press `⌘⇧B` to access the build task menu or use **Terminal → Run Task** and select:

- **xcode: Build (Debug)** — Default build task (recommended for development)
- **xcode: Build (Release)** — Production build
- **xcode: Clean** — Clean build artifacts

## Using Xcode

```bash
open Privducai.xcodeproj
```

Then press `⌘R` to build and run in Xcode.

## Command Line (Manual)

```bash
xcodebuild -project Privducai.xcodeproj \
  -scheme Privducai \
  -configuration Debug \
  -destination "generic/platform=macOS" \
  build
```
