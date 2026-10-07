import Darwin
import Foundation

struct CLIConfiguration: Equatable, Sendable {
    let executablePath: String?
    let homeDirectory: URL

    init(executablePath: String? = nil, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.executablePath = executablePath
        self.homeDirectory = homeDirectory
    }
}

enum OMPClientError: Error, Equatable, LocalizedError, Sendable {
    case executableNotFound
    case configuredExecutableUnavailable
    case launchFailed
    case commandFailed(Int32)
    case timedOut
    case outputTooLarge
    case invalidResponse
    case cancelled

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            "OMP was not found. Choose the omp executable."
        case .configuredExecutableUnavailable:
            "The configured OMP path is unavailable. Choose another path or use automatic discovery."
        case .launchFailed:
            "OMP could not be started."
        case .commandFailed(let status):
            "OMP exited with status \(status)."
        case .timedOut:
            "OMP did not finish within 30 seconds."
        case .outputTooLarge:
            "OMP returned more than 16 MiB of usage data."
        case .invalidResponse:
            "OMP returned an unreadable usage response."
        case .cancelled:
            "The OMP request was cancelled."
        }
    }
}

struct OMPClient: Sendable {
    private static let timeout: TimeInterval = 30
    private static let maximumOutputBytes = 16 * 1024 * 1024

    func fetch(configuration: CLIConfiguration) async throws -> UsageSnapshot {
        let executable = try resolveExecutable(configuration: configuration)
        let environment = processEnvironment(configuration: configuration, executable: executable)
        let invocation = ProcessInvocation(
            executableURL: executable,
            workingDirectory: configuration.homeDirectory,
            environment: environment,
            maximumOutputBytes: Self.maximumOutputBytes,
            timeout: Self.timeout
        )
        let data = try await invocation.run()
        return try Self.decode(data, receivedAt: Date())
    }

    static func decode(_ data: Data, receivedAt: Date = Date()) throws -> UsageSnapshot {
        let envelope: OMPWireEnvelope
        do {
            envelope = try JSONDecoder().decode(OMPWireEnvelope.self, from: data)
        } catch {
            throw OMPClientError.invalidResponse
        }

        let drafts = envelope.reports.map { report in
            let sourceAccount = Self.sourceAccount(for: report)
            let privateDisplayLabel = Self.nonEmpty(report.metadata?.email)
                ?? Self.nonEmpty(report.metadata?.organizationName)
                ?? Self.nonEmpty(report.metadata?.accountID)
                ?? Self.nonEmpty(report.metadata?.projectID)
                ?? Self.nonEmpty(report.metadata?.organizationID)
            let quotas = report.limits.map { limit in
                let window = limit.window.map {
                    QuotaWindow(
                        identity: QuotaWindowIdentity(id: $0.id),
                        label: $0.label,
                        durationMilliseconds: $0.durationMs,
                        resetLabel: $0.resetLabel
                    )
                }
                let scope = QuotaScope(
                    provider: limit.scope.provider,
                    accountID: limit.scope.accountID,
                    organizationID: limit.scope.organizationID,
                    projectID: limit.scope.projectID,
                    modelID: limit.scope.modelID,
                    tier: limit.scope.tier,
                    windowID: limit.scope.windowID,
                    shared: limit.scope.shared
                )
                return UsageQuotaDraft(
                    id: limit.id,
                    label: limit.label,
                    scope: scope,
                    window: window,
                    amount: UsageAmount(
                        used: limit.amount.used,
                        limit: limit.amount.limit,
                        remaining: limit.amount.remaining,
                        usedFraction: limit.amount.usedFraction,
                        remainingFraction: limit.amount.remainingFraction,
                        unit: UsageUnit(sourceValue: limit.amount.unit)
                    ),
                    status: UsageLimitStatus(sourceValue: limit.status),
                    resetsAt: limit.window?.resetsAt?.date
                )
            }
            return UsageReportDraft(
                provider: report.provider,
                sourceAccount: sourceAccount,
                privateDisplayLabel: privateDisplayLabel,
                fetchedAt: report.fetchedAt.date,
                resetCredits: report.resetCredits?.availableCount,
                quotas: quotas
            )
        }
        guard drafts.allSatisfy({ draft in
            !draft.provider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && draft.quotas.allSatisfy {
                    guard let provider = $0.scope?.provider else { return false }
                    return !provider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
        }) else {
            throw OMPClientError.invalidResponse
        }
        return UsageSnapshot(
            generatedAt: envelope.generatedAt.date,
            receivedAt: receivedAt,
            reportDrafts: drafts
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.allSatisfy(\.isWhitespace) else { return nil }
        return value
    }

    private static func sourceAccount(for report: OMPWireReport) -> SourceAccountIdentity? {
        let identity = SourceAccountIdentity(
            accountID: Self.nonEmpty(report.metadata?.accountID) ?? Self.uniqueNonEmpty(report.limits.map { $0.scope.accountID }),
            organizationID: Self.nonEmpty(report.metadata?.organizationID),
            projectID: Self.nonEmpty(report.metadata?.projectID)
        )
        guard identity.accountID != nil || identity.organizationID != nil || identity.projectID != nil else {
            return nil
        }
        return identity
    }

    private static func uniqueNonEmpty(_ values: [String?]) -> String? {
        let uniqueValues = Set(values.compactMap { Self.nonEmpty($0) })
        return uniqueValues.count == 1 ? uniqueValues.first : nil
    }

    private func resolveExecutable(configuration: CLIConfiguration) throws -> URL {
        if let configuredPath = configuration.executablePath {
            let expandedPath = Self.expandingHome(in: configuredPath, home: configuration.homeDirectory)
            guard FileManager.default.isExecutableFile(atPath: expandedPath) else {
                throw OMPClientError.configuredExecutableUnavailable
            }
            return URL(fileURLWithPath: expandedPath).standardizedFileURL
        }

        let candidates = [
            configuration.homeDirectory.appendingPathComponent(".local/bin/omp").path,
            "/opt/homebrew/bin/omp",
            "/usr/local/bin/omp",
            "/opt/local/bin/omp",
            "/usr/bin/omp",
            "/bin/omp"
        ]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw OMPClientError.executableNotFound
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    private func processEnvironment(configuration: CLIConfiguration, executable: URL) -> [String: String] {
        let home = configuration.homeDirectory.standardizedFileURL
        let pathCandidates = [
            executable.deletingLastPathComponent().path,
            home.appendingPathComponent(".local/bin").path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/opt/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        var seen = Set<String>()
        let path = pathCandidates.filter { seen.insert($0).inserted }.joined(separator: ":")
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["PWD"] = home.path
        environment["PATH"] = path
        return environment
    }

    private static func expandingHome(in path: String, home: URL) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        let suffix = path == "~" ? "" : String(path.dropFirst(2))
        return home.appending(path: suffix).standardizedFileURL.path
    }
}

private struct OMPWireEnvelope: Decodable {
    let generatedAt: OMPWireDate
    let reports: [OMPWireReport]
}

private struct OMPWireReport: Decodable {
    let provider: String
    let fetchedAt: OMPWireDate
    let limits: [OMPWireLimit]
    let metadata: OMPWireMetadata?
    let resetCredits: OMPWireResetCredits?
}

private struct OMPWireMetadata: Decodable {
    let email: String?
    let accountID: String?
    let organizationID: String?
    let organizationName: String?
    let projectID: String?

    private enum CodingKeys: String, CodingKey {
        case email
        case accountID = "accountId"
        case organizationID = "orgId"
        case organizationName = "orgName"
        case projectID = "projectId"
    }
}

private struct OMPWireLimit: Decodable {
    let id: String
    let label: String
    let scope: OMPWireScope
    let window: OMPWireWindow?
    let amount: OMPWireAmount
    let status: String?
}

private struct OMPWireScope: Decodable {
    let provider: String
    let accountID: String?
    let organizationID: String?
    let projectID: String?
    let modelID: String?
    let tier: String?
    let windowID: String?
    let shared: Bool?

    private enum CodingKeys: String, CodingKey {
        case provider
        case accountID = "accountId"
        case organizationID = "orgId"
        case projectID = "projectId"
        case modelID = "modelId"
        case tier
        case windowID = "windowId"
        case shared
    }
}

private struct OMPWireWindow: Decodable {
    let id: String
    let label: String
    let durationMs: Double?
    let resetsAt: OMPWireDate?
    let resetLabel: String?
}

private struct OMPWireAmount: Decodable {
    let used: Double?
    let limit: Double?
    let remaining: Double?
    let usedFraction: Double?
    let remainingFraction: Double?
    let unit: String
}

private struct OMPWireResetCredits: Decodable {
    let availableCount: Int
}

private struct OMPWireDate: Decodable {
    let date: Date

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let milliseconds = try container.decode(Double.self)
        guard milliseconds.isFinite else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid OMP timestamp")
        }
        date = Date(timeIntervalSince1970: milliseconds / 1_000)
    }
}

private final class ProcessInvocation: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.quotablet.omp-process", qos: .utility)
    private let cancellationLock = NSLock()
    private let executableURL: URL
    private let workingDirectory: URL
    private let environment: [String: String]
    private let maximumOutputBytes: Int
    private let timeout: TimeInterval

    private var cancellationRequested = false
    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var continuation: CheckedContinuation<Data, Error>?
    private var timeoutSource: DispatchSourceTimer?
    private var escalationSource: DispatchSourceTimer?
    private var output = Data()
    private var exitStatus: Int32?
    private var stdoutEOF = false
    private var stderrEOF = false
    private var failure: OMPClientError?
    private var didStart = false
    private var didFinish = false

    init(
        executableURL: URL,
        workingDirectory: URL,
        environment: [String: String],
        maximumOutputBytes: Int,
        timeout: TimeInterval
    ) {
        self.executableURL = executableURL
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.maximumOutputBytes = maximumOutputBytes
        self.timeout = timeout
    }

    func run() async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    self.start(continuation)
                }
            }
        } onCancel: {
            self.requestCancellation()
        }
    }

    private func start(_ continuation: CheckedContinuation<Data, Error>) {
        self.continuation = continuation
        guard !wasCancellationRequested else {
            finish(.failure(.cancelled))
            return
        }

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executableURL
        process.arguments = ["usage", "--json"]
        process.environment = environment
        process.currentDirectoryURL = workingDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        self.process = process
        stdoutPipe = stdout
        stderrPipe = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            self.queue.async { self.receiveStdout(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            self.queue.async { self.receiveStderr(data) }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            guard let self else { return }
            self.queue.async { self.receiveExit(status) }
        }

        let timeoutSource = DispatchSource.makeTimerSource(queue: queue)
        timeoutSource.schedule(deadline: .now() + timeout)
        timeoutSource.setEventHandler { [weak self] in self?.abort(.timedOut) }
        self.timeoutSource = timeoutSource
        timeoutSource.resume()

        do {
            try process.run()
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()
            didStart = true
            if wasCancellationRequested { abort(.cancelled) }
        } catch {
            finish(.failure(.launchFailed))
        }
    }

    private func receiveStdout(_ data: Data) {
        guard !didFinish, !stdoutEOF else { return }
        guard !data.isEmpty else {
            stdoutEOF = true
            stdoutPipe?.fileHandleForReading.readabilityHandler = nil
            finishIfComplete()
            return
        }
        guard failure == nil else { return }
        guard data.count <= maximumOutputBytes - output.count else {
            abort(.outputTooLarge)
            return
        }
        output.append(data)
    }

    private func receiveStderr(_ data: Data) {
        guard !didFinish, !stderrEOF else { return }
        guard !data.isEmpty else {
            stderrEOF = true
            stderrPipe?.fileHandleForReading.readabilityHandler = nil
            finishIfComplete()
            return
        }
    }

    private func receiveExit(_ status: Int32) {
        guard !didFinish else { return }
        exitStatus = status
        escalationSource?.cancel()
        escalationSource = nil
        finishIfComplete()
    }

    private func finishIfComplete() {
        guard !didFinish else { return }
        if let failure {
            if !didStart || exitStatus != nil {
                finish(.failure(failure))
            }
            return
        }
        guard exitStatus != nil, stdoutEOF, stderrEOF else { return }
        guard let exitStatus else { return }
        if exitStatus == 0 {
            finish(.success(output))
        } else {
            finish(.failure(.commandFailed(exitStatus)))
        }
    }

    private func abort(_ error: OMPClientError) {
        guard !didFinish else { return }
        if failure == nil { failure = error }
        guard didStart, let process else {
            if continuation != nil { finish(.failure(failure ?? error)) }
            return
        }
        if exitStatus != nil || !process.isRunning {
            finish(.failure(failure ?? error))
            return
        }
        process.terminate()
        guard escalationSource == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 1)
        source.setEventHandler { [weak self] in
            guard let self, !self.didFinish, let process = self.process, process.isRunning else { return }
            _ = kill(process.processIdentifier, SIGKILL)
        }
        escalationSource = source
        source.resume()
    }

    private func requestCancellation() {
        cancellationLock.lock()
        cancellationRequested = true
        cancellationLock.unlock()
        queue.async { self.abort(.cancelled) }
    }

    private var wasCancellationRequested: Bool {
        cancellationLock.lock()
        defer { cancellationLock.unlock() }
        return cancellationRequested
    }

    private func finish(_ result: Result<Data, OMPClientError>) {
        guard !didFinish else { return }
        didFinish = true
        timeoutSource?.cancel()
        escalationSource?.cancel()
        timeoutSource = nil
        escalationSource = nil
        process?.terminationHandler = nil
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        try? stdoutPipe?.fileHandleForReading.close()
        try? stderrPipe?.fileHandleForReading.close()
        try? stdoutPipe?.fileHandleForWriting.close()
        try? stderrPipe?.fileHandleForWriting.close()
        stdoutPipe = nil
        stderrPipe = nil
        process = nil

        guard let continuation else { return }
        self.continuation = nil
        switch result {
        case .success(let data): continuation.resume(returning: data)
        case .failure(let error): continuation.resume(throwing: error)
        }
    }
}
