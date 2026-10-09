import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MenuBarLabel: View {
    @Bindable var store: UsageStore

    var body: some View {
        let now = store.presentationDate
        let content = store.menuBarContent
        let badges = MenuBarBadge.badges(for: content, now: now)
        let summary = store.menuBarAccessibilityLabel(now: now)
        glyph(for: badges, overflow: content.hiddenAttentionCount)
            .accessibilityLabel(summary)
            .help(summary)
    }

    @ViewBuilder
    private func glyph(for badges: [MenuBarBadge], overflow: Int) -> some View {
        if badges.isEmpty {
            Image(systemName: "gauge.with.dots.needle.33percent")
        } else {
            Image(nsImage: MenuBarBadgeRenderer.image(for: badges, overflow: overflow))
                .renderingMode(.template)
        }
    }
}

struct UsagePanel: View {
    @Bindable var store: UsageStore
    @State private var isChoosingCLI = false
    @State private var selectionError: String?

    var body: some View {
        panel(now: store.presentationDate)
        .frame(width: 420, height: 600)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .fileImporter(
            isPresented: $isChoosingCLI,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await store.setCLIPath(url.path) }
            case .failure:
                selectionError = "The OMP executable was not changed."
            }
        }
    }

    private func panel(now: Date) -> some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.65)
            if let error = store.lastError {
                NoticeRow(text: error.localizedDescription, symbol: "exclamationmark.triangle.fill", color: .orange)
            }
            if store.persistenceWarning {
                NoticeRow(text: "Private data could not be saved.", symbol: "lock.fill", color: .secondary)
            }
            if let selectionError {
                NoticeRow(text: selectionError, symbol: "info.circle", color: .secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    let attention = store.snapshot?.attentionItems() ?? []
                    let summaryRepeatsAttention = store.pinnedQuotas.keys.isEmpty && !attention.isEmpty
                    if !attention.isEmpty {
                        attentionSection(attention, now: now)
                    }
                    if !summaryRepeatsAttention {
                        menuBarSelection(now: now)
                    }
                    collectionContent(now: now)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().opacity(0.65)
            footer
        }
        .background(.regularMaterial)
        .accessibilityIdentifier("quotablet.usage-panel")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Quotablet")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                Text(collectionStatus)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(collectionStatus)
            }
            Spacer(minLength: 8)
            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(store.isRefreshing)
            .accessibilityLabel("Refresh usage now")
            .help("Fetch the latest usage reports from OMP.")
            .keyboardShortcut("r", modifiers: .command)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var collectionStatus: String {
        if store.isRefreshing { return "Refreshing OMP" }
        if store.lastError != nil {
            return store.snapshot == nil ? "Refresh failed" : "Refresh failed · showing saved data"
        }
        guard let snapshot = store.snapshot else { return "Waiting for OMP" }
        if snapshot.reports.isEmpty {
            return store.snapshotOrigin == .cached ? "Saved snapshot · no usage reports" : "No usage reports"
        }
        return store.snapshotOrigin == .cached ? "Saved snapshot" : "OMP snapshot received"
    }

    private func menuBarSelection(now: Date) -> some View {
        let content = store.menuBarContent
        let slots = content.slots
        let badges = MenuBarBadge.badges(for: content, now: now)
        let layout = SummaryLayout.forSlotCount(slots.count)
        return VStack(alignment: .leading, spacing: layout.cardSpacing) {
            HStack(spacing: 6) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text("MENU BAR SUMMARY")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .tracking(0.7)
                Spacer()
                Text(selectionKind(for: slots))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            if slots.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("No usage window is available for the menu bar summary.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text(store.freshness(for: nil).displayLabel(now: now))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            } else {
                switch layout {
                case .list:
                    ForEach(Array(zip(slots, badges).enumerated()), id: \.offset) { _, pair in
                        MenuBarSlotRow(
                            slot: pair.0,
                            badge: pair.1,
                            accountLabel: pair.0.selected.map { accountLabel(for: $0.report, number: $0.accountNumber) },
                            freshness: store.freshness(for: pair.0.selected?.report),
                            now: now,
                            onRemove: { key in Task { await store.removePin(key) } }
                        )
                    }
                case .flower:
                    QuotaFlowerSummary(
                        slots: slots,
                        badges: badges,
                        freshness: store.freshness(of: slots),
                        now: now,
                        onRemove: { key in Task { await store.removePin(key) } }
                    )
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, layout.cardVerticalPadding)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityIdentifier("quotablet.menu-bar-selection")
    }

    private func attentionSection(_ items: [AttentionItem], now: Date) -> some View {
        // Every account that needs attention has a row, so none is hidden here, and the menu bar counts the same accounts for its numbers.
        let badges = MenuBarBadge.badges(for: MenuBarContent(slots: items.map { MenuBarSlot.attention($0.selection) }), now: now)
        // The rows share one badge column so their text lines up whatever tag or number each badge carries.
        let badgeWidth = badges.map { MenuBarBadgeRenderer.image(for: [$0], height: 22).size.width }.max() ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text("NEEDS ATTENTION · \(items.count)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .tracking(0.7)
                Spacer()
            }
            ForEach(Array(zip(items, badges).enumerated()), id: \.offset) { _, pair in
                AttentionRow(
                    item: pair.0,
                    badge: pair.1,
                    badgeWidth: badgeWidth,
                    accountLabel: accountLabel(for: pair.0.selection.report, number: pair.0.selection.accountNumber),
                    now: now
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityIdentifier("quotablet.needs-attention")
    }

    private func selectionKind(for slots: [MenuBarSlot]) -> String {
        switch slots.first {
        case nil: "NONE"
        case .defaulted?: "MOST USED"
        case .attention?: "NEEDS ATTENTION · \(slots.count)"
        case .pinned?, .missing?: "PINNED · \(slots.count)"
        }
    }

    @ViewBuilder
    private func collectionContent(now: Date) -> some View {
        if let snapshot = store.snapshot {
            if snapshot.reports.isEmpty {
                EmptyState(
                    symbol: "chart.bar.xaxis",
                    title: store.snapshotOrigin == .cached ? "No saved usage reports" : "No usage reports",
                    detail: "OMP returned a valid empty snapshot. A later refresh can add reports."
                )
                .frame(maxWidth: .infinity, minHeight: 245)
            } else {
                let topAttention = Dictionary(uniqueKeysWithValues: snapshot.accountAttention().map { ($0.selection.report.id, $0) })
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(snapshot.reports) { report in
                        AccountSection(
                            report: report,
                            accountLabel: accountLabel(for: report, number: snapshot.accountNumber(of: report)),
                            now: now,
                            freshness: store.freshness(for: report),
                            pins: store.pinnedQuotas,
                            attention: topAttention[report.id],
                            onTogglePin: { key in Task { await store.togglePin(key) } }
                        )
                    }
                }
            }
        } else if store.isRefreshing {
            EmptyState(
                symbol: "arrow.triangle.2.circlepath",
                title: "Connecting to OMP",
                detail: "Usage appears here when OMP returns its current reports."
            )
            .frame(maxWidth: .infinity, minHeight: 245)
        } else if store.lastError != nil {
            EmptyState(
                symbol: "terminal",
                title: "Usage is unavailable",
                detail: "Choose the OMP executable or retry after it is available."
            )
            .frame(maxWidth: .infinity, minHeight: 245)
        } else {
            EmptyState(
                symbol: "chart.bar.xaxis",
                title: "Waiting for usage",
                detail: "Quotablet reads usage from your local OMP installation."
            )
            .frame(maxWidth: .infinity, minHeight: 245)
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            HStack(spacing: 14) {
                Button {
                    store.setRevealsIdentifiers(!store.revealsIdentifiers)
                } label: {
                    Image(systemName: store.revealsIdentifiers ? "eye.slash" : "eye")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(store.revealsIdentifiers ? "Hide account identifiers" : "Show account identifiers")
                .help(store.revealsIdentifiers ? "Hide account names and identifiers for this session." : "Reveal account names and identifiers for this session.")
                .keyboardShortcut("p", modifiers: [.command, .shift])

                Button {
                    isChoosingCLI = true
                    selectionError = nil
                } label: {
                    Label("Choose OMP…", systemImage: "gearshape")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Choose OMP executable")
                .help("Select the executable used for omp usage --json.")

                if store.executablePath != nil {
                    Button("Automatic") {
                        Task { await store.setCLIPath(nil) }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Use automatic OMP discovery")
                }

                Spacer(minLength: 0)
                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label("Quit", systemImage: "power")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Quit Quotablet")
                .keyboardShortcut("q", modifiers: .command)
            }
            HStack {
                Text(store.executablePath == nil ? "Automatic CLI discovery" : "Custom CLI path")
                Spacer()
                Text("Refreshes every \(UsagePolicy.refreshIntervalSeconds / 60) minutes")
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .accessibilityElement(children: .combine)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func accountLabel(for report: UsageReport, number: Int) -> String {
        guard store.revealsIdentifiers else { return UsageFormatting.accountAlias(number) }
        return report.revealedAccountLabel ?? "Account"
    }
}


private struct UsageQuotaRow: View {
    let quota: UsageQuota
    let provider: String
    let accountLabel: String
    let now: Date
    let isPinned: Bool
    let onTogglePin: (QuotaPinKey) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(quota.label)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(2)
                    HStack(spacing: 5) {
                        Text(quota.windowDisplayName)
                        if let tier = quota.scope?.tier, !tier.allSatisfy(\.isWhitespace) {
                            Text("·")
                            Text(tier)
                        }
                        if let status = quota.status.label {
                            Text("·")
                            Text(status)
                        } else if quota.isKnownExhausted {
                            Text("·")
                            Text("No remaining")
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(statusColor)
                }
                Spacer(minLength: 8)
                Text(UsageFormatting.remainingText(quota.amount))
                    .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(minWidth: 74, alignment: .trailing)
                    .accessibilityHidden(true)
                Button {
                    guard let key = quota.pinKey else { return }
                    onTogglePin(key)
                } label: {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(quota.pinKey == nil)
                .accessibilityLabel(pinAccessibilityLabel)
                .help(quota.pinKey == nil ? "This quota has no unique stable account and window key." : (isPinned ? "Remove this quota from the menu bar." : "Pin this quota in the menu bar."))
            }
            if let progress = quota.amount?.progress {
                HStack(spacing: 6) {
                    Text(UsageFormatting.progressLabel(progress))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .controlSize(.mini)
                        .tint(statusColor)
                        .accessibilityHidden(true)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(UsageFormatting.progressLabel(progress))
            }
            HStack(spacing: 8) {
                Text(resetDescription)
                if quota.scope?.shared == true && quota.isKnownExhausted {
                    Text("Shared limit exhausted")
                        .foregroundStyle(.orange)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(rowAccessibilityLabel)
        }
        .accessibilityElement(children: .contain)
    }

    private var statusColor: Color {
        if quota.isKnownExhausted { return .red }
        switch quota.status {
        case .nearLimit: return .orange
        case .available, .missing, .unknown(_): return .secondary
        case .exhausted: return .red
        }
    }

    private var resetDescription: String {
        UsageFormatting.resetDescription(
            for: quota.resetsAt,
            resetLabel: quota.window?.resetLabel,
            now: now
        )
    }

    private var pinAccessibilityLabel: String {
        guard quota.pinKey != nil else {
            return "Pin unavailable for \(quota.label) because its account and window identity is ambiguous"
        }
        return isPinned ? "Unpin \(quota.label) from the menu bar" : "Pin \(quota.label) in the menu bar"
    }

    private var rowAccessibilityLabel: String {
        let remaining = UsageFormatting.remainingText(quota.amount)
        let tier = quota.scope?.tier.map { ", tier \($0)" } ?? ""
        let progress = quota.amount?.progress.map { ", \(UsageFormatting.progressLabel($0))" } ?? ""
        let shared = quota.scope?.shared == true && quota.isKnownExhausted ? ", shared limit exhausted" : ""
        return "\(ProviderRegistry.displayName(for: provider)), \(accountLabel), \(quota.label), \(quota.windowDisplayName), \(remaining), \(resetDescription)\(tier)\(progress)\(shared)"
    }
}

private struct AccountSection: View {
    let report: UsageReport
    let accountLabel: String
    let now: Date
    let freshness: UsageFreshness
    let pins: MenuBarPins
    let attention: AttentionItem?
    let onTogglePin: (QuotaPinKey) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(ProviderRegistry.displayName(for: report.provider))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    Text(accountLabel)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 2)
                    Text(providerAge)
                        .font(.system(size: 10, weight: ageIsStale ? .semibold : .regular))
                        .foregroundStyle(ageIsStale || freshness.refreshStatus == .failed ? Color.orange : Color.secondary)
                        .lineLimit(1)
                        .accessibilityLabel(providerAge)
                }
                if let attention {
                    Text(attentionSummary(of: attention))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(attention.urgency.color)
                }
            }
            if let resetCredits = report.resetCredits {
                Text("Reset credits · \(resetCredits)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            if report.quotas.isEmpty {
                Text("No quota windows in this report.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 5)
            } else {
                VStack(spacing: 0) {
                    ForEach(report.quotas) { quota in
                        UsageQuotaRow(
                            quota: quota,
                            provider: report.provider,
                            accountLabel: accountLabel,
                            now: now,
                            isPinned: quota.pinKey.map { pins.contains($0) } ?? false,
                            onTogglePin: onTogglePin
                        )
                        if quota.id != report.quotas.last?.id {
                            Divider().padding(.vertical, 9)
                        }
                    }
                }
            }
        }
        .padding(.top, 2)
        .accessibilityElement(children: .contain)
    }

    private var ageIsStale: Bool {
        freshness.isStale(at: now)
    }

    private var providerAge: String {
        freshness.displayLabel(now: now)
    }

    private func attentionSummary(of item: AttentionItem) -> String {
        let quota = item.selection.quota
        let reset = UsageFormatting.resetPhrase(for: quota.resetsAt, resetLabel: quota.window?.resetLabel, now: now)
        return "\(quota.label) \(item.urgency.label.lowercased()) · \(reset)"
    }
}

private struct MenuBarSlotRow: View {
    let slot: MenuBarSlot
    let badge: MenuBarBadge
    let accountLabel: String?
    let freshness: UsageFreshness
    let now: Date
    let onRemove: (QuotaPinKey) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(nsImage: MenuBarBadgeRenderer.image(for: [badge], height: 22))
                .renderingMode(.template)
                .accessibilityHidden(true)
            switch slot {
            case .pinned(let selection), .attention(let selection), .defaulted(let selection):
                selectionDetails(selection)
            case .missing(let key):
                missingDetails(key)
            }
        }
    }

    private func selectionDetails(_ selection: SelectedQuota) -> some View {
        let remaining = UsageFormatting.remainingText(selection.quota.amount)
        let needsAttention = freshness.isStale(at: now) || freshness.refreshStatus == .failed
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(ProviderRegistry.displayName(for: selection.report.provider))
                        .font(.system(size: 13, weight: .semibold))
                    if let accountLabel {
                        Text(accountLabel)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                Text(selection.quota.label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(remaining)
                    .font(.system(size: 16, weight: .semibold, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .accessibilityLabel(remaining)
                Text(freshness.displayLabel(now: now))
                    .font(.system(size: 9, weight: needsAttention ? .semibold : .regular))
                    .foregroundStyle(needsAttention ? Color.orange : Color.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func missingDetails(_ key: QuotaPinKey) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Pinned quota unavailable")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(freshness.displayLabel(now: now))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Remove") {
                onRemove(key)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove unavailable pinned quota")
        }
    }
}

private struct AttentionRow: View {
    let item: AttentionItem
    let badge: MenuBarBadge
    let badgeWidth: CGFloat
    let accountLabel: String
    let now: Date

    var body: some View {
        let quota = item.selection.quota
        return HStack(alignment: .center, spacing: 10) {
            Image(nsImage: MenuBarBadgeRenderer.image(for: [badge], height: 22))
                .renderingMode(.template)
                .frame(width: badgeWidth, alignment: .leading)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(ProviderRegistry.displayName(for: item.selection.report.provider))
                        .font(.system(size: 13, weight: .semibold))
                        .layoutPriority(1)
                    Text(accountLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .truncationMode(.middle)
                }
                .lineLimit(1)
                HStack(spacing: 5) {
                    Text(quota.label)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(item.urgency.label)
                        .fontWeight(.semibold)
                        .foregroundStyle(item.urgency.color)
                        .layoutPriority(1)
                    if badge.isStale {
                        Text("·")
                            .foregroundStyle(.secondary)
                        Text("Stale")
                            .fontWeight(.semibold)
                            .foregroundStyle(.orange)
                            .layoutPriority(1)
                    }
                }
                .font(.system(size: 11))
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(UsageFormatting.remainingText(quota.amount))
                    .font(.system(size: 16, weight: .semibold, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(resetDescription)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rowAccessibilityLabel)
    }

    private var resetDescription: String {
        let quota = item.selection.quota
        return UsageFormatting.resetDescription(for: quota.resetsAt, resetLabel: quota.window?.resetLabel, now: now)
    }

    private var rowAccessibilityLabel: String {
        let quota = item.selection.quota
        let provider = ProviderRegistry.displayName(for: item.selection.report.provider)
        let remaining = UsageFormatting.remainingText(quota.amount)
        let stale = badge.isStale ? ", stale" : ""
        return "\(provider), \(accountLabel), \(quota.label), \(item.urgency.label.lowercased()), \(remaining), \(resetDescription)\(stale)"
    }
}

private struct NoticeRow: View {
    let text: String
    let symbol: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

private struct EmptyState: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 270)
        }
        .accessibilityElement(children: .combine)
    }
}

private extension QuotaUrgency {
    var color: Color {
        switch self {
        case .exhausted: .red
        case .nearLimit: .orange
        }
    }
}

