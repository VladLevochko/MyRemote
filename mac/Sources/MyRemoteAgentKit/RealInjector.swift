import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import MyRemoteCore

/// Builds the synthetic events for an `InputAction` without posting them, so tests
/// can inspect exactly what would be sent while never touching the live session.
public enum EventFactory {
    public static func flags(for modifiers: [KeyModifier]) -> CGEventFlags {
        var flags: CGEventFlags = []
        for modifier in modifiers {
            switch modifier {
            case .control: flags.insert(.maskControl)
            case .option: flags.insert(.maskAlternate)
            case .shift: flags.insert(.maskShift)
            case .command: flags.insert(.maskCommand)
            }
        }
        return flags
    }

    /// Key down followed by key up, with exactly the requested modifiers.
    public static func keyStroke(
        _ key: VirtualKey, modifiers: [KeyModifier], source: CGEventSource?
    ) -> [CGEvent] {
        var flags = flags(for: modifiers)
        if key.isArrow {
            // Hardware arrow keys always carry these two flags; mirror them so the
            // event is indistinguishable from a real key press.
            flags.insert(.maskNumericPad)
            flags.insert(.maskSecondaryFn)
        }
        return [true, false].compactMap { keyDown in
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key.code), keyDown: keyDown)
            // Set explicitly even when empty: otherwise modifiers the user happens to
            // be holding would leak into the shortcut.
            event?.flags = flags
            return event
        }
    }

    /// Key down / key up pairs carrying `text` as their Unicode payload.
    public static func unicodeKeyStroke(_ text: String, source: CGEventSource?) -> [CGEvent] {
        let units = Array(text.utf16)
        return [true, false].compactMap { keyDown in
            let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown)
            event?.flags = []
            event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            return event
        }
    }

    /// The system-defined (subtype 8) event pair for a media key.
    public static func mediaKeyStroke(_ key: MediaKey) -> [CGEvent] {
        [true, false].compactMap { keyDown in
            NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: MediaKey.eventFlags(keyDown: keyDown)),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: key.eventData1(keyDown: keyDown),
                data2: -1
            )?.cgEvent
        }
    }

    public static func mouseMove(to point: CGPoint, dx: Double, dy: Double, source: CGEventSource?) -> CGEvent? {
        let event = CGEvent(
            mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
        event?.flags = []
        event?.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx.rounded()))
        event?.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy.rounded()))
        return event
    }

    /// Down/up pairs for a single or double click at `point`.
    public static func click(
        button: MouseButton, count: Int, at point: CGPoint, source: CGEventSource?
    ) -> [CGEvent] {
        let cgButton: CGMouseButton = button == .left ? .left : .right
        let down: CGEventType = button == .left ? .leftMouseDown : .rightMouseDown
        let up: CGEventType = button == .left ? .leftMouseUp : .rightMouseUp
        var events: [CGEvent] = []
        for clickNumber in 1...max(1, min(2, count)) {
            for type in [down, up] {
                guard let event = CGEvent(
                    mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: cgButton)
                else { continue }
                event.flags = []
                event.setIntegerValueField(.mouseEventClickState, value: Int64(clickNumber))
                events.append(event)
            }
        }
        return events
    }

    /// Pixel scroll. The contract's positive `dy` is "like wheel down" and positive
    /// `dx` is "like wheel right"; CoreGraphics uses the opposite sign for both axes.
    public static func scroll(pixelsX: Int32, pixelsY: Int32, source: CGEventSource?) -> CGEvent? {
        guard pixelsX != 0 || pixelsY != 0 else { return nil }
        let event = CGEvent(
            scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
            wheel1: -pixelsY, wheel2: -pixelsX, wheel3: 0)
        event?.flags = []
        return event
    }
}

/// Posts real events into the user's session. Never used by tests.
public final class RealInjector: InputInjector {
    private let source = CGEventSource(stateID: .hidSystemState)
    private let tap: CGEventTapLocation = .cghidEventTap
    private var scrollAccumulator = ScrollAccumulator()

    private var trustCheckedAt: TimeInterval = -.infinity
    private var trusted = false
    private let trustLock = NSLock()

    public init() {}

    /// `AXIsProcessTrusted()`, cached for half a second so that a stream of pointer
    /// events does not hammer the TCC database. This call never shows a prompt.
    public var isTrusted: Bool {
        trustLock.lock()
        defer { trustLock.unlock() }
        let now = RemoteServer.monotonicNow()
        if now - trustCheckedAt > 0.5 {
            trusted = AXIsProcessTrusted()
            trustCheckedAt = now
        }
        return trusted
    }

    public func perform(_ action: InputAction) -> InjectionResult {
        // Posting without the permission silently does nothing (and may make the
        // system show its own prompt), so refuse up front and report it.
        guard isTrusted else { return .accessibilityDenied }

        switch action {
        case let .key(key, modifiers):
            post(EventFactory.keyStroke(key, modifiers: modifiers, source: source))

        case let .mediaKey(key):
            post(EventFactory.mediaKeyStroke(key))

        case let .pointer(dx, dy):
            guard let current = CGEvent(source: nil)?.location else { break }
            let target = PointerMath.move(
                from: (Double(current.x), Double(current.y)), dx: dx, dy: dy, displays: Self.displayBounds())
            if let event = EventFactory.mouseMove(
                to: CGPoint(x: target.x, y: target.y), dx: dx, dy: dy, source: source) {
                post([event])
            }

        case let .click(button, count):
            guard let location = CGEvent(source: nil)?.location else { break }
            post(EventFactory.click(button: button, count: count, at: location, source: source))

        case let .scroll(dx, dy):
            let pixels = scrollAccumulator.add(dx: dx, dy: dy)
            if let event = EventFactory.scroll(pixelsX: pixels.x, pixelsY: pixels.y, source: source) {
                post([event])
            }

        case let .text(text):
            let steps = TextTyping.steps(for: text)
            for (index, step) in steps.enumerated() {
                switch step {
                case let .unicode(chunk):
                    post(EventFactory.unicodeKeyStroke(chunk, source: source))
                case let .key(key):
                    post(EventFactory.keyStroke(key, modifiers: [], source: source))
                }
                // Give the target app a moment between chunks; back-to-back Unicode
                // events are occasionally reordered or dropped by slow text fields.
                if index < steps.count - 1 {
                    usleep(2_000)
                }
            }
        }
        return .ok
    }

    private func post(_ events: [CGEvent]) {
        for event in events {
            event.post(tap: tap)
        }
    }

    /// Bounds of all active displays in global (top-left origin) coordinates.
    static func displayBounds() -> [ScreenRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return [] }
        return displays.prefix(Int(count)).map { display in
            let bounds = CGDisplayBounds(display)
            return ScreenRect(
                x: Double(bounds.origin.x), y: Double(bounds.origin.y),
                width: Double(bounds.size.width), height: Double(bounds.size.height))
        }
    }
}
