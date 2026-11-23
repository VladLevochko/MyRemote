import Foundation

/// Semantic player commands, section 4.2 (`cmd.action`).
public enum CmdAction: String, Sendable, CaseIterable {
    case playPause, seekBackward, seekForward, volumeUp, volumeDown, toggleMute
    case toggleFullscreen, nextItem, previousItem, skip, toggleSubtitles
}

/// Named keys, section 4.2 (`key.key`).
public enum RemoteKey: String, Sendable, CaseIterable {
    case up, down, left, right, enter, escape, space, tab, backspace

    public var virtualKey: VirtualKey {
        switch self {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .enter: return .enter
        case .escape: return .escape
        case .space: return .space
        case .tab: return .tab
        case .backspace: return .backspace
        }
    }
}

/// Keyboard modifiers in canonical order (control, option, shift, command).
public enum KeyModifier: String, Codable, Sendable, CaseIterable, Comparable {
    case control, option, shift, command

    private var order: Int { KeyModifier.allCases.firstIndex(of: self)! }
    public static func < (lhs: KeyModifier, rhs: KeyModifier) -> Bool { lhs.order < rhs.order }
}

/// A physical key identified by its macOS virtual keycode (`kVK_*`, ANSI positions).
public struct VirtualKey: Equatable, Hashable, Sendable {
    /// Stable human-readable name; appears in `INJECT` lines.
    public let name: String
    public let code: UInt16

    public init(name: String, code: UInt16) {
        self.name = name
        self.code = code
    }

    public static let c = VirtualKey(name: "c", code: 8)
    public static let f = VirtualKey(name: "f", code: 3)
    public static let j = VirtualKey(name: "j", code: 38)
    public static let k = VirtualKey(name: "k", code: 40)
    public static let l = VirtualKey(name: "l", code: 37)
    public static let m = VirtualKey(name: "m", code: 46)
    public static let n = VirtualKey(name: "n", code: 45)
    public static let p = VirtualKey(name: "p", code: 35)
    public static let s = VirtualKey(name: "s", code: 1)

    public static let enter = VirtualKey(name: "enter", code: 36)          // kVK_Return
    public static let tab = VirtualKey(name: "tab", code: 48)              // kVK_Tab
    public static let space = VirtualKey(name: "space", code: 49)          // kVK_Space
    public static let backspace = VirtualKey(name: "backspace", code: 51)  // kVK_Delete
    public static let escape = VirtualKey(name: "escape", code: 53)        // kVK_Escape
    public static let left = VirtualKey(name: "left", code: 123)           // kVK_LeftArrow
    public static let right = VirtualKey(name: "right", code: 124)         // kVK_RightArrow
    public static let down = VirtualKey(name: "down", code: 125)           // kVK_DownArrow
    public static let up = VirtualKey(name: "up", code: 126)               // kVK_UpArrow

    /// Hardware arrow keys always carry the numeric-pad and secondary-fn flags.
    public var isArrow: Bool { (123...126).contains(code) }
}

/// System media keys posted as `NSEvent.systemDefined` subtype 8.
public enum MediaKey: String, Codable, Sendable, CaseIterable {
    case playPause, next, previous, volumeUp, volumeDown, mute

    /// `NX_KEYTYPE_*` from IOKit/hidsystem/ev_keymap.h.
    public var nxKeyType: Int32 {
        switch self {
        case .volumeUp: return 0     // NX_KEYTYPE_SOUND_UP
        case .volumeDown: return 1   // NX_KEYTYPE_SOUND_DOWN
        case .mute: return 7         // NX_KEYTYPE_MUTE
        case .playPause: return 16   // NX_KEYTYPE_PLAY
        case .next: return 17        // NX_KEYTYPE_NEXT
        case .previous: return 18    // NX_KEYTYPE_PREVIOUS
        }
    }

    /// `data1` of the systemDefined event for key down / key up.
    public func eventData1(keyDown: Bool) -> Int {
        (Int(nxKeyType) << 16) | ((keyDown ? 0xA : 0xB) << 8)
    }

    /// Modifier-flags word that accompanies the systemDefined event.
    public static func eventFlags(keyDown: Bool) -> UInt {
        keyDown ? 0xA00 : 0xB00
    }
}

/// A concrete thing the agent does to the system. This is what an `InputInjector`
/// executes and what `--dry-run` prints as `INJECT <json>`.
public enum InputAction: Equatable, Sendable {
    case key(VirtualKey, modifiers: [KeyModifier])
    case mediaKey(MediaKey)
    case pointer(dx: Double, dy: Double)
    case click(button: MouseButton, count: Int)
    case scroll(dx: Double, dy: Double)
    case text(String)

    public static func key(_ key: VirtualKey) -> InputAction { .key(key, modifiers: []) }
}

extension InputAction: Encodable {
    private enum CodingKeys: String, CodingKey {
        case kind, key, keyCode, modifiers, dx, dy, button, count, text
    }

    /// JSON shape of `INJECT` lines (documented in mac/README.md):
    ///   {"kind":"key","key":"k","keyCode":40,"modifiers":[]}
    ///   {"kind":"mediaKey","key":"playPause"}
    ///   {"kind":"pointer","dx":12.5,"dy":-3.25}
    ///   {"kind":"click","button":"left","count":1}
    ///   {"kind":"scroll","dx":0,"dy":-40.5}
    ///   {"kind":"text","text":"..."}
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .key(key, modifiers):
            try c.encode("key", forKey: .kind)
            try c.encode(key.name, forKey: .key)
            try c.encode(key.code, forKey: .keyCode)
            try c.encode(modifiers.sorted(), forKey: .modifiers)
        case let .mediaKey(key):
            try c.encode("mediaKey", forKey: .kind)
            try c.encode(key, forKey: .key)
        case let .pointer(dx, dy):
            try c.encode("pointer", forKey: .kind)
            try c.encode(dx, forKey: .dx)
            try c.encode(dy, forKey: .dy)
        case let .click(button, count):
            try c.encode("click", forKey: .kind)
            try c.encode(button, forKey: .button)
            try c.encode(count, forKey: .count)
        case let .scroll(dx, dy):
            try c.encode("scroll", forKey: .kind)
            try c.encode(dx, forKey: .dx)
            try c.encode(dy, forKey: .dy)
        case let .text(text):
            try c.encode("text", forKey: .kind)
            try c.encode(text, forKey: .text)
        }
    }
}

public enum InjectionResult: Equatable, Sendable {
    case ok
    /// The agent lacks the Accessibility permission; nothing was posted.
    case accessibilityDenied
}

/// Everything that touches the real input system goes through this protocol so the
/// protocol logic can be tested with a fake.
public protocol InputInjector: AnyObject {
    /// Whether events can currently be injected (Accessibility permission).
    var isTrusted: Bool { get }
    func perform(_ action: InputAction) -> InjectionResult
}
