import Foundation

/// Diagnostics go to stderr only. stdout is reserved for the machine-readable
/// `PAIRING` and `INJECT` lines of the headless CLI.
public enum Log {
    private static let lock = NSLock()

    public static func info(_ message: @autoclosure () -> String) {
        write("info", message())
    }

    public static func error(_ message: @autoclosure () -> String) {
        write("error", message())
    }

    private static func write(_ level: String, _ message: String) {
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardError.write(Data("MyRemoteAgent[\(level)] \(message)\n".utf8))
    }
}

/// Line-oriented stdout that is flushed after every line, as section 6 of the
/// contract requires for `PAIRING` and `INJECT`.
public final class LineOutput: @unchecked Sendable {
    public static let standardOutput = LineOutput { line in
        fputs(line + "\n", stdout)
        fflush(stdout)
    }

    private let lock = NSLock()
    private let sink: (String) -> Void

    public init(sink: @escaping (String) -> Void) {
        self.sink = sink
    }

    public func writeLine(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        sink(line)
    }
}
