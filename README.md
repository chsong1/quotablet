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

Quotablet lives in the menu bar as a window-style `MenuBarExtra`. The label shows one item for each provider that OMP reports on, and for each provider whose accounts OMP lists without a report. An item is the provider's logo and the share of that provider's combined limit that is used. The panel opens on one emblem for each provider and nothing else: the provider's logo with a petal for each of its accounts around it. Click an emblem to see that provider's accounts.

**Collection cadence.** On launch the app loads any saved snapshot, then refreshes immediately. It refreshes again every 5 minutes and whenever you press the panel refresh control. A separate presentation clock ticks every 30 seconds so age and reset countdowns move without another OMP call.

**Freshness.** Provider age is measured from each report's `fetchedAt`. Age of 15 minutes or more is treated as stale by app policy. A provider is stale when every account that contributes to its figure is stale. One stale account among fresh ones leaves the provider fresh, and the provider's page marks that account. An account with no usable figure does not count either way. A stale provider's percentage in the menu bar uses the secondary label color, and a stale account's petal is striped. A failed refresh keeps the last successful snapshot and surfaces the error. A successful empty snapshot replaces the previous reports with none. Missing remaining values stay unknown; unknown is never treated as zero remaining. When a reset time has already passed, the UI says to recheck. That does not claim the quota has been replenished.

**Data age.** The panel header shows how old the data on screen is. It uses the oldest report's `fetchedAt`, because that is the oldest figure the panel draws. A snapshot with no report uses the time OMP generated it. The line reads `Updated just now` under one minute, then `Updated 3m ago`, `Updated 2h 5m ago`, and `Updated 1d 1h ago`. While a refresh runs it reads `Refreshing · updated 3m ago`. A saved snapshot that has not been refreshed yet reads `Saved snapshot · updated 2h 5m ago`. After a failed refresh the saved data stays, and the line reads `Refresh failed · data from 2h 5m ago`. With no snapshot the line reads `Waiting for OMP`, `Refreshing OMP`, or `Refresh failed`. The presentation clock moves the age every 30 seconds while the panel is open, and VoiceOver reads the same text.

**Menu bar.** The label has one item for each provider that has a report or a problem account. A problem account is an account that OMP lists without a report. An item is the provider's logo, then the share of the provider's combined limit that is used, as whole digits and a percent sign such as `79%`. The text uses the 12 pt medium system font with monospaced digits. The order is fixed so that positions stay learnable: Claude, Codex, Grok, Cursor, then any other provider by id in alphabetical order. A provider with no usable figure shows `–`. A stale provider draws its percentage in the secondary label color, and its logo does not change. A provider with a problem account draws a red dot, 4 pt across, after its percentage. The dot uses the system red, and the logo does not change. A provider with no report draws its logo, the `–`, and the dot. With no snapshot or no provider, the label shows the `gauge.with.dots.needle.33percent` symbol.

VoiceOver and the hover text of the menu bar item list the providers in the same order and end with the freshness text, as in `Claude 79% used across 5 accounts; Codex 94% used across 3 accounts; Grok 1% used, 1 account; Cursor 100% used, 1 account. Provider data under 1m old`. The freshness text describes the oldest report in the snapshot, whichever provider it belongs to. When only some accounts have a usable figure, the text says how many the figure covers, as in `Claude 74% used across 4 of 5 accounts`. A provider with problem accounts names them after its figure, as in `Claude 77% used across 4 accounts, 1 account needs sign-in`. A provider with no report reads `Claude, 5 accounts need sign-in`.

**Combined usage.** The figure treats all accounts of a provider as one pool. If you have five Codex accounts, their five limits together are 100%, and the figure is how much of that has been used. It is the share used and not the share left.

Each account contributes one quota, its capacity quota, which is the quota that stands for the account's total limit. Quotablet picks it in three steps.

1. The candidates are the account's quotas that report a used share, except scoped quotas and product usage. A quota is scoped when its label ends in a parenthetical that names something narrower than its window, so `Claude 7 Day (Fable)` is scoped. A parenthetical that only restates the window, such as `Grok Build (Weekly)`, does not scope the quota. A Claude or Codex quota is also scoped when its scope names a tier, which is how OMP's own roll-up of capacity reads it. Other providers use the tier for something else, such as the name of a plan, so it narrows nothing for them. Product usage is described below.
2. The longest window wins. A window's length is the duration OMP reports. When OMP reports none, a window labeled `Hourly`, `Daily`, `Weekly`, or `Monthly` counts as 1 hour, 1 day, 7 days, or 30 days. Any other window without a duration ranks shortest.
3. Windows of equal length go to the quota with the highest used share, then to the fixed order of provider, account, window, and quota label.

An account with no such quota is not measured. It counts toward the number of accounts and not toward the figure.

**Grok's shared pool.** OMP reports a Grok account's weekly credit pool as `xai-oauth:credits:1w`, and each product that draws on it as `xai-oauth:product:<product>:1w`, such as `Cursor (Weekly)` or `API (Weekly)`. The pool and its products carry the same shared flag and the same window, so only the ids tell them apart. Quotablet reads the ids of the `xai-oauth` provider this way and no other provider's. A product row is product usage. It is never a candidate, however high its percent, so it cannot stand for the account, cannot flag it, and is not counted again in the figure. An account whose report holds only product usage is not measured, and Quotablet does not add the products up in its place. When the pool and the older monthly counter `xai-oauth:included:1mo` are both there, the pool stands for the account, as in OMP's own capacity policy for Grok. The longest-window step alone would pick the monthly counter.

OMP reports each product as a percent and gives it a remaining amount that is only the rest of 100%. It does not say what the percent is a percent of. So Quotablet shows each product's used percent as OMP reports it, labeled `Reported by OMP`, and never adds the products together, sets them against the pool, or works out what is left for them. A product named Cursor inside the Grok pool is not the Cursor provider. No field in `omp usage --json` ties an account of one provider to an account of another, and the Cursor report carries no account identity at all, so Quotablet draws no link between them from emails or names. The two stay separate, and the Grok product usage never enters Cursor's figure. Dollars stay separate too: a quota in USD keeps its own amounts on the provider page and is never added to a percent. Root `capacity` in the OMP output is not read. It repeats these same quotas without account identities and keeps the highest percent of each window, which is the rule that product usage must not take part in.

The figure of a provider comes from the capacity quotas of its measured accounts. When every one of them has a positive limit and they all share one unit other than percent, such as USD, the limits are pooled. Each account contributes its used share, capped at 100%, times its limit, and the figure is that total over the sum of the limits. An account that overspent its limit therefore counts as full, not more. Otherwise the figure is the mean of the accounts' used shares, so each account is one equal part of 100%.

**Provider logos.** Quotablet ships no provider logos, and this repository holds none of them. The MIT license covers Quotablet's code and not anyone's trademarks. Anthropic and xAI require written permission before another product uses their logos, and OpenAI's logo files are not transferable. So you install the files on your own Mac from the official brand pages, and Quotablet reads them at run time. The logos the app does bundle are identity marks for account badges, described under **Account company logos**.

- [Anthropic](https://www.anthropic.com/legal/trademark-guidelines)
- [OpenAI](https://openai.com/brand/)
- [xAI](https://x.ai/legal/brand-guidelines)
- [Cursor](https://cursor.com/brand)

Put the files in `~/Library/Application Support/Quotablet/Logos/`, beside `settings.json`. Quotablet only reads that directory and never writes to it. For a provider id such as `anthropic`, `openai-codex`, `xai-oauth`, or `cursor`, Quotablet takes the first of these files that exists.

- On a dark menu bar or panel: `<id>-on-dark.pdf`, `<id>-on-dark.png`, `<id>.pdf`, then `<id>.png`.
- On a light menu bar or panel: `<id>-on-light.pdf`, `<id>-on-light.png`, `<id>.pdf`, then `<id>.png`.

The id is the provider id in lowercase. A PDF stays sharp at every scale, so prefer it. Quotablet picks the variant each time the menu bar image is drawn, so a change of the menu bar's appearance switches the file. The panel picks the variant from its own appearance.

Quotablet draws each logo exactly as its file provides it. It never recolors, tints, dims, masks, outlines, shadows, rotates, or stretches a logo, and a stale provider's logo looks like a fresh one. It does trim the transparent margin around the artwork, which does not change the mark, because some official files are about half margin. It then scales the artwork to a height of 15 pt with its aspect ratio kept and centers it vertically in the menu bar. The menu bar image is not a template image, so a logo keeps its colors. The percentages use the system label colors and follow the menu bar's appearance. Keep provider logo files out of this repository. The tests draw invented shapes, except for the identity logos described under **Account company logos**.

Quotablet loads each file once and keeps it in memory. On each 30 second presentation tick it checks the modification date of the `Logos` directory and loads the files again when that date has changed. Adding, removing, or renaming a file changes the date. Overwriting a file in place does not, so remove the old file first or restart Quotablet. There is no file watcher.

**Letter badge.** A provider with no usable logo file shows a badge in place of the logo. The badge is a 14 pt rounded square with the provider's initial in a heavy system font. The letters are `C` for Claude, `O` for Codex, `G` for Grok, and `U` for Cursor. For a provider that Quotablet does not know, the panel shows the raw provider id and the badge shows its first letter in capitals. The badge is drawn in the system label color. It fills from the bottom as the provider's combined limit is used, and the letter is cut out of it so that the letter stays readable over both the used and the unused part. The fill covers the used share of the badge's area, not of its height, so the rounded corners do not skew the reading. A badge has one of three looks.

- **Fresh.** The unused part is drawn at 30% of the label color's opacity and the used part at the full label color.
- **Stale.** Every measured account of the provider is 15 minutes old or older. The badge dims and 1 pt stripes cross the filled part. The stripes keep an exhausted stale provider from looking like a fresh, unused one. An unknown badge dims by the same proportion when its data is stale. It has no fill, so it has no stripes.
- **Unknown.** No account of the provider reports a usable share. The badge is a 1 pt outline with a solid letter and no fill, so it never reads as 0% or 100%.

**Panel layout.** The panel is a header and a body, with no footer. The header shows the app's name, the age of the data on screen, a refresh button (**⌘R**), and a `⋯` menu. The menu says whether OMP is found automatically or by a custom path, and holds **Choose OMP…**, **Use Automatic Discovery** while a custom path is set, and **Quit Quotablet**. **⌘Q** quits whenever the panel is open, with or without the menu.

**Provider emblems.** The panel opens on one emblem for each provider. The body under the header holds nothing else. The emblems keep the menu bar order and fill rows left to right: one emblem alone, two to a row for two to four providers, and three to a row for five to nine. A last row with fewer emblems is centered. An emblem is up to 180 pt across and shrinks to fit the body. Each provider takes a color from a fixed palette by its position, so no emblem uses a brand color. The palette is blue, brown, indigo, teal, gray, cyan, slate blue, and purple. It holds no red, orange, yellow, or green, because the badges use those colors for status.

The provider's logo sits in a dark disc in the middle of its emblem, over a soft glow of the provider's color. Quotablet draws it from the same files as the menu bar, unmodified and trimmed to its artwork, in the variant that suits the panel's appearance. A provider with no logo file shows its letter in place of the logo.

Around the logo, each account has one petal in account-number order. The first petal points to 12 o'clock and the rest follow clockwise. A petal is pointed at both ends and widest a little past its middle. A provider with one account gets a band around the logo, set near the rim so a lone account does not outweigh a flower of several. A provider whose accounts OMP lists only as problems gets one unmeasured band. Every petal of an emblem takes the provider's color. A petal fills outward from the logo by the account's capacity quota. The fill covers the used share of the petal's area and not of its length, and it shades from the full color at the base to a lighter tone at the tip. A petal has one of three looks.

- **Fresh.** The unused part is a pale track with a fine outline, and the used part is filled.
- **Stale.** The account's report is 15 minutes old or older. The fill is desaturated and dimmed, and 1.5 pt stripes cross it, so an exhausted stale account does not look like a fresh, unused one.
- **Unknown.** The account reports no usable share. The petal is a dashed outline with no fill, so it never reads as 0% or 100%.

A petal whose account needs attention carries a small badge on its tip. A red disc with an `xmark` marks an account with an exhausted quota, and an orange disc with an `!` marks one whose most urgent quota is near limit. The two glyphs differ in shape, so a badge never rests on its color alone.

Under each emblem, the provider's name is followed by the used share of its busiest account, such as `Claude 100%`, because the account closest to its limit is the one that runs out first. The share is a dash when no account reports one. The provider's combined figure stays in the menu bar and on the provider's page. When some accounts need to sign in again, a dark capsule with a red `person.crop.circle.badge.exclamationmark` symbol and the count follows the share, so it never reads as a quota status. The count adds the disconnected accounts and the accounts without usage data.

Each time the panel opens, the petals unfold from the logo one after another. With Reduce Motion on, they appear in place. The emblem under the pointer lifts and brightens, and the pointer becomes a pointing hand. A click anywhere on an emblem or its caption opens that provider's page.

With ten or more providers, the panel shows one tappable row for each provider instead. A row holds the provider's logo, name, number of accounts, badges, used share, and a bar in the provider's color. The accounts read `5 accounts`, `4 of 5 accounts` when only four of five have a usable figure, or `1 account`. Problem accounts follow, as in `4 accounts, 1 account needs sign-in`. A provider with no report reads only its problem accounts. The share reads `79% used`, `Unknown` when the provider's reports hold no usable figure, or `—` when it has no report.

VoiceOver reads each emblem as a button with a label such as `Claude 68% used across 5 accounts, 1 near limit` and the hint `Shows accounts`. When several accounts stand behind the figure, the label ends with the busiest account, as in `, busiest account 100% used`. When some accounts are exhausted and others are near limit, the label says both, as in `1 exhausted, 2 near limit`. A stale provider adds `stale`. Problem accounts follow the figure and come before the attention counts, as in `Claude 77% used across 4 accounts, 1 account needs sign-in, 1 exhausted`. Accounts without usage data read `2 accounts without usage data`. A list row reads the same way, without the busiest account.

**Provider page.** A click on an emblem opens that provider's page in place of the emblems. The header has a back chevron, the provider's logo and name, and a pill in the provider's color with the provider's combined figure, such as `79% used`. The pill reads `Unknown` when the provider's reports hold no usable figure and `—` when the provider has no report. VoiceOver reads the pill as the provider's summary sentence, such as `Claude 79% used across 5 accounts, 1 account needs sign-in`. The chevron, the **Escape** key, and the button named `Back to providers` return to the emblems. Quotablet does not save which page is open. If a refresh drops the provider while its page is open, the panel returns to the emblems. Any other refresh keeps the page and updates it.

The change takes 0.35 seconds. The emblem's color grows into the page, and the provider's logo moves from the middle of the emblem to the header. Going back reverses both. With Reduce Motion on, the two pages cross-fade.

Three to eight accounts bloom into a larger flower of their own, drawn like the emblem's petals. It has one petal for each account in account-number order, so a petal keeps its place from one refresh to the next. The account's number sits inside its petal, and every petal takes the provider's color. A petal fills by the account's capacity quota, the same quota that the provider's combined figure counts for that account, so the two agree. An account whose report is stale has a striped petal, and a small key, `Stale data`, under the flower explains the stripes. The key appears only when some account is stale. An account that needs attention gets a tip badge. With fewer than three accounts or more than eight, there is no flower.

Below the flower, each account has one compact row, in urgency order.

1. Accounts with an exhausted quota come first, ordered by the latest reset among their exhausted quotas, because all of those quotas must clear. An account whose exhausted quota has no reset time comes after the ones with a known time.
2. Accounts whose most urgent quota is near limit come next, most used first.
3. The other accounts follow, most used first.

Accounts that tie keep the order of their numbers.

A row starts with the account's number in the provider's color, or with the account's identity logo while identifiers are revealed (see **Account company logos**), followed by a status symbol when the account needs attention. A column follows for each window name that any account reports. A window is any quota the account reports except product usage, and the column header is its short name. A cell holds a thin bar, the used percent, and the time until the window resets when the window has a reset time. An exhausted window shows that time, in red, in place of its percent. A window at 0% with no reset time shows `0%` and no time. A window with no usable figure shows a dash. A row for a stale account carries a `Stale` marker, and its bars are striped. The row tints red when the account has an exhausted quota and orange when its most urgent quota is near limit. An account with product usage adds one caption line under its cells, such as `Product usage · Reported by OMP · Cursor 22% · GrokBot 1% · API 1%`.

The short name of a window is its length, so `Claude 7 Day` reads `7d` and `Claude 7 Day (Fable)` reads `7d Fable`. A parenthetical that only restates the window is dropped, so `Grok Build (Weekly)` reads `7d`. A parenthetical restates the window when it equals the window label or is `Daily`, `Weekly`, `Monthly`, or `Hourly`, in any letter case. A quota without a window length keeps its label, such as `Cursor Models`. When two quotas of one account would get the same short name, as the four weekly pools of an older Grok shape do, each takes what its label says besides the provider's name and the window words. They read `Credits`, `Build`, `Tasks`, and `Chat`. Quotas that still share a name get a count, as in `Models 2`, so every quota keeps a column. The weekly credit pool of Grok reads `Shared pool` in place of its length, and the products that draw on it are not windows.

A provider with one or two accounts, such as Cursor and Grok today, shows a card for each account in place of the rows. A card gives every window a line of its own, with the window's name, a bar, the percent, and the time until reset. A quota in US dollars adds a line under its own with its amounts beside the percent, such as `$12.40 of $553.95`. A quota in any other unit shows only its percent, because OMP does not name a currency for it. Under the windows, an account with product usage shows a block headed `Product usage` and `Reported by OMP`. It lists each product with a thin bar and its used percent, in smaller type beside a rule, with no remaining amount and no reset time, so it reads as a breakdown of the pool and not as limits of its own.

An account with reset credits shows a small capsule with the `arrow.counterclockwise` symbol and the count, such as `↺ 2`, in the secondary color. In a row the capsule sits under the account's number, and in a card it follows the status symbol. The capsule has a filled background, and the countdown beside a window has none. An account with zero reset credits, or none reported, shows no capsule.

Below the account rows, each problem account has a row of its own: disconnected accounts first, then accounts without usage data, each kind in the order OMP listed it. A row starts with a gray chip with `!` in place of a number. It names the account `Disconnected account` or `Account without usage data`, and numbers the names within the provider when it has several of one kind, as in `Disconnected account 2`. A disconnected account adds the reason, such as `Refresh token not found or invalid`, and `since 3h 12m ago` when OMP says when it disabled the account, and ends with the hint `Sign in again in OMP`. An account without usage data ends with `Signed in, but OMP returned no usage`. A problem row has no windows and no bar. A provider whose accounts are all problems shows only these rows under the header, and no flower.

Five accounts with three windows each fit in the panel without scrolling, unless an account shows reset credits or product usage, or the provider has problem accounts. Longer lists scroll.

VoiceOver reads each account row as one element, such as `Account 2, near limit, 7 day 91% used, resets in 3 days 23 hours; 5 hour 0% used; 7 day Fable 78% used`. Windows that need attention come first. Product usage follows the windows, as in `, product usage reported by OMP: Cursor 22%; GrokBot 1%; API 1%`. A quota in dollars reads its amounts after its percent, as in `Other Models 2% used, $12.40 of $553.95`. A stale account ends with `, stale`. Reset credits come last, as in `, 2 reset credits available`. Window lengths are spoken in words, as in `7 day`. The account name comes from the eye button, so a revealed identifier replaces `Account 2`. When the badge wears an identity logo, the row also names the brand, what the logo is, and the number right after the account's name, as in `person@suresofttech.com, Suresoft company, account 2, near limit, 7 day 91% used`, `person@gmail.com, Gmail email provider, account 2, near limit, 7 day 91% used`, or `person@privaterelay.appleid.com, Apple private email relay, account 2, near limit, 7 day 91% used`. While identifiers are hidden, no label names a brand or a role. VoiceOver reads each problem row as one element too, such as `Disconnected account 2, Refresh token not found or invalid, since 3h 12m ago, Sign in again in OMP`.

**No pins.** Earlier builds pinned quotas to the menu bar. The menu bar now follows providers, so pins, the pin buttons, and the summary card are gone. The petal chart returned as the provider emblems, with one petal for each account. A `pinnedQuotas` key in an old `settings.json` is ignored and is dropped the next time Quotablet saves its settings.

**Needs attention.** A quota needs attention when OMP reports its status as exhausted or near limit, or when its remaining amount is zero or below. A quota that OMP reports as available, or without a recognized status, needs attention only when its remaining amount is zero or below. Quotablet adds no percentage threshold and no setting. An account takes the urgency of its most urgent quota, with exhausted ahead of near limit. A product's use of the shared pool is not a quota with a limit, so it never needs attention and never counts toward the urgency of an account. The tip badges mark accounts by that urgency, the badges of a list row count them by it, and the provider page orders and tints its rows by it.

An account can count as exhausted while some of its quotas still work. OMP reports each quota on its own, and the data does not say which quotas cover the whole account. So the provider page lists every window of the account and shows which ones ran out.

**Problem accounts.** `omp usage --json` lists two kinds of account that have no report. `disabledCredentials` holds accounts whose OAuth credentials OMP disabled, for example after a failed token refresh. OMP already leaves out credentials that a user replaced or deleted, and credentials that an active account replaces. Quotablet shows each of these as a disconnected account. `accountsWithoutUsage` holds signed-in accounts for which OMP returned no usage report. Quotablet shows each of these as an account without usage data. A problem account has no figure, so it counts toward neither a provider's combined figure nor its number of accounts. The reason of a disconnected account is the `error_description` that its cause embeds, such as `Refresh token not found or invalid`, else a JSON `message` it embeds, such as `Invalid refresh token`. Without either, the reason is the clause after the last `: ` of the cause, without the quotes and braces of a JSON body. Older OMP output has neither list. An entry that Quotablet cannot read is dropped, and it never costs the reports.

**Account labels.** Account names, identifiers and mapped identity logos are visible by default on each launch. The eye button in a provider page's header, or **⌘⇧P** while a page is open, hides them for the current session; this choice is not written to disk. When hidden, an account shows as `Account N`, counted from 1 in report order within its provider. A problem account follows the same rule: it shows its kind, `Disconnected account` or `Account without usage data`, while hidden. When visible, it shows its email, else its organization name, account id, project id, or organization id.

**Account company logos.** The badge of an account whose email domain has a logo wears that logo in place of the plain number. The domain comes only from the email field that OMP reports. An organization name or an id that looks like an address names no domain. The match is exact and ignores letter case, so `Person@SureSoftTech.com` and `person@suresofttech.com` both belong to `suresofttech.com`, and `Person@Gmail.com` belongs to `gmail.com`. A prefix, a suffix and a subdomain are other domains, so `evilsuresofttech.com`, `suresofttech.com.example.invalid`, `mail.suresofttech.com`, `mail.gmail.com` and `googlemail.com` belong to none of the mapped domains, and neither does an address with a second `@`. Every unlisted domain, and a missing or unreadable email, keeps the plain number.

The mapped domains and what each logo means are fixed:

- `suresofttech.com` → Suresoft, the company that employs the account's user.
- `gmail.com` → Gmail, the mail provider that hosts the address, not an employer.
- `kakao.com` → Kakao, the mail provider that hosts the address, not an employer.
- `naver.com` → Naver, the mail provider that hosts the address, not an employer.
- `privaterelay.appleid.com` → Apple, the private email relay that hosts the address, not an employer.

Only `suresofttech.com` is treated as a company. The four public-provider logos name the mail provider or privacy relay the address is hosted on and never say who employs the user. Other domains of the same providers, such as `icloud.com`, `outlook.com` or `daum.net`, stay numbers.

The domain of an account's email is part of who it is, so a logo shows only while identifiers are revealed, which is the default on each launch. If you hide identifiers, every badge becomes its plain number, and nothing that the page draws or says names a brand, a company, a mail provider or a privacy relay. A badge with a logo keeps the 24 pt footprint of the plain one. The logo sits centered on a white 24 pt plate ringed in the provider's color, fitted unmodified into a 14 × 14 pt box with equal space on every side, and the number sits in a 10.5 pt disc of that color hanging 3 pt off the plate's lower right corner, so a row still finds its petal by number. The number is the account's usual one, counted in report order within its provider, so it does not move when the rows reorder by urgency, and two accounts that share a logo tell apart by it. A stale account stripes and dims the ring and the disc as it does a plain badge, and the logo stays as its file provides it. The same badge is used on account rows and on the one-or-two-account cards. The petals of the account flower and the `!` chip of a problem account are not badges of this kind and are unchanged.

**Company logo assets.** The app reads each identity logo from a PNG in its bundle and never from the network. The Xcode project bundles the files into the app and into the test bundle. The resource name is `company-<id>.png` under `Quotablet/Resources`, with one file per mapped domain: `company-suresoft.png`, `company-gmail.png`, `company-kakao.png`, `company-naver.png` and `company-apple.png`. Quotablet draws each as the file provides it, trimmed of its transparent margin and scaled like a provider logo, and never recolors, tints, dims, masks, outlines or stretches it. A missing or unreadable file leaves that domain's badge as the plain number. The five files are official site or product icons retrieved by plain public GET on 2026-10-20, with no login and no terms accepted at download. They identify the email domain's brand on the badge only: Suresoft as employer, and Gmail, Kakao, Naver and Apple as the mail provider or privacy relay that hosts the address. No licence from the owners was found or obtained for Quotablet to redistribute these marks; the MIT license covers Quotablet's code and not them. Google's Brand Resource Center says product icons are requested through the Partner Marketing Hub; Apple's third-party guidelines allow Apple word marks in compatibility references but not the Apple Logo; Kakao's media-kit page and Naver's brand guide restrict commercial use and redistribution of their brand materials, though whether those notices also cover these site icons is unconfirmed. Replacing a file means updating the provenance below. To add another domain, list its exact email domain, display name and role in `AccountCompany`, add its PNG to `Quotablet/Resources` as `company-<id>.png` in both targets of the Xcode project, and record where it came from here.

**Suresoft (`company-suresoft.png`).** The file is the 192 × 192 icon that `https://www.suresofttech.com/` declares as its `rel="icon"`, byte for byte from `https://www.suresofttech.com/img/favicon/android-icon-192x192.png`, retrieved on 2026-10-20 (`Last-Modified: Mon, 01 Jun 2026 23:35:08 GMT`, 3,114 bytes, SHA-256 `59231cbfdb70132ba05cba3d3e1d4a46e6055ba90de40cb8e785fe3991c0cbce`). It is the first letter of the site's own wordmark, `https://www.suresofttech.com/img/logo.svg`, in the company's navy `#002878`. The whole wordmark is 212 × 22 and cannot be read in a 24 pt badge, so the badge uses the letter.

**Gmail (`company-gmail.png`).** The file is Google's Gmail 2020q4 product icon, byte for byte from `https://www.gstatic.com/images/branding/product/2x/gmail_2020q4_96dp.png`, retrieved on 2026-10-20 (`Last-Modified: Thu, 27 Aug 2020 22:15:00 GMT`, 192 × 192, 1,922 bytes, SHA-256 `d49100a00e2caa1626f9f3339879e047327f28c0c3a2a18c767c1a5682863981`). It is the four-color envelope mark Google was serving for Gmail on that date; Google says it is redesigning product icons, so a later fetch may differ. No conversion: the bundled PNG is the response body as served.

**Kakao (`company-kakao.png`).** The file is the favicon Kakao serves for its accounts host, byte for byte from `https://accounts.kakao.com/favicon.ico`, retrieved on 2026-10-20 (`Last-Modified: Mon, 21 Sep 2026 02:17:59 GMT`, 200 × 200, 1,929 bytes, SHA-256 `a831552363b302de8bcfd9167af27faf9eb99300981fefdc003b7b5e49b74dbd`). The response is a PNG despite the `.ico` URL and `image/x-icon` content type. No conversion: the bundled PNG is that body renamed.

**Naver (`company-naver.png`).** The file is the 192 × 192 apple-touch icon that `https://m.naver.com/` declares (`apple-touch-icon-precomposed`), byte for byte from `https://s.pstatic.net/static/www/mobile/edit/20240814_0/upload_1723602600973mkojJ.png`, retrieved on 2026-10-20 (`Last-Modified: Wed, 14 Aug 2024 02:30:01 GMT`, 192 × 192, 28,738 bytes, SHA-256 `9d631b15112d122d4ac5744451cc2669cd6491d0831dafad349460351a6fbd0d`). Naver's corporate brand-resource ZIP holds the NAVER wordmark and not this N tile, so the badge uses the site's own declared icon rather than a guide asset. No conversion: the bundled PNG is the response body as served.

**Apple (`company-apple.png`).** The file is the Apple mark that `https://www.apple.com/` publishes as its Organization JSON-LD `logo`, byte for byte from `https://www.apple.com/ac/structured-data/images/knowledge_graph_logo.png?202610011401`, retrieved on 2026-10-20 (`Last-Modified: Tue, 10 May 2016 22:25:17 GMT`, 302 × 302, 10,070 bytes, SHA-256 `4ea439d373443bf940df4c21ddfbd479fcaf3ecbe61928fa16004c67c28834cd`). The Sign in with Apple logo package is not used; the badge uses this public site logo instead. No conversion: the bundled PNG is the response body as served.

**App icon.** The app icon is Quotablet's own emblem: six cyan petals around a dark disc that holds the letter `Q`, over a soft cyan glow on a navy rounded square. The petals take the panel's petal outline and fill to uneven shares, as accounts do, and the `Q` is set in the rounded heavy system font of the letter badges. The artwork is original to this repository and holds no third-party mark. `Tools/RenderAppIcon.swift` draws it and writes the ten images of a macOS icon set into `Quotablet/Resources/Assets.xcassets`, so change the script and run `swift Tools/RenderAppIcon.swift` from the repository root rather than editing the PNGs. The icon fills Apple's macOS icon grid, an 824 × 824 continuous rounded square centered in a 1024 × 1024 canvas, so macOS 26 shows it as it is and does not box it in a gray squircle. It is a plain asset catalog rather than an Icon Composer file, which would need Xcode 26 or later.

**OMP executable.** Automatic discovery checks, in order:

1. `~/.local/bin/omp`
2. `/opt/homebrew/bin/omp`
3. `/usr/local/bin/omp`
4. `/opt/local/bin/omp`
5. `/usr/bin/omp`
6. `/bin/omp`

**Choose OMP…**, in the header's `⋯` menu, stores an explicit path to a trusted executable. When usage is unavailable and no snapshot is saved, the panel also shows a **Choose OMP…** button. If that override is missing or not executable, refresh fails with a configured-path error until you pick another file or choose **Use Automatic Discovery**, which clears the override and restores discovery. Quotablet starts the chosen binary directly with arguments `usage --json`. It does not run a shell and does not perform its own OMP authentication. OMP itself may contact provider APIs or a configured authentication broker over the network.

## Local data

Runtime settings and the last successful snapshot live under:

`~/Library/Application Support/Quotablet`

The directory holds `settings.json` and `usage-snapshot.json`. `settings.json` stores the OMP executable override. A `pinnedQuotas` or `pinnedQuota` key from an earlier build is ignored. `usage-snapshot.json` holds the reports and the problem accounts. A snapshot saved before problem accounts existed still loads, with none. Each report also keeps the lowercase domain of its account's email address, such as `suresofttech.com` or `gmail.com`, which is how a badge finds its identity logo. A snapshot saved before that existed still loads, and its badges stay plain numbers until the next refresh. The shared pool and its product usage are not stored on their own. Quotablet reads them from the ids and scopes that each saved quota already holds, so a snapshot saved by an earlier build reads the same way and needs no migration. The directory and files have owner-only permissions. Writes use atomic temporary files renamed into place. The `Logos` directory described above is yours to create and fill, and Quotablet only reads it.

That Application Support cache is private app state. It is separate from the repository's ignored `.local/` directory, which is only for local developer build and artifact output such as DerivedData.

## Privacy

Keep authentication tokens, account identifiers, real usage snapshots, logs, and signing private keys out of this repository. Use synthetic accounts and values in examples, tests, and public samples. Even aliased screenshots can reveal real usage patterns. Redacted CLI output can still leak account prefixes and limits.

Ignore rules do not remove files that are already tracked. Review the files included in each commit before publishing.

## License

[MIT](LICENSE). Copyright 2026 chsong1.
