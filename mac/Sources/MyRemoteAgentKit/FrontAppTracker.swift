import AppKit
import ApplicationServices
import Foundation
import MyRemoteCore

/// What is known about the frontmost application at one moment.
public struct FrontAppSnapshot: Equatable, Sendable {
    public var bundleId: String?
    public var name: String?
    public var processIdentifier: pid_t
    /// Title of the focused window; nil when unknown (no Accessibility permission,
    /// no window, or the app did not answer in time).
    public var windowTitle: String?

    public init(bundleId: String?, name: String?, processIdentifier: pid_t, windowTitle: String?) {
        self.bundleId = bundleId
        self.name = name
        self.processIdentifier = processIdentifier
        self.windowTitle = windowTitle
    }

    /// `frontApp` of the contract; nil when the bundle id is unknown.
    public var frontApp: FrontApp? {
        guard let bundleId, !bundleId.isEmpty else { return nil }
        return FrontApp(bundleId: bundleId, name: name ?? bundleId)
    }

    public var profile: Profile {
        ProfileDetector.detect(bundleId: bundleId, windowTitle: windowTitle)
    }
}

public protocol FrontAppProvider: AnyObject {
    /// Frontmost app without the window title. Called on the main thread.
    func frontmostApplication() -> FrontAppSnapshot?
    /// Title of the focused window of `pid`. Called on a background queue; may block
    /// briefly on the target application.
    func focusedWindowTitle(of pid: pid_t) -> String?
}

/// NSWorkspace for the app, the Accessibility API for the window title.
public final class SystemFrontAppProvider: FrontAppProvider {
    public init() {}

    public func frontmostApplication() -> FrontAppSnapshot? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return FrontAppSnapshot(
            bundleId: app.bundleIdentifier, name: app.localizedName,
            processIdentifier: app.processIdentifier, windowTitle: nil)
    }

    public func focusedWindowTitle(of pid: pid_t) -> String? {
        // Without the permission the AX calls just fail; skip them altogether.
        guard AXIsProcessTrusted() else { return nil }
        let application = AXUIElementCreateApplication(pid)
        // Never let a hung front app stall the tracker.
        AXUIElementSetMessagingTimeout(application, 0.25)

        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success
        else { return nil }
        return title as? String
    }
}

/// Polls the frontmost application and its focused window title and reports
/// changes. Polling (rather than only NSWorkspace notifications) is what catches
/// tab switches inside a browser, where the app stays the same and only the
/// window title changes.
public final class FrontAppTracker {
    private let provider: FrontAppProvider
    private let interval: TimeInterval
    private let onChange: (FrontAppSnapshot?) -> Void
    private let titleQueue = DispatchQueue(label: "dev.myremote.agent.frontapp")

    // Main thread only.
    private var timer: DispatchSourceTimer?
    private var last: FrontAppSnapshot??
    private var pollInFlight = false

    /// - Parameter onChange: called on the main queue, first with the initial
    ///   snapshot and then whenever it changes.
    public init(
        provider: FrontAppProvider = SystemFrontAppProvider(),
        interval: TimeInterval = 1.0,
        onChange: @escaping (FrontAppSnapshot?) -> Void
    ) {
        self.provider = provider
        self.interval = interval
        self.onChange = onChange
    }

    /// Must be called on the main thread.
    public func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.poll() }
        self.timer = timer
        timer.resume()
    }

    public func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        timer?.cancel()
        timer = nil
    }

    private func poll() {
        guard !pollInFlight else { return }
        guard var snapshot = provider.frontmostApplication() else {
            report(nil)
            return
        }
        pollInFlight = true
        let provider = self.provider
        titleQueue.async { [weak self] in
            snapshot.windowTitle = provider.focusedWindowTitle(of: snapshot.processIdentifier)
            DispatchQueue.main.async {
                guard let self else { return }
                self.pollInFlight = false
                self.report(snapshot)
            }
        }
    }

    private func report(_ snapshot: FrontAppSnapshot?) {
        if let last, last == snapshot { return }
        last = .some(snapshot)
        onChange(snapshot)
    }
}
