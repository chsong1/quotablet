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

Quotablet lives in the menu bar as a window-style `MenuBarExtra`. The label shows one item for each provider that OMP reports on. An item is the provider's logo and the share of that provider's combined limit that is used. The panel groups quotas by status, and a collapsed **All quotas** list holds every report that OMP returned.

**Collection cadence.** On launch the app loads any saved snapshot, then refreshes immediately. It refreshes again every 5 minutes and whenever you press the panel refresh control. A separate presentation clock ticks every 30 seconds so age and reset countdowns move without another OMP call.

**Freshness.** Provider age is measured from each report's `fetchedAt`. Age of 15 minutes or more is treated as stale by app policy, and the menu bar draws the percentage of a stale provider in the secondary label color. A failed refresh keeps the last successful snapshot and surfaces the error. A successful empty snapshot replaces the previous reports with none. Missing remaining values stay unknown; unknown is never treated as zero remaining. When a reset time has already passed, the UI says to recheck. That does not claim the quota has been replenished.

**Menu bar.** The label has one item for each provider that has a report. An item is the provider's logo, then the share of the provider's combined limit that is used, as whole digits and a percent sign such as `79%`. The text uses the 12 pt medium system font with monospaced digits. The order is fixed so that positions stay learnable: Claude, Codex, Grok, Cursor, then any other provider by id in alphabetical order. A provider with no usable figure shows `–`. A provider whose data is stale draws its percentage in the secondary label color, and its logo does not change. With no snapshot or no provider, the label shows the `gauge.with.dots.needle.33percent` symbol.

VoiceOver and the hover text of the menu bar item list the providers in the same order and end with the freshness text, as in `Claude 79% used across 5 accounts; Codex 94% used across 3 accounts; Grok 1% used, 1 account; Cursor 100% used, 1 account. Provider data under 1m old`. When only some accounts have a usable figure, the text says how many the figure covers, as in `Claude 74% used across 4 of 5 accounts`.

**Combined usage.** The figure treats all accounts of a provider as one pool. If you have five Codex accounts, their five limits together are 100%, and the figure is how much of that has been used. It is the share used and not the share left.

Each account contributes one quota, its capacity quota, which is the quota that stands for the account's total limit. Quotablet picks it in three steps.

1. The candidates are the account's quotas that report a used share, except scoped quotas. A quota is scoped when its label ends in a parenthetical that names something narrower than its window, so `Claude 7 Day (Fable)` is scoped. A parenthetical that only restates the window, such as `Grok Build (Weekly)`, does not scope the quota.
2. The longest window wins. A window's length is the duration OMP reports. When OMP reports none, a window labeled `Hourly`, `Daily`, `Weekly`, or `Monthly` counts as 1 hour, 1 day, 7 days, or 30 days. Any other window without a duration ranks shortest.
3. Windows of equal length go to the quota with the highest used share, then to the fixed order of provider, account, window, and quota label.

An account with no such quota is not measured. It counts toward the number of accounts and not toward the figure.

The figure of a provider comes from the capacity quotas of its measured accounts. When every one of them has a positive limit and they all share one unit other than percent, such as USD, the limits are pooled. Each account contributes its used share, capped at 100%, times its limit, and the figure is that total over the sum of the limits. An account that overspent its limit therefore counts as full, not more. Otherwise the figure is the mean of the accounts' used shares, so each account is one equal part of 100%.

**Provider logos.** Quotablet ships no logos, and this repository holds none. The MIT license covers Quotablet's code and not anyone's trademarks. Anthropic and xAI require written permission before another product uses their logos, and OpenAI's logo files are not transferable. So you install the files on your own Mac from the official brand pages, and Quotablet reads them at run time.

- [Anthropic](https://www.anthropic.com/legal/trademark-guidelines)
- [OpenAI](https://openai.com/brand/)
- [xAI](https://x.ai/legal/brand-guidelines)
- [Cursor](https://cursor.com/brand)

Put the files in `~/Library/Application Support/Quotablet/Logos/`, beside `settings.json`. Quotablet only reads that directory and never writes to it. For a provider id such as `anthropic`, `openai-codex`, `xai-oauth`, or `cursor`, Quotablet takes the first of these files that exists.

- On a dark menu bar: `<id>-on-dark.pdf`, `<id>-on-dark.png`, `<id>.pdf`, then `<id>.png`.
- On a light menu bar: `<id>-on-light.pdf`, `<id>-on-light.png`, `<id>.pdf`, then `<id>.png`.

The id is the provider id in lowercase. A PDF stays sharp at every scale, so prefer it. Quotablet picks the variant each time the menu bar image is drawn, so a change of the menu bar's appearance switches the file.

Quotablet draws each logo exactly as its file provides it. It never recolors, tints, dims, masks, outlines, shadows, rotates, or stretches a logo, and a stale provider's logo looks like a fresh one. It does trim the transparent margin around the artwork, which does not change the mark, because some official files are about half margin. It then scales the artwork to a height of 15 pt with its aspect ratio kept and centers it vertically in the menu bar. The menu bar image is not a template image, so a logo keeps its colors. The percentages use the system label colors and follow the menu bar's appearance. Keep logo files out of this repository. The tests draw invented shapes.

Quotablet loads each file once and keeps it in memory. On each 30 second presentation tick it checks the modification date of the `Logos` directory and loads the files again when that date has changed. Adding, removing, or renaming a file changes the date. Overwriting a file in place does not, so remove the old file first or restart Quotablet. There is no file watcher.

**Letter badge.** A provider with no usable logo file shows a badge in place of the logo. The badge is a 14 pt rounded square with the provider's initial in a heavy system font. The letters are `C` for Claude, `O` for Codex, `G` for Grok, and `U` for Cursor. For a provider that Quotablet does not know, the panel shows the raw provider id and the badge shows its first letter in capitals. The badge is drawn in the system label color. It fills from the bottom as the provider's combined limit is used, and the letter is cut out of it so that the letter stays readable over both the used and the unused part. The fill covers the used share of the badge's area, not of its height, so the rounded corners do not skew the reading. A badge has one of three looks.

- **Fresh.** The unused part is drawn at 30% of the label color's opacity and the used part at the full label color.
- **Stale.** Provider data is 15 minutes old or older. The badge dims and 1 pt stripes cross the filled part. The stripes keep an exhausted stale provider from looking like a fresh, unused one. An unknown badge dims by the same proportion when its data is stale. It has no fill, so it has no stripes.
- **Unknown.** No account of the provider reports a usable share. The badge is a 1 pt outline with a solid letter and no fill, so it never reads as 0% or 100%.

**No pins.** Earlier builds pinned quotas to the menu bar. The menu bar now follows providers, so pins, the pin buttons, the summary card, and the petal chart are gone. A `pinnedQuotas` key in an old `settings.json` is ignored and is dropped the next time Quotablet saves its settings.

**Needs attention.** The status groups below list the quotas that need attention. A quota needs attention when OMP reports its status as exhausted or near limit, or when its remaining amount is zero or below. A quota that OMP reports as available, or without a recognized status, needs attention only when its remaining amount is zero or below. Quotablet adds no percentage threshold and no setting.

Quotablet ranks quotas with one comparator, and the first difference decides.

1. An exhausted quota comes before a near-limit quota.
2. The quota with the smaller remaining share comes first. A quota with no usable usage figure comes after the ones that have one. An exhausted quota counts as having nothing left, so this step never separates two exhausted quotas.
3. The quota that resets sooner comes first. A quota with no reset time comes last.
4. Quotas that still tie keep a fixed order of provider, account, window, and quota label.

So exhausted quotas come first with the soonest reset on top, and near-limit quotas follow with the least remaining on top.

**Status groups.** The panel opens with up to three groups. A group appears only when it has rows, and its header counts rows, not accounts or quotas.

- **Exhausted** lists quotas that ran out, under a red header. The large figure is the time until the quota resets, such as `9h 21m`. A reset time in the past reads `Recheck`, and a missing reset time reads a dash. The header caption is `resets in`.
- **Near limit** lists quotas that OMP reports as near limit, under an orange header. The large figure is the share left, such as `3%`. A small line under it shows the reset, such as `resets 4d 14h`. The header caption is `left`.
- **OK** lists accounts with no quota that needs attention, under a green header. Each row shows the account's quota with the least left, a thin bar for that share, and the percent left. Accounts are ordered most used first. The header caption is `left`. The group starts open, a chevron collapses it, and Quotablet does not save that choice.

Every row is one line. A status symbol comes first, so color is never the only signal. The account tag follows, such as `C1` for Claude Account 1 or `U1` for Cursor Account 1. After the tag come the quota labels. A quota with a window length shows the length, so `Claude 7 Day` reads `7d` and `Claude 7 Day (Fable)` reads `7d Fable`. A parenthetical that only restates the window is dropped, so `Grok Build (Weekly)` reads `7d`. A parenthetical restates the window when it equals the window label or is `Daily`, `Weekly`, `Monthly`, or `Hourly`, in any letter case. A quota without a window length keeps its label, such as `Cursor Models`. A row whose report is stale adds `Stale` in orange. Text, symbols, and bars use their own shade of each color in the light and dark appearances, so they stay readable in both.

Quotas of one account share a row when they need the same attention and reset in the same minute. Cursor Account 1 can show `Cursor Models, Other Models` once, with one countdown. Quotas that reset at different times get their own rows, so a different reset is never hidden. Rows follow the ranking above, so the soonest reset leads Exhausted and the least remaining leads Near limit.

An account can sit under Exhausted while some of its quotas still work. OMP reports each quota on its own, and the data does not say which quotas cover the whole account. A row therefore names the quota that ran out and never says the account is blocked. An account with an exhausted 7-day quota and a healthy 5-hour quota appears only under Exhausted, on a row labeled `7d`. An account with quotas in both attention states has a row in each of the two groups. An account appears under OK only when none of its quotas needs attention.

VoiceOver reads each group header as a heading, such as `Exhausted, 2`, and each row as one element, such as `Claude Account 1, 7 Day exhausted, resets in 9h 21m`, `Codex Account 1, 7 days near limit, 3% left, resets in 4d 14h`, or `Claude Account 2, OK, 7 Day, 22% left`. A spoken row keeps the parenthetical of the quota label, as in `Grok Account 1, OK, Grok Build (Weekly), 40% left`. No window length sits beside the label, so the parenthetical repeats nothing. A row uses the account label from the eye button, so a revealed identifier replaces `Account 1`. A stale row ends with `stale`.

**All quotas.** Below the groups, a collapsed **All quotas · N** list holds one account section for each report that OMP returned. N counts quotas. Each section shows the remaining amount and the reset time of every quota. An account that reports no quotas appears only in this list. Each account section gets a second header line when that account has a quota that needs attention. The line names the account's top-ranked quota, such as `Claude 7 Day exhausted · resets in 18h 5m` in red or `Claude 5 Hour near limit · resets in 2h 10m` in orange. Account sections keep the order OMP sends.

The header line names a quota and never says that the account is blocked. OMP reports each quota on its own, and some quotas, such as `7 Day (Fable)`, cover only certain models. The data does not say which quotas cover the whole account. So Quotablet reports the quota that ran out and leaves the conclusion to you.

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

The directory holds `settings.json` and `usage-snapshot.json`. `settings.json` stores the OMP executable override. A `pinnedQuotas` or `pinnedQuota` key from an earlier build is ignored. The directory and files have owner-only permissions. Writes use atomic temporary files renamed into place. The `Logos` directory described above is yours to create and fill, and Quotablet only reads it.

That Application Support cache is private app state. It is separate from the repository's ignored `.local/` directory, which is only for local developer build and artifact output such as DerivedData.

## Privacy

Keep authentication tokens, account identifiers, real usage snapshots, logs, and signing private keys out of this repository. Use synthetic accounts and values in examples, tests, and public samples. Even aliased screenshots can reveal real usage patterns. Redacted CLI output can still leak account prefixes and limits.

Ignore rules do not remove files that are already tracked. Review the files included in each commit before publishing.

## License

[MIT](LICENSE). Copyright 2026 chsong1.
