import Darwin
import Foundation

struct PersistedSettings: Codable, Equatable, Sendable {
    var executablePath: String?
}

struct StoredApplicationState: Sendable {
    let settings: PersistedSettings
    let snapshot: UsageSnapshot?
}

final class AppPersistence: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.quotablet.persistence", qos: .utility)
    private let fileManager = FileManager.default
    private let directoryURL: URL
    private let settingsURL: URL
    private let snapshotURL: URL
    // The user installs logo files here. The app only reads them.
    let logosDirectoryURL: URL

    init(directoryURL: URL? = nil) {
        let supportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        self.directoryURL = directoryURL ?? supportDirectory.appendingPathComponent("Quotablet", isDirectory: true)
        settingsURL = self.directoryURL.appendingPathComponent("settings.json")
        snapshotURL = self.directoryURL.appendingPathComponent("usage-snapshot.json")
        logosDirectoryURL = self.directoryURL.appendingPathComponent("Logos", isDirectory: true)
    }

    func load() async -> StoredApplicationState {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.loadSynchronously())
            }
        }
    }

    func save(settings: PersistedSettings) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.write(settings, to: self.settingsURL))
            }
        }
    }

    func save(snapshot: UsageSnapshot) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.write(snapshot, to: self.snapshotURL))
            }
        }
    }
    func flush() async {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume()
            }
        }
    }

    private func loadSynchronously() -> StoredApplicationState {
        var settings = PersistedSettings(executablePath: nil)
        if let data = try? Data(contentsOf: settingsURL),
           let decoded = try? JSONDecoder().decode(PersistedSettings.self, from: data) {
            settings = decoded
        }
        let snapshot: UsageSnapshot?
        if let data = try? Data(contentsOf: snapshotURL) {
            snapshot = try? JSONDecoder().decode(UsageSnapshot.self, from: data)
        } else {
            snapshot = nil
        }
        return StoredApplicationState(settings: settings, snapshot: snapshot)
    }

    private func write<Value: Encodable>(_ value: Value, to destination: URL) -> Bool {
        do {
            try ensurePrivateDirectory()
            let data = try JSONEncoder().encode(value)
            try writeAtomically(data, to: destination)
            return true
        } catch {
            return false
        }
    }

    private func ensurePrivateDirectory() throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        guard Darwin.chmod(directoryURL.path, mode_t(S_IRWXU)) == 0 else {
            throw PersistenceFailure.fileSystem
        }
    }

    private func writeAtomically(_ data: Data, to destination: URL) throws {
        let temporary = directoryURL.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else { throw PersistenceFailure.fileSystem }
        var openDescriptor = descriptor
        defer {
            if openDescriptor >= 0 { _ = Darwin.close(openDescriptor) }
            try? fileManager.removeItem(at: temporary)
        }

        let wroteAllBytes = data.withUnsafeBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress else { return data.isEmpty }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, baseAddress.advanced(by: offset), buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if written == 0 { return false }
                offset += written
            }
            return true
        }
        guard wroteAllBytes, Darwin.fsync(descriptor) == 0, Darwin.close(descriptor) == 0 else {
            throw PersistenceFailure.fileSystem
        }
        openDescriptor = -1
        guard Darwin.rename(temporary.path, destination.path) == 0 else {
            throw PersistenceFailure.fileSystem
        }
    }
}

private enum PersistenceFailure: Error {
    case fileSystem
}
