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

Quotablet lives in the menu bar as a window-style `MenuBarExtra`. The label shows one badge for each quota you pin. With nothing pinned, it shows the quotas that need attention. The panel groups quotas by status, and a collapsed **All quotas** list holds every report that OMP returned.

**Collection cadence.** On launch the app loads any saved snapshot, then refreshes immediately. It refreshes again every 5 minutes and whenever you press the panel refresh control. A separate presentation clock ticks every 30 seconds so age and reset countdowns move without another OMP call.

**Freshness.** Provider age is measured from each report's `fetchedAt`. Age of 15 minutes or more is treated as stale by app policy, and the badge for a stale quota changes look. A failed refresh keeps the last successful snapshot and surfaces the error. A successful empty snapshot replaces the previous reports with none. Missing remaining values stay unknown; unknown is never treated as zero remaining. When a reset time has already passed, the UI says to recheck. That does not claim the quota has been replenished.

**Menu bar badges.** Press the pin button on a quota row to add that quota to the menu bar. Press it again to remove the quota. Each pinned quota gets one badge, in the order you pinned them. Quotablet draws all badges into one template image, so the menu bar tints them to match its appearance and they stay sharp at every display scale.

A badge is a 14 pt rounded square with the provider's initial in a heavy system font. The letters are `C` for Claude, `O` for Codex, `G` for Grok, and `U` for Cursor. For a provider that Quotablet does not know, the panel shows the raw provider id and the badge shows its first letter in capitals. The badge fills from the bottom as the quota is used. The fill covers the used share of the badge's area, not of its height, so the rounded corners do not skew the reading. The letter is cut out of the badge and stays readable over both the used and the unused part.

A badge shows a small account number only when the number tells accounts apart. If a provider's pinned quotas come from two or more accounts, each of those badges shows the number of its account. The number matches the `N` in the panel's `Account N` label. If every pinned quota of a provider comes from one account, none of those badges shows a number. A missing pin never shows a number and does not count as an account. With nothing pinned, the menu bar shows the quotas that need attention, described under **Needs attention** below. With no quota available, the menu bar shows the `gauge.with.dots.needle.33percent` symbol.

A badge shows a small window tag only when the tag tells windows apart. If one account pins quotas with two or more window lengths, each badge of that account shows the length of its window, so the 5-hour and 7-day quotas of one Claude account read `5h` and `7d`. If an account pins one quota, or all its pinned quotas share one length, none of its badges shows a tag. Two quotas of the same length, such as `7 Day` and `7 Day (Fable)`, count as one length. A missing pin never shows a tag and does not count toward the lengths.

The tag text is the window's duration in compact form, such as `5h`, `7d`, or `30d`. A window with no duration shows the first letter of its label in capitals, so a window labeled `Monthly` shows `M`. The tag sits right of the badge, aligned with its top edge, and the account number stays aligned with the bottom edge. A stale badge dims its tag the same way it dims the account number. The summary card's row list draws the same badge image, so its rows show the tag. The petals in the chart show only the letter and account number, because the legend row already shows the quota label.

A badge has one of four looks.

- **Fresh.** The unused part is drawn at 30% opacity and the used part at full opacity.
- **Stale.** Provider data is 15 minutes old or older. The badge dims and 1 pt stripes cross the filled part. The stripes keep an exhausted stale quota from looking like a fresh, unused one. An unknown badge dims by the same proportion when its data is stale. It has no fill, so it has no stripes.
- **Unknown.** The quota has no usable usage figure. The badge is a 1 pt outline with a solid letter and no fill, so it never reads as 0% or 100%.
- **Missing.** The pinned key is absent from the current snapshot or matches more than one quota. The badge keeps its position as a dashed outline with a dimmed letter. Quotablet does not substitute another quota. In the summary card's row list, the row says "Pinned quota unavailable" and has a **Remove** button. In the petal chart, the legend row says "Unavailable" and has the same button. VoiceOver reads "Pinned quota unavailable" in both layouts.

**Needs attention.** With nothing pinned, the menu bar shows the quotas that need attention instead of one arbitrary quota. A quota needs attention when OMP reports its status as exhausted or near limit, or when its remaining amount is zero or below. A quota that OMP reports as available, or without a recognized status, needs attention only when its remaining amount is zero or below. Quotablet adds no percentage threshold and no setting.

Quotablet ranks quotas with one comparator, and the first difference decides.

1. An exhausted quota comes before a near-limit quota.
2. The quota with the smaller remaining share comes first. A quota with no usable usage figure comes after the ones that have one. An exhausted quota counts as having nothing left, so this step never separates two exhausted quotas.
3. The quota that resets sooner comes first. A quota with no reset time comes last.
4. Quotas that still tie keep a fixed order of provider, account, window, and quota label.

So exhausted quotas come first with the soonest reset on top, and near-limit quotas follow with the least remaining on top.

The menu bar shows one badge for each account, and that badge stands for the account's top-ranked quota. An account with a healthy 5-hour quota and an exhausted 7-day quota shows the 7-day quota. The label holds the first 4 accounts in rank order. When more accounts need attention, `+N` follows the last badge, where N is the number of accounts that did not fit. `+N` uses the same font as the account numbers and sits on the same bottom edge. An attention badge shows its account number when two or more accounts of its provider need attention, even if some of those accounts did not fit in the label. If Codex Accounts 1 and 3 need attention and only Account 1 fits, the Codex badge shows the number 1 instead of a bare `O`. An attention badge shows its window tag whenever its account has quotas with two or more window lengths, so the exhausted 7-day quota of an account that also has a 5-hour quota reads `7d`. The tag names the window that needs attention. Pins and attention never mix. Once you pin a quota, the menu bar shows only your pins and no `+N`, and the panel still lists what needs attention.

With nothing pinned and nothing needing attention, the menu bar shows one badge for the most used quota, which is the quota with the highest known used share. Ties go to the sooner reset, then to the fixed order above. If no quota has a known used share, the menu bar shows the first quota in provider order.

**Status groups.** The panel opens with up to three groups. A group appears only when it has rows, and its header counts rows, not accounts or quotas.

- **Exhausted** lists quotas that ran out, under a red header. The large figure is the time until the quota resets, such as `9h 21m`. A reset time in the past reads `Recheck`, and a missing reset time reads a dash. The header caption is `resets in`.
- **Near limit** lists quotas that OMP reports as near limit, under an orange header. The large figure is the share left, such as `3%`. A small line under it shows the reset, such as `resets 4d 14h`. The header caption is `left`.
- **OK** lists accounts with no quota that needs attention, under a green header. Each row shows the account's quota with the least left, a thin bar for that share, and the percent left. Accounts are ordered most used first. The header caption is `left`. The group starts open, a chevron collapses it, and Quotablet does not save that choice.

Every row is one line. A status symbol comes first, so color is never the only signal. The account tag follows, such as `C1` for Claude Account 1 or `U1` for Cursor Account 1. Unlike a menu bar badge, the tag always includes the account number. After the tag come the quota labels. A quota with a window length shows the length, so `Claude 7 Day` reads `7d` and `Claude 7 Day (Fable)` reads `7d Fable`. A parenthetical that only restates the window is dropped, so `Grok Build (Weekly)` reads `7d`. A parenthetical restates the window when it equals the window label or is `Daily`, `Weekly`, `Monthly`, or `Hourly`, in any letter case. A quota without a window length keeps its label, such as `Cursor Models`. A row whose report is stale adds `Stale` in orange. Text, symbols, and bars use their own shade of each color in the light and dark appearances, so they stay readable in both.

Quotas of one account share a row when they need the same attention and reset in the same minute. Cursor Account 1 can show `Cursor Models, Other Models` once, with one countdown. Quotas that reset at different times get their own rows, so a different reset is never hidden. Rows follow the ranking above, so the soonest reset leads Exhausted and the least remaining leads Near limit.

An account can sit under Exhausted while some of its quotas still work. OMP reports each quota on its own, and the data does not say which quotas cover the whole account. A row therefore names the quota that ran out and never says the account is blocked. An account with an exhausted 7-day quota and a healthy 5-hour quota appears only under Exhausted, on a row labeled `7d`. An account with quotas in both attention states has a row in each of the two groups. An account appears under OK only when none of its quotas needs attention.

VoiceOver reads each group header as a heading, such as `Exhausted, 2`, and each row as one element, such as `Claude Account 1, 7 Day exhausted, resets in 9h 21m`, `Codex Account 1, 7 days near limit, 3% left, resets in 4d 14h`, or `Claude Account 2, OK, 7 Day, 22% left`. A spoken row keeps the parenthetical of the quota label, as in `Grok Account 1, OK, Grok Build (Weekly), 40% left`. No window length sits beside the label, so the parenthetical repeats nothing. A row uses the account label from the eye button, so a revealed identifier replaces `Account 1`. A stale row ends with `stale`.

**All quotas.** Below the groups and the summary card, a collapsed **All quotas · N** list holds one account section for each report that OMP returned. N counts quotas. Each section shows the remaining amount, the reset time, and a pin button for every quota, and pinning happens here. An account that reports no quotas appears only in this list. Each account section gets a second header line when that account has a quota that needs attention. The line names the account's top-ranked quota, such as `Claude 7 Day exhausted · resets in 18h 5m` in red or `Claude 5 Hour near limit · resets in 2h 10m` in orange. Account sections keep the order OMP sends.

The header line names a quota and never says that the account is blocked. OMP reports each quota on its own, and some quotas, such as `7 Day (Fable)`, cover only certain models. The data does not say which quotas cover the whole account. So Quotablet reports the quota that ran out and leaves the conclusion to you.

VoiceOver and the hover text of the menu bar item start with `Needs attention:` and list each shown account, such as `Claude Account 1, Claude 7 Day, 0% left, exhausted, resets in 18h 5m`. Semicolons separate the accounts. When some did not fit, the list ends with `and 2 more accounts`. The freshness text follows the list. With nothing pinned and nothing needing attention, the text starts with `Most used:` instead. With pins, the text lists the pinned quotas with no prefix.

**Summary card.** The card repeats your pins, and it shows only when something is pinned. It sits below the status groups. With nothing pinned there is no card, because the OK group already ranks the most used accounts. The card shows one row per quota when it holds 1 or 2 quotas, or more than 8. With 3 to 8 pinned quotas it draws a petal chart and a legend instead, so 8 pins take 200 pt of height and the card does not grow with each pin.

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
