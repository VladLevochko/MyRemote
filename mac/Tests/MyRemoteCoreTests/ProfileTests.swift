import Foundation
import MyRemoteCore
import XCTest

final class ProfileDetectionTests: XCTestCase {
    func testAppleTVApp() {
        XCTAssertEqual(ProfileDetector.detect(bundleId: "com.apple.TV", windowTitle: nil), .appletv)
        XCTAssertEqual(ProfileDetector.detect(bundleId: "com.apple.TV", windowTitle: "Severance"), .appletv)
        // Even if a show is literally called "YouTube", the TV app stays appletv.
        XCTAssertEqual(ProfileDetector.detect(bundleId: "com.apple.TV", windowTitle: "YouTube"), .appletv)
    }

    func testYouTubeInEveryListedBrowser() {
        let browsers = [
            "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome",
            "com.google.Chrome.canary", "com.google.Chrome.beta", "company.thebrowser.Browser",
            "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly",
            "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.brave.Browser",
            "com.brave.Browser.nightly", "com.operasoftware.Opera", "com.operasoftware.OperaGX",
            "com.vivaldi.Vivaldi", "org.chromium.Chromium", "app.zen-browser.zen",
            "com.kagi.kagimacOS", "com.duckduckgo.macos.browser", "company.thebrowser.dia",
        ]
        for browser in browsers {
            XCTAssertEqual(
                ProfileDetector.detect(bundleId: browser, windowTitle: "Rick Astley - Never Gonna Give You Up - YouTube"),
                .youtube, browser)
            XCTAssertEqual(
                ProfileDetector.detect(bundleId: browser, windowTitle: "Stranger Things | Netflix"), .netflix, browser)
            XCTAssertEqual(
                ProfileDetector.detect(bundleId: browser, windowTitle: "Hacker News"), .generic, browser)
        }
    }

    func testBrowserTitleVariants() {
        let chrome = "com.google.Chrome"
        XCTAssertEqual(ProfileDetector.detect(bundleId: chrome, windowTitle: "YouTube"), .youtube)
        XCTAssertEqual(ProfileDetector.detect(bundleId: chrome, windowTitle: "(3) Video - YouTube - Google Chrome"), .youtube)
        XCTAssertEqual(ProfileDetector.detect(bundleId: chrome, windowTitle: "Video - YouTube - Audio playing - Google Chrome – Vlad"), .youtube)
        XCTAssertEqual(ProfileDetector.detect(bundleId: chrome, windowTitle: "Netflix"), .netflix)
        XCTAssertEqual(ProfileDetector.detect(bundleId: chrome, windowTitle: "Netflix - Google Chrome"), .netflix)
        // YouTube is checked first, as in the contract.
        XCTAssertEqual(ProfileDetector.detect(bundleId: chrome, windowTitle: "Netflix trailer - YouTube"), .youtube)
        XCTAssertEqual(ProfileDetector.detect(bundleId: chrome, windowTitle: ""), .generic)
    }

    func testBrowserWithUnknownTitleIsGeneric() {
        XCTAssertEqual(ProfileDetector.detect(bundleId: "com.google.Chrome", windowTitle: nil), .generic)
    }

    func testNonBrowsersAreGenericWhateverTheTitle() {
        for app in ["com.apple.finder", "org.videolan.vlc", "com.colliderli.iina", "com.apple.Terminal",
                    "com.apple.Music", "com.googlecode.iterm2", "com.apple.SafariBookmarksAgent.fake"] {
            XCTAssertEqual(ProfileDetector.detect(bundleId: app, windowTitle: "YouTube downloader"), .generic, app)
            XCTAssertEqual(ProfileDetector.detect(bundleId: app, windowTitle: "Netflix"), .generic, app)
        }
    }

    func testUnknownFrontApp() {
        XCTAssertEqual(ProfileDetector.detect(bundleId: nil, windowTitle: nil), .generic)
        XCTAssertEqual(ProfileDetector.detect(bundleId: nil, windowTitle: "YouTube"), .generic)
        XCTAssertEqual(ProfileDetector.detect(bundleId: "", windowTitle: "YouTube"), .generic)
    }

    func testBundleIdMatchingIsCaseInsensitiveAndPrefixAware() {
        XCTAssertTrue(ProfileDetector.isBrowser(bundleId: "COM.GOOGLE.CHROME"))
        XCTAssertEqual(ProfileDetector.detect(bundleId: "com.apple.tv", windowTitle: nil), .appletv)
        // Installed web apps live below the browser's identifier.
        XCTAssertTrue(ProfileDetector.isBrowser(bundleId: "com.google.Chrome.app.agimnkijcaahngcdmfeangaknmldooml"))
        XCTAssertTrue(ProfileDetector.isBrowser(bundleId: "com.apple.Safari.WebApp.1234"))
        // A prefix is a dotted prefix, not a string prefix.
        XCTAssertFalse(ProfileDetector.isBrowser(bundleId: "com.google.ChromeRemoteDesktop"))
        XCTAssertFalse(ProfileDetector.isBrowser(bundleId: "com.apple.SafariViewService.x"))
        XCTAssertFalse(ProfileDetector.isBrowser(bundleId: "com.apple.TV"))
    }
}

final class ProfileMapTests: XCTestCase {
    /// The complete table, spelled out. `nil` = unsupported. If a mapping changes,
    /// this test and the table in mac/README.md must change with it.
    private let expected: [Profile: [CmdAction: InputAction?]] = [
        .youtube: [
            .playPause: .key(.k),
            .seekBackward: .key(.j),
            .seekForward: .key(.l),
            .volumeUp: .key(.up),
            .volumeDown: .key(.down),
            .toggleMute: .key(.m),
            .toggleFullscreen: .key(.f),
            .nextItem: .key(.n, modifiers: [.shift]),
            .previousItem: .key(.p, modifiers: [.shift]),
            .skip: nil,
            .toggleSubtitles: .key(.c),
        ],
        .netflix: [
            .playPause: .key(.space),
            .seekBackward: .key(.left),
            .seekForward: .key(.right),
            .volumeUp: .key(.up),
            .volumeDown: .key(.down),
            .toggleMute: .key(.m),
            .toggleFullscreen: .key(.f),
            .nextItem: nil,
            .previousItem: nil,
            .skip: .key(.s),
            .toggleSubtitles: nil,
        ],
        .appletv: [
            .playPause: .key(.space),
            .seekBackward: .key(.left),
            .seekForward: .key(.right),
            .volumeUp: .key(.up, modifiers: [.command]),
            .volumeDown: .key(.down, modifiers: [.command]),
            .toggleMute: nil,
            .toggleFullscreen: .key(.f, modifiers: [.control, .command]),
            .nextItem: .key(.right, modifiers: [.command]),
            .previousItem: .key(.left, modifiers: [.command]),
            .skip: nil,
            .toggleSubtitles: nil,
        ],
        .generic: [
            .playPause: .mediaKey(.playPause),
            .seekBackward: .key(.left),
            .seekForward: .key(.right),
            .volumeUp: .mediaKey(.volumeUp),
            .volumeDown: .mediaKey(.volumeDown),
            .toggleMute: .mediaKey(.mute),
            .toggleFullscreen: .key(.f, modifiers: [.control, .command]),
            .nextItem: .mediaKey(.next),
            .previousItem: .mediaKey(.previous),
            .skip: nil,
            .toggleSubtitles: nil,
        ],
    ]

    func testEveryProfileMapsEveryAction() {
        for profile in Profile.allCases {
            guard let table = expected[profile] else { return XCTFail("no expectations for \(profile)") }
            XCTAssertEqual(Set(table.keys), Set(CmdAction.allCases), "\(profile) table is incomplete")
            for action in CmdAction.allCases {
                XCTAssertEqual(
                    ProfileMap.action(for: action, profile: profile), table[action]!,
                    "\(profile).\(action.rawValue)")
            }
        }
    }

    /// Over HDMI the system volume cannot be changed, so only `generic` may use the
    /// system volume/mute keys.
    func testOnlyGenericUsesSystemVolumeKeys() {
        let systemVolume: Set<MediaKey> = [.volumeUp, .volumeDown, .mute]
        for profile in Profile.allCases where profile != .generic {
            for action in CmdAction.allCases {
                if case let .mediaKey(key)? = ProfileMap.action(for: action, profile: profile) {
                    XCTAssertFalse(systemVolume.contains(key), "\(profile).\(action.rawValue) uses a system volume key")
                }
            }
        }
        XCTAssertEqual(ProfileMap.action(for: .volumeUp, profile: .generic), .mediaKey(.volumeUp))
        XCTAssertEqual(ProfileMap.action(for: .volumeDown, profile: .generic), .mediaKey(.volumeDown))
    }

    func testGenericUsesSystemMediaKeysForTransport() {
        XCTAssertEqual(ProfileMap.action(for: .playPause, profile: .generic), .mediaKey(.playPause))
        XCTAssertEqual(ProfileMap.action(for: .nextItem, profile: .generic), .mediaKey(.next))
        XCTAssertEqual(ProfileMap.action(for: .previousItem, profile: .generic), .mediaKey(.previous))
    }

    func testSkippingAYouTubeAdIsUnsupported() {
        XCTAssertNil(ProfileMap.action(for: .skip, profile: .youtube))
    }

    func testVirtualKeyCodes() {
        // kVK_* constants from Carbon's Events.h (HIToolbox).
        let codes: [(VirtualKey, UInt16)] = [
            (.s, 0x01), (.f, 0x03), (.c, 0x08), (.p, 0x23), (.l, 0x25), (.j, 0x26), (.k, 0x28),
            (.n, 0x2D), (.m, 0x2E), (.enter, 0x24), (.tab, 0x30), (.space, 0x31), (.backspace, 0x33),
            (.escape, 0x35), (.left, 0x7B), (.right, 0x7C), (.down, 0x7D), (.up, 0x7E),
        ]
        for (key, code) in codes {
            XCTAssertEqual(key.code, code, key.name)
        }
        XCTAssertTrue(VirtualKey.left.isArrow)
        XCTAssertTrue(VirtualKey.up.isArrow)
        XCTAssertFalse(VirtualKey.space.isArrow)
    }

    func testRemoteKeysMapToVirtualKeys() {
        let expected: [RemoteKey: VirtualKey] = [
            .up: .up, .down: .down, .left: .left, .right: .right, .enter: .enter,
            .escape: .escape, .space: .space, .tab: .tab, .backspace: .backspace,
        ]
        XCTAssertEqual(Set(expected.keys), Set(RemoteKey.allCases))
        for key in RemoteKey.allCases {
            XCTAssertEqual(key.virtualKey, expected[key])
            XCTAssertEqual(key.virtualKey.name, key.rawValue)
        }
    }

    func testMediaKeyEventEncoding() {
        // NX_KEYTYPE_* from IOKit/hidsystem/ev_keymap.h.
        XCTAssertEqual(MediaKey.volumeUp.nxKeyType, 0)
        XCTAssertEqual(MediaKey.volumeDown.nxKeyType, 1)
        XCTAssertEqual(MediaKey.mute.nxKeyType, 7)
        XCTAssertEqual(MediaKey.playPause.nxKeyType, 16)
        XCTAssertEqual(MediaKey.next.nxKeyType, 17)
        XCTAssertEqual(MediaKey.previous.nxKeyType, 18)
        XCTAssertEqual(MediaKey.playPause.eventData1(keyDown: true), 0x100A00)
        XCTAssertEqual(MediaKey.playPause.eventData1(keyDown: false), 0x100B00)
        XCTAssertEqual(MediaKey.volumeUp.eventData1(keyDown: true), 0x000A00)
        XCTAssertEqual(MediaKey.eventFlags(keyDown: true), 0xA00)
        XCTAssertEqual(MediaKey.eventFlags(keyDown: false), 0xB00)
    }
}
