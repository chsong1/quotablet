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

Quotablet lives in the menu bar as a window-style `MenuBarExtra`. The label shows one item for each provider that OMP reports on. An item is the provider's logo and the share of that provider's combined limit that is used. The panel opens on a flower with one petal for each provider and nothing else. Click a petal to see that provider's accounts.

**Collection cadence.** On launch the app loads any saved snapshot, then refreshes immediately. It refreshes again every 5 minutes and whenever you press the panel refresh control. A separate presentation clock ticks every 30 seconds so age and reset countdowns move without another OMP call.

**Freshness.** Provider age is measured from each report's `fetchedAt`. Age of 15 minutes or more is treated as stale by app policy. A provider is stale when every account that contributes to its figure is stale. One stale account among fresh ones leaves the provider fresh, and the provider's page marks that account. An account with no usable figure does not count either way. A stale provider's percentage in the menu bar uses the secondary label color, and its petal is striped. A failed refresh keeps the last successful snapshot and surfaces the error. A successful empty snapshot replaces the previous reports with none. Missing remaining values stay unknown; unknown is never treated as zero remaining. When a reset time has already passed, the UI says to recheck. That does not claim the quota has been replenished.

**Menu bar.** The label has one item for each provider that has a report. An item is the provider's logo, then the share of the provider's combined limit that is used, as whole digits and a percent sign such as `79%`. The text uses the 12 pt medium system font with monospaced digits. The order is fixed so that positions stay learnable: Claude, Codex, Grok, Cursor, then any other provider by id in alphabetical order. A provider with no usable figure shows `–`. A stale provider draws its percentage in the secondary label color, and its logo does not change. With no snapshot or no provider, the label shows the `gauge.with.dots.needle.33percent` symbol.

VoiceOver and the hover text of the menu bar item list the providers in the same order and end with the freshness text, as in `Claude 79% used across 5 accounts; Codex 94% used across 3 accounts; Grok 1% used, 1 account; Cursor 100% used, 1 account. Provider data under 1m old`. The freshness text describes the oldest report in the snapshot, whichever provider it belongs to. When only some accounts have a usable figure, the text says how many the figure covers, as in `Claude 74% used across 4 of 5 accounts`.

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

- On a dark menu bar or panel: `<id>-on-dark.pdf`, `<id>-on-dark.png`, `<id>.pdf`, then `<id>.png`.
- On a light menu bar or panel: `<id>-on-light.pdf`, `<id>-on-light.png`, `<id>.pdf`, then `<id>.png`.

The id is the provider id in lowercase. A PDF stays sharp at every scale, so prefer it. Quotablet picks the variant each time the menu bar image is drawn, so a change of the menu bar's appearance switches the file. The panel picks the variant from its own appearance.

Quotablet draws each logo exactly as its file provides it. It never recolors, tints, dims, masks, outlines, shadows, rotates, or stretches a logo, and a stale provider's logo looks like a fresh one. It does trim the transparent margin around the artwork, which does not change the mark, because some official files are about half margin. It then scales the artwork to a height of 15 pt with its aspect ratio kept and centers it vertically in the menu bar. The menu bar image is not a template image, so a logo keeps its colors. The percentages use the system label colors and follow the menu bar's appearance. Keep logo files out of this repository. The tests draw invented shapes.

Quotablet loads each file once and keeps it in memory. On each 30 second presentation tick it checks the modification date of the `Logos` directory and loads the files again when that date has changed. Adding, removing, or renaming a file changes the date. Overwriting a file in place does not, so remove the old file first or restart Quotablet. There is no file watcher.

**Letter badge.** A provider with no usable logo file shows a badge in place of the logo. The badge is a 14 pt rounded square with the provider's initial in a heavy system font. The letters are `C` for Claude, `O` for Codex, `G` for Grok, and `U` for Cursor. For a provider that Quotablet does not know, the panel shows the raw provider id and the badge shows its first letter in capitals. The badge is drawn in the system label color. It fills from the bottom as the provider's combined limit is used, and the letter is cut out of it so that the letter stays readable over both the used and the unused part. The fill covers the used share of the badge's area, not of its height, so the rounded corners do not skew the reading. A badge has one of three looks.

- **Fresh.** The unused part is drawn at 30% of the label color's opacity and the used part at the full label color.
- **Stale.** Every measured account of the provider is 15 minutes old or older. The badge dims and 1 pt stripes cross the filled part. The stripes keep an exhausted stale provider from looking like a fresh, unused one. An unknown badge dims by the same proportion when its data is stale. It has no fill, so it has no stripes.
- **Unknown.** No account of the provider reports a usable share. The badge is a 1 pt outline with a solid letter and no fill, so it never reads as 0% or 100%.

**Provider flower.** The panel opens on a flower that draws each provider as one petal. The body between the header and the footer holds nothing else. The flower is up to 300 pt across and sits in the middle of the body. The petals keep the menu bar order. The first petal sits at 12 o'clock and the rest follow clockwise. Each petal takes a color from a fixed palette by its position, so no petal uses a brand color. The palette is blue, brown, indigo, teal, gray, cyan, slate blue, and purple. It holds no red, orange, yellow, or green, because the badges use those colors for status.

Inside a petal, large rounded digits show the same figure as the menu bar item of its provider, the share of the combined limit that is used, such as `77%`. The digits are dark over the fill and use the primary text color over the empty part. The color changes exactly at the edge of the fill, so a figure that the edge cuts through stays readable. A petal fills outward from its inner edge. The fill covers the used share of the petal's area and not of its length, because a petal widens toward its tip. A petal has one of three looks.

- **Fresh.** The unused part is a pale track and the used part is solid.
- **Stale.** Every measured account of the provider is 15 minutes old or older. The fill is desaturated and dimmed, and 1.5 pt stripes cross it, so an exhausted stale provider does not look like a fresh, unused one. The digits keep the primary text color.
- **Unknown.** No account of the provider reports a usable share. The petal is an outline with no fill, so it never reads as 0% or 100%. Its digits are a dash.

The provider's logo sits outside the petal's tip, 18 pt tall. Quotablet draws it from the same files as the menu bar, unmodified and trimmed to its artwork, in the variant that suits the panel's appearance. A logo wider than 2:1 shrinks, with its shape unchanged, to fit 36 pt. A provider with no logo file shows its letter in place of the logo.

A badge at the tip counts the accounts that need attention. A red badge with a crossed octagon shows how many accounts have at least one exhausted quota. When none has, an orange badge with a warning triangle shows how many accounts have a near-limit quota as their most urgent one. A provider with neither shows no badge. The two symbols differ in shape, so a badge never rests on its color alone.

The petal under the pointer lifts and brightens, and the pointer becomes a pointing hand. A click on a petal opens that provider's page. Hover and click both test the pointer against the outline of each petal, because the frames of neighboring petals overlap. The gaps between petals and the hole in the middle do nothing.

The flower appears for three to eight providers. With fewer or more, the panel shows one tappable row for each provider instead. A row holds the provider's logo, name, number of accounts, badge, used share, and a bar in the petal's color. The accounts read `5 accounts`, `4 of 5 accounts` when only four of five have a usable figure, or `1 account`. The share reads `79% used`, or `Unknown` when the provider has no usable figure.

VoiceOver reads each petal as a button with a label such as `Claude 68% used across 5 accounts, 1 near limit` and the hint `Shows accounts`. When some accounts are exhausted and others are near limit, the label says both, as in `1 exhausted, 2 near limit`. A stale provider ends with `stale`. A list row reads the same way.

**Provider page.** A click on a petal opens that provider's page in place of the flower. The header has a back chevron, the provider's logo and name, and a pill in the petal's color with the provider's combined figure, such as `79% used`. The chevron, the **Escape** key, and the button named `Back to providers` return to the flower. Quotablet does not save which page is open. If a refresh drops the provider while its page is open, the panel returns to the flower. Any other refresh keeps the page and updates it.

The change takes 0.35 seconds. The petal's color grows into the page, and the provider's logo moves from the petal's tip to the header. Going back reverses both. With Reduce Motion on, the two pages cross-fade.

Three to eight accounts bloom into a flower of their own. It has one petal for each account in account-number order, so a petal keeps its place from one refresh to the next. The account's number sits inside its petal, and the same palette gives the color by position. A petal fills by the account's capacity quota, the same quota that the provider's petal counts for that account, so the two agree. An account whose report is stale has a striped petal, and a small key, `Stale data`, under the flower explains the stripes. The key appears only when some account is stale. An account that needs attention gets a badge with its symbol and no count. With fewer than three accounts or more than eight, there is no flower.

Below the flower, each account has one compact row, in urgency order.

1. Accounts with an exhausted quota come first, ordered by the latest reset among their exhausted quotas, because all of those quotas must clear. An account whose exhausted quota has no reset time comes after the ones with a known time.
2. Accounts whose most urgent quota is near limit come next, most used first.
3. The other accounts follow, most used first.

Accounts that tie keep the order of their numbers.

A row starts with the account's number in its petal color, followed by a status symbol when the account needs attention. A column follows for each window name that any account reports. A window is any quota the account reports, and the column header is its short name. A cell holds a thin bar, the used percent, and the time until the window resets when the window has a reset time. An exhausted window shows that time, in red, in place of its percent. A window at 0% with no reset time shows `0%` and no time. A window with no usable figure shows a dash. A row for a stale account carries a `Stale` marker, and its bars are striped. The row tints red when the account has an exhausted quota and orange when its most urgent quota is near limit.

The short name of a window is its length, so `Claude 7 Day` reads `7d` and `Claude 7 Day (Fable)` reads `7d Fable`. A parenthetical that only restates the window is dropped, so `Grok Build (Weekly)` reads `7d`. A parenthetical restates the window when it equals the window label or is `Daily`, `Weekly`, `Monthly`, or `Hourly`, in any letter case. A quota without a window length keeps its label, such as `Cursor Models`. When two quotas of one account would get the same short name, as the four weekly pools of Grok do, each takes what its label says besides the provider's name and the window words. They read `Credits`, `Build`, `Tasks`, and `Chat`. Quotas that still share a name get a count, as in `Models 2`, so every quota keeps a column.

A provider with one or two accounts, such as Cursor and Grok today, shows a card for each account in place of the rows. A card gives every window a line of its own, with the window's name, a bar, the percent, and the time until reset.

Five accounts with three windows each fit in the panel without scrolling. Longer lists scroll.

VoiceOver reads each account row as one element, such as `Account 2, near limit, 7 day 91% used, resets in 3 days 23 hours; 5 hour 0% used; 7 day Fable 78% used`. Windows that need attention come first, and a stale account ends with `, stale`. Window lengths are spoken in words, as in `7 day`. The account name comes from the eye button, so a revealed identifier replaces `Account 2`.

**No pins.** Earlier builds pinned quotas to the menu bar. The menu bar now follows providers, so pins, the pin buttons, and the summary card are gone. The petal chart returned as the provider flower, with one petal for each provider. A `pinnedQuotas` key in an old `settings.json` is ignored and is dropped the next time Quotablet saves its settings.

**Needs attention.** A quota needs attention when OMP reports its status as exhausted or near limit, or when its remaining amount is zero or below. A quota that OMP reports as available, or without a recognized status, needs attention only when its remaining amount is zero or below. Quotablet adds no percentage threshold and no setting. An account takes the urgency of its most urgent quota, with exhausted ahead of near limit. The badges on the flower count accounts by that urgency, and the provider page orders and tints its rows by it.

An account can count as exhausted while some of its quotas still work. OMP reports each quota on its own, and the data does not say which quotas cover the whole account. So the provider page lists every window of the account and shows which ones ran out.

**Account labels.** Account names and identifiers stay hidden by default. An account shows as `Account N`, counted from 1 in report order within its provider. The eye button in the footer reveals names and identifiers on the provider page. Reveal is session-only and is not written to disk.

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
