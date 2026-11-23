import Foundation
import MyRemoteCore

public enum StateStoreError: Error, CustomStringConvertible {
    case cannotCreateDirectory(String, underlying: String)
    case cannotWrite(String, underlying: String)

    public var description: String {
        switch self {
        case let .cannotCreateDirectory(path, underlying):
            return "cannot create state directory \(path): \(underlying)"
        case let .cannotWrite(path, underlying):
            return "cannot write \(path): \(underlying)"
        }
    }
}

/// Persistent agent state: `agent-id`, `token` and `identity.p12`, one file each,
/// all mode 0600 inside a 0700 directory.
public final class StateStore {
    public static let agentIdFile = "agent-id"
    public static let tokenFile = "token"
    public static let identityFile = "identity.p12"

    public let directory: URL

    /// `~/Library/Application Support/MyRemote`
    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("MyRemote", isDirectory: true)
    }

    public init(directory: URL) throws {
        self.directory = directory.standardizedFileURL
        do {
            try FileManager.default.createDirectory(
                at: self.directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch {
            throw StateStoreError.cannotCreateDirectory(self.directory.path, underlying: "\(error.localizedDescription)")
        }
    }

    public func url(for name: String) -> URL {
        directory.appendingPathComponent(name, isDirectory: false)
    }

    // MARK: Agent id

    public func loadOrCreateAgentId() throws -> String {
        if let existing = readString(Self.agentIdFile), AgentID.isWellFormed(existing) {
            return existing
        }
        let id = AgentID.generate()
        try write(Data(id.utf8), to: Self.agentIdFile)
        return id
    }

    // MARK: Token

    public func loadOrCreateToken() throws -> String {
        if let existing = readString(Self.tokenFile), PairingToken.isWellFormed(existing) {
            return existing
        }
        return try resetToken()
    }

    /// Generates and persists a fresh token. The certificate and agent id are untouched.
    @discardableResult
    public func resetToken() throws -> String {
        let token = PairingToken.generate()
        try write(Data(token.utf8), to: Self.tokenFile)
        return token
    }

    // MARK: Raw files

    public func read(_ name: String) -> Data? {
        try? Data(contentsOf: url(for: name))
    }

    private func readString(_ name: String) -> String? {
        guard let data = read(name), let text = String(data: data, encoding: .utf8) else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Atomic write: the data lands in a 0600 temporary file in the same directory
    /// and is renamed over the destination, so the secret never exists with wider
    /// permissions and a crash never leaves a half-written file.
    public func write(_ data: Data, to name: String) throws {
        let destination = url(for: name)
        let temporary = url(for: ".\(name).\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else {
            throw StateStoreError.cannotWrite(destination.path, underlying: String(cString: strerror(errno)))
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            unlink(temporary.path)
            throw StateStoreError.cannotWrite(destination.path, underlying: "\(error.localizedDescription)")
        }
        guard rename(temporary.path, destination.path) == 0 else {
            let reason = String(cString: strerror(errno))
            unlink(temporary.path)
            throw StateStoreError.cannotWrite(destination.path, underlying: reason)
        }
    }
}
