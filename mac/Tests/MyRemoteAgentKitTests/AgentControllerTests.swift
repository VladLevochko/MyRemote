import Foundation
import MyRemoteAgentKit
import MyRemoteCore
import XCTest

/// The wiring used by both the headless CLI and the menu bar app, in-process, in
/// dry-run mode: nothing is injected, nothing is advertised, the port is ephemeral.
final class AgentControllerTests: XCTestCase {
    private var directory: URL!
    private var controller: AgentController?
    private var clients: [TestClient] = []

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func append(_ line: String) { lock.withLock { stored.append(line) } }
        var all: [String] { lock.withLock { stored } }
    }

    override func setUpWithError() throws {
        directory = try TestDirectories.make()
    }

    override func tearDown() {
        clients.forEach { $0.close() }
        clients = []
        controller?.stop()
        controller = nil
        TestDirectories.remove(directory)
    }

    private func options(profile: Profile? = .youtube) -> AgentOptions {
        var options = AgentOptions()
        options.headless = true
        options.dryRun = true
        options.loopback = true
        options.port = 0
        options.stateDirectory = directory
        options.forcedProfile = profile
        options.advertise = false
        return options
    }

    private func connect(_ controller: AgentController) async throws -> TestClient {
        let pairing = try PairingURI.parse(try controller.pairingURI())
        let client = TestClient(port: UInt16(pairing.port), pinnedFingerprint: pairing.fp)
        clients.append(client)
        try await client.connect()
        guard case .welcome = try await client.hello(token: pairing.token) else {
            throw TestClientError(description: "no welcome")
        }
        return client
    }

    func testPairingURIDescribesTheRunningServer() async throws {
        let controller = try AgentController(options: options(), power: FakePower())
        self.controller = controller
        let port = try controller.start()

        let uri = try controller.pairingURI()
        XCTAssertTrue(uri.hasPrefix("myremote://pair?v=1&host=127.0.0.1&port=\(port)&id=\(controller.agent.id)&name="))
        let pairing = try PairingURI.parse(uri)
        XCTAssertEqual(pairing.host, "127.0.0.1")
        XCTAssertEqual(pairing.port, Int(port))
        XCTAssertEqual(pairing.id, controller.agent.id)
        XCTAssertEqual(pairing.name, controller.agent.name)
        XCTAssertEqual(pairing.fp, controller.identity.fingerprint)
        XCTAssertFalse(pairing.name.isEmpty)

        // The URI alone is enough for a client: pin fp, connect to host:port, send token.
        let client = TestClient(port: UInt16(pairing.port), pinnedFingerprint: pairing.fp)
        clients.append(client)
        try await client.connect()
        guard case let .welcome(v, agent, state) = try await client.hello(token: pairing.token) else {
            return XCTFail("no welcome")
        }
        XCTAssertEqual(v, 1)
        XCTAssertEqual(agent, AgentInfo(id: pairing.id, name: pairing.name))
        // Dry run: accessibility is reported as true; --profile pins the profile, frontApp is null.
        XCTAssertEqual(state, RemoteState(frontApp: nil, profile: .youtube, accessibility: true))
    }

    func testDryRunPrintsInjectLinesInsteadOfInjecting() async throws {
        let lines = Lines()
        let controller = try AgentController(
            options: options(), power: FakePower(), output: LineOutput { lines.append($0) })
        self.controller = controller
        try controller.start()
        let client = try await connect(controller)

        try await client.send(.cmd(action: "playPause", id: 7))
        let first = try await client.receiveMessage()
        XCTAssertEqual(first, .ack(id: 7, ok: true, error: nil))
        try await client.send(.cmd(action: "skip", id: 8))   // unsupported on YouTube: no INJECT
        let second = try await client.receiveMessage()
        XCTAssertEqual(second, .ack(id: 8, ok: false, error: .unsupported))
        try await client.send(.pointer(dx: 12.5, dy: -3.25))
        try await client.send(.text(text: "Привіт 🎬\nдругий рядок", id: 9))
        let third = try await client.receiveMessage()
        XCTAssertEqual(third, .ack(id: 9, ok: true, error: nil))

        XCTAssertEqual(lines.all, [
            #"INJECT {"key":"k","keyCode":40,"kind":"key","modifiers":[]}"#,
            #"INJECT {"dx":12.5,"dy":-3.25,"kind":"pointer"}"#,
            #"INJECT {"kind":"text","text":"Привіт 🎬\nдругий рядок"}"#,
        ])
        XCTAssertTrue(lines.all.allSatisfy { !$0.contains("\n") }, "one action, one line")
    }

    func testDisplaySleepIsPreventedExactlyWhileAClientIsAuthenticated() async throws {
        let power = FakePower()
        let controller = try AgentController(options: options(), power: power)
        self.controller = controller
        try controller.start()
        XCTAssertFalse(power.isActive)

        // A connection that has not authenticated does not count.
        let pairing = try PairingURI.parse(try controller.pairingURI())
        let pending = TestClient(port: UInt16(pairing.port), pinnedFingerprint: pairing.fp)
        clients.append(pending)
        try await pending.connect()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(power.isActive)

        let first = try await connect(controller)
        await waitUntil("assertion to be taken") { power.isActive }
        let second = try await connect(controller)
        await waitUntil("two clients") { controller.server.clients.count == 2 }

        first.close()
        await waitUntil("one client") { controller.server.clients.count == 1 }
        XCTAssertTrue(power.isActive, "still one authenticated client")

        second.close()
        await waitUntil("assertion to be released") { !power.isActive }
        XCTAssertEqual(power.transitions, [true, false])
    }

    func testResetPairingThroughTheController() async throws {
        let power = FakePower()
        let controller = try AgentController(options: options(), power: power)
        self.controller = controller
        try controller.start()
        let before = try PairingURI.parse(try controller.pairingURI())
        let client = try await connect(controller)
        await waitUntil("assertion to be taken") { power.isActive }

        try controller.resetPairing()

        guard case .error(code: .unauthorized, _) = try await client.receiveMessage() else {
            return XCTFail("expected error unauthorized")
        }
        let closeCode = try await client.receiveClose()
        XCTAssertEqual(closeCode, 4401)
        await waitUntil("assertion to be released") { !power.isActive }

        let after = try PairingURI.parse(try controller.pairingURI())
        XCTAssertNotEqual(after.token, before.token)
        XCTAssertEqual(after.fp, before.fp)
        XCTAssertEqual(after.id, before.id)
        XCTAssertEqual(after.port, before.port)
    }

    func testStateIsPersistedInTheGivenDirectoryOnly() throws {
        let controller = try AgentController(options: options(), power: FakePower())
        self.controller = controller
        try controller.start()
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
            ["agent-id", "token", "identity.p12"])
        for name in ["agent-id", "token", "identity.p12"] {
            let attributes = try FileManager.default.attributesOfItem(
                atPath: directory.appendingPathComponent(name).path)
            XCTAssertEqual((attributes[.posixPermissions] as! NSNumber).intValue, 0o600, name)
        }
    }
}
