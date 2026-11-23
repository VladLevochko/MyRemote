import Foundation

// MARK: - Detection (PROTOCOL.md section 5)

public enum ProfileDetector {
    /// Bundle identifiers that count as "a browser". Entries match the identifier
    /// itself and anything below it (`com.google.Chrome` also matches
    /// `com.google.Chrome.canary` and installed Chrome web apps
    /// `com.google.Chrome.app.<id>`). Comparison is case-insensitive.
    public static let browserBundleIdPrefixes: [String] = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "com.google.Chrome",
        "org.chromium.Chromium",
        "company.thebrowser.Browser",   // Arc
        "company.thebrowser.dia",       // Dia
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "org.mozilla.nightly",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "com.operasoftware.Opera",
        "com.operasoftware.OperaGX",
        "com.vivaldi.Vivaldi",
        "app.zen-browser.zen",
        "com.kagi.kagimacOS",           // Orion
        "com.duckduckgo.macos.browser",
    ]

    public static let appleTVBundleId = "com.apple.TV"

    public static func isBrowser(bundleId: String) -> Bool {
        let id = bundleId.lowercased()
        return browserBundleIdPrefixes.contains { prefix in
            let p = prefix.lowercased()
            return id == p || id.hasPrefix(p + ".")
        }
    }

    /// - `com.apple.TV` -> appletv
    /// - a browser whose focused window title contains "YouTube" -> youtube,
    ///   contains "Netflix" -> netflix (YouTube is checked first, as in the contract)
    /// - anything else, including a browser whose title is unknown -> generic
    public static func detect(bundleId: String?, windowTitle: String?) -> Profile {
        guard let bundleId, !bundleId.isEmpty else { return .generic }
        if bundleId.caseInsensitiveCompare(appleTVBundleId) == .orderedSame {
            return .appletv
        }
        guard isBrowser(bundleId: bundleId), let title = windowTitle else { return .generic }
        if title.range(of: "YouTube", options: .caseInsensitive) != nil { return .youtube }
        if title.range(of: "Netflix", options: .caseInsensitive) != nil { return .netflix }
        return .generic
    }
}

// MARK: - Action mapping

/// Per-profile translation of a semantic command into a concrete input action.
/// `nil` means the profile has no equivalent -> `ack ok=false error=unsupported`.
///
/// Sources (checked 2026-11-22), see mac/README.md for the full table and caveats:
/// - YouTube:  https://support.google.com/youtube/answer/7631406
/// - Netflix:  https://help.netflix.com/en/node/24855
/// - Apple TV: https://support.apple.com/guide/tvapp-mac/atvc572afcf3/mac and the
///             key equivalents in TV.app 1.7's own main menu (macOS 27.0.1)
/// - generic:  https://support.apple.com/102650 (Control-Command-F)
public enum ProfileMap {
    public static func action(for cmd: CmdAction, profile: Profile) -> InputAction? {
        switch profile {
        case .youtube: return youtube(cmd)
        case .netflix: return netflix(cmd)
        case .appletv: return appleTV(cmd)
        case .generic: return generic(cmd)
        }
    }

    // Over HDMI macOS cannot change the system output volume, so the player
    // profiles drive the player's own volume and never the system volume keys.

    private static func youtube(_ cmd: CmdAction) -> InputAction? {
        switch cmd {
        case .playPause: return .key(.k)                       // documented
        case .seekBackward: return .key(.j)                    // documented, 10 s
        case .seekForward: return .key(.l)                     // documented, 10 s
        case .volumeUp: return .key(.up)                       // documented, 5 %, needs player focus
        case .volumeDown: return .key(.down)                   // documented, 5 %, needs player focus
        case .toggleMute: return .key(.m)                      // documented
        case .toggleFullscreen: return .key(.f)                // documented
        case .nextItem: return .key(.n, modifiers: [.shift])   // documented
        case .previousItem: return .key(.p, modifiers: [.shift]) // documented, playlists only
        case .skip: return nil                                 // no hotkey for skipping ads
        case .toggleSubtitles: return .key(.c)                 // documented
        }
    }

    private static func netflix(_ cmd: CmdAction) -> InputAction? {
        switch cmd {
        case .playPause: return .key(.space)                   // documented
        case .seekBackward: return .key(.left)                 // documented, 10 s
        case .seekForward: return .key(.right)                 // documented, 10 s
        case .volumeUp: return .key(.up)                       // documented
        case .volumeDown: return .key(.down)                   // documented
        case .toggleMute: return .key(.m)                      // documented
        case .toggleFullscreen: return .key(.f)                // documented
        case .nextItem: return nil                             // no documented shortcut
        case .previousItem: return nil                         // no documented shortcut
        case .skip: return .key(.s)                            // documented: "Skip intro"
        case .toggleSubtitles: return nil                      // no documented shortcut
        }
    }

    private static func appleTV(_ cmd: CmdAction) -> InputAction? {
        switch cmd {
        case .playPause: return .key(.space)                               // documented
        case .seekBackward: return .key(.left)                             // UNCONFIRMED
        case .seekForward: return .key(.right)                             // UNCONFIRMED
        case .volumeUp: return .key(.up, modifiers: [.command])            // documented
        case .volumeDown: return .key(.down, modifiers: [.command])        // documented
        case .toggleMute: return nil                                       // no documented shortcut
        case .toggleFullscreen: return .key(.f, modifiers: [.control, .command]) // documented
        case .nextItem: return .key(.right, modifiers: [.command])         // app menu only: Controls > Next
        case .previousItem: return .key(.left, modifiers: [.command])      // app menu only: Controls > Previous
        case .skip: return nil                                             // no shortcut ("Skip Intro" is a button)
        case .toggleSubtitles: return nil                                  // no documented shortcut
        }
    }

    private static func generic(_ cmd: CmdAction) -> InputAction? {
        switch cmd {
        case .playPause: return .mediaKey(.playPause)
        case .seekBackward: return .key(.left)                 // convention, not universal
        case .seekForward: return .key(.right)                 // convention, not universal
        case .volumeUp: return .mediaKey(.volumeUp)
        case .volumeDown: return .mediaKey(.volumeDown)
        case .toggleMute: return .mediaKey(.mute)
        case .toggleFullscreen: return .key(.f, modifiers: [.control, .command]) // macOS standard
        case .nextItem: return .mediaKey(.next)
        case .previousItem: return .mediaKey(.previous)
        case .skip: return nil
        case .toggleSubtitles: return nil
        }
    }
}
