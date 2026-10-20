import AppKit
import SwiftUI

private enum PageMetrics {
    static let headerHeight: CGFloat = 46
    static let inset: CGFloat = 18
    static let headWidth: CGFloat = 46
    static let rowSpacing: CGFloat = 8
    static let rowPadding: CGFloat = 8
    static let chip: CGFloat = 24
    // The badge of an account whose email domain has a logo keeps the 24 pt footprint of the plain number. The mark is centered on a full-size
    // white plate with equal space on every side; the number's disc hangs off the lower right corner so it covers as little of the mark as it can.
    static let chipRing: CGFloat = 1.25
    static let chipMark: CGFloat = 14
    static let chipDisc: CGFloat = 10.5
    static let chipDiscOverhang: CGFloat = 3
    static let chipDiscDigits: CGFloat = 7
    // The width of a window's name on a card. The money line and the product usage under the windows line up with its bar.
    static let windowName: CGFloat = 96

    // Three accounts leave room for a larger flower. Five accounts with three windows each still need the height for their rows.
    static func flowerDiameter(accountCount: Int) -> CGFloat {
        accountCount <= FlowerLayout.petalRange.lowerBound ? 214 : 182
    }
}

enum StatusInk {
    // Plain system colors measured about 1.7:1 (orange, green) and 2.7:1 (red) as text on the light panel,
    // so text, symbols, figures and bars take their own shade in each appearance.
    static func nsColor(for status: AccountStatus) -> NSColor {
        let pair = shades(for: status)
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? pair.dark : pair.light
        }
    }

    static func color(for status: AccountStatus) -> Color {
        Color(nsColor: nsColor(for: status))
    }

    // Container fills and strokes tint with the plain system color, which adapts by itself.
    static func tint(for status: AccountStatus) -> Color {
        switch status {
        case .exhausted: Color(nsColor: .systemRed)
        case .nearLimit: Color(nsColor: .systemOrange)
        case .ok: Color(nsColor: .systemGreen)
        }
    }

    private static func shades(for status: AccountStatus) -> (dark: NSColor, light: NSColor) {
        switch status {
        case .exhausted:
            return (
                dark: NSColor(srgbRed: 1.0, green: 0.44, blue: 0.40, alpha: 1),
                light: NSColor(srgbRed: 0.62, green: 0.07, blue: 0.06, alpha: 1)
            )
        case .nearLimit:
            return (dark: .systemOrange, light: NSColor(srgbRed: 0.52, green: 0.24, blue: 0.0, alpha: 1))
        case .ok:
            return (dark: .systemGreen, light: NSColor(srgbRed: 0.04, green: 0.37, blue: 0.13, alpha: 1))
        }
    }
}

struct StaleMark: View {
    var body: some View {
        Text("Stale")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(StatusInk.color(for: .nearLimit))
            .fixedSize()
    }
}

private extension View {
    // An account that needs attention sits in a tinted container with a stroke. One that is fine stays neutral, so it does not compete.
    func statusCard(_ status: AccountStatus, radius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let tint = StatusInk.tint(for: status)
        let isNeutral = status == .ok
        return background(shape.fill(isNeutral ? Color.primary.opacity(0.05) : tint.opacity(0.12)))
            .overlay(shape.strokeBorder(isNeutral ? Color.clear : tint.opacity(0.35), lineWidth: 1))
    }
}

struct ProviderPage: View {
    let detail: ProviderDetail
    // The color of the provider's petal on the front page, which tints this page.
    let color: Color
    let logos: ProviderLogoCatalog
    let now: Date
    // The name of an account, which the identifier toggle turns from "Account 2" into the account's own.
    let accountLabel: (AccountDetail) -> String
    let showsAccountLabels: Bool
    // Pairs the logo and the tint with the front page's. Nil under Reduce Motion, which cross-fades instead.
    let namespace: Namespace.ID?
    let back: () -> Void

    private var provider: String { detail.usage.provider }
    private var layout: FlowerLayout { FlowerLayout.forItemCount(detail.accounts.count) }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(color.opacity(0.10))
                .paired(PanelHero.tint(provider), in: namespace)
            VStack(spacing: 0) {
                header
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("quotablet.provider-page")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: back) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Back to providers")
            .help("Back to providers")
            .accessibilityIdentifier("quotablet.provider-back")
            ProviderMark(provider: provider, logos: logos, height: 22, maxWidth: 44)
                .paired(PanelHero.logo(provider), in: namespace)
            Text(ProviderRegistry.displayName(for: provider))
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            Text(detail.usage.usedText)
                .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(PetalLook.inkOnColor)
                .padding(.horizontal, 11)
                .frame(height: 28)
                .background(Capsule().fill(color))
                .accessibilityLabel(detail.usage.spokenSummary)
        }
        .padding(.leading, PageMetrics.inset - 6)
        .padding(.trailing, PageMetrics.inset)
        .frame(height: PageMetrics.headerHeight)
    }

    @ViewBuilder
    private var content: some View {
        switch layout {
        case .flower:
            VStack(spacing: 6) {
                let diameter = PageMetrics.flowerDiameter(accountCount: detail.accounts.count)
                AccountFlower(accounts: detail.accounts, diameter: diameter)
                    .frame(maxWidth: .infinity)
                    .frame(height: diameter)
                    .overlay(alignment: .bottomLeading) {
                        if detail.hasStaleAccount { StaleKey() }
                    }
                compactRows
            }
            .padding(.horizontal, PageMetrics.inset)
            .padding(.bottom, 8)
        case .list:
            if detail.accounts.count < FlowerLayout.petalRange.lowerBound {
                roomyCards
            } else {
                compactRows
                    .padding(.horizontal, PageMetrics.inset)
                    .padding(.bottom, 8)
            }
        }
    }

    // The account's petal color. Accounts without a flower take the provider's own.
    private func chipColor(for account: AccountDetail) -> Color {
        layout == .flower ? QuotaPalette.color(at: account.number - 1) : color
    }

    // The company whose logo the account's badge wears. Nil while identifiers are hidden, and nil when the app has no logo file for the company,
    // so the badge falls back to its number and the label never names a logo that the badge does not show.
    private func badgeCompany(of account: AccountDetail) -> AccountCompany? {
        guard
            let company = account.badgeCompany(revealingIdentifiers: showsAccountLabels),
            CompanyLogos.logo(for: company) != nil
        else { return nil }
        return company
    }

    private var compactRows: some View {
        VStack(spacing: 3) {
            HStack(spacing: PageMetrics.rowSpacing) {
                Text("Account")
                    .frame(width: PageMetrics.headWidth, alignment: .leading)
                ForEach(detail.windowColumns, id: \.self) { name in
                    Text(name)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, PageMetrics.rowPadding)
            .accessibilityHidden(true)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(detail.accountsByUrgency, id: \.number) { account in
                        AccountRow(
                            account: account,
                            color: chipColor(for: account),
                            columns: detail.windowColumns,
                            label: accountLabel(account),
                            showsLabel: showsAccountLabels,
                            company: badgeCompany(of: account),
                            now: now
                        )
                    }
                    problemRows
                }
            }
        }
    }

    // One or two accounts have the page to themselves, so each window gets a line of its own.
    private var roomyCards: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(detail.accountsByUrgency, id: \.number) { account in
                    AccountCard(
                        account: account,
                        color: chipColor(for: account),
                        label: accountLabel(account),
                        company: badgeCompany(of: account),
                        now: now
                    )
                }
                problemRows
            }
            .padding(.horizontal, PageMetrics.inset)
            .padding(.vertical, 8)
        }
    }

    // An account OMP lists without a report has no petal and no figure, so its row follows the accounts.
    private var problemRows: some View {
        ForEach(detail.problems, id: \.number) { problem in
            ProblemRow(detail: problem, label: problem.label(revealing: showsAccountLabels), now: now)
        }
    }
}

private struct AccountFlower: View {
    let accounts: [AccountDetail]
    let diameter: CGFloat

    var body: some View {
        let flower = FlowerGeometry(petalCount: accounts.count, diameter: diameter)
        ZStack {
            ForEach(accounts.indices, id: \.self) { index in
                PetalView(
                    geometry: flower.petals[index],
                    petal: Petal(accounts[index]),
                    color: QuotaPalette.color(at: index),
                    label: .number(petalCount: accounts.count),
                    badgeShowsCount: false
                )
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
        .accessibilityIdentifier("quotablet.account-flower")
    }
}

private struct StaleKey: View {
    var body: some View {
        HStack(spacing: 5) {
            Capsule()
                .fill(Color.primary.opacity(0.55))
                .mask { StripeBands(direction: .vertical) }
                .frame(width: 16, height: 6)
            Text("Stale data")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityHidden(true)
    }
}

// The account's number in its petal's color, so a row finds its petal by color and number. An account whose email domain has a logo wears the
// logo instead: the mark on a white plate ringed in the petal's color, and the number in a small disc of that color on the plate's corner.
// The badge keeps the footprint of the plain one. The mark is drawn as its file provides it, so the petal's color and staleness touch only
// the ring and the disc.
struct AccountChip: View {
    let number: Int
    // Nil for the plain number. The page passes a company only while identifiers are revealed, because a logo names where the account's email
    // lives or who employs its user.
    let company: AccountCompany?
    let color: Color
    let isStale: Bool

    var body: some View {
        if let company, let logo = CompanyLogos.logo(for: company) {
            companyBadge(logo)
        } else {
            plainBadge
        }
    }

    private var plainBadge: some View {
        Text("\(number)")
            .font(.system(size: 12, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(isStale ? Color.primary : PetalLook.inkOnColor)
            .frame(width: PageMetrics.chip, height: PageMetrics.chip)
            .background { ChipFill(color: color, isStale: isStale) }
    }

    private func companyBadge(_ logo: ProviderLogo) -> some View {
        let mark = LogoFit.size(aspectRatio: logo.aspectRatio, height: PageMetrics.chipMark, maxWidth: PageMetrics.chipMark)
        return ChipFill(color: color, isStale: isStale)
            .frame(width: PageMetrics.chip, height: PageMetrics.chip)
            .overlay {
                Circle()
                    .fill(Color.white)
                    .padding(PageMetrics.chipRing)
                    .overlay {
                        Image(nsImage: logo.artwork(height: mark.height))
                            .renderingMode(.original)
                            .resizable()
                            .frame(width: mark.width, height: mark.height)
                    }
            }
            .overlay(alignment: .bottomTrailing) {
                Text("\(number)")
                    .font(.system(size: PageMetrics.chipDiscDigits, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(PetalLook.inkOnColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(width: PageMetrics.chipDisc, height: PageMetrics.chipDisc)
                    .background {
                        // The disc rests on the plate and on the bare panel, so a stale fill needs a white base to show its stripes over.
                        if isStale { Circle().fill(Color.white) }
                        ChipFill(color: color, isStale: isStale)
                    }
                    .offset(x: PageMetrics.chipDiscOverhang, y: PageMetrics.chipDiscOverhang)
            }
    }
}

// How a chip is filled with its petal's color. A stale account's chip is a pale track under dimmed stripes, as its petal and its bars are.
private struct ChipFill: View {
    let color: Color
    let isStale: Bool

    var body: some View {
        if isStale {
            ZStack {
                Circle().fill(color.opacity(PetalLook.trackOpacity))
                Circle().fill(color)
                    .saturation(PetalLook.staleSaturation)
                    .opacity(PetalLook.staleOpacity)
                    .mask { StripeBands() }
            }
        } else {
            Circle().fill(color)
        }
    }
}

private struct StatusGlyph: View {
    let urgency: QuotaUrgency

    var body: some View {
        Image(systemName: urgency.symbol)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(StatusInk.color(for: AccountStatus(topUrgency: urgency)))
    }
}

// The reset credits an account has, counted beside the arrow that resets a quota. The row's label speaks them, so the capsule is only seen.
private struct ResetCreditsCapsule: View {
    let count: Int

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 8, weight: .bold))
            Text("\(count)")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 1.5)
        .background(Capsule().fill(Color.primary.opacity(0.08)))
        .fixedSize()
    }
}

// An exclamation mark in place of a number, because the account has no petal and no figure.
private struct ProblemChip: View {
    var body: some View {
        Text("!")
            .font(.system(size: 12, weight: .heavy, design: .rounded))
            .foregroundStyle(PetalLook.inkOnColor)
            .frame(width: PageMetrics.chip, height: PageMetrics.chip)
            .background(Circle().fill(Color(nsColor: .systemGray)))
    }
}

// An account OMP lists without a report. It has no windows and no bar, only what is wrong and what to do about it.
private struct ProblemRow: View {
    let detail: ProblemDetail
    let label: String
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ProblemChip()
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let cause {
                    Text(cause)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(detail.hint)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, PageMetrics.rowPadding)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .statusCard(.ok, radius: 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(detail.accessibilityLabel(label: label, now: now))
        .accessibilityIdentifier("quotablet.problem-row.\(detail.number)")
    }

    // The reason and the time, such as "Refresh token not found or invalid · since 3h 12m ago". Nil when OMP gives neither.
    private var cause: String? {
        let parts = [detail.problem.reason, detail.sinceText(now: now)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private struct CountdownTag: View {
    let text: String
    let ink: Color
    var size: CGFloat = 10.5

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: size - 2.5, weight: .bold))
            Text(text)
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(ink)
        .lineLimit(1)
        .fixedSize()
    }
}

private struct AccountRow: View {
    let account: AccountDetail
    let color: Color
    let columns: [String]
    let label: String
    let showsLabel: Bool
    // Nil for the plain number. The page passes a company only while identifiers are revealed.
    let company: AccountCompany?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showsLabel {
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: PageMetrics.rowSpacing) {
                head
                    .frame(width: PageMetrics.headWidth, alignment: .leading)
                ForEach(columns, id: \.self) { name in
                    if let window = account.windows.first(where: { $0.name.short == name }) {
                        WindowCell(window: window, isStale: account.isStale, now: now)
                    } else {
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }
            }
            if let summary = account.productUsageSummary {
                Text("\(AccountDetail.productUsageTitle) · \(AccountDetail.productUsageSource) · \(summary)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, PageMetrics.rowPadding)
        .padding(.vertical, 5)
        .statusCard(account.status, radius: 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(account.accessibilityLabel(accountLabel: label, now: now, company: company))
        .accessibilityIdentifier("quotablet.account-row.\(account.number)")
    }

    private var head: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                AccountChip(number: account.number, company: company, color: color, isStale: account.isStale)
                if let urgency = account.urgency {
                    StatusGlyph(urgency: urgency)
                }
            }
            if let credits = account.resetCredits {
                ResetCreditsCapsule(count: credits)
            }
            if account.isStale {
                StaleMark()
            }
        }
    }
}

private struct WindowCell: View {
    let window: WindowEntry
    let isStale: Bool
    let now: Date

    var body: some View {
        let status = AccountStatus(topUrgency: window.urgency)
        let ink = StatusInk.color(for: status)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                switch window.reading(now: now) {
                case .used(let percent, let resetsIn):
                    Text(percent)
                        .font(.system(size: 11, weight: status == .ok ? .semibold : .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(status == .ok ? Color.primary : ink)
                    Spacer(minLength: 0)
                    if let resetsIn {
                        CountdownTag(text: resetsIn, ink: status == .ok ? Color.secondary : ink)
                    }
                case .exhausted(let resetsIn):
                    CountdownTag(text: resetsIn, ink: ink, size: 11.5)
                    Spacer(minLength: 0)
                }
            }
            ThinBar(used: window.usedFraction, color: ink, height: 4, isStale: isStale)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct AccountCard: View {
    let account: AccountDetail
    let color: Color
    let label: String
    // Nil for the plain number. The page passes a company only while identifiers are revealed.
    let company: AccountCompany?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                AccountChip(number: account.number, company: company, color: color, isStale: account.isStale)
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let urgency = account.urgency {
                    StatusGlyph(urgency: urgency)
                }
                if let credits = account.resetCredits {
                    ResetCreditsCapsule(count: credits)
                }
                Spacer(minLength: 8)
                if account.isStale {
                    StaleMark()
                }
            }
            VStack(spacing: 9) {
                ForEach(Array(account.windows.enumerated()), id: \.offset) { _, window in
                    VStack(alignment: .leading, spacing: 3) {
                        WindowLine(window: window, isStale: account.isStale, now: now)
                        if let money = window.money {
                            MoneyLine(money: money)
                        }
                    }
                }
                if !account.productUsage.isEmpty {
                    ProductUsageBlock(entries: account.productUsage, isStale: account.isStale)
                }
            }
        }
        .padding(12)
        .statusCard(account.status, radius: 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(account.accessibilityLabel(accountLabel: label, now: now, company: company))
        .accessibilityIdentifier("quotablet.account-row.\(account.number)")
    }
}

private struct WindowLine: View {
    let window: WindowEntry
    let isStale: Bool
    let now: Date

    var body: some View {
        let status = AccountStatus(topUrgency: window.urgency)
        let ink = StatusInk.color(for: status)
        HStack(spacing: 10) {
            Text(window.name.short)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: PageMetrics.windowName, alignment: .leading)
            ThinBar(used: window.usedFraction, color: ink, height: 5, isStale: isStale)
            switch window.reading(now: now) {
            case .used(let percent, let resetsIn):
                Text(percent)
                    .font(.system(size: 13, weight: status == .ok ? .semibold : .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(status == .ok ? Color.primary : ink)
                    .frame(width: 44, alignment: .trailing)
                ZStack(alignment: .trailing) {
                    Color.clear
                    if let resetsIn {
                        CountdownTag(text: resetsIn, ink: status == .ok ? Color.secondary : ink, size: 11)
                    }
                }
                .frame(width: 70, height: 14)
            case .exhausted(let resetsIn):
                CountdownTag(text: resetsIn, ink: ink, size: 13)
                    .frame(width: 114, alignment: .trailing)
            }
        }
    }
}

// What a quota in dollars has used, under its own line. The percent above it is the same quota's share, and the two are never added.
private struct MoneyLine: View {
    let money: MoneyUsage

    var body: some View {
        Text(money.text())
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.leading, PageMetrics.windowName + 10)
    }
}

// What each product has used of the shared pool, as OMP reports it. It sits under the account's windows in smaller, quieter type with a rule down
// its side, so it reads as a breakdown and not as limits of its own. A product has a used percent and nothing more: no remaining amount, no reset time.
private struct ProductUsageBlock: View {
    let entries: [ProductUsageEntry]
    let isStale: Bool

    private static let indent: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(AccountDetail.productUsageTitle)
                    .font(.system(size: 11, weight: .semibold))
                Text(AccountDetail.productUsageSource)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                HStack(spacing: 10) {
                    Text(entry.name)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: PageMetrics.windowName - Self.indent, alignment: .leading)
                    ThinBar(used: entry.usedFraction, color: .secondary, height: 3, isStale: isStale)
                    Text(UsageFormatting.usedPercent(entry.usedFraction))
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                    Color.clear.frame(width: 70, height: 1)
                }
            }
        }
        .padding(.leading, Self.indent)
        .overlay(alignment: .leading) {
            Capsule()
                .fill(Color.primary.opacity(0.18))
                .frame(width: 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
