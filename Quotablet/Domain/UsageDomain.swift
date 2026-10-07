import Foundation

enum UsageUnit: Codable, Equatable, Sendable {
    case missing
    case percent
    case usd
    case tokens
    case requests
    case minutes
    case bytes
    case unknown(String)

    init(sourceValue: String?) {
        guard let sourceValue, !sourceValue.allSatisfy(\.isWhitespace) else {
            self = .missing
            return
        }
        switch sourceValue.lowercased() {
        case "percent": self = .percent
        case "usd": self = .usd
        case "tokens": self = .tokens
        case "requests": self = .requests
        case "minutes": self = .minutes
        case "bytes": self = .bytes
        default: self = .unknown(sourceValue)
        }
    }

    var suffix: String? {
        switch self {
        case .missing: nil
        case .percent: "%"
        case .usd: "USD"
        case .tokens: "tokens"
        case .requests: "requests"
        case .minutes: "min"
        case .bytes: "bytes"
        case .unknown(let value): value
        }
    }
}

enum UsageLimitStatus: Codable, Equatable, Sendable {
    case missing
    case available
    case nearLimit
    case exhausted
    case unknown(String)

    init(sourceValue: String?) {
        guard let sourceValue, !sourceValue.allSatisfy(\.isWhitespace) else {
            self = .missing
            return
        }
        switch sourceValue.lowercased().replacingOccurrences(of: "-", with: "_") {
        case "available", "ok": self = .available
        case "near_limit", "warning", "low": self = .nearLimit
        case "exhausted", "unavailable", "limited": self = .exhausted
        default: self = .unknown(sourceValue)
        }
    }

    var label: String? {
        switch self {
        case .missing: nil
        case .available: "Available"
        case .nearLimit: "Near limit"
        case .exhausted: "Exhausted"
        case .unknown(let value): value.replacingOccurrences(of: "_", with: " ")
        }
    }
}

struct UsageAmount: Codable, Equatable, Sendable {
    let used: Double?
    let limit: Double?
    let remaining: Double?
    let usedFraction: Double?
    let remainingFraction: Double?
    let unit: UsageUnit

    var displayedRemaining: Double? {
        if let remaining { return remaining }
        if unit == .percent {
            if let remainingFraction { return remainingFraction * 100 }
            if let usedFraction { return (1 - usedFraction) * 100 }
            if let limit, let used {
                let difference = limit - used
                return limit <= 1 ? difference * 100 : difference
            }
            if let used { return 100 - used }
        }
        if let limit, let used { return limit - used }
        if let limit, let remainingFraction { return limit * remainingFraction }
        return nil
    }

    var progress: Double? {
        let value: Double?
        if let usedFraction {
            value = usedFraction
        } else if let remainingFraction {
            value = 1 - remainingFraction
        } else if let limit, limit > 0, let used {
            value = used / limit
        } else if unit == .percent, let used {
            value = used / 100
        } else {
            value = nil
        }
        guard let value, value.isFinite else { return nil }
        return min(max(value, 0), 1)
    }

    var isKnownExhausted: Bool {
        return displayedRemaining.map { $0 <= 0 } ?? false
    }
}

struct QuotaScope: Codable, Hashable, Sendable {
    let provider: String
    let accountID: String?
    let organizationID: String?
    let projectID: String?
    let modelID: String?
    let tier: String?
    let windowID: String?
    let shared: Bool?
}

struct QuotaWindowIdentity: Codable, Hashable, Sendable {
    let id: String
}

struct QuotaWindow: Codable, Equatable, Sendable {
    let identity: QuotaWindowIdentity
    let label: String
    let durationMilliseconds: Double?
    let resetLabel: String?

    var displayName: String {
        let sourceLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = sourceLabel.isEmpty ? identity.id : sourceLabel
        guard !name.isEmpty else { return "Window unknown" }
        guard let duration = UsageFormatting.compactDuration(milliseconds: durationMilliseconds) else { return name }
        guard !name.localizedCaseInsensitiveContains(duration) else { return name }
        return "\(name) · \(duration)"
    }

    var compactDisplayName: String {
        if let duration = UsageFormatting.compactDuration(milliseconds: durationMilliseconds) { return duration }
        let sourceName = identity.id.isEmpty ? label : identity.id
        let prefix = String(sourceName.prefix(12))
        return sourceName.count > 12 ? "\(prefix)…" : prefix
    }
}

struct StableAccountIdentity: Codable, Hashable, Sendable {
    let provider: String
    let accountID: String
    let organizationID: String?
    let projectID: String?

    var sortComponents: [String] {
        [provider, accountID, organizationID ?? "", projectID ?? ""]
    }
}

struct SourceAccountIdentity: Codable, Equatable, Sendable {
    let accountID: String?
    let organizationID: String?
    let projectID: String?

    func stableIdentity(provider: String) -> StableAccountIdentity? {
        guard let accountID, !accountID.allSatisfy(\.isWhitespace) else { return nil }
        return StableAccountIdentity(
            provider: provider,
            accountID: accountID,
            organizationID: organizationID,
            projectID: projectID
        )
    }

    var revealedIdentifier: String? {
        accountID ?? projectID ?? organizationID
    }
}

struct TransientAccountIdentity: Codable, Hashable, Sendable {
    let snapshotID: UUID
    let reportOrdinal: Int
}

enum AccountIdentity: Codable, Equatable, Sendable {
    case stable(StableAccountIdentity)
    case transient(TransientAccountIdentity)
}

struct QuotaPinKey: Codable, Hashable, Sendable {
    let account: StableAccountIdentity
    let limitID: String
    let scope: QuotaScope?
    let window: QuotaWindowIdentity
}

struct UsageQuotaDraft: Equatable, Sendable {
    let id: String
    let label: String
    let scope: QuotaScope?
    let window: QuotaWindow?
    let amount: UsageAmount?
    let status: UsageLimitStatus
    let resetsAt: Date?
}

struct UsageReportDraft: Equatable, Sendable {
    let provider: String
    let sourceAccount: SourceAccountIdentity?
    let privateDisplayLabel: String?
    let fetchedAt: Date?
    let resetCredits: Int?
    let quotas: [UsageQuotaDraft]
}

struct ReportRowID: Codable, Hashable, Sendable {
    let snapshotID: UUID
    let ordinal: Int
}

struct QuotaRowID: Codable, Hashable, Sendable {
    let snapshotID: UUID
    let reportOrdinal: Int
    let quotaOrdinal: Int
}

struct UsageQuota: Codable, Equatable, Identifiable, Sendable {
    let id: QuotaRowID
    let pinKey: QuotaPinKey?
    let limitID: String
    let label: String
    let scope: QuotaScope?
    let window: QuotaWindow?
    let amount: UsageAmount?
    let status: UsageLimitStatus
    let resetsAt: Date?

    var isKnownExhausted: Bool {
        if case .exhausted = status { return true }
        return amount?.isKnownExhausted ?? false
    }

    var windowDisplayName: String {
        window?.displayName ?? "Window unknown"
    }
}

struct UsageReport: Codable, Equatable, Identifiable, Sendable {
    let id: ReportRowID
    let provider: String
    let accountIdentity: AccountIdentity
    let sourceAccount: SourceAccountIdentity?
    let privateDisplayLabel: String?
    let fetchedAt: Date?
    let resetCredits: Int?
    let quotas: [UsageQuota]

    var revealedAccountLabel: String? {
        privateDisplayLabel ?? sourceAccount?.revealedIdentifier
    }

    var stableSortComponents: [String] {
        switch accountIdentity {
        case .stable(let identity): ["0"] + identity.sortComponents
        case .transient(let identity): ["1", String(identity.reportOrdinal)]
        }
    }
}

struct SelectedQuota: Equatable, Sendable {
    let report: UsageReport
    let quota: UsageQuota
}

enum SummarySelection: Equatable, Sendable {
    case pinned(SelectedQuota)
    case defaulted(SelectedQuota)
    case unavailable
    case none
}

struct UsageSnapshot: Codable, Equatable, Sendable {
    let revision: UUID
    let generatedAt: Date
    let receivedAt: Date
    let reports: [UsageReport]

    init(
        generatedAt: Date,
        receivedAt: Date = Date(),
        revision: UUID = UUID(),
        reportDrafts: [UsageReportDraft]
    ) {
        self.revision = revision
        self.generatedAt = generatedAt
        self.receivedAt = receivedAt

        let stableCandidates = reportDrafts.map { draft in
            draft.sourceAccount?.stableIdentity(provider: draft.provider)
        }
        let stableCounts = Dictionary(grouping: stableCandidates.compactMap { $0 }, by: { $0 }).mapValues(\.count)

        var quotaKeys: [QuotaPinKey?] = []
        for (reportOrdinal, draft) in reportDrafts.enumerated() {
            guard let stableAccount = stableCandidates[reportOrdinal], stableCounts[stableAccount] == 1 else {
                quotaKeys.append(contentsOf: draft.quotas.map { _ in nil })
                continue
            }
            quotaKeys.append(contentsOf: draft.quotas.map { quota in
                guard
                    !quota.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    let window = quota.window,
                    !window.identity.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return nil }
                return QuotaPinKey(
                    account: stableAccount,
                    limitID: quota.id,
                    scope: quota.scope,
                    window: window.identity
                )
            })
        }
        let keyCounts = Dictionary(grouping: quotaKeys.compactMap { $0 }, by: { $0 }).mapValues(\.count)

        var keyIndex = 0
        self.reports = reportDrafts.enumerated().map { reportOrdinal, draft in
            let candidate = stableCandidates[reportOrdinal]
            let accountIdentity: AccountIdentity
            if let candidate, stableCounts[candidate] == 1 {
                accountIdentity = .stable(candidate)
            } else {
                accountIdentity = .transient(TransientAccountIdentity(snapshotID: revision, reportOrdinal: reportOrdinal))
            }
            let quotas = draft.quotas.enumerated().map { quotaOrdinal, quotaDraft in
                let candidateKey = quotaKeys[keyIndex]
                keyIndex += 1
                let pinKey = candidateKey.flatMap { keyCounts[$0] == 1 ? $0 : nil }
                return UsageQuota(
                    id: QuotaRowID(snapshotID: revision, reportOrdinal: reportOrdinal, quotaOrdinal: quotaOrdinal),
                    pinKey: pinKey,
                    limitID: quotaDraft.id,
                    label: quotaDraft.label,
                    scope: quotaDraft.scope,
                    window: quotaDraft.window,
                    amount: quotaDraft.amount,
                    status: quotaDraft.status,
                    resetsAt: quotaDraft.resetsAt
                )
            }
            return UsageReport(
                id: ReportRowID(snapshotID: revision, ordinal: reportOrdinal),
                provider: draft.provider,
                accountIdentity: accountIdentity,
                sourceAccount: draft.sourceAccount,
                privateDisplayLabel: draft.privateDisplayLabel,
                fetchedAt: draft.fetchedAt,
                resetCredits: draft.resetCredits,
                quotas: quotas
            )
        }
    }

    func summarySelection(pinnedKey: QuotaPinKey?) -> SummarySelection {
        if let pinnedKey {
            let matches = reports.flatMap { report in
                report.quotas.compactMap { quota in
                    quota.pinKey == pinnedKey ? SelectedQuota(report: report, quota: quota) : nil
                }
            }
            guard matches.count == 1, let match = matches.first else { return .unavailable }
            return .pinned(match)
        }
        let candidates = reports.flatMap { report in
            report.quotas.map { SelectedQuota(report: report, quota: $0) }
        }
        let sorted = candidates.sorted { left, right in
            if left.report.provider != right.report.provider {
                return left.report.provider.localizedStandardCompare(right.report.provider) == .orderedAscending
            }
            if left.report.stableSortComponents != right.report.stableSortComponents {
                return left.report.stableSortComponents.lexicographicallyPrecedes(right.report.stableSortComponents)
            }
            let leftWindowID = left.quota.window?.identity.id ?? ""
            let rightWindowID = right.quota.window?.identity.id ?? ""
            if leftWindowID != rightWindowID {
                return leftWindowID.localizedStandardCompare(rightWindowID) == .orderedAscending
            }
            if left.quota.label != right.quota.label {
                return left.quota.label.localizedStandardCompare(right.quota.label) == .orderedAscending
            }
            if left.quota.id.reportOrdinal != right.quota.id.reportOrdinal {
                return left.quota.id.reportOrdinal < right.quota.id.reportOrdinal
            }
            return left.quota.id.quotaOrdinal < right.quota.id.quotaOrdinal
        }
        guard let first = sorted.first else { return .none }
        return .defaulted(first)
    }
}

enum UsageSnapshotOrigin: Equatable, Sendable {
    case cached
    case live
}

enum UsageRefreshStatus: Equatable, Sendable {
    case idle
    case refreshing
    case failed
}

struct UsageFreshness: Equatable, Sendable {
    static let staleAfterSeconds: TimeInterval = 15 * 60

    let origin: UsageSnapshotOrigin?
    let fetchedAt: Date?
    let refreshStatus: UsageRefreshStatus

    func isStale(at now: Date) -> Bool {
        ageSeconds(at: now).map { $0 >= Self.staleAfterSeconds } ?? false
    }

    func displayLabel(now: Date) -> String {
        if origin == nil, refreshStatus == .idle { return "Waiting for OMP" }
        if origin == nil, refreshStatus == .refreshing { return "Connecting to OMP" }

        var parts: [String] = []
        if refreshStatus == .failed { parts.append("Refresh failed") }
        if refreshStatus == .refreshing { parts.append("Refreshing") }
        if origin == .cached { parts.append("Saved") }
        if isStale(at: now) { parts.append("Stale") }
        if let age = ageSeconds(at: now) {
            parts.append("Provider data \(UsageFormatting.ageDescription(age)) old")
        } else if origin != nil || refreshStatus != .idle {
            parts.append("Provider age unknown")
        }
        return parts.isEmpty ? "Waiting for OMP" : parts.joined(separator: " · ")
    }

    func compactIndicator(now: Date) -> String? {
        var parts: [String] = []
        if refreshStatus == .failed { parts.append("Failed") }
        if origin == .cached { parts.append("Saved") }
        if isStale(at: now) { parts.append("Stale") }
        if parts.isEmpty, refreshStatus == .refreshing { parts.append("Refreshing") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func ageSeconds(at now: Date) -> TimeInterval? {
        guard let fetchedAt else { return nil }
        let age = max(0, now.timeIntervalSince(fetchedAt))
        return age.isFinite ? age : nil
    }
}

enum UsageFormatting {
    static func providerName(_ providerID: String) -> String {
        switch providerID.lowercased() {
        case "anthropic": "Claude"
        case "openai-codex": "Codex"
        case "cursor": "Cursor"
        case "xai-oauth": "Grok"
        default: providerID
        }
    }

    static func remainingText(_ amount: UsageAmount?) -> String {
        guard let amount, let value = amount.displayedRemaining, value.isFinite else { return "Remaining unknown" }
        let number = formatNumber(value)
        switch amount.unit {
        case .usd:
            return "\(value.formatted(.currency(code: "USD").precision(.fractionLength(2)))) left"
        case .percent:
            return "\(number)% left"
        default:
            guard let suffix = amount.unit.suffix else { return "\(number) left" }
            return "\(number) \(suffix) left"
        }
    }

    static func progressLabel(_ fraction: Double) -> String {
        "Used \(progressValue(fraction))"
    }

    static func progressValue(_ fraction: Double) -> String {
        guard fraction.isFinite else { return "unknown" }
        return "\(formatNumber(min(max(fraction, 0), 1) * 100))%"
    }

    static func compactDuration(milliseconds: Double?) -> String? {
        guard let milliseconds, milliseconds.isFinite, milliseconds > 0 else { return nil }
        let hours = milliseconds / 3_600_000
        if hours >= 24 {
            let days = hours / 24
            if abs(days.rounded() - days) < 0.000_001 { return "\(formatNumber(days))d" }
        }
        if hours >= 1 { return "\(formatNumber(hours))h" }
        let minutes = milliseconds / 60_000
        if minutes >= 1 { return "\(formatNumber(minutes))m" }
        return "\(formatNumber(milliseconds / 1_000))s"
    }

    static func resetDescription(for resetsAt: Date?, resetLabel: String?, now: Date) -> String {
        guard let resetsAt else { return "Reset unknown" }
        let interval = resetsAt.timeIntervalSince(now)
        guard interval > 0 else { return "Reset passed · recheck" }
        guard interval.isFinite, interval < Double(Int.max) else { return "Reset time unknown" }

        let countdown: String
        let minutes = Int(interval / 60)
        if minutes < 60 {
            countdown = "\(max(1, minutes))m"
        } else {
            let hours = minutes / 60
            if hours < 24 {
                countdown = "\(hours)h \(minutes % 60)m"
            } else {
                let days = hours / 24
                countdown = "\(days)d \(hours % 24)h"
            }
        }
        let label = resetLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let verb: String
        if let label, !label.isEmpty {
            verb = String(label.prefix(1)).uppercased() + String(label.dropFirst())
        } else {
            verb = "Resets"
        }
        return "\(verb) in \(countdown)"
    }

    static func ageDescription(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "age unknown" }
        if seconds < 60 { return "under 1m" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h \(minutes % 60)m" }
        let days = hours / 24
        return "\(days)d \(hours % 24)h"
    }

    private static func formatNumber(_ value: Double) -> String {
        guard value.isFinite else { return "Unknown" }
        return value.formatted(.number.grouping(.automatic).precision(.fractionLength(0...2)))
    }
}

