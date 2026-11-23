import Foundation
import MyRemoteAgentKit
import MyRemoteCore
import Network
import XCTest

/// Loopback integration tests: the real `RemoteServer`, the real TLS identity from
/// a temp state directory, an ephemeral port, and a real WebSocket client that pins
/// the certificate fingerprint. Input goes to a recording injector, never to the system.
final class ServerIntegrationTests: XCTestCase {
    private var directory: URL!
    private var agents: [TestAgent] = []
    private var clients: [TestClient] = []

    override func setUpWithError() throws {
        directory = try TestDirectories.make()
    }

    override func tearDown() {
        clients.forEach { $0.close() }
        agents.forEach { $0.server.stop() }
        clients = []
        agents = []
        TestDirectories.remove(directory)
    }

    private func startAgent(
        preferredPort: UInt16 = 0,
        session: SessionConfig = SessionConfig(),
        state: RemoteState = TestAgent.youtubeState,
        injector: RecordingInjector = RecordingInjector(),
        in customDirectory: URL? = nil
    ) throws -> TestAgent {
        let agent = try TestAgent.start(
            in: customDirectory ?? directory, preferredPort: preferredPort, session: session,
            state: state, injector: injector)
        agents.append(agent)
        return agent
    }

    private func rawClient(_ agent: TestAgent, pin: String? = nil) async throws -> TestClient {
        let client = TestClient(port: agent.port, pinnedFingerprint: pin ?? agent.identity.fingerprint)
        clients.append(client)
        try await client.connect()
        return client
    }

    private func authenticatedClient(_ agent: TestAgent, device: String = "Galaxy S24") async throws -> TestClient {
        let client = try await rawClient(agent)
        let answer = try await client.hello(token: agent.token, device: device)
        guard case .welcome = answer else {
            throw TestClientError(description: "expected welcome, got \(answer)")
        }
        return client
    }

    // MARK: Handshake

    func testHelloIsAnsweredWithWelcome() async throws {
        let agent = try startAgent()
        XCTAssertNotEqual(agent.port, 0)
        XCTAssertNotEqual(agent.port, ServerConfig.defaultPort, "tests must not use the production port")

        let client = try await rawClient(agent)
        let answer = try await client.hello(token: agent.token)
        XCTAssertEqual(answer, .welcome(v: 1, agent: agent.agent, state: TestAgent.youtubeState))
        XCTAssertTrue(AgentID.isWellFormed(agent.agent.id))

        await waitUntil("client to be listed") { agent.server.clients.count == 1 }
        XCTAssertEqual(agent.server.clients.first?.device, "Galaxy S24")
    }

    func testFixtureHelloShapeIsAcceptedOverTheWire() async throws {
        let agent = try startAgent()
        let client = try await rawClient(agent)
        // The fixture's JSON verbatim, with only the token swapped for this agent's.
        let hello = try Fixtures.text("client/hello.json")
            .replacingOccurrences(of: "q83vEjRWeJCrze8SNFZ4kKvN7xI0VniQq83vEjRWeJA", with: agent.token)
        try await client.send(hello)
        guard case .welcome = try await client.receiveMessage() else { return XCTFail("no welcome") }
    }

    func testWrongTokenGetsUnauthorizedAndClose4401() async throws {
        let agent = try startAgent()
        let client = try await rawClient(agent)
        let answer = try await client.hello(token: PairingToken.generate())
        XCTAssertEqual(answer, .error(code: .unauthorized, message: "invalid token"))
        let closeCode = try await client.receiveClose()
        XCTAssertEqual(closeCode, 4401)
        XCTAssertTrue(agent.server.clients.isEmpty)
        XCTAssertTrue(agent.injector.actions.isEmpty)
    }

    func testNonHelloFirstGetsUnauthorizedAndClose4401() async throws {
        let agent = try startAgent()
        let client = try await rawClient(agent)
        try await client.send(.cmd(action: "playPause", id: 1))
        guard case .error(code: .unauthorized, _) = try await client.receiveMessage() else {
            return XCTFail("expected error unauthorized")
        }
        let closeCode = try await client.receiveClose()
        XCTAssertEqual(closeCode, 4401)
        XCTAssertTrue(agent.injector.actions.isEmpty, "an unauthenticated command must never be injected")
    }

    func testUnsupportedVersionGetsClose4400() async throws {
        let agent = try startAgent()
        let client = try await rawClient(agent)
        guard case .error(code: .unsupportedVersion, _) = try await client.hello(token: agent.token, v: 2) else {
            return XCTFail("expected error unsupported_version")
        }
        let closeCode = try await client.receiveClose()
        XCTAssertEqual(closeCode, 4400)
    }

    func testHelloTimeoutClosesWith4401() async throws {
        // The production value is 5 s; a short one keeps the test fast. The 5 s rule
        // itself is covered with a fake clock in SessionTests.
        let agent = try startAgent(session: SessionConfig(helloTimeout: 0.3))
        let client = try await rawClient(agent)
        let started = Date()
        guard case .error(code: .unauthorized, _) = try await client.receiveMessage() else {
            return XCTFail("expected error unauthorized")
        }
        let closeCode = try await client.receiveClose()
        XCTAssertEqual(closeCode, 4401)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.25)
    }

    func testDefaultHelloTimeoutIsFiveSecondsAndIdleIsThirty() {
        XCTAssertEqual(SessionConfig().helloTimeout, 5)
        XCTAssertEqual(SessionConfig().idleTimeout, 30)
        XCTAssertEqual(ServerConfig.defaultPort, 47110)
        XCTAssertEqual(ServerConfig.bonjourType, "_myremote._tcp")
    }

    // MARK: Commands

    func testCmdWithIdIsAckedAndReachesTheInjectorMapped() async throws {
        let agent = try startAgent()   // profile: youtube
        let client = try await authenticatedClient(agent)

        try await client.send(try Fixtures.text("client/cmd_with_id.json"))   // playPause, id 7
        let ack = try await client.receiveMessage()
        XCTAssertEqual(ack, .ack(id: 7, ok: true, error: nil))
        XCTAssertEqual(agent.injector.actions, [.key(.k)], "youtube maps playPause to the k key")
    }

    func testCmdWithoutIdIsExecutedButNotAcked() async throws {
        let agent = try startAgent()
        let client = try await authenticatedClient(agent)
        try await client.send(try Fixtures.text("client/cmd_without_id.json"))   // seekForward
        // A following ping proves that no ack was queued in between.
        try await client.send(.ping(t: 1))
        let answer = try await client.receiveMessage()
        XCTAssertEqual(answer, .pong(t: 1))
        XCTAssertEqual(agent.injector.actions, [.key(.l)])
    }

    func testUnsupportedAndUnknownActions() async throws {
        let agent = try startAgent()
        let client = try await authenticatedClient(agent)
        try await client.send(.cmd(action: "skip", id: 1))          // no YouTube equivalent
        let unsupported = try await client.receiveMessage()
        XCTAssertEqual(unsupported, .ack(id: 1, ok: false, error: .unsupported))
        try await client.send(.cmd(action: "explode", id: 2))
        let unknown = try await client.receiveMessage()
        XCTAssertEqual(unknown, .ack(id: 2, ok: false, error: .badRequest))
        XCTAssertTrue(agent.injector.actions.isEmpty)
    }

    func testEveryClientFixtureOverTheWire() async throws {
        let agent = try startAgent()
        let client = try await authenticatedClient(agent)
        for name in ["cmd_with_id", "cmd_without_id", "key", "pointer", "click_left", "click_right_double", "scroll", "text", "ping"] {
            try await client.send(try Fixtures.text("client/\(name).json"))
        }
        // Exactly the acks for the three messages with an id, then the pong, in order.
        let first = try await client.receiveMessage()
        let second = try await client.receiveMessage()
        let third = try await client.receiveMessage()
        let fourth = try await client.receiveMessage()
        XCTAssertEqual(first, .ack(id: 7, ok: true, error: nil))
        XCTAssertEqual(second, .ack(id: 8, ok: true, error: nil))
        XCTAssertEqual(third, .ack(id: 9, ok: true, error: nil))
        XCTAssertEqual(fourth, .pong(t: 1_790_000_000_123))
        XCTAssertEqual(agent.injector.actions, [
            .key(.k),
            .key(.l),
            .key(.enter),
            .pointer(dx: 12.5, dy: -3.25),
            .click(button: .left, count: 1),
            .click(button: .right, count: 2),
            .scroll(dx: 0, dy: -40.5),
            .text("Привіт, світ! 🎬 \"quoted\""),
        ])
    }

    func testAccessibilityDeniedIsReportedInStateAndAck() async throws {
        let injector = RecordingInjector()
        injector.isTrusted = false
        let state = RemoteState(frontApp: nil, profile: .generic, accessibility: false)
        let agent = try startAgent(state: state, injector: injector)
        let client = try await rawClient(agent)
        let welcome = try await client.hello(token: agent.token)
        XCTAssertEqual(welcome, .welcome(v: 1, agent: agent.agent, state: state))

        try await client.send(.key(key: "enter", id: 8))
        let ack = try await client.receiveMessage()
        XCTAssertEqual(ack, .ack(id: 8, ok: false, error: .accessibilityDenied))
        XCTAssertTrue(injector.actions.isEmpty)
    }

    // MARK: Protocol robustness

    func testPingPong() async throws {
        let agent = try startAgent()
        let client = try await authenticatedClient(agent)
        try await client.send(try Fixtures.text("client/ping.json"))
        let pong = try await client.receiveMessage()
        XCTAssertEqual(pong, .pong(t: 1_790_000_000_123))
        try await assertSameJSONText(WireJSON.string(pong), try Fixtures.text("server/pong.json"))
    }

    func testUnknownTypeGetsBadRequestAndTheConnectionStaysOpen() async throws {
        let agent = try startAgent()
        let client = try await authenticatedClient(agent)
        try await client.send(#"{"type":"hologram","intensity":11}"#)
        guard case .error(code: .badRequest, _) = try await client.receiveMessage() else {
            return XCTFail("expected error bad_request")
        }
        try await client.send("this is not json")
        guard case .error(code: .badRequest, _) = try await client.receiveMessage() else {
            return XCTFail("expected error bad_request")
        }
        // Still open and still authenticated.
        try await client.send(.cmd(action: "toggleMute", id: 3))
        let ack = try await client.receiveMessage()
        XCTAssertEqual(ack, .ack(id: 3, ok: true, error: nil))
        XCTAssertEqual(agent.injector.actions, [.key(.m)])
    }

    func testBinaryFramesAreIgnored() async throws {
        let agent = try startAgent()
        // Before hello: ignored, not treated as "something other than hello".
        let client = try await rawClient(agent)
        try await client.sendBinary(Data([0, 1, 2, 3]))
        guard case .welcome = try await client.hello(token: agent.token) else { return XCTFail("no welcome") }
        // After hello: ignored, no error, no ack.
        try await client.sendBinary(Data(#"{"type":"cmd","action":"playPause","id":1}"#.utf8))
        try await client.send(.ping(t: 9))
        let answer = try await client.receiveMessage()
        XCTAssertEqual(answer, .pong(t: 9))
        XCTAssertTrue(agent.injector.actions.isEmpty)
    }

    func testAnyRequestPathIsAccepted() async throws {
        // The contract's URL is /ws. NWProtocolWebSocket does not expose the request
        // path to the server, so the agent cannot be stricter than "any path".
        let agent = try startAgent()
        let client = TestClient(port: agent.port, pinnedFingerprint: agent.identity.fingerprint, path: "/")
        clients.append(client)
        try await client.connect()
        guard case .welcome = try await client.hello(token: agent.token) else { return XCTFail("no welcome") }
    }

    func testIdleConnectionIsClosed() async throws {
        let agent = try startAgent(session: SessionConfig(idleTimeout: 0.4))
        let client = try await authenticatedClient(agent)
        // Activity keeps it alive past the timeout...
        for t in 0..<4 {
            try await Task.sleep(nanoseconds: 150_000_000)
            try await client.send(.ping(t: t))
            let pong = try await client.receiveMessage()
            XCTAssertEqual(pong, .pong(t: t))
        }
        // ...silence does not.
        let closeCode = try await client.receiveClose(timeout: 3)
        XCTAssertEqual(closeCode, 1001)
        await waitUntil("client to be dropped") { agent.server.clients.isEmpty }
    }

    // MARK: State push and multiple clients

    func testStateIsPushedToEveryAuthenticatedClientOnChange() async throws {
        let agent = try startAgent()
        let first = try await authenticatedClient(agent, device: "Phone A")
        let second = try await authenticatedClient(agent, device: "Phone B")
        let pending = try await rawClient(agent)   // connected, not authenticated
        await waitUntil("both clients") { agent.server.clients.count == 2 }
        XCTAssertEqual(Set(agent.server.clients.map(\.device)), ["Phone A", "Phone B"])

        let appleTV = RemoteState(
            frontApp: FrontApp(bundleId: "com.apple.TV", name: "TV"), profile: .appletv, accessibility: true)
        agent.server.updateState(appleTV)
        let pushedToFirst = try await first.receiveMessage()
        let pushedToSecond = try await second.receiveMessage()
        XCTAssertEqual(pushedToFirst, .state(appleTV))
        XCTAssertEqual(pushedToSecond, .state(appleTV))
        try await assertSameJSONText(WireJSON.string(pushedToFirst), try Fixtures.text("server/state_appletv.json"))

        // Setting the same state again pushes nothing; the next thing each client sees is its pong.
        agent.server.updateState(appleTV)
        try await first.send(.ping(t: 1))
        let pong = try await first.receiveMessage()
        XCTAssertEqual(pong, .pong(t: 1))

        // The mapping follows the new profile for connections that were already open.
        try await second.send(.cmd(action: "volumeUp", id: 5))
        let ack = try await second.receiveMessage()
        XCTAssertEqual(ack, .ack(id: 5, ok: true, error: nil))
        XCTAssertEqual(agent.injector.actions, [.key(.up, modifiers: [.command])])

        // The unauthenticated connection got no state push: its first message is the welcome.
        guard case let .welcome(_, _, state) = try await pending.hello(token: agent.token) else {
            return XCTFail("no welcome")
        }
        XCTAssertEqual(state, appleTV)
    }

    func testClientObserverSeesConnectAndDisconnect() async throws {
        let agent = try startAgent()
        let lock = NSLock()
        var counts: [Int] = []
        agent.server.observeClients { clients in lock.withLock { counts.append(clients.count) } }

        let client = try await authenticatedClient(agent)
        await waitUntil("connect to be observed") { lock.withLock { counts } == [1] }
        client.close()
        await waitUntil("disconnect to be observed") { lock.withLock { counts } == [1, 0] }
    }

    // MARK: TLS identity and pinning

    func testServedCertificateFingerprintEqualsPairingFingerprint() async throws {
        let agent = try startAgent()
        let pairing = try agent.pairing()
        XCTAssertTrue(CertificateFingerprint.isWellFormed(pairing.fp))

        let client = TestClient(port: agent.port, pinnedFingerprint: pairing.fp)
        clients.append(client)
        try await client.connect()
        // What the server really presented in the handshake, hashed by the client.
        XCTAssertEqual(client.servedFingerprint, pairing.fp)
        XCTAssertEqual(client.servedFingerprint, CertificateFingerprint.sha256Hex(ofDER: agent.identity.certificateDER))
    }

    func testWrongPinIsDetectedClientSideBeforeAnyDataIsSent() async throws {
        let agent = try startAgent()
        let wrongPin = String(repeating: "00", count: 32)
        let client = TestClient(port: agent.port, pinnedFingerprint: wrongPin)
        clients.append(client)
        do {
            try await client.connect()
            XCTFail("a client pinned to another fingerprint must not get a connection")
        } catch {
            // Expected: the TLS handshake was aborted by the client's pin check.
        }
        // The client did see the real certificate and could tell it was not the pinned one.
        XCTAssertEqual(client.servedFingerprint, agent.identity.fingerprint)
        XCTAssertNotEqual(client.servedFingerprint, wrongPin)
        // Nothing reached the application layer of the server.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(agent.server.clients.isEmpty)
        XCTAssertTrue(agent.injector.actions.isEmpty)
    }

    func testIdentityAgentIdAndTokenAreStableAcrossRestart() async throws {
        let first = try startAgent()
        let before = try first.pairing()
        let firstClient = try await authenticatedClient(first)
        let servedBefore = firstClient.servedFingerprint
        firstClient.close()
        first.server.stop()

        let second = try startAgent()   // same state directory
        let after = try second.pairing()
        XCTAssertEqual(after.fp, before.fp, "the certificate must survive a restart")
        XCTAssertEqual(after.id, before.id, "the agent id must survive a restart")
        XCTAssertEqual(after.token, before.token, "the token must survive a restart")
        XCTAssertEqual(second.identity.certificateDER, first.identity.certificateDER)

        // A phone paired before the restart: old pin, old token, still works.
        let client = TestClient(port: second.port, pinnedFingerprint: before.fp)
        clients.append(client)
        try await client.connect()
        XCTAssertEqual(client.servedFingerprint, servedBefore)
        guard case let .welcome(_, agentInfo, _) = try await client.hello(token: before.token) else {
            return XCTFail("no welcome after restart")
        }
        XCTAssertEqual(agentInfo.id, before.id)
    }

    // MARK: Reset pairing

    func testResetPairingInvalidatesTheOldTokenAndDropsConnections() async throws {
        let agent = try startAgent()
        let oldPairing = try agent.pairing()
        let authenticated = try await authenticatedClient(agent)
        let pending = try await rawClient(agent)   // connected, hello not sent yet
        await waitUntil("client to be listed") { agent.server.clients.count == 1 }

        let newToken = try agent.server.resetPairing()

        // The authenticated connection is told why and closed.
        guard case .error(code: .unauthorized, _) = try await authenticated.receiveMessage() else {
            return XCTFail("expected error unauthorized on reset")
        }
        let closeCode = try await authenticated.receiveClose()
        XCTAssertEqual(closeCode, 4401)
        // The not-yet-authenticated connection is dropped the same way.
        guard case .error(code: .unauthorized, _) = try await pending.receiveMessage() else {
            return XCTFail("expected error unauthorized on the pending connection")
        }
        let pendingCloseCode = try await pending.receiveClose()
        XCTAssertEqual(pendingCloseCode, 4401)
        await waitUntil("clients to be dropped") { agent.server.clients.isEmpty }

        // New token: different, well-formed, persisted. Certificate and id: unchanged.
        XCTAssertNotEqual(newToken, oldPairing.token)
        XCTAssertTrue(PairingToken.isWellFormed(newToken))
        XCTAssertEqual(agent.token, newToken)
        XCTAssertEqual(try agent.store.loadOrCreateToken(), newToken)
        let newPairing = try agent.pairing()
        XCTAssertEqual(newPairing.fp, oldPairing.fp)
        XCTAssertEqual(newPairing.id, oldPairing.id)

        // The old token no longer works...
        let stale = try await rawClient(agent)
        let rejected = try await stale.hello(token: oldPairing.token)
        XCTAssertEqual(rejected, .error(code: .unauthorized, message: "invalid token"))
        let staleCloseCode = try await stale.receiveClose()
        XCTAssertEqual(staleCloseCode, 4401)

        // ...and the new one does.
        let fresh = try await rawClient(agent)
        guard case .welcome = try await fresh.hello(token: newToken) else { return XCTFail("no welcome") }
    }

    // MARK: Ports

    func testBusyPreferredPortFallsBackToAFreePort() async throws {
        let first = try startAgent()
        let otherDirectory = try TestDirectories.make("second")
        defer { TestDirectories.remove(otherDirectory) }
        let second = try startAgent(preferredPort: first.port, in: otherDirectory)

        XCTAssertNotEqual(second.port, 0)
        XCTAssertNotEqual(second.port, first.port, "the second agent must not share the busy port")
        // Both are reachable, each with its own identity.
        _ = try await authenticatedClient(first)
        _ = try await authenticatedClient(second)
        XCTAssertNotEqual(first.identity.fingerprint, second.identity.fingerprint)
        XCTAssertNotEqual(first.agent.id, second.agent.id)
    }

    func testPreferredPortIsUsedWhenFree() async throws {
        // Find a free port by binding an ephemeral one and releasing it.
        let probe = try startAgent()
        let freePort = probe.port
        probe.server.stop()
        try await Task.sleep(nanoseconds: 300_000_000)

        let otherDirectory = try TestDirectories.make("preferred")
        defer { TestDirectories.remove(otherDirectory) }
        let agent = try startAgent(preferredPort: freePort, in: otherDirectory)
        XCTAssertEqual(agent.port, freePort)
    }
}

private func assertSameJSONText(_ actual: String, _ expected: String, file: StaticString = #filePath, line: UInt = #line) async throws {
    let a = try JSONSerialization.jsonObject(with: Data(actual.utf8)) as! NSObject
    let b = try JSONSerialization.jsonObject(with: Data(expected.utf8)) as! NSObject
    XCTAssertEqual(a, b, file: file, line: line)
}
