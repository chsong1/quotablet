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

struct QuotaScope: Codable, Equatable, Sendable {
    let provider: String
    let accountID: String?
    let organizationID: String?
    let projectID: String?
    let modelID: String?
    let tier: String?
    let windowID: String?
    let shared: Bool?
}

struct QuotaWindowIdentity: Codable, Equatable, Sendable {
    let id: String
}

// A label such as "Weekly" names a period when a window gives no duration. A month counts as 30 days.
enum PeriodWord: String, Sendable {
    case hourly
    case daily
    case weekly
    case monthly

    init?(label: String) {
        self.init(rawValue: label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    var milliseconds: Double {
        switch self {
        case .hourly: 3_600_000
        case .daily: 86_400_000
        case .weekly: 604_800_000
        case .monthly: 2_592_000_000
        }
    }
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

    // The duration OMP reports, else the period the label names. A window that gives neither is 0, which ranks it shortest.
    var effectiveLengthMilliseconds: Double {
        if let durationMilliseconds, durationMilliseconds.isFinite, durationMilliseconds > 0 { return durationMilliseconds }
        return PeriodWord(label: label)?.milliseconds ?? 0
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

    var urgency: QuotaUrgency? {
        if isKnownExhausted { return .exhausted }
        if case .nearLimit = status { return .nearLimit }
        return nil
    }

    // An exhausted quota has nothing left whatever its amount says, so it counts as empty even when the amount is unknown.
    var remainingShare: Double? {
        if isKnownExhausted { return 0 }
        return amount?.progress.map { 1 - $0 }
    }

    var windowDisplayName: String {
        window?.displayName ?? "Window unknown"
    }

    // The parenthetical a label ends in when it narrows the quota below its window, such as "Fable" in "Claude 7 Day (Fable)".
    // One that only restates the window, such as "(Weekly)", narrows nothing.
    var scopeDetail: String? {
        guard
            let close = label.lastIndex(of: ")"),
            let open = label[..<close].lastIndex(of: "(")
        else { return nil }
        let detail = label[label.index(after: open)..<close].trimmingCharacters(in: .whitespacesAndNewlines)
        let windowLabel = window?.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let restatesWindow = detail.isEmpty
            || PeriodWord(label: detail) != nil
            || windowLabel.map { detail.caseInsensitiveCompare($0) == .orderedSame } == true
        return restatesWindow ? nil : detail
    }

    var isScoped: Bool { scopeDetail != nil }
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

    var accountStatus: AccountStatus {
        AccountStatus(topUrgency: quotas.compactMap(\.urgency).min())
    }
}

struct SelectedQuota: Equatable, Sendable {
    let report: UsageReport
    let quota: UsageQuota
    let accountNumber: Int
}

// Declaration order is rank order, so a lower case sorts first.
enum QuotaUrgency: Comparable, Sendable {
    case exhausted
    case nearLimit

    var label: String {
        switch self {
        case .exhausted: "Exhausted"
        case .nearLimit: "Near limit"
        }
    }
}

struct AttentionItem: Equatable, Sendable {
    let selection: SelectedQuota
    let urgency: QuotaUrgency
}

// The group a row sits in. An account takes the status of its most urgent quota, and one with nothing to flag is ok.
enum AccountStatus: Comparable, Sendable {
    case exhausted
    case nearLimit
    case ok

    init(topUrgency: QuotaUrgency?) {
        switch topUrgency {
        case .exhausted?: self = .exhausted
        case .nearLimit?: self = .nearLimit
        case nil: self = .ok
        }
    }
}

// One row of the Exhausted or Near limit group. Its quotas belong to one account, share an urgency, and reset in the same minute.
struct AttentionLine: Equatable, Sendable {
    let report: UsageReport
    let accountNumber: Int
    let urgency: QuotaUrgency
    // Never empty and in rank order, so the first one stands for the line.
    let quotas: [SelectedQuota]
    let resetsAt: Date?

    var lead: SelectedQuota { quotas[0] }
}

// One row of the OK group: an account with no quota that needs attention, led by its quota with the least left.
struct HealthyLine: Equatable, Sendable {
    let report: UsageReport
    let accountNumber: Int
    let lead: SelectedQuota
}

struct StatusOverview: Equatable, Sendable {
    // Groups hold lines in display order, and a group's count is its line count.
    let exhausted: [AttentionLine]
    let nearLimit: [AttentionLine]
    // Most used first.
    let ok: [HealthyLine]

    var isEmpty: Bool { exhausted.isEmpty && nearLimit.isEmpty && ok.isEmpty }
}

struct ProviderUsage: Equatable, Sendable {
    let provider: String
    // Reports of this provider, whether or not a figure could be read from them.
    let accountCount: Int
    // Each measured account's capacity quota, in report order.
    let measured: [SelectedQuota]
    // The used share of the combined limit. Nil when no account is measured.
    let usedFraction: Double?
    // Any measured account's report is stale.
    let isStale: Bool

    // For example "5 accounts" or "1 account". When only some accounts are measured, the count says how many the figure covers: "4 of 5 accounts".
    var accountsPhrase: String {
        guard accountCount != 1 else { return "1 account" }
        let isPartial = measured.count > 0 && measured.count < accountCount
        return "\(isPartial ? "\(measured.count) of \(accountCount)" : "\(accountCount)") accounts"
    }

    // For example "Claude 79% used across 5 accounts" or "Grok 1% used, 1 account".
    var spokenSummary: String {
        let name = ProviderRegistry.displayName(for: provider)
        let lead = usedFraction == nil ? "\(name) usage unknown" : "\(name) \(UsageFormatting.usedPercent(usedFraction)) used"
        return accountCount == 1 ? "\(lead), \(accountsPhrase)" : "\(lead) across \(accountsPhrase)"
    }
}

extension Array where Element == ProviderUsage {
    // Every provider's sentence in one, for the menu bar item and the panel's chart.
    var spokenSummary: String {
        map(\.spokenSummary).joined(separator: "; ")
    }
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

        self.reports = reportDrafts.enumerated().map { reportOrdinal, draft in
            let candidate = stableCandidates[reportOrdinal]
            let accountIdentity: AccountIdentity
            if let candidate, stableCounts[candidate] == 1 {
                accountIdentity = .stable(candidate)
            } else {
                accountIdentity = .transient(TransientAccountIdentity(snapshotID: revision, reportOrdinal: reportOrdinal))
            }
            let quotas = draft.quotas.enumerated().map { quotaOrdinal, quotaDraft in
                UsageQuota(
                    id: QuotaRowID(snapshotID: revision, reportOrdinal: reportOrdinal, quotaOrdinal: quotaOrdinal),
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

    func accountNumber(of report: UsageReport) -> Int {
        let sameProvider = reports.filter { $0.provider == report.provider }
        return (sameProvider.firstIndex { $0.id == report.id } ?? 0) + 1
    }

    func attentionItems() -> [AttentionItem] {
        selections
            .compactMap { selection in selection.quota.urgency.map { AttentionItem(selection: selection, urgency: $0) } }
            .sorted(by: Self.ranksBefore)
    }

    func accountAttention() -> [AttentionItem] {
        var seen = Set<ReportRowID>()
        return attentionItems().filter { seen.insert($0.selection.report.id).inserted }
    }

    func statusOverview() -> StatusOverview {
        // attentionItems() is in rank order, so a line ranks by the quota that opened it, and each later quota joins the first line it runs out with.
        var drafts: [(urgency: QuotaUrgency, quotas: [SelectedQuota])] = []
        for item in attentionItems() {
            let joined = drafts.firstIndex { $0.urgency == item.urgency && Self.runOutTogether($0.quotas[0], item.selection) }
            if let joined {
                drafts[joined].quotas.append(item.selection)
            } else {
                drafts.append((item.urgency, [item.selection]))
            }
        }
        let attention = drafts.map { draft in
            AttentionLine(
                report: draft.quotas[0].report,
                accountNumber: draft.quotas[0].accountNumber,
                urgency: draft.urgency,
                quotas: draft.quotas,
                resetsAt: draft.quotas[0].quota.resetsAt
            )
        }
        return StatusOverview(
            exhausted: attention.filter { $0.urgency == .exhausted },
            nearLimit: attention.filter { $0.urgency == .nearLimit },
            ok: reports.compactMap(healthyLine(for:)).sorted { Self.isMoreUsedBefore($0.lead, $1.lead) }
        )
    }

    private var selections: [SelectedQuota] {
        reports.flatMap { report -> [SelectedQuota] in
            let number = accountNumber(of: report)
            return report.quotas.map { SelectedQuota(report: report, quota: $0, accountNumber: number) }
        }
    }

    private func healthyLine(for report: UsageReport) -> HealthyLine? {
        guard report.accountStatus == .ok else { return nil }
        let number = accountNumber(of: report)
        let quotas = report.quotas.map { SelectedQuota(report: report, quota: $0, accountNumber: number) }
        return Self.mostUsed(among: quotas).map { HealthyLine(report: report, accountNumber: number, lead: $0) }
    }

    // With no known usage, fall back to the first quota in the stable order.
    private static func mostUsed(among candidates: [SelectedQuota]) -> SelectedQuota? {
        let measured = candidates.filter { $0.quota.remainingShare != nil }
        return measured.isEmpty ? candidates.min(by: isStablyBefore) : measured.min(by: isMoreUsedBefore)
    }

    // A quota with no reset time pairs only with another such quota, so a different reset is never hidden.
    private static func runOutTogether(_ left: SelectedQuota, _ right: SelectedQuota) -> Bool {
        left.report.id == right.report.id && resetMinute(of: left.quota) == resetMinute(of: right.quota)
    }

    private static func resetMinute(of quota: UsageQuota) -> Double? {
        quota.resetsAt.map { ($0.timeIntervalSince1970 / 60).rounded(.down) }
    }

    // The first key that differs decides: urgency, then the least remaining, then the earliest reset, then the stable order.
    private static func ranksBefore(_ left: AttentionItem, _ right: AttentionItem) -> Bool {
        if left.urgency != right.urgency { return left.urgency < right.urgency }
        return ascendingUnknownLast(left.selection.quota.remainingShare, right.selection.quota.remainingShare)
            ?? resetsBeforeStableOrder(left.selection, right.selection)
    }

    private static func isMoreUsedBefore(_ left: SelectedQuota, _ right: SelectedQuota) -> Bool {
        ascendingUnknownLast(left.quota.remainingShare, right.quota.remainingShare) ?? resetsBeforeStableOrder(left, right)
    }

    private static func resetsBeforeStableOrder(_ left: SelectedQuota, _ right: SelectedQuota) -> Bool {
        ascendingUnknownLast(left.quota.resetsAt, right.quota.resetsAt) ?? isStablyBefore(left, right)
    }

    // A tie is nil, so the caller falls through to its next key.
    private static func ascendingUnknownLast<Value: Comparable>(_ left: Value?, _ right: Value?) -> Bool? {
        guard let left else { return right == nil ? nil : false }
        guard let right else { return true }
        return left == right ? nil : left < right
    }

    private static func isStablyBefore(_ left: SelectedQuota, _ right: SelectedQuota) -> Bool {
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
}

extension UsageSnapshot {
    // One entry for each provider that has a report, in the registry's order.
    func providerUsage(now: Date) -> [ProviderUsage] {
        Dictionary(grouping: reports, by: \.provider)
            .map { provider, accounts in
                let measured = accounts.compactMap(capacityQuota(of:))
                return ProviderUsage(
                    provider: provider,
                    accountCount: accounts.count,
                    measured: measured,
                    usedFraction: Self.combinedUsedFraction(of: measured.compactMap(\.quota.amount)),
                    isStale: measured.contains { UsageFreshness(origin: nil, fetchedAt: $0.report.fetchedAt, refreshStatus: .idle).isStale(at: now) }
                )
            }
            .sorted { ProviderRegistry.ranksBefore($0.provider, $1.provider) }
    }

    // The one quota that stands for an account's whole limit: the longest window that is not narrowed to a scope such as a model.
    private func capacityQuota(of report: UsageReport) -> SelectedQuota? {
        let number = accountNumber(of: report)
        return report.quotas
            .filter { $0.amount?.progress != nil && !$0.isScoped }
            .map { SelectedQuota(report: report, quota: $0, accountNumber: number) }
            .min(by: Self.isBetterCapacityQuota)
    }

    // The longest window wins. Windows of one length go to the most used quota, then to the stable order.
    private static func isBetterCapacityQuota(_ left: SelectedQuota, _ right: SelectedQuota) -> Bool {
        let leftLength = left.quota.window?.effectiveLengthMilliseconds ?? 0
        let rightLength = right.quota.window?.effectiveLengthMilliseconds ?? 0
        if leftLength != rightLength { return leftLength > rightLength }
        let leftUsed = left.quota.amount?.progress ?? 0
        let rightUsed = right.quota.amount?.progress ?? 0
        if leftUsed != rightUsed { return leftUsed > rightUsed }
        return isStablyBefore(left, right)
    }

    // Each account counts as one equal part of 100%. When every account reports a positive limit in one unit, the limits pool instead,
    // so the figure is the used share of the capacity the accounts really have.
    private static func combinedUsedFraction(of amounts: [UsageAmount]) -> Double? {
        let measured = amounts.compactMap { amount in amount.progress.map { (limit: amount.limit, unit: amount.unit, share: $0) } }
        guard let first = measured.first else { return nil }
        let limits = measured.compactMap { entry in entry.limit.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } }
        // A missing unit names nothing, so two of them need not match.
        let poolsLimits = limits.count == measured.count
            && first.unit != .percent
            && first.unit != .missing
            && measured.allSatisfy { $0.unit == first.unit }
        let fraction: Double
        if poolsLimits {
            // The used amount comes from the clamped share, so a quota that reports only what remains still counts.
            let used = zip(measured, limits).reduce(0) { $0 + $1.0.share * $1.1 }
            fraction = used / limits.reduce(0, +)
        } else {
            fraction = measured.reduce(0) { $0 + $1.share } / Double(measured.count)
        }
        return min(max(fraction, 0), 1)
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

    private func ageSeconds(at now: Date) -> TimeInterval? {
        guard let fetchedAt else { return nil }
        let age = max(0, now.timeIntervalSince(fetchedAt))
        return age.isFinite ? age : nil
    }
}

enum ResetCountdown: Equatable, Sendable {
    // Bare text such as "9h 21m", for the caller to put in its own sentence.
    case remaining(String)
    case passed
    case unknown
}

enum UsageFormatting {
    static func accountAlias(_ number: Int) -> String {
        "Account \(number)"
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

    // The window length names a quota more briefly than its label does, so "Claude 7 Day (Fable)" becomes "7d Fable".
    // A parenthetical that only restates the window, such as "Grok Build (Weekly)", repeats the length and is dropped.
    static func shortLabel(for quota: UsageQuota) -> String {
        guard
            let window = quota.window,
            let duration = compactDuration(milliseconds: window.durationMilliseconds)
        else { return quota.label }
        return quota.scopeDetail.map { "\(duration) \($0)" } ?? duration
    }

    static func percentLeft(_ quota: UsageQuota) -> String? {
        quota.remainingShare.map { "\(Int(($0 * 100).rounded()))%" }
    }

    // Whole digits and a percent sign. An en dash stands for a share that is unknown.
    static func usedPercent(_ fraction: Double?) -> String {
        guard let fraction, fraction.isFinite else { return "–" }
        return "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
    }

    // The tag always carries the account number, such as "C1" for Claude Account 1.
    static func accountTag(provider: String, number: Int) -> String {
        "\(ProviderRegistry.badgeLetter(for: provider))\(number)"
    }

    static func countdown(to resetsAt: Date?, now: Date) -> ResetCountdown {
        guard let resetsAt else { return .unknown }
        let interval = resetsAt.timeIntervalSince(now)
        guard interval > 0 else { return .passed }
        guard interval.isFinite, interval < Double(Int.max) else { return .unknown }

        let minutes = Int(interval / 60)
        if minutes < 60 { return .remaining("\(max(1, minutes))m") }
        let hours = minutes / 60
        if hours < 24 { return .remaining("\(hours)h \(minutes % 60)m") }
        return .remaining("\(hours / 24)d \(hours % 24)h")
    }

    static func resetDescription(for resetsAt: Date?, resetLabel: String?, now: Date) -> String {
        switch countdown(to: resetsAt, now: now) {
        case .unknown:
            return "Reset unknown"
        case .passed:
            return "Reset passed · recheck"
        case .remaining(let remaining):
            let label = resetLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
            let verb: String
            if let label, !label.isEmpty {
                verb = String(label.prefix(1)).uppercased() + String(label.dropFirst())
            } else {
                verb = "Resets"
            }
            return "\(verb) in \(remaining)"
        }
    }

    // The reset text inside a line, such as "resets in 2h 5m" after a comma.
    static func resetPhrase(for resetsAt: Date?, resetLabel: String?, now: Date) -> String {
        let description = resetDescription(for: resetsAt, resetLabel: resetLabel, now: now)
        return String(description.prefix(1)).lowercased() + String(description.dropFirst())
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

enum ProviderRegistry {
    private struct Entry: Sendable {
        let id: String
        let displayName: String
        let badgeLetter: String
    }

    // The menu bar lists providers in this order, so each keeps its place from one refresh to the next.
    private static let entries = [
        Entry(id: "anthropic", displayName: "Claude", badgeLetter: "C"),
        Entry(id: "openai-codex", displayName: "Codex", badgeLetter: "O"),
        Entry(id: "xai-oauth", displayName: "Grok", badgeLetter: "G"),
        Entry(id: "cursor", displayName: "Cursor", badgeLetter: "U"),
    ]

    static func displayName(for providerID: String) -> String {
        entry(for: providerID).displayName
    }

    static func badgeLetter(for providerID: String) -> String {
        entry(for: providerID).badgeLetter
    }

    // Known providers come first in registry order, and unknown ones follow alphabetically.
    static func ranksBefore(_ left: String, _ right: String) -> Bool {
        let leftRank = rank(of: left)
        let rightRank = rank(of: right)
        if leftRank != rightRank { return leftRank < rightRank }
        return left.localizedStandardCompare(right) == .orderedAscending
    }

    private static func rank(of providerID: String) -> Int {
        entries.firstIndex { $0.id == providerID.lowercased() } ?? entries.count
    }

    private static func entry(for providerID: String) -> Entry {
        entries.first { $0.id == providerID.lowercased() }
            ?? Entry(id: providerID, displayName: providerID, badgeLetter: String(providerID.prefix(1)).uppercased())
    }
}

