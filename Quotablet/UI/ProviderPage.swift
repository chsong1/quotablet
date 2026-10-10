import AppKit
import SwiftUI

private enum PageMetrics {
    static let headerHeight: CGFloat = 46
    static let inset: CGFloat = 18
    static let headWidth: CGFloat = 46
    static let rowSpacing: CGFloat = 8
    static let rowPadding: CGFloat = 8
    static let chip: CGFloat = 24

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
                            now: now
                        )
                    }
                }
            }
        }
    }

    // One or two accounts have the page to themselves, so each window gets a line of its own.
    private var roomyCards: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(detail.accountsByUrgency, id: \.number) { account in
                    AccountCard(account: account, color: chipColor(for: account), label: accountLabel(account), now: now)
                }
            }
            .padding(.horizontal, PageMetrics.inset)
            .padding(.vertical, 8)
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

// The account's number in its petal's color, so a row finds its petal by color and number.
private struct AccountChip: View {
    let number: Int
    let color: Color
    let isStale: Bool

    var body: some View {
        Text("\(number)")
            .font(.system(size: 12, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(isStale ? Color.primary : PetalLook.inkOnColor)
            .frame(width: PageMetrics.chip, height: PageMetrics.chip)
            .background {
                if isStale {
                    Circle().fill(color.opacity(PetalLook.trackOpacity))
                    Circle().fill(color)
                        .saturation(PetalLook.staleSaturation)
                        .opacity(PetalLook.staleOpacity)
                        .mask { StripeBands() }
                } else {
                    Circle().fill(color)
                }
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
        }
        .padding(.horizontal, PageMetrics.rowPadding)
        .padding(.vertical, 5)
        .statusCard(account.status, radius: 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(account.accessibilityLabel(accountLabel: label, now: now))
        .accessibilityIdentifier("quotablet.account-row.\(account.number)")
    }

    private var head: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                AccountChip(number: account.number, color: color, isStale: account.isStale)
                if let urgency = account.urgency {
                    StatusGlyph(urgency: urgency)
                }
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
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                AccountChip(number: account.number, color: color, isStale: account.isStale)
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let urgency = account.urgency {
                    StatusGlyph(urgency: urgency)
                }
                Spacer(minLength: 8)
                if account.isStale {
                    StaleMark()
                }
            }
            VStack(spacing: 9) {
                ForEach(Array(account.windows.enumerated()), id: \.offset) { _, window in
                    WindowLine(window: window, isStale: account.isStale, now: now)
                }
            }
        }
        .padding(12)
        .statusCard(account.status, radius: 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(account.accessibilityLabel(accountLabel: label, now: now))
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
                .frame(width: 96, alignment: .leading)
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
