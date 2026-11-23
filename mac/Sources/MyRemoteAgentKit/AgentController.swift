import Foundation
import MyRemoteCore

public struct AgentOptions: Equatable {
    /// No menu bar UI, only the server (`--headless`).
    public var headless = false
    /// Print `INJECT <json>` instead of injecting (`--dry-run`).
    public var dryRun = false
    /// Put `host=127.0.0.1` into the pairing URI (`--loopback`).
    public var loopback = false
    /// `--port`; nil means the default 47110, 0 means any free port.
    public var port: UInt16?
    /// `--state-dir`; nil means `~/Library/Application Support/MyRemote`.
    public var stateDirectory: URL?
    /// Extension, not in the contract (`--profile`): pin the profile instead of
    /// following the frontmost app; `frontApp` is then reported as null.
    public var forcedProfile: Profile?
    /// Extension, not in the contract (`--no-bonjour` turns it off).
    public var advertise = true

    public init() {}
}

/// Owns everything the agent consists of and wires it together: state store, TLS
/// identity, server, injector, front-app tracking, the display-sleep assertion.
/// Shared by the headless CLI and the menu bar app.
public final class AgentController {
    public let options: AgentOptions
    public let store: StateStore
    public let identity: TLSIdentity
    public let agent: AgentInfo
    public let server: RemoteServer
    public let injector: InputInjector

    /// Called on the main queue when the set of authenticated clients changes.
    public var onClientsChanged: (([ConnectedClient]) -> Void)?
    /// Called on the main queue when the published state changes.
    public var onStateChanged: ((RemoteState) -> Void)?

    private let power: DisplaySleepPreventing
    private let frontAppProvider: FrontAppProvider
    private var tracker: FrontAppTracker?
    private var accessibilityTimer: DispatchSourceTimer?
    private var snapshot: FrontAppSnapshot?

    public init(
        options: AgentOptions,
        injector: InputInjector? = nil,
        power: DisplaySleepPreventing = PowerAssertion(),
        frontAppProvider: FrontAppProvider = SystemFrontAppProvider(),
        output: LineOutput = .standardOutput
    ) throws {
        self.options = options
        self.power = power
        self.frontAppProvider = frontAppProvider

        let store = try StateStore(directory: options.stateDirectory ?? StateStore.defaultDirectory)
        self.store = store
        self.identity = try TLSIdentityStore.loadOrCreate(in: store)
        let agent = AgentInfo(id: try store.loadOrCreateAgentId(), name: HostInfo.computerName())
        self.agent = agent

        let chosenInjector = injector ?? (options.dryRun ? DryRunInjector(output: output) : RealInjector())
        self.injector = chosenInjector

        let initialState = RemoteState(
            frontApp: nil,
            profile: options.forcedProfile ?? .generic,
            accessibility: chosenInjector.isTrusted)
        self.server = RemoteServer(
            config: ServerConfig(
                preferredPort: options.port ?? ServerConfig.defaultPort,
                advertise: options.advertise,
                serviceName: agent.name),
            store: store,
            identity: identity,
            agent: agent,
            token: try store.loadOrCreateToken(),
            injector: chosenInjector,
            initialState: initialState)

        server.observeClients { [weak self] clients in
            // Keep the TV awake exactly as long as someone is holding the remote.
            self?.power.setActive(!clients.isEmpty)
            DispatchQueue.main.async {
                self?.onClientsChanged?(clients)
            }
        }
    }

    /// Starts the server. Returns the bound port.
    @discardableResult
    public func start() throws -> UInt16 {
        // Look at the frontmost app once, synchronously, before accepting anyone:
        // the very first `welcome` should already carry the right profile.
        if options.forcedProfile == nil, snapshot == nil,
           var initial = frontAppProvider.frontmostApplication() {
            initial.windowTitle = frontAppProvider.focusedWindowTitle(of: initial.processIdentifier)
            snapshot = initial
            server.updateState(composeState())
        }
        return try server.start()
    }

    /// Starts following the frontmost app and the Accessibility permission.
    /// Main thread only; needs a running main run loop to make progress.
    public func startTracking() {
        dispatchPrecondition(condition: .onQueue(.main))
        if options.forcedProfile == nil, tracker == nil {
            let tracker = FrontAppTracker(provider: frontAppProvider) { [weak self] snapshot in
                self?.snapshot = snapshot
                self?.publishState()
            }
            self.tracker = tracker
            tracker.start()
        }
        if accessibilityTimer == nil {
            // The permission can be granted or revoked at any time in System Settings.
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
            timer.setEventHandler { [weak self] in self?.publishState() }
            accessibilityTimer = timer
            timer.resume()
        }
        publishState()
    }

    private func composeState() -> RemoteState {
        RemoteState(
            frontApp: options.forcedProfile == nil ? snapshot?.frontApp : nil,
            profile: options.forcedProfile ?? snapshot?.profile ?? .generic,
            accessibility: injector.isTrusted)
    }

    private func publishState() {
        let state = composeState()
        guard state != server.currentState else { return }
        server.updateState(state)
        onStateChanged?(state)
    }

    public var port: UInt16 { server.port }

    public var isAccessibilityGranted: Bool { injector.isTrusted }

    /// The pairing URI for the current token, port and address.
    public func pairingURI() throws -> String {
        try PairingURI.build(PairingInfo(
            host: HostInfo.pairingHost(loopback: options.loopback),
            port: Int(server.port),
            id: agent.id,
            name: agent.name,
            fp: identity.fingerprint,
            token: server.currentToken))
    }

    /// New token, same certificate and agent id, all connections dropped.
    public func resetPairing() throws {
        try server.resetPairing()
    }

    public func stop() {
        tracker?.stop()
        tracker = nil
        accessibilityTimer?.cancel()
        accessibilityTimer = nil
        server.stop()
        power.setActive(false)
    }
}
