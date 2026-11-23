import Foundation
import MyRemoteCore
import XCTest

/// Contract tests against `protocol/fixtures` (see its README): every fixture must
/// decode into the typed model and re-encode to semantically the same JSON.
final class FixtureContractTests: XCTestCase {
    func testFixtureDirectoriesAreFoundAndNotEmpty() throws {
        XCTAssertGreaterThanOrEqual(try Fixtures.files(in: "client").count, 10)
        XCTAssertGreaterThanOrEqual(try Fixtures.files(in: "server").count, 7)
        XCTAssertFalse(try Fixtures.data("pairing/cases.json").isEmpty)
    }

    // MARK: client -> server

    func testEveryClientFixtureRoundTrips() throws {
        for url in try Fixtures.files(in: "client") {
            let original = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(ClientMessage.self, from: original)
            try assertSameJSON(WireJSON.encode(decoded), original, url.lastPathComponent)
            // The lenient entry point used by the session agrees with the strict decoder.
            XCTAssertEqual(ClientMessage.parse(original), .message(decoded), url.lastPathComponent)
        }
    }

    func testClientFixturesDecodeToExpectedValues() throws {
        let expected: [String: ClientMessage] = [
            "client/click_left.json": .click(button: .left, count: 1),
            "client/click_right_double.json": .click(button: .right, count: 2),
            "client/cmd_with_id.json": .cmd(action: "playPause", id: 7),
            "client/cmd_without_id.json": .cmd(action: "seekForward", id: nil),
            "client/hello.json": .hello(
                v: 1, token: "q83vEjRWeJCrze8SNFZ4kKvN7xI0VniQq83vEjRWeJA", device: "Galaxy S24"),
            "client/key.json": .key(key: "enter", id: 8),
            "client/ping.json": .ping(t: 1_790_000_000_123),
            "client/pointer.json": .pointer(dx: 12.5, dy: -3.25),
            "client/scroll.json": .scroll(dx: 0, dy: -40.5),
            "client/text.json": .text(text: "Привіт, світ! 🎬 \"quoted\"", id: 9),
        ]
        for (path, message) in expected {
            let decoded = try JSONDecoder().decode(ClientMessage.self, from: try Fixtures.data(path))
            XCTAssertEqual(decoded, message, path)
        }
        // Every fixture on disk has an expectation here, so a new fixture cannot be
        // silently skipped by this test.
        let onDisk = Set(try Fixtures.files(in: "client").map { "client/" + $0.lastPathComponent })
        XCTAssertEqual(onDisk, Set(expected.keys))
    }

    func testCmdAndKeyFixturesUseKnownVocabulary() throws {
        for path in ["client/cmd_with_id.json", "client/cmd_without_id.json"] {
            guard case let .cmd(action, _) = try JSONDecoder().decode(ClientMessage.self, from: try Fixtures.data(path))
            else { return XCTFail(path) }
            XCTAssertNotNil(CmdAction(rawValue: action), action)
        }
        guard case let .key(key, _) = try JSONDecoder().decode(
            ClientMessage.self, from: try Fixtures.data("client/key.json"))
        else { return XCTFail("key.json") }
        XCTAssertNotNil(RemoteKey(rawValue: key), key)
    }

    // MARK: server -> client

    func testEveryServerFixtureRoundTrips() throws {
        for url in try Fixtures.files(in: "server") {
            let original = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(ServerMessage.self, from: original)
            try assertSameJSON(WireJSON.encode(decoded), original, url.lastPathComponent)
        }
    }

    func testServerFixturesDecodeToExpectedValues() throws {
        let expected: [String: ServerMessage] = [
            "server/ack_error.json": .ack(id: 8, ok: false, error: .accessibilityDenied),
            "server/ack_ok.json": .ack(id: 7, ok: true, error: nil),
            "server/error.json": .error(code: .unauthorized, message: "invalid token"),
            "server/pong.json": .pong(t: 1_790_000_000_123),
            "server/state_appletv.json": .state(RemoteState(
                frontApp: FrontApp(bundleId: "com.apple.TV", name: "TV"), profile: .appletv, accessibility: true)),
            "server/state_no_front_app.json": .state(RemoteState(
                frontApp: nil, profile: .generic, accessibility: false)),
            "server/welcome.json": .welcome(
                v: 1,
                agent: AgentInfo(id: "0123456789abcdef", name: "MacBook Pro"),
                state: RemoteState(
                    frontApp: FrontApp(bundleId: "com.google.Chrome", name: "Google Chrome"),
                    profile: .youtube, accessibility: true)),
        ]
        for (path, message) in expected {
            let decoded = try JSONDecoder().decode(ServerMessage.self, from: try Fixtures.data(path))
            XCTAssertEqual(decoded, message, path)
        }
        let onDisk = Set(try Fixtures.files(in: "server").map { "server/" + $0.lastPathComponent })
        XCTAssertEqual(onDisk, Set(expected.keys))
    }

    /// What this agent actually sends must equal the fixtures, not merely be decodable.
    func testServerMessagesBuiltByTheAgentMatchFixtures() throws {
        try assertSameJSON(WireJSON.encode(ServerMessage.ackOK(7)), try Fixtures.data("server/ack_ok.json"))
        try assertSameJSON(
            WireJSON.encode(ServerMessage.ackFailed(8, .accessibilityDenied)),
            try Fixtures.data("server/ack_error.json"))
        try assertSameJSON(
            WireJSON.encode(ServerMessage.state(RemoteState(frontApp: nil, profile: .generic, accessibility: false))),
            try Fixtures.data("server/state_no_front_app.json"))
    }

    // MARK: pairing

    private struct PairingCases: Decodable {
        struct Expect: Decodable {
            let host: String
            let port: Int
            let id: String
            let name: String
            let fp: String
            let token: String
        }
        struct Valid: Decodable {
            let uri: String
            let expect: Expect
        }
        struct Invalid: Decodable {
            let uri: String
            let reason: String
        }
        let valid: [Valid]
        let invalid: [Invalid]
    }

    private func pairingCases() throws -> PairingCases {
        try JSONDecoder().decode(PairingCases.self, from: try Fixtures.data("pairing/cases.json"))
    }

    func testValidPairingURIsParseToExpectedFields() throws {
        let cases = try pairingCases()
        XCTAssertFalse(cases.valid.isEmpty)
        for entry in cases.valid {
            let expected = PairingInfo(
                host: entry.expect.host, port: entry.expect.port, id: entry.expect.id,
                name: entry.expect.name, fp: entry.expect.fp, token: entry.expect.token)
            XCTAssertEqual(try PairingURI.parse(entry.uri), expected, entry.uri)
        }
    }

    func testPairingURIsBuiltFromExpectedFieldsAgreeWithFixtures() throws {
        let cases = try pairingCases()
        for entry in cases.valid {
            let info = PairingInfo(
                host: entry.expect.host, port: entry.expect.port, id: entry.expect.id,
                name: entry.expect.name, fp: entry.expect.fp, token: entry.expect.token)
            let built = try PairingURI.build(info)
            // Whatever we build, parsing it gives the fixture's fields back...
            XCTAssertEqual(try PairingURI.parse(built), info)
            // ...and every parameter we emit is spelled exactly as in the fixture
            // (the fixture may order them differently and add unknown ones).
            let fixtureParameters = Set(entry.uri.split(separator: "?", maxSplits: 1)[1].split(separator: "&"))
            let builtParameters = Set(built.split(separator: "?", maxSplits: 1)[1].split(separator: "&"))
            XCTAssertTrue(
                builtParameters.isSubset(of: fixtureParameters),
                "built \(built) is not spelled like fixture \(entry.uri)")
        }
        // The first fixture is in the contract's canonical parameter order: byte-identical.
        let canonical = try XCTUnwrap(cases.valid.first)
        let info = try PairingURI.parse(canonical.uri)
        XCTAssertEqual(try PairingURI.build(info), canonical.uri)
    }

    func testInvalidPairingURIsAreRejectedForTheStatedReason() throws {
        let cases = try pairingCases()
        XCTAssertFalse(cases.invalid.isEmpty)
        let expectedErrors: [String: PairingError] = [
            "unsupported version": .unsupportedVersion("2"),
            "missing fp": .missingParameter("fp"),
            "fp is not 64 hex chars": .invalidFingerprint,
            "port out of range": .invalidPort,
            "token is not 32 bytes of base64url": .invalidToken,
            "wrong scheme": .wrongScheme,
            "wrong action": .wrongAction,
            "garbage": .notAPairingURI,
        ]
        for entry in cases.invalid {
            XCTAssertThrowsError(try PairingURI.parse(entry.uri), entry.reason) { error in
                guard let expected = expectedErrors[entry.reason] else {
                    // A reason this test does not know yet: being rejected is enough.
                    return
                }
                XCTAssertEqual(error as? PairingError, expected, entry.reason)
            }
        }
    }
}
