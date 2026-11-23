import Foundation
import MyRemoteCore
import XCTest

/// The shared contract fixtures in `<repo>/protocol/fixtures`, located relative to
/// this source file so the tests read the very files the Android side reads.
enum Fixtures {
    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // MyRemoteCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // mac
        .deletingLastPathComponent()  // repository root
        .appendingPathComponent("protocol/fixtures", isDirectory: true)

    static func files(in directory: String) throws -> [URL] {
        let url = root.appendingPathComponent(directory, isDirectory: true)
        return try FileManager.default
            .contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func data(_ relativePath: String) throws -> Data {
        try Data(contentsOf: root.appendingPathComponent(relativePath))
    }
}

/// Semantic JSON equality: key order and number formatting (0 vs 0.0) do not matter,
/// but every key, value, and explicit null must match.
func assertSameJSON(
    _ actual: Data, _ expected: Data, _ message: String = "", file: StaticString = #filePath, line: UInt = #line
) throws {
    let a = try JSONSerialization.jsonObject(with: actual, options: [.fragmentsAllowed]) as! NSObject
    let b = try JSONSerialization.jsonObject(with: expected, options: [.fragmentsAllowed]) as! NSObject
    XCTAssertEqual(
        a, b,
        "\(message) actual=\(String(decoding: actual, as: UTF8.self)) expected=\(String(decoding: expected, as: UTF8.self))",
        file: file, line: line)
}

/// Records what the protocol logic asks the system to do; injects nothing.
final class FakeInjector: InputInjector {
    var isTrusted = true
    private(set) var actions: [InputAction] = []

    func perform(_ action: InputAction) -> InjectionResult {
        guard isTrusted else { return .accessibilityDenied }
        actions.append(action)
        return .ok
    }
}
