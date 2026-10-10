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
    @State private var route = PanelRoute.flower
    @Namespace private var heroNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        panel(now: store.presentationDate)
        .frame(width: 420, height: 600)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onChange(of: store.snapshot?.revision) { _, _ in
            route = route.resolved(in: store.snapshot)
        }
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
            content(now: now)
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
    private func content(now: Date) -> some View {
        if let snapshot = store.snapshot {
            if snapshot.reports.isEmpty {
                EmptyState(
                    symbol: "chart.bar.xaxis",
                    title: store.snapshotOrigin == .cached ? "No saved usage reports" : "No usage reports",
                    detail: "OMP returned a valid empty snapshot. A later refresh can add reports."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                pages(of: snapshot, now: now)
            }
        } else if store.isRefreshing {
            EmptyState(
                symbol: "arrow.triangle.2.circlepath",
                title: "Connecting to OMP",
                detail: "Usage appears here when OMP returns its current reports."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.lastError != nil {
            EmptyState(
                symbol: "terminal",
                title: "Usage is unavailable",
                detail: "Choose the OMP executable or retry after it is available."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            EmptyState(
                symbol: "chart.bar.xaxis",
                title: "Waiting for usage",
                detail: "Quotablet reads usage from your local OMP installation."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // The front page, with one provider's page over it while the route names that provider. The front page stays under the open page,
    // so the petal that opened grows out of its place and shrinks back into it.
    private func pages(of snapshot: UsageSnapshot, now: Date) -> some View {
        let providers = snapshot.providerUsage(now: now)
        let current = route.resolved(in: snapshot)
        let namespace: Namespace.ID? = reduceMotion ? nil : heroNamespace
        return ZStack {
            if FlowerLayout.forItemCount(providers.count) == .flower {
                ProviderFlower(providers: providers, logos: store.logos, route: current, namespace: namespace, open: open)
            } else {
                ProviderList(providers: providers, logos: store.logos, route: current, namespace: namespace, open: open)
            }
            if case .provider(let id) = current, let detail = snapshot.providerDetail(of: id, now: now) {
                ProviderPage(
                    detail: detail,
                    color: QuotaPalette.color(at: providers.firstIndex { $0.provider == id } ?? 0),
                    logos: store.logos,
                    now: now,
                    accountLabel: { accountLabel(for: $0.report, number: $0.number) },
                    showsAccountLabels: store.revealsIdentifiers,
                    namespace: namespace,
                    back: close
                )
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    // One short ease in both directions. Under Reduce Motion nothing is paired or scaled, so the same ease only cross-fades.
    private var routeAnimation: Animation {
        .easeInOut(duration: 0.35)
    }

    private func open(_ provider: String) {
        withAnimation(routeAnimation) { route = .provider(provider) }
    }

    private func close() {
        withAnimation(routeAnimation) { route = .flower }
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

