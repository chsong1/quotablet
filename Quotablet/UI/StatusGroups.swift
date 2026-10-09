import AppKit
import SwiftUI

extension AccountStatus {
    var title: String {
        switch self {
        case .exhausted: QuotaUrgency.exhausted.label
        case .nearLimit: QuotaUrgency.nearLimit.label
        case .ok: "OK"
        }
    }

    // Three shapes, so a status never rests on its color alone.
    var symbol: String {
        switch self {
        case .exhausted: "xmark.octagon.fill"
        case .nearLimit: "exclamationmark.triangle.fill"
        case .ok: "checkmark.circle.fill"
        }
    }

    // Names the figure at the right of each row in the group.
    var caption: String {
        switch self {
        case .exhausted: "resets in"
        case .nearLimit, .ok: "left"
        }
    }

    // For example "Exhausted, 2", which is how VoiceOver reads a group header.
    func headerLabel(count: Int) -> String {
        "\(title), \(count)"
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

extension ResetCountdown {
    // The large figure of an Exhausted row. Only a running countdown is worth reading large, so the other two are plain fallbacks.
    var figure: String {
        switch self {
        case .remaining(let text): text
        case .passed: "Recheck"
        case .unknown: "—"
        }
    }

    // The small line under a Near limit figure.
    var caption: String {
        switch self {
        case .remaining(let text): "resets \(text)"
        case .passed: "reset passed"
        case .unknown: "reset unknown"
        }
    }
}

extension AttentionLine {
    // For example "Codex Account 1, 7 days near limit, 3% left, resets in 4d 14h". An Exhausted line skips the share, which is zero.
    func accessibilityLabel(accountLabel: String, isStale: Bool, now: Date) -> String {
        let names = quotas.map { $0.quota.spokenName(provider: report.provider) }.joined(separator: " and ")
        var parts = [
            "\(ProviderRegistry.displayName(for: report.provider)) \(accountLabel)",
            "\(names) \(urgency.label.lowercased())"
        ]
        if urgency == .nearLimit {
            parts.append(lead.quota.spokenShareLeft)
        }
        parts.append(UsageFormatting.resetPhrase(for: resetsAt, resetLabel: lead.quota.window?.resetLabel, now: now))
        if isStale {
            parts.append("stale")
        }
        return parts.joined(separator: ", ")
    }
}

extension HealthyLine {
    // For example "Claude Account 2, OK, 7 Day, 22% left".
    func accessibilityLabel(accountLabel: String, isStale: Bool) -> String {
        var parts = [
            "\(ProviderRegistry.displayName(for: report.provider)) \(accountLabel)",
            AccountStatus.ok.title,
            lead.quota.spokenName(provider: report.provider),
            lead.quota.spokenShareLeft
        ]
        if isStale {
            parts.append("stale")
        }
        return parts.joined(separator: ", ")
    }
}

private extension UsageQuota {
    // A window label such as "Claude 7 Day" repeats the provider, which the row already speaks first.
    func spokenName(provider: String) -> String {
        let prefix = "\(ProviderRegistry.displayName(for: provider)) "
        guard label.hasPrefix(prefix), label.dropFirst(prefix.count).first?.isNumber == true else { return label }
        return String(label.dropFirst(prefix.count))
    }

    var spokenShareLeft: String {
        UsageFormatting.percentLeft(self).map { "\($0) left" } ?? "remaining unknown"
    }
}

private enum StatusMetrics {
    static let rowHeight: CGFloat = 28
    static let headerHeight: CGFloat = 22
    static let groupSpacing: CGFloat = 10
    static let cornerRadius: CGFloat = 10
    static let tagWidth: CGFloat = 30
    static let barWidth: CGFloat = 64
    static let barHeight: CGFloat = 3
    static let percentWidth: CGFloat = 46
    static let headerGap: CGFloat = 6
}

private enum Typeface {
    static let figure: Font = .system(size: 20, weight: .semibold, design: .rounded).monospacedDigit()
    static let fallback: Font = .system(size: 14, weight: .semibold, design: .rounded)
    static let healthyPercent: Font = .system(size: 15, weight: .semibold, design: .rounded).monospacedDigit()
}

struct StatusGroups: View {
    let overview: StatusOverview
    @Binding var isOKExpanded: Bool
    let now: Date
    let accountLabel: (UsageReport, Int) -> String
    let isStale: (UsageReport) -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: StatusMetrics.groupSpacing) {
            attentionGroup(.exhausted, lines: overview.exhausted)
            attentionGroup(.nearLimit, lines: overview.nearLimit)
            if !overview.ok.isEmpty {
                FoldableStatusSection(status: .ok, count: overview.ok.count, isExpanded: $isOKExpanded) {
                    ForEach(Array(overview.ok.enumerated()), id: \.offset) { _, line in
                        HealthyLineRow(
                            line: line,
                            accountLabel: accountLabel(line.report, line.accountNumber),
                            isStale: isStale(line.report)
                        )
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("quotablet.status-groups")
    }

    @ViewBuilder
    private func attentionGroup(_ urgency: QuotaUrgency, lines: [AttentionLine]) -> some View {
        if !lines.isEmpty {
            StatusSection(status: AccountStatus(topUrgency: urgency), count: lines.count) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    AttentionLineRow(
                        line: line,
                        accountLabel: accountLabel(line.report, line.accountNumber),
                        isStale: isStale(line.report),
                        now: now
                    )
                }
            }
        }
    }
}

// A chevron and a label that fold the content below them. The caller holds the state, so nothing is saved.
struct DisclosureToggle<Label: View>: View {
    @Binding var isExpanded: Bool
    let spokenLabel: String
    private let label: Label

    init(isExpanded: Binding<Bool>, spokenLabel: String, @ViewBuilder label: () -> Label) {
        _isExpanded = isExpanded
        self.spokenLabel = spokenLabel
        self.label = label()
    }

    var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 10)
                    .foregroundStyle(.secondary)
                label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(spokenLabel)
        .accessibilityValue(isExpanded ? "expanded" : "collapsed")
    }
}

private struct StatusSection<Rows: View>: View {
    let status: AccountStatus
    let count: Int
    private let rows: Rows

    init(status: AccountStatus, count: Int, @ViewBuilder rows: () -> Rows) {
        self.status = status
        self.count = count
        self.rows = rows()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StatusMetrics.headerGap) {
            HStack(spacing: 6) {
                StatusHeading(status: status, count: count)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(status.headerLabel(count: count))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                StatusCaption(status: status)
            }
            .frame(height: StatusMetrics.headerHeight)
            VStack(spacing: 0) {
                rows
            }
            .statusContainer(status)
        }
    }
}

// The same section with a chevron that folds its rows. The caption goes with the rows it describes.
private struct FoldableStatusSection<Rows: View>: View {
    let status: AccountStatus
    let count: Int
    @Binding var isExpanded: Bool
    private let rows: Rows

    init(status: AccountStatus, count: Int, isExpanded: Binding<Bool>, @ViewBuilder rows: () -> Rows) {
        self.status = status
        self.count = count
        _isExpanded = isExpanded
        self.rows = rows()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StatusMetrics.headerGap) {
            HStack(spacing: 6) {
                DisclosureToggle(isExpanded: $isExpanded, spokenLabel: status.headerLabel(count: count)) {
                    StatusHeading(status: status, count: count)
                }
                .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                if isExpanded {
                    StatusCaption(status: status)
                }
            }
            .frame(height: StatusMetrics.headerHeight)
            if isExpanded {
                VStack(spacing: 0) {
                    rows
                }
                .statusContainer(status)
            }
        }
    }
}

private struct StatusHeading: View {
    let status: AccountStatus
    let count: Int

    var body: some View {
        let ink = StatusInk.color(for: status)
        HStack(spacing: 6) {
            Image(systemName: status.symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(ink)
            Text(status.title)
                .font(.system(size: 12.5, weight: .bold))
                .foregroundStyle(ink)
            Text("\(count)")
                .font(.system(size: 11, weight: .bold).monospacedDigit())
                .foregroundStyle(ink)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(StatusInk.tint(for: status).opacity(0.18)))
        }
    }
}

private struct StatusCaption: View {
    let status: AccountStatus

    var body: some View {
        Text(status.caption)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.trailing, 10)
            .accessibilityHidden(true)
    }
}

private extension View {
    // Attention groups sit in a tinted container with a stroke. OK stays neutral, so it does not compete with them.
    func statusContainer(_ status: AccountStatus) -> some View {
        let shape = RoundedRectangle(cornerRadius: StatusMetrics.cornerRadius, style: .continuous)
        let tint = StatusInk.tint(for: status)
        let isNeutral = status == .ok
        return padding(.vertical, 4)
            .padding(.horizontal, 10)
            .background(shape.fill(isNeutral ? Color.primary.opacity(0.05) : tint.opacity(0.12)))
            .overlay(shape.strokeBorder(isNeutral ? Color.clear : tint.opacity(0.35), lineWidth: 1))
    }
}

private struct AttentionLineRow: View {
    let line: AttentionLine
    let accountLabel: String
    let isStale: Bool
    let now: Date

    private var status: AccountStatus {
        AccountStatus(topUrgency: line.urgency)
    }

    private var countdown: ResetCountdown {
        UsageFormatting.countdown(to: line.resetsAt, now: now)
    }

    var body: some View {
        HStack(spacing: 8) {
            RowHead(status: status, tag: UsageFormatting.accountTag(provider: line.report.provider, number: line.accountNumber))
            Text(line.quotas.map { UsageFormatting.shortLabel(for: $0.quota) }.joined(separator: ", "))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if isStale {
                StaleMark()
            }
            Spacer(minLength: 6)
            figure
        }
        .frame(minHeight: StatusMetrics.rowHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.accessibilityLabel(accountLabel: accountLabel, isStale: isStale, now: now))
    }

    @ViewBuilder
    private var figure: some View {
        let ink = StatusInk.color(for: status)
        switch line.urgency {
        case .exhausted:
            Text(countdown.figure)
                .font(countdownFont)
                .foregroundStyle(ink)
                .fixedSize()
        case .nearLimit:
            let percent = UsageFormatting.percentLeft(line.lead.quota)
            VStack(alignment: .trailing, spacing: 0) {
                Text(percent ?? "—")
                    .font(percent == nil ? Typeface.fallback : Typeface.figure)
                    .foregroundStyle(ink)
                    .fixedSize()
                Text(countdown.caption)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var countdownFont: Font {
        if case .remaining = countdown { return Typeface.figure }
        return Typeface.fallback
    }
}

private struct HealthyLineRow: View {
    let line: HealthyLine
    let accountLabel: String
    let isStale: Bool

    var body: some View {
        HStack(spacing: 8) {
            RowHead(status: .ok, tag: UsageFormatting.accountTag(provider: line.report.provider, number: line.accountNumber))
            Text(UsageFormatting.shortLabel(for: line.lead.quota))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if isStale {
                StaleMark()
            }
            Spacer(minLength: 6)
            ShareBar(share: line.lead.quota.remainingShare, ink: StatusInk.color(for: .ok))
                .frame(width: StatusMetrics.barWidth)
            Text(UsageFormatting.percentLeft(line.lead.quota) ?? "—")
                .font(Typeface.healthyPercent)
                .lineLimit(1)
                .frame(width: StatusMetrics.percentWidth, alignment: .trailing)
        }
        .frame(minHeight: StatusMetrics.rowHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.accessibilityLabel(accountLabel: accountLabel, isStale: isStale))
    }
}

// The status symbol and the account tag, which share one column layout so the labels of every row line up.
private struct RowHead: View {
    let status: AccountStatus
    let tag: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: status.symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(status == .ok ? Color.secondary : StatusInk.color(for: status))
                .frame(width: 16)
            Text(tag)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .fixedSize()
                .frame(minWidth: StatusMetrics.tagWidth, alignment: .leading)
        }
    }
}

private struct StaleMark: View {
    var body: some View {
        Text("Stale")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(StatusInk.color(for: .nearLimit))
            .fixedSize()
    }
}

private struct ShareBar: View {
    let share: Double?
    let ink: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.14))
                if let share {
                    Capsule()
                        .fill(ink)
                        .frame(width: max(StatusMetrics.barHeight, proxy.size.width * min(max(share, 0), 1)))
                }
            }
        }
        .frame(height: StatusMetrics.barHeight)
        .accessibilityHidden(true)
    }
}
