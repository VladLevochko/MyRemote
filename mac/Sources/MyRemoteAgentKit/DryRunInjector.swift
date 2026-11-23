import Foundation
import MyRemoteCore

/// `--dry-run`: nothing is injected into the system. Every action that would have
/// been performed is printed as one line `INJECT <json>` and flushed.
public final class DryRunInjector: InputInjector {
    public static let linePrefix = "INJECT "

    private let output: LineOutput

    public init(output: LineOutput = .standardOutput) {
        self.output = output
    }

    /// In dry-run mode `state.accessibility` is always true.
    public var isTrusted: Bool { true }

    public func perform(_ action: InputAction) -> InjectionResult {
        output.writeLine(Self.line(for: action))
        return .ok
    }

    public static func line(for action: InputAction) -> String {
        linePrefix + WireJSON.string(action)
    }
}
