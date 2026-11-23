import AppKit
import ApplicationServices
import Foundation
import MyRemoteCore

/// The menu bar ("status item") UI. Main thread only.
final class MenuBarAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let accessibilitySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    private let options: AgentOptions
    private var controller: AgentController?
    private var statusItem: NSStatusItem?
    private var clients: [ConnectedClient] = []
    private var pairingWindow: PairingWindowController?

    init(options: AgentOptions) {
        self.options = options
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let controller = try AgentController(options: options)
            try controller.start()
            controller.onClientsChanged = { [weak self] clients in
                self?.clients = clients
                self?.refreshStatusIcon()
            }
            controller.onStateChanged = { [weak self] _ in
                self?.refreshStatusIcon()
            }
            controller.startTracking()
            self.controller = controller
            // Unlike the headless CLI, the app does not print the pairing URI: it
            // contains the token, and an app's stdout tends to end up in logs.
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "MyRemote could not start"
            alert.informativeText = "\(error)"
            alert.addButton(withTitle: "Quit")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        statusItem = item
        refreshStatusIcon()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: Status item

    private func refreshStatusIcon() {
        guard let button = statusItem?.button else { return }
        let granted = controller?.isAccessibilityGranted ?? false
        let symbol = !granted ? "exclamationmark.triangle" : (clients.isEmpty ? "av.remote" : "av.remote.fill")
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "MyRemote") {
            image.isTemplate = true
            button.image = image
            button.title = ""
        } else {
            button.image = nil
            button.title = "MR"
        }
        button.toolTip = statusLine()
    }

    private func statusLine() -> String {
        guard let controller else { return "MyRemote is not running" }
        return "MyRemote: listening on port \(controller.port)"
    }

    private func clientsLine() -> String {
        switch clients.count {
        case 0: return "No devices connected"
        case 1: return "1 device connected"
        default: return "\(clients.count) devices connected"
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(info(statusLine()))
        menu.addItem(info(clientsLine()))
        for client in clients {
            let name = client.device.isEmpty ? "Unnamed device" : client.device
            menu.addItem(info("    \(name) (\(client.remoteAddress))"))
        }
        if options.dryRun {
            menu.addItem(info("Dry run: events are not injected"))
        }
        menu.addItem(.separator())

        menu.addItem(action("Pair New Device…", #selector(showPairingWindow)))
        menu.addItem(.separator())

        if controller?.isAccessibilityGranted ?? false {
            menu.addItem(info("Accessibility: granted"))
        } else {
            menu.addItem(info("Accessibility: not granted (the remote cannot control this Mac)"))
            menu.addItem(action("Open Accessibility Settings…", #selector(openAccessibilitySettings)))
        }
        menu.addItem(.separator())

        menu.addItem(action("Reset Pairing…", #selector(resetPairing)))
        menu.addItem(.separator())
        menu.addItem(action("Quit MyRemote", #selector(quit), key: "q"))
    }

    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        item.isEnabled = controller != nil || selector == #selector(quit)
        return item
    }

    // MARK: Actions

    @objc private func showPairingWindow() {
        guard let controller else { return }
        let window = pairingWindow ?? PairingWindowController()
        pairingWindow = window
        window.show(uri: Result { try controller.pairingURI() }, agentName: controller.agent.name)
    }

    @objc private func openAccessibilitySettings() {
        // Asking with the prompt option is what puts this app into the Accessibility
        // list so that the user only has to flip its switch. It is called here, on an
        // explicit click, and nowhere else.
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        NSWorkspace.shared.open(Self.accessibilitySettingsURL)
    }

    @objc private func resetPairing() {
        guard let controller else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Reset pairing?"
        alert.informativeText =
            "Every paired phone is disconnected and has to scan a new code. "
            + "The certificate and the agent identity stay the same."
        alert.addButton(withTitle: "Reset Pairing")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try controller.resetPairing()
        } catch {
            let failure = NSAlert()
            failure.alertStyle = .critical
            failure.messageText = "Pairing could not be reset"
            failure.informativeText = "\(error)"
            failure.runModal()
            return
        }
        // If the old code is still on screen, replace it: it no longer works.
        if let pairingWindow, pairingWindow.isVisible {
            pairingWindow.show(uri: Result { try controller.pairingURI() }, agentName: controller.agent.name)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

/// "Pair new device": the pairing URI as a QR code and as selectable text.
final class PairingWindowController: NSObject {
    private let window: NSWindow
    private let imageView = NSImageView()
    private let heading = NSTextField(labelWithString: "")
    private let uriField = NSTextField(wrappingLabelWithString: "")
    private let hint = NSTextField(wrappingLabelWithString: "")
    private var currentURI = ""

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 600),
            styleMask: [.titled, .closable], backing: .buffered, defer: true)
        super.init()
        window.title = "Pair New Device"
        window.isReleasedWhenClosed = false

        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        heading.alignment = .center

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.white.cgColor
        imageView.layer?.cornerRadius = 8

        uriField.isSelectable = true
        uriField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        uriField.lineBreakMode = .byCharWrapping
        uriField.maximumNumberOfLines = 0
        uriField.preferredMaxLayoutWidth = 380

        hint.stringValue =
            "Scan this code with the MyRemote app on your phone. "
            + "The code contains a secret: anyone who can read it can control this Mac."
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        hint.alignment = .center
        hint.preferredMaxLayoutWidth = 380

        let copyButton = NSButton(title: "Copy Pairing Link", target: self, action: #selector(copyURI))

        let stack = NSStackView(views: [heading, imageView, hint, uriField, copyButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 420),
            imageView.widthAnchor.constraint(equalToConstant: 300),
            imageView.heightAnchor.constraint(equalToConstant: 300),
        ])
        window.contentView = content
    }

    var isVisible: Bool { window.isVisible }

    func show(uri: Result<String, Error>, agentName: String) {
        heading.stringValue = agentName
        switch uri {
        case let .success(text):
            currentURI = text
            uriField.stringValue = text
            if let cgImage = QRCode.image(for: text, pixelsPerModule: 10) {
                imageView.image = NSImage(cgImage: cgImage, size: NSSize(width: 300, height: 300))
            } else {
                imageView.image = nil
            }
        case let .failure(error):
            currentURI = ""
            uriField.stringValue = "The pairing link could not be created: \(error)"
            imageView.image = nil
        }
        window.layoutIfNeeded()
        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func copyURI() {
        guard !currentURI.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(currentURI, forType: .string)
    }
}
