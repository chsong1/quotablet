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
enum PeriodWord: String, CaseIterable, Sendable {
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

    // An exhausted quota is full whatever its amount says, so it counts as used up even when the amount is unknown.
    var usedShare: Double? {
        if isKnownExhausted { return 1 }
        return amount?.progress
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

    var topUrgency: QuotaUrgency? {
        quotas.compactMap(\.urgency).min()
    }

    var accountStatus: AccountStatus {
        AccountStatus(topUrgency: topUrgency)
    }

    func isStale(at now: Date) -> Bool {
        UsageFreshness(origin: nil, fetchedAt: fetchedAt, refreshStatus: .idle).isStale(at: now)
    }
}

struct SelectedQuota: Equatable, Sendable {
    let report: UsageReport
    let quota: UsageQuota
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

// The status of an account or a window. An account takes the status of its most urgent quota, and one with nothing to flag is ok.
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

struct AttentionBadge: Equatable, Sendable {
    let urgency: QuotaUrgency
    let count: Int
}

// How many of a provider's accounts need attention, by the urgency rules every quota already follows.
struct ProviderAttention: Equatable, Sendable {
    // Accounts with at least one exhausted quota.
    let exhaustedAccounts: Int
    // Accounts whose most urgent quota is near limit.
    let nearLimitAccounts: Int

    // Exhausted wins, because an account that ran out matters more than one that is close.
    var badge: AttentionBadge? {
        if exhaustedAccounts > 0 { return AttentionBadge(urgency: .exhausted, count: exhaustedAccounts) }
        if nearLimitAccounts > 0 { return AttentionBadge(urgency: .nearLimit, count: nearLimitAccounts) }
        return nil
    }

    // For example "1 exhausted" and "2 near limit". Unlike the badge, speech keeps both counts.
    var spokenParts: [String] {
        var parts: [String] = []
        if exhaustedAccounts > 0 { parts.append("\(exhaustedAccounts) \(QuotaUrgency.exhausted.label.lowercased())") }
        if nearLimitAccounts > 0 { parts.append("\(nearLimitAccounts) \(QuotaUrgency.nearLimit.label.lowercased())") }
        return parts
    }
}

extension ProviderAttention {
    init(accountUrgencies: [QuotaUrgency?]) {
        self.init(
            exhaustedAccounts: accountUrgencies.filter { $0 == .exhausted }.count,
            nearLimitAccounts: accountUrgencies.filter { $0 == .nearLimit }.count
        )
    }
}

struct ProviderUsage: Equatable, Sendable {
    let provider: String
    // Reports of this provider, whether or not a figure could be read from them.
    let accountCount: Int
    // Each measured account's capacity quota, in report order.
    let measured: [SelectedQuota]
    // The used share of the combined limit. Nil when no account is measured.
    let usedFraction: Double?
    // Every measured account's report is stale. One stale account among fresh ones leaves its provider fresh,
    // and the provider's page marks that account.
    let isStale: Bool
    let attention: ProviderAttention

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

    // What a petal and a list row speak, such as "Claude 79% used across 5 accounts, 1 exhausted, 2 near limit, stale".
    var petalAccessibilityLabel: String {
        ([spokenSummary] + attention.spokenParts + (isStale ? ["stale"] : [])).joined(separator: ", ")
    }
}

extension Array where Element == ProviderUsage {
    // Every provider's sentence in one, for the menu bar item.
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
                    isStale: !measured.isEmpty && measured.allSatisfy { $0.report.isStale(at: now) },
                    attention: ProviderAttention(accountUrgencies: accounts.map(\.topUrgency))
                )
            }
            .sorted { ProviderRegistry.ranksBefore($0.provider, $1.provider) }
    }

    // The one quota that stands for an account's whole limit: the longest window that is not narrowed to a scope such as a model.
    private func capacityQuota(of report: UsageReport) -> SelectedQuota? {
        report.quotas
            .filter { $0.amount?.progress != nil && !$0.isScoped }
            .map { SelectedQuota(report: report, quota: $0) }
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

// Which page of the panel is showing. It is view state, so it is never saved.
enum PanelRoute: Equatable, Sendable {
    case flower
    case provider(String)

    // A refresh can drop the provider whose page is open. That page has nothing left to show, so the route returns to the flower.
    func resolved(in snapshot: UsageSnapshot?) -> PanelRoute {
        guard case .provider(let id) = self else { return self }
        return snapshot?.reports.contains { $0.provider == id } == true ? self : .flower
    }
}

// What a window is called on its provider's page.
struct WindowName: Equatable, Sendable {
    // Heads the window's column, such as "5h" or "7d Fable".
    let short: String
    // The same name with its window length in words, for a screen reader.
    let spoken: String
}

// One quota of an account as its provider's page shows it.
struct WindowEntry: Equatable, Sendable {
    let name: WindowName
    // Nil when the quota reports no usable figure. An exhausted quota is full whatever its amount says.
    let usedFraction: Double?
    let urgency: QuotaUrgency?
    let resetsAt: Date?
}

// What a window's cell says. The rule lives here so the compact row and the roomy card cannot disagree.
enum WindowReading: Equatable, Sendable {
    // The used percent, or a dash when the figure is unknown, and the time until the window resets when it has a reset time.
    case used(percent: String, resetsIn: String?)
    // An exhausted window that has a reset time. It says when the window comes back, in place of its percent.
    case exhausted(resetsIn: String)
}

extension WindowEntry {
    func reading(now: Date) -> WindowReading {
        let resetsIn: String?
        switch UsageFormatting.countdown(to: resetsAt, now: now) {
        case .remaining(let compact, _): resetsIn = compact
        case .passed: resetsIn = "Recheck"
        case .unknown: resetsIn = nil
        }
        if urgency == .exhausted, let resetsIn { return .exhausted(resetsIn: resetsIn) }
        return .used(percent: usedFraction.map { UsageFormatting.usedPercent($0) } ?? "—", resetsIn: resetsIn)
    }

    // For example "7 day 91% used, resets in 3 days 23 hours".
    func spokenSummary(now: Date) -> String {
        var parts = ["\(name.spoken) \(usedFraction.map { "\(UsageFormatting.usedPercent($0)) used" } ?? "usage unknown")"]
        switch UsageFormatting.countdown(to: resetsAt, now: now) {
        case .remaining(_, let spoken): parts.append("resets in \(spoken)")
        case .passed: parts.append("reset passed, recheck")
        case .unknown: break
        }
        return parts.joined(separator: ", ")
    }
}

// One account on its provider's page: its petal, its row, and every window it reports.
struct AccountDetail: Equatable, Sendable {
    let report: UsageReport
    // Report order within the provider, counted from 1.
    let number: Int
    // The used share of the one quota the provider's figure counts for this account, so the account's petal and the provider's petal agree.
    // Nil when the account is not measured.
    let capacityFraction: Double?
    let isStale: Bool
    let windows: [WindowEntry]

    var urgency: QuotaUrgency? { report.topUrgency }
    var status: AccountStatus { report.accountStatus }

    // The used share of the window closest to running out. Nil when no window has a figure.
    var mostUsedFraction: Double? { windows.compactMap(\.usedFraction).max() }

    // When the last exhausted window resets, because the account stays blocked until all of them clear.
    // Nil when nothing is exhausted or one exhausted window has no reset time.
    var clearsAt: Date? {
        let exhausted = windows.filter { $0.urgency == .exhausted }
        let resets = exhausted.compactMap(\.resetsAt)
        guard !exhausted.isEmpty, resets.count == exhausted.count else { return nil }
        return resets.max()
    }

    // An account with an exhausted quota leads, and the one that clears first comes first. Near-limit accounts follow, then the rest,
    // each by most used. The account number breaks ties.
    static func ranksBefore(_ left: AccountDetail, _ right: AccountDetail) -> Bool {
        if left.status != right.status { return left.status < right.status }
        if left.status == .exhausted, let order = ordered(left.clearsAt, right.clearsAt, ascending: true) { return order }
        if let order = ordered(left.mostUsedFraction, right.mostUsedFraction, ascending: false) { return order }
        return left.number < right.number
    }

    // A tie is nil, so the caller falls through to its next key. A missing value comes after every known one.
    private static func ordered<Value: Comparable>(_ left: Value?, _ right: Value?, ascending: Bool) -> Bool? {
        guard left != right else { return nil }
        guard let left else { return false }
        guard let right else { return true }
        return ascending ? left < right : left > right
    }

    // For example "Account 2, near limit, 7 day 91% used, resets in 3 days 23 hours; 5 hour 0% used". Windows that need attention come first.
    func accessibilityLabel(accountLabel: String, now: Date) -> String {
        var parts = [accountLabel]
        if let urgency { parts.append(urgency.label.lowercased()) }
        if !windows.isEmpty {
            let leading = windows.filter { $0.urgency == .exhausted } + windows.filter { $0.urgency == .nearLimit }
            let rest = windows.filter { $0.urgency == nil }
            parts.append((leading + rest).map { $0.spokenSummary(now: now) }.joined(separator: "; "))
        }
        if isStale { parts.append("stale") }
        return parts.joined(separator: ", ")
    }
}

// One provider's page: the provider's figures and each of its accounts.
struct ProviderDetail: Equatable, Sendable {
    let usage: ProviderUsage
    // In account-number order, so an account's petal keeps its place from one refresh to the next.
    let accounts: [AccountDetail]

    // Most urgent first, which is the order of the rows.
    var accountsByUrgency: [AccountDetail] { accounts.sorted(by: AccountDetail.ranksBefore) }

    // Every window name that any account reports, in the order they first appear, so each row lines its windows up under one heading.
    var windowColumns: [String] {
        var names: [String] = []
        for name in accounts.flatMap(\.windows).map(\.name.short) where !names.contains(name) {
            names.append(name)
        }
        return names
    }

    var hasStaleAccount: Bool { accounts.contains(where: \.isStale) }
}

extension UsageSnapshot {
    // One provider's accounts as its page shows them. Nil when no report names the provider.
    func providerDetail(of provider: String, now: Date) -> ProviderDetail? {
        guard let usage = providerUsage(now: now).first(where: { $0.provider == provider }) else { return nil }
        let capacity = Dictionary(uniqueKeysWithValues: usage.measured.map { ($0.report.id, $0.quota) })
        let accounts = reports
            .filter { $0.provider == provider }
            .enumerated()
            .map { offset, report in
                AccountDetail(
                    report: report,
                    number: offset + 1,
                    capacityFraction: capacity[report.id]?.amount?.progress,
                    isStale: report.isStale(at: now),
                    windows: Self.windowEntries(of: report)
                )
            }
        return ProviderDetail(usage: usage, accounts: accounts)
    }

    private static func windowEntries(of report: UsageReport) -> [WindowEntry] {
        let names = UsageFormatting.windowNames(for: report.quotas, provider: report.provider)
        return zip(report.quotas, names).map { quota, name in
            WindowEntry(name: name, usedFraction: quota.usedShare, urgency: quota.urgency, resetsAt: quota.resetsAt)
        }
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
    // The time left in two forms, for the caller to put in its own sentence: printed such as "9h 21m", and spoken such as "9 hours 21 minutes".
    case remaining(compact: String, spoken: String)
    case passed
    case unknown
}

enum UsageFormatting {
    static func accountAlias(_ number: Int) -> String {
        "Account \(number)"
    }

    private enum DurationUnit {
        case day
        case hour
        case minute
        case second

        var letter: String {
            switch self {
            case .day: "d"
            case .hour: "h"
            case .minute: "m"
            case .second: "s"
            }
        }

        var word: String {
            switch self {
            case .day: "day"
            case .hour: "hour"
            case .minute: "minute"
            case .second: "second"
            }
        }
    }

    // A window's length in the largest unit that holds it. Only whole days count as days, so 36 hours stays 36 hours.
    private static func durationParts(milliseconds: Double?) -> (value: String, unit: DurationUnit)? {
        guard let milliseconds, milliseconds.isFinite, milliseconds > 0 else { return nil }
        let hours = milliseconds / 3_600_000
        if hours >= 24 {
            let days = hours / 24
            if abs(days.rounded() - days) < 0.000_001 { return (formatNumber(days), .day) }
        }
        if hours >= 1 { return (formatNumber(hours), .hour) }
        let minutes = milliseconds / 60_000
        if minutes >= 1 { return (formatNumber(minutes), .minute) }
        return (formatNumber(milliseconds / 1_000), .second)
    }

    static func compactDuration(milliseconds: Double?) -> String? {
        durationParts(milliseconds: milliseconds).map { "\($0.value)\($0.unit.letter)" }
    }

    // A window's length with its unit spelled out, such as "7 day", for speech.
    static func spokenDuration(milliseconds: Double?) -> String? {
        durationParts(milliseconds: milliseconds).map { "\($0.value) \($0.unit.word)" }
    }

    // The window length names a quota more briefly than its label does, so "Claude 7 Day (Fable)" becomes "7d Fable".
    // A parenthetical that only restates the window, such as "Grok Build (Weekly)", repeats the length and is dropped.
    static func shortLabel(for quota: UsageQuota) -> String {
        windowLabel(of: quota, length: compactDuration(milliseconds:))
    }

    // The short label with its window length in words, such as "7 day Fable".
    static func spokenLabel(for quota: UsageQuota) -> String {
        windowLabel(of: quota, length: spokenDuration(milliseconds:))
    }

    private static func windowLabel(of quota: UsageQuota, length: (Double?) -> String?) -> String {
        guard let window = quota.window, let duration = length(window.durationMilliseconds) else { return quota.label }
        return quota.scopeDetail.map { "\(duration) \($0)" } ?? duration
    }

    // Names the quotas of one account for its provider's page. A quota keeps its short name. Quotas that would share one, such as the weekly
    // pools of Grok that all read "7d", take what their labels say besides the provider and the window. Quotas that still share a name
    // after that are counted, so every quota keeps a column of its own.
    static func windowNames(for quotas: [UsageQuota], provider: String) -> [WindowName] {
        let shorts = quotas.map(shortLabel(for:))
        let names = zip(quotas, shorts).map { quota, short in
            if shorts.filter({ $0 == short }).count > 1, let distinct = distinctName(of: quota, provider: provider) {
                return WindowName(short: distinct, spoken: distinct)
            }
            return WindowName(short: short, spoken: spokenLabel(for: quota))
        }
        // A count must not land on a name a later quota already has, such as "Build 2", so every first name is reserved up front.
        var taken = Set(names.map(\.short))
        var kept: Set<String> = []
        return names.map { name in
            if kept.insert(name.short).inserted { return name }
            var count = 2
            while taken.contains("\(name.short) \(count)") { count += 1 }
            taken.insert("\(name.short) \(count)")
            return WindowName(short: "\(name.short) \(count)", spoken: "\(name.spoken) \(count)")
        }
    }

    // What a label says besides the provider and its window, such as "Credits" in "SuperGrok Weekly Credits". A word fused to the
    // provider's name goes with it, so "SuperGrok" drops whole and "GrokTasks" leaves "Tasks".
    private static func distinctName(of quota: UsageQuota, provider: String) -> String? {
        let providerName = ProviderRegistry.displayName(for: provider)
        let windowWords = Set(PeriodWord.allCases.map(\.rawValue) + (quota.window?.label.lowercased().split(separator: " ").map(String.init) ?? []))
        let words = quota.label
            .split(whereSeparator: { $0.isWhitespace || $0 == "(" || $0 == ")" })
            .compactMap { word -> String? in
                var text = String(word)
                if let name = text.range(of: providerName, options: [.caseInsensitive, .backwards]) {
                    text = String(text[name.upperBound...])
                }
                return text.isEmpty || windowWords.contains(text.lowercased()) ? nil : text
            }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    // Whole digits and a percent sign. An en dash stands for a share that is unknown.
    static func usedPercent(_ fraction: Double?) -> String {
        guard let fraction, fraction.isFinite else { return "–" }
        return "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
    }

    static func countdown(to resetsAt: Date?, now: Date) -> ResetCountdown {
        guard let resetsAt else { return .unknown }
        let interval = resetsAt.timeIntervalSince(now)
        guard interval > 0 else { return .passed }
        guard interval.isFinite, interval < Double(Int.max) else { return .unknown }

        let minutes = Int(interval / 60)
        if minutes < 60 {
            let shown = max(1, minutes)
            return .remaining(compact: "\(shown)m", spoken: spokenSpan((shown, "minute")))
        }
        let hours = minutes / 60
        if hours < 24 {
            return .remaining(compact: "\(hours)h \(minutes % 60)m", spoken: spokenSpan((hours, "hour"), (minutes % 60, "minute")))
        }
        return .remaining(compact: "\(hours / 24)d \(hours % 24)h", spoken: spokenSpan((hours / 24, "day"), (hours % 24, "hour")))
    }

    // For example "3 days 23 hours". A part that is zero is left out, so exactly one hour reads "1 hour".
    private static func spokenSpan(_ parts: (value: Int, unit: String)...) -> String {
        parts
            .filter { $0.value > 0 }
            .map { "\($0.value) \($0.unit)\($0.value == 1 ? "" : "s")" }
            .joined(separator: " ")
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

