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

Quotablet lives in the menu bar as a window-style `MenuBarExtra`. The label shows one badge for each quota you pin. The panel lists every report returned by OMP.

**Collection cadence.** On launch the app loads any saved snapshot, then refreshes immediately. It refreshes again every 5 minutes and whenever you press the panel refresh control. A separate presentation clock ticks every 30 seconds so age and reset countdowns move without another OMP call.

**Freshness.** Provider age is measured from each report's `fetchedAt`. Age of 15 minutes or more is treated as stale by app policy, and the badge for a stale quota changes look. A failed refresh keeps the last successful snapshot and surfaces the error. A successful empty snapshot replaces the previous reports with none. Missing remaining values stay unknown; unknown is never treated as zero remaining. When a reset time has already passed, the UI says to recheck. That does not claim the quota has been replenished.

**Menu bar badges.** Press the pin button on a quota row to add that quota to the menu bar. Press it again to remove the quota. Each pinned quota gets one badge, in the order you pinned them. Quotablet draws all badges into one template image, so the menu bar tints them to match its appearance and they stay sharp at every display scale.

A badge is a 14 pt rounded square with the provider's initial in a heavy system font. The letters are `C` for Claude, `O` for Codex, `G` for Grok, and `U` for Cursor. For a provider that Quotablet does not know, the panel shows the raw provider id and the badge shows its first letter in capitals. The badge fills from the bottom as the quota is used. The fill covers the used share of the badge's area, not of its height, so the rounded corners do not skew the reading. The letter is cut out of the badge and stays readable over both the used and the unused part.

A badge shows a small account number only when the number tells accounts apart. If a provider's pinned quotas come from two or more accounts, each of those badges shows the number of its account. The number matches the `N` in the panel's `Account N` label. If every pinned quota of a provider comes from one account, none of those badges shows a number. A missing pin never shows a number and does not count as an account. With nothing pinned, the menu bar shows the first quota in provider order, and the panel marks it as selected by default. With no quota available, the menu bar shows the `gauge.with.dots.needle.33percent` symbol.

A badge has one of four looks.

- **Fresh.** The unused part is drawn at 30% opacity and the used part at full opacity.
- **Stale.** Provider data is 15 minutes old or older. The badge dims and 1 pt stripes cross the filled part. The stripes keep an exhausted stale quota from looking like a fresh, unused one. An unknown badge dims by the same proportion when its data is stale. It has no fill, so it has no stripes.
- **Unknown.** The quota has no usable usage figure. The badge is a 1 pt outline with a solid letter and no fill, so it never reads as 0% or 100%.
- **Missing.** The pinned key is absent from the current snapshot or matches more than one quota. The badge keeps its position as a dashed outline with a dimmed letter. Quotablet does not substitute another quota. In the summary card's row list, the row says "Pinned quota unavailable" and has a **Remove** button. In the petal chart, the legend row says "Unavailable" and has the same button. VoiceOver reads "Pinned quota unavailable" in both layouts.

**Summary card.** The card at the top of the panel repeats your pins. It shows one row per quota when it holds 1 or 2 quotas, or more than 8. With 3 to 8 pinned quotas it draws a petal chart and a legend instead, so 8 pins take 200 pt of height and the card does not grow with each pin.

The chart has one petal per pin, in the order you pinned them. The first petal points at 12 o'clock and the others follow clockwise. Each petal fills outward from the center hole over a pale track of its own color. The fill covers the used share of the petal's area, not of its length, because a petal widens outward and its length would skew the reading. Each petal carries the badge's letter and account number. When the used share changes, the fill grows or shrinks over 0.35 seconds.

A petal has the same four looks as a badge.

- **Fresh.** The track holds the whole petal at 22% opacity. The fill covers the used share in the petal's color, and the letter is white.
- **Stale.** The fill is desaturated, drawn at 55% opacity, and crossed by 1.5 pt horizontal stripes. The track stays and the letter stays white.
- **Unknown.** The petal has no track and no fill. It is a 1.5 pt outline in the petal's color, and the letter takes that color. Both dim by the same proportion when the data is stale.
- **Missing.** The petal has no fill. It is a dashed 1.5 pt outline and a letter in gray. The legend row says "Unavailable" and keeps the **Remove** button.

Petal colors come from a fixed list, assigned in pin order: blue, orange, green, purple, pink, teal, indigo, and yellow. A color only tells petals apart. The letters and the legend identify the quota.

The legend sits to the right of the chart with one row per pin, in pin order. A row shows a dot in the petal's color, the letter and account number, the quota label, and the remaining amount. A stale row adds "Stale" in orange after the label. One line under the chart and legend shows the age of the oldest report among the pins. VoiceOver reads the chart as one element, "Usage chart, N pinned quotas". It reads each legend row as one element with the same text as the menu bar label, plus "stale" for a stale row.

**No company logos.** Badges and petals use a system-font letter on a system shape, and petal colors come from the generic list above, never from a provider's brand colors. Quotablet does not draw, trace, embed, or download any company logo. Anthropic, OpenAI, and xAI publish brand rules that forbid altering their logos, and a usage gauge alters a logo by filling and recoloring it. This repository is also public.

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

The directory holds `settings.json` and `usage-snapshot.json`. `settings.json` stores the OMP executable override and the pinned quota keys in menu bar order. A settings file without pinned keys means nothing is pinned, and a `pinnedQuota` key from an earlier build is ignored. The directory and files have owner-only permissions. Writes use atomic temporary files renamed into place.

That Application Support cache is private app state. It is separate from the repository's ignored `.local/` directory, which is only for local developer build and artifact output such as DerivedData.

## Privacy

Keep authentication tokens, account identifiers, real usage snapshots, logs, and signing private keys out of this repository. Use synthetic accounts and values in examples, tests, and public samples. Even aliased screenshots can reveal real usage patterns. Redacted CLI output can still leak account prefixes and limits.

Ignore rules do not remove files that are already tracked. Review the files included in each commit before publishing.

## License

[MIT](LICENSE). Copyright 2026 chsong1.
