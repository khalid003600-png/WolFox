# WolFox for YouTube (iOS)

WolFox is an open-source iOS project derived from the YTKACE YouTube enhancement. The public WolFox repository contains source code, resources, build scripts, tests, and notices only. It does **not** contain an IPA, app bundle, built WolFox library, Debian package, or other built WolFox application artifact.

## Project identity and compatibility

The app display name, executable/process name, injected library, resource bundle, and optional Safari extension use the WolFox name. The host app bundle identifier remains `com.google.ios.youtube` because the tweak targets YouTube. The legacy Debian package identifier `com.wolfox.ytkace`, existing `YTKACE.Preference.*` keys, and historical storage/backup identifiers are retained where needed for upgrade and data compatibility. These are internal compatibility values, not user-facing branding.

The old developer/profile section was removed from the app settings. Source attribution and third-party notices remain in `LICENSE` and `THIRD_PARTY_NOTICES.md`.

## Features

- Downloads for videos, audio, Shorts and playlists, with an in-app library.
- SponsorBlock, background playback, Picture in Picture, playback and queue controls.
- Interface customization, tab editing, OLED mode and other YouTube enhancements.
- Optional Safari extension named **Open in WolFox**.

Feature support depends on the exact YouTube and iOS versions.

## Build the library locally

Build with Theos and an iOS SDK:

```sh
export THEOS=/path/to/theos
bash Scripts/build.sh
```

The build writes the arm64 library to `dist/WolFox.dylib`. The repository intentionally excludes generated binaries and prebuilt FFmpeg static libraries. To build locally, first provide arm64 FFmpeg static libraries under `Vendor/FFmpeg/lib/` (or build them from the FFmpeg source with `Scripts/build-ffmpeg.sh`), and retain the included LGPL notices.

## Build a local no-jailbreak IPA

For an extracted YouTube app you are legally allowed to modify:

```sh
bash Scripts/build-ipa.sh /path/to/YouTube.app dist/WolFox.dylib /path/to/WolFox-YouTube-1.2.1.ipa
```

For an existing decrypted YouTube IPA:

```sh
bash Scripts/sideload-repack.sh /path/to/YouTube.ipa dist/WolFox.dylib /path/to/WolFox-YouTube-1.2.1.ipa
```

The repacker changes the executable and app-folder names to WolFox, replaces a prior `YTKACE.dylib` load with `@rpath/WolFox.dylib`, and inserts `WolFox.bundle`. It verifies that the host app bundle identifier remains `com.google.ios.youtube`. The scripts only build locally; no app or IPA is committed to this repository.

The build scripts use local ad-hoc signing only; they do not provide an Apple signing certificate or provisioning profile. Re-sign the locally built IPA with ESign or another sideloading tool before installation. The executable rename is compatibility-sensitive and still needs installation and launch testing on a device.

### Optional Safari extension

The extension build requires macOS and Xcode's iOS SDK:

```sh
bash Scripts/build-safari-extension.sh /path/to/output
```

It produces `OpenInWolFox.appex` with the executable name `OpenInWolFox`.

### GitHub Actions

The workflows are definitions only; they have not been run as part of this source upload. Their outputs are not committed to the repository. Building an IPA, library, or package through Actions is separate from publishing this source-only repository.

## Source and licenses

WolFox is based on YTKACE. The upstream MIT license, attribution, and third-party notices remain in this project. WolFox is not affiliated with Google or YouTube.

Project repository: <https://github.com/khalid003600-png/WolFox>
