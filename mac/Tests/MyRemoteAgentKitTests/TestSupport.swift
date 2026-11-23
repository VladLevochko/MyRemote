import CryptoKit
import Foundation
import MyRemoteAgentKit
import MyRemoteCore
import Network
import Security
import XCTest

// MARK: - Fixtures and temp directories

enum Fixtures {
    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // MyRemoteAgentKitTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // mac
        .deletingLastPathComponent()  // repository root
        .appendingPathComponent("protocol/fixtures", isDirectory: true)

    static func text(_ relativePath: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum TestDirectories {
    /// A fresh directory for one test. Never the real state directory. Set
    /// `MYREMOTE_TEST_TMPDIR` to choose where these are created.
    static func make(_ label: String = "state") throws -> URL {
        let base = ProcessInfo.processInfo.environment["MYREMOTE_TEST_TMPDIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.temporaryDirectory
        let url = base.appendingPathComponent("myremote-tests-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func remove(_ url: URL) {
        guard url.lastPathComponent.hasPrefix("myremote-tests-") else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Fakes

/// Thread-safe recording injector. Injects nothing.
final class RecordingInjector: InputInjector {
    private let lock = NSLock()
    private var recorded: [InputAction] = []
    private var trusted = true

    var isTrusted: Bool {
        get { lock.withLock { trusted } }
        set { lock.withLock { trusted = newValue } }
    }

    var actions: [InputAction] { lock.withLock { recorded } }

    func perform(_ action: InputAction) -> InjectionResult {
        lock.withLock {
            guard trusted else { return .accessibilityDenied }
            recorded.append(action)
            return .ok
        }
    }
}

final class FakePower: DisplaySleepPreventing {
    private let lock = NSLock()
    private var history: [Bool] = []

    func setActive(_ active: Bool) {
        lock.withLock {
            if history.last != active { history.append(active) }
        }
    }

    var isActive: Bool { lock.withLock { history.last ?? false } }
    var transitions: [Bool] { lock.withLock { history } }
}

// MARK: - A running server on an ephemeral port

struct TestAgent {
    static let youtubeState = RemoteState(
        frontApp: FrontApp(bundleId: "com.google.Chrome", name: "Google Chrome"),
        profile: .youtube, accessibility: true)

    let directory: URL
    let store: StateStore
    let identity: TLSIdentity
    let agent: AgentInfo
    let server: RemoteServer
    let injector: RecordingInjector
    let port: UInt16

    /// Starts the real server with the real TLS identity from `directory`,
    /// on an ephemeral port, without Bonjour, with a recording injector.
    static func start(
        in directory: URL,
        preferredPort: UInt16 = 0,
        session: SessionConfig = SessionConfig(),
        state: RemoteState = TestAgent.youtubeState,
        injector: RecordingInjector = RecordingInjector(),
        advertise: Bool = false
    ) throws -> TestAgent {
        let store = try StateStore(directory: directory)
        let identity = try TLSIdentityStore.loadOrCreate(in: store)
        let agent = AgentInfo(id: try store.loadOrCreateAgentId(), name: "Test Mac")
        let server = RemoteServer(
            config: ServerConfig(
                preferredPort: preferredPort, advertise: advertise, serviceName: "MyRemote Test \(agent.id)",
                session: session, closeGrace: 0.5),
            store: store, identity: identity, agent: agent,
            token: try store.loadOrCreateToken(),
            injector: injector, initialState: state)
        let port = try server.start()
        return TestAgent(
            directory: directory, store: store, identity: identity, agent: agent,
            server: server, injector: injector, port: port)
    }

    var token: String { server.currentToken }

    /// What the pairing URI of this agent says, after a build/parse round trip.
    func pairing() throws -> PairingInfo {
        try PairingURI.parse(try PairingURI.build(PairingInfo(
            host: "127.0.0.1", port: Int(port), id: agent.id, name: agent.name,
            fp: identity.fingerprint, token: token)))
    }
}

// MARK: - A real WebSocket client that pins the certificate fingerprint

struct TestClientError: Error, CustomStringConvertible {
    let description: String
}

struct ReceivedFrame {
    let opcode: NWProtocolWebSocket.Opcode
    let data: Data
    let closeCode: UInt16?

    var text: String { String(decoding: data, as: UTF8.self) }
}

/// Resumes a continuation at most once, from whichever of several callbacks is first.
private final class Once<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<T, Error>) {
        let pending = lock.withLock { () -> CheckedContinuation<T, Error>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(with: result)
    }
}

/// WSS client built on Network.framework, behaving as the contract asks of the
/// phone: it does not validate the chain or the hostname, it pins the SHA-256 of
/// the leaf certificate, and it refuses the connection on a mismatch.
final class TestClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "myremote.tests.client")
    private final class FingerprintBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: String?
        var value: String? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    private let served = FingerprintBox()

    /// SHA-256 of the DER leaf certificate the server actually presented.
    var servedFingerprint: String? { served.value }

    /// - Parameter pinnedFingerprint: the `fp` from the pairing URI.
    init(port: UInt16, pinnedFingerprint: String, path: String = "/ws") {
        let tls = NWProtocolTLS.Options()
        let pinned = pinnedFingerprint
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let served = self.served
        sec_protocol_options_set_verify_block(
            tls.securityProtocolOptions,
            { _, trust, complete in
                let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
                      let leaf = chain.first
                else { return complete(false) }
                let der = SecCertificateCopyData(leaf) as Data
                let fingerprint = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
                served.value = fingerprint
                // The pin is the only trust decision: no chain, no hostname.
                complete(fingerprint == pinned)
            },
            queue)

        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        let parameters = NWParameters(tls: tls)
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        connection = NWConnection(
            to: .url(URL(string: "wss://127.0.0.1:\(port)\(path)")!), using: parameters)
    }

    /// Completes when TLS and the WebSocket upgrade are done; throws if either fails.
    func connect(timeout: TimeInterval = 5) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Once(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.resume(with: .success(()))
                case let .failed(error), let .waiting(error):
                    once.resume(with: .failure(TestClientError(description: "connect failed: \(error)")))
                case .cancelled:
                    once.resume(with: .failure(TestClientError(description: "connect cancelled")))
                default:
                    break
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) {
                once.resume(with: .failure(TestClientError(description: "connect timed out")))
            }
            connection.start(queue: queue)
        }
    }

    func send(_ text: String) async throws {
        try await send(Data(text.utf8), opcode: .text)
    }

    func send(_ message: ClientMessage) async throws {
        try await send(WireJSON.encode(message), opcode: .text)
    }

    func sendBinary(_ data: Data) async throws {
        try await send(data, opcode: .binary)
    }

    private func send(_ data: Data, opcode: NWProtocolWebSocket.Opcode) async throws {
        let metadata = NWProtocolWebSocket.Metadata(opcode: opcode)
        let context = NWConnection.ContentContext(identifier: "send", metadata: [metadata])
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data, contentContext: context, isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: TestClientError(description: "send failed: \(error)"))
                    } else {
                        continuation.resume()
                    }
                })
        }
    }

    /// The next WebSocket message (text, binary or close).
    func receive(timeout: TimeInterval = 5) async throws -> ReceivedFrame {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ReceivedFrame, Error>) in
            let once = Once(continuation)
            queue.asyncAfter(deadline: .now() + timeout) {
                once.resume(with: .failure(TestClientError(description: "receive timed out after \(timeout) s")))
            }
            connection.receiveMessage { content, context, _, error in
                if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                    as? NWProtocolWebSocket.Metadata {
                    var closeCode: UInt16?
                    if metadata.opcode == .close {
                        switch metadata.closeCode {
                        case let .protocolCode(defined): closeCode = defined.rawValue
                        case let .applicationCode(value): closeCode = value
                        case let .privateCode(value): closeCode = value
                        @unknown default: closeCode = nil
                        }
                    }
                    once.resume(with: .success(
                        ReceivedFrame(opcode: metadata.opcode, data: content ?? Data(), closeCode: closeCode)))
                } else if let error {
                    once.resume(with: .failure(TestClientError(description: "receive failed: \(error)")))
                } else {
                    once.resume(with: .failure(TestClientError(description: "connection ended without a close frame")))
                }
            }
        }
    }

    /// The next message, which must be a text frame holding a server message.
    func receiveMessage(timeout: TimeInterval = 5) async throws -> ServerMessage {
        let frame = try await receive(timeout: timeout)
        guard frame.opcode == .text else {
            throw TestClientError(description: "expected a text frame, got \(frame.opcode) code \(String(describing: frame.closeCode))")
        }
        return try JSONDecoder().decode(ServerMessage.self, from: frame.data)
    }

    /// The next message, which must be a close frame; returns its close code.
    func receiveClose(timeout: TimeInterval = 5) async throws -> UInt16 {
        let frame = try await receive(timeout: timeout)
        guard frame.opcode == .close, let code = frame.closeCode else {
            throw TestClientError(description: "expected a close frame, got \(frame.opcode): \(frame.text)")
        }
        return code
    }

    /// Asserts that nothing arrives for `duration`.
    func expectSilence(for duration: TimeInterval) async {
        do {
            let frame = try await receive(timeout: duration)
            XCTFail("expected silence, got \(frame.opcode): \(frame.text)")
        } catch {
            // Timed out: good. Note that the pending receive stays registered, so a
            // client must not be used for further receives after this.
        }
    }

    /// hello with `token`; returns the server's first answer.
    func hello(token: String, v: Int = 1, device: String = "Galaxy S24") async throws -> ServerMessage {
        try await send(.hello(v: v, token: token, device: device))
        return try await receiveMessage()
    }

    func close() {
        connection.cancel()
    }
}

extension TestAgent {
    /// A client pinned to this agent's fingerprint, connected and authenticated.
    func connectedClient(device: String = "Galaxy S24") async throws -> (TestClient, ServerMessage) {
        let client = TestClient(port: port, pinnedFingerprint: identity.fingerprint)
        try await client.connect()
        let welcome = try await client.hello(token: token, device: device)
        return (client, welcome)
    }
}

/// Polls until `condition` holds; for state that changes on another queue.
func waitUntil(
    timeout: TimeInterval = 5, _ what: String = "condition", file: StaticString = #filePath, line: UInt = #line,
    _ condition: () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            XCTFail("timed out waiting for \(what)", file: file, line: line)
            return
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}
