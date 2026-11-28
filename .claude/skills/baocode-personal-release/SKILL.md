---
name: baocode-personal-release
description: >-
  Use ONLY when the user explicitly requests bumping the personal build number, building
  local macOS/Windows installers, signing the personal update manifest (latest.json), or
  publishing a personal-channel GitHub Release for payAgain/baocode.
---

# BaoCode Personal Channel Release

Execute this runbook only when explicitly requested by the user. Full specification: [../../docs/personal-updates.md](../../docs/personal-updates.md).

## Security & Scope Guardrails
- **NEVER** echo, log, display, hardcode, or commit contents of `~/.local/share/baocode-personal-signing/update-signing.key`.
- **NEVER** trigger release steps, bump versions, tag, or push to `origin`/`upstream` autonomously.
- Confirm exact target platforms with the user first (e.g., local macOS build only vs macOS + Windows, skip Linux/CI workflow if requested).

## Release Checklist

### 1. Pre-Flight Verification
1. Verify active branch (`personal/main` or user-specified branch) and clean `git status`.
2. Ensure `flutter analyze --fatal-infos` and targeted regression tests for recent changes pass.

### 2. Bump Personal Build Number
Run from repo root (increments only build `+N` without duplicating previously published builds for the same `x.y.z`):
```sh
dart run tool/bump_version.dart --personal
```
Review changes in `pubspec.yaml` and `lib/update/version.dart`, then commit (`chore(release): prepare personal BaoCode <x.y.z>+<build>`).

### 3. Build Installers Locally
- **macOS** (produces `build/installers/BaoCode-<x.y.z>-mac-{arm64,x64}.zip` and `.dmg`):
  ```sh
  dart run tool/build_macos.dart
  ```
- **Windows** (requires Inno Setup, produces `BaoCode-<x.y.z>-setup.exe`):
  ```sh
  dart run tool/build_windows.dart
  ```

### 4. Sign Personal Update Manifest
Replace `<ver>` with `pubspec.yaml` version (`x.y.z`), adding `--macos-x64` / `--dmg-x64` / `--windows-x64` if built:
```sh
BAOCODE_UPDATE_SIGNING_KEY="$HOME/.local/share/baocode-personal-signing/update-signing.key" \
  dart run tool/release_manifest.dart --personal \
  --macos-arm64 "build/installers/BaoCode-<ver>-mac-arm64.zip" \
  --dmg-arm64 "build/installers/BaoCode-<ver>-mac-arm64.dmg" \
  --notes-zh '<concise Chinese changelog>'
```
Verify generated `build/personal-release/latest.json` (and signature output tag `v<ver>+<build>`).

### 5. Publish GitHub Release & Verify
1. Push commit and tag `v<ver>+<build>` to `origin` (`payAgain/baocode`) when instructed.
2. Create draft GitHub Release for that tag on `payAgain/baocode`, upload matching installer artifacts and `latest.json`, then publish as Latest Release.
3. Read back `https://github.com/payAgain/baocode/releases/latest/download/latest.json` to verify version, tag, SHA-256, and reachable download URLs.
