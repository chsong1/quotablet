# Quotablet

Quotablet is a personal SwiftUI menu bar app for macOS. It shows AI account usage limits returned by a local `omp usage --json` run and caches the last successful snapshot privately.

Build with macOS 14 or later and Xcode 16 or later with Swift 6. Usage collection requires an already installed, authenticated OMP CLI. The app does not log in for you and does not ship its own credentials.

This repository ships the menu bar app only. It has no WidgetKit extension, no Quotablet server, no auto-updater, and no notarized release packaging.

## Build and run

The Xcode project signs locally with ad-hoc identity `-` and manual signing. No Apple team or certificates are required.

From the repository root:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project Quotablet.xcodeproj \
  -scheme Quotablet \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .local/DerivedData \
  build
```

```sh
open .local/DerivedData/Build/Products/Debug/Quotablet.app
```

Run the shared `Quotablet` scheme tests the same way:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project Quotablet.xcodeproj \
  -scheme Quotablet \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .local/DerivedData \
  test
```

Set `DEVELOPER_DIR` on each command. Keep DerivedData under the ignored `.local/` tree so build products stay out of git. These commands target Apple silicon. The app has been built and run with Xcode 27.0.

## What it does

Quotablet lives in the menu bar as a window-style `MenuBarExtra`. The label summarizes one quota. The panel lists every report returned by OMP.

**Collection cadence.** On launch the app loads any saved snapshot, then refreshes immediately. It refreshes again every 5 minutes and whenever you press the panel refresh control. A separate presentation clock ticks every 30 seconds so age and reset countdowns move without another OMP call.

**Freshness.** Provider age is measured from each report's `fetchedAt`. Age of 15 minutes or more is treated as stale by app policy. A failed refresh keeps the last successful snapshot and surfaces the error. A successful empty snapshot replaces the previous reports with none. Missing remaining values stay unknown; unknown is never treated as zero remaining. When a reset time has already passed, the UI says to recheck. That does not claim the quota has been replenished.

**Menu bar pin.** You can pin one stable provider, account, limit, and window key for the menu bar summary. If that key is missing from the current snapshot, the pin stays unavailable. Quotablet does not silently substitute another quota. Pinning one row is not a statement about global provider availability.

**Account labels.** Account names and identifiers stay hidden by default and show as `Account N` per provider. Reveal is session-only and is not written to disk.

**OMP executable.** Automatic discovery checks, in order:

1. `~/.local/bin/omp`
2. `/opt/homebrew/bin/omp`
3. `/usr/local/bin/omp`
4. `/opt/local/bin/omp`
5. `/usr/bin/omp`
6. `/bin/omp`

**Choose OMP…** stores an explicit path to a trusted executable. If that override is missing or not executable, refresh fails with a configured-path error until you pick another file or press **Automatic**, which clears the override and restores discovery. Quotablet starts the chosen binary directly with arguments `usage --json`. It does not run a shell and does not perform its own OMP authentication. OMP itself may contact provider APIs or a configured authentication broker over the network.

## Local data

Runtime settings and the last successful snapshot live under:

`~/Library/Application Support/Quotablet`

The directory holds `settings.json` and `usage-snapshot.json`. The directory and files have owner-only permissions. Writes use atomic temporary files renamed into place.

That Application Support cache is private app state. It is separate from the repository's ignored `.local/` directory, which is only for local developer build and artifact output such as DerivedData.

## Privacy

Keep authentication tokens, account identifiers, real usage snapshots, logs, and signing private keys out of this repository. Use synthetic accounts and values in examples, tests, and public samples. Even aliased screenshots can reveal real usage patterns. Redacted CLI output can still leak account prefixes and limits.

Ignore rules do not remove files that are already tracked. Review the files included in each commit before publishing.

## License

[MIT](LICENSE). Copyright 2026 chsong1.
