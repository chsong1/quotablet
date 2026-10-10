import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MenuBarLabel: View {
    @Bindable var store: UsageStore
    // The logo variant is picked when AppKit draws the image, so SwiftUI must build a new image when the menu bar changes appearance.
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let now = store.presentationDate
        let providers = store.snapshot?.providerUsage(now: now) ?? []
        let summary = store.menuBarAccessibilityLabel(now: now)
        glyph(for: providers)
            .accessibilityLabel(summary)
            .help(summary)
    }

    @ViewBuilder
    private func glyph(for providers: [ProviderUsage]) -> some View {
        if providers.isEmpty {
            Image(systemName: "gauge.with.dots.needle.33percent")
        } else {
            Image(nsImage: ProviderMenuBarRenderer.image(for: providers, logos: store.logos))
                .renderingMode(.original)
                .id(colorScheme)
        }
    }
}

struct UsagePanel: View {
    @Bindable var store: UsageStore
    @State private var isChoosingCLI = false
    @State private var selectionError: String?
    @State private var isDetailsExpanded = false
    @State private var isOKExpanded = true
    @State private var isAllQuotasExpanded = false

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
                    providerFlower(now: now)
                    details(now: now)
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

    @ViewBuilder
    private func providerFlower(now: Date) -> some View {
        if let providers = store.snapshot?.providerUsage(now: now), !providers.isEmpty {
            ProviderFlowerCard(providers: providers, logos: store.logos)
        }
    }

    @ViewBuilder
    private func details(now: Date) -> some View {
        if let overview = store.snapshot?.statusOverview(), !overview.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                DisclosureToggle(isExpanded: $isDetailsExpanded, spokenLabel: overview.detailsSpokenLabel) {
                    Text(overview.detailsLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                if isDetailsExpanded {
                    StatusGroups(
                        overview: overview,
                        isOKExpanded: $isOKExpanded,
                        now: now,
                        accountLabel: { accountLabel(for: $0, number: $1) },
                        isStale: { store.freshness(for: $0).isStale(at: now) }
                    )
                }
            }
            .accessibilityIdentifier("quotablet.details")
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
                allQuotas(snapshot, now: now)
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

    private func allQuotas(_ snapshot: UsageSnapshot, now: Date) -> some View {
        let quotaCount = snapshot.reports.reduce(0) { $0 + $1.quotas.count }
        return VStack(alignment: .leading, spacing: 10) {
            DisclosureToggle(isExpanded: $isAllQuotasExpanded, spokenLabel: "All quotas, \(quotaCount)") {
                Text("All quotas · \(quotaCount)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            if isAllQuotasExpanded {
                let topAttention = Dictionary(uniqueKeysWithValues: snapshot.accountAttention().map { ($0.selection.report.id, $0) })
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(snapshot.reports) { report in
                        AccountSection(
                            report: report,
                            accountLabel: accountLabel(for: report, number: snapshot.accountNumber(of: report)),
                            now: now,
                            freshness: store.freshness(for: report),
                            attention: topAttention[report.id]
                        )
                    }
                }
            }
        }
        .accessibilityIdentifier("quotablet.all-quotas")
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
    let attention: AttentionItem?

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
                            now: now
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

