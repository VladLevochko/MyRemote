# MyRemote — macOS agent

The Mac half of MyRemote: a menu bar agent that accepts authenticated commands
from the phone over the LAN and turns them into keyboard, mouse and media-key
events. The wire protocol is defined in [`../docs/PROTOCOL.md`](../docs/PROTOCOL.md);
this package implements it and is tested against the shared fixtures in
[`../protocol/fixtures`](../protocol/fixtures).

- Swift package, no Xcode project, no third-party dependencies.
- Requires macOS 15 or later (the TLS identity is imported with
  `kSecImportToMemoryOnly`, which does not exist before macOS 15) and a Swift 6
  toolchain. Developed on macOS 27.0.1 / Swift 6.4, arm64.

## Layout

| Path | What |
|---|---|
| `Sources/MyRemoteCore` | Pure logic: Codable protocol models, pairing URI, token, the session state machine, profile detection, action mapping, the `InputInjector` protocol. No I/O. |
| `Sources/MyRemoteAgentKit` | Everything that touches the system: WSS server (Network.framework), TLS identity, state store, real and dry-run injectors, front-app tracking, display-sleep assertion, menu bar UI, CLI. |
| `Sources/MyRemoteAgent` | The executable; a one-line `main.swift`. |
| `Tests/MyRemoteCoreTests` | Fixture contract tests, session state machine (fake clock), profiles, pairing. |
| `Tests/MyRemoteAgentKitTests` | Loopback integration tests against the real server and TLS identity, the spawned headless binary, component tests. |
| `scripts/make-app.sh` | Builds `MyRemote.app`. |

## Build and test

```sh
cd mac
swift build
swift test
```

The tests never inject input and never use port 47110 or the real state
directory: servers bind ephemeral ports, state lives in temporary directories
(set `MYREMOTE_TEST_TMPDIR` to choose where), and input goes to a recording or
dry-run injector. Tests do not advertise over Bonjour.

Two tests are opt-in and skipped by default:

| Variable | Test | Why it is opt-in |
|---|---|---|
| `MYREMOTE_TEST_BONJOUR=1` | `BonjourTests` — browses for the advertised service and checks the TXT records | Bonjour is subject to Local Network privacy; started from an IDE it can raise a system prompt. From Terminal it does not. |
| `MYREMOTE_TEST_REAL_INJECTION=1` | `RealInjectionSmokeTests` — moves the mouse pointer a few points and back | The only test that posts real events. Needs Accessibility for the process running the tests. Never types or clicks. |

## Run

### As a menu bar app

```sh
scripts/make-app.sh          # -> dist/MyRemote.app, ad-hoc signed
open dist/MyRemote.app
```

A remote-control icon appears in the menu bar (a warning triangle while
Accessibility is missing). The menu shows the port and the connected devices and
offers:

- **Pair New Device…** — a window with the pairing QR code and the same URI as
  selectable text. The code contains the secret token; treat it like a password.
- **Open Accessibility Settings…** — shown while the permission is missing.
- **Reset Pairing…** — generates a new token and disconnects every phone. The
  certificate and the agent id stay.
- **Quit MyRemote**

On first launch macOS asks whether MyRemote may find devices on the local network
(that is the Bonjour advertisement). Allow it, or the phone can only connect via
the address in the QR code.

`make-app.sh` environment:

| Variable | Default | |
|---|---|---|
| `MYREMOTE_CODESIGN_IDENTITY` | `-` (ad-hoc) | A signing identity from `security find-identity -v -p codesigning`. |
| `MYREMOTE_APP_OUT` | `mac/dist` | Output directory. |
| `MYREMOTE_BUNDLE_ID` | `dev.myremote.agent` | |
| `MYREMOTE_VERSION` | `0.1.0` | |

### Headless (PROTOCOL.md section 6)

```
MyRemoteAgent --headless [--dry-run] [--loopback] [--port <n>] [--state-dir <path>]
```

```sh
swift build
.build/debug/MyRemoteAgent --headless --dry-run --loopback --port 0 --state-dir /some/empty/dir
```

stdout carries exactly two kinds of lines, each flushed immediately:

```
PAIRING myremote://pair?v=1&host=127.0.0.1&port=55437&id=86e6ac057304fc48&name=...&fp=<64 hex>&token=<43 chars>
INJECT {"key":"space","keyCode":49,"kind":"key","modifiers":[]}
```

Diagnostics go to stderr. `SIGINT`/`SIGTERM` shut the agent down cleanly (exit 0);
bad arguments exit with 64.

Flags beyond the contract (extensions, safe to ignore):

| Flag | |
|---|---|
| `--profile youtube\|netflix\|appletv\|generic` | Pin the profile instead of following the frontmost app; `frontApp` is then `null`. Makes `INJECT` output deterministic in tests. |
| `--no-bonjour` | Do not advertise `_myremote._tcp`. |
| `--help` | Usage. |

Without `--headless` the same flags apply to the menu bar app.

#### `INJECT` line format

The contract fixes the `INJECT ` prefix and "one JSON object per line" but not the
object. This agent prints the concrete input action, keys sorted:

| Action | Example |
|---|---|
| Key stroke | `{"key":"f","keyCode":3,"kind":"key","modifiers":["control","command"]}` |
| Media key | `{"key":"playPause","kind":"mediaKey"}` |
| Pointer move | `{"dx":12.5,"dy":-3.25,"kind":"pointer"}` |
| Click | `{"button":"right","count":2,"kind":"click"}` |
| Scroll | `{"dx":0,"dy":-40.5,"kind":"scroll"}` |
| Text | `{"kind":"text","text":"Привіт 🎬"}` |

`key` is a stable name (`k`, `space`, `enter`, `left`, …), `keyCode` the macOS
virtual keycode, `modifiers` a subset of `control`, `option`, `shift`, `command` in
that order. Media key names: `playPause`, `next`, `previous`, `volumeUp`,
`volumeDown`, `mute`. A command that is `unsupported` or rejected prints nothing.

## Granting Accessibility

Synthetic input needs **System Settings › Privacy & Security › Accessibility**.

1. Start MyRemote and choose **Open Accessibility Settings…** from its menu. This
   registers the app in the list and opens the pane.
2. Turn the MyRemote switch on.

The agent notices the change within a second; no restart is needed. While the
permission is missing the agent never posts events: commands with an `id` are
answered with `ack ok=false error=accessibility_denied`, and
`state.accessibility` is `false`.

The same permission is what lets the agent read the focused window's title.
Without it a browser is always reported as `generic`, because YouTube and
Netflix are recognised by the window title.

macOS binds the permission to the code signature. An ad-hoc signature changes
with every build, so after rebuilding the app, remove MyRemote from the
Accessibility list and add it again — or sign with a stable identity
(`MYREMOTE_CODESIGN_IDENTITY`). When you run the bare binary from a terminal
(`--headless` without `--dry-run`), the permission that counts is the terminal's.

## State

`~/Library/Application Support/MyRemote` (or `--state-dir`), directory mode 0700,
files mode 0600:

| File | |
|---|---|
| `agent-id` | 16 hex characters, generated once. |
| `token` | The pairing secret (32 random bytes, base64url). Replaced by "Reset pairing". |
| `identity.p12` | Self-signed P-256 certificate and key, valid 20 years, generated once. |

The TLS identity is created by `/usr/bin/openssl` on first start and imported
into memory only. Nothing is stored in a keychain and no keychain prompt appears.
Deleting `identity.p12` gives the agent a new certificate, so every phone has to
pair again.

## Profiles

The profile follows the frontmost app: `com.apple.TV` → `appletv`; a browser
whose focused window title contains "YouTube" → `youtube`, "Netflix" →
`netflix`; anything else → `generic`. Recognised browsers: Safari (and Safari web
apps), Chrome (all channels and installed web apps), Chromium, Arc, Dia, Firefox
(all channels), Edge, Brave, Opera, Opera GX, Vivaldi, Zen, Orion, DuckDuckGo.

Over HDMI macOS cannot change the output volume, so the player profiles use the
player's own volume shortcuts; only `generic` uses the system volume keys.

| `cmd.action` | `youtube` | `netflix` | `appletv` | `generic` |
|---|---|---|---|---|
| `playPause` | `K` ✅ | `Space` ✅ | `Space` ✅ | media Play/Pause |
| `seekBackward` | `J` (10 s) ✅ | `←` (10 s) ✅ | `←` ⚠️ | `←` ◻️ |
| `seekForward` | `L` (10 s) ✅ | `→` (10 s) ✅ | `→` ⚠️ | `→` ◻️ |
| `volumeUp` | `↑` (5 %) ✅ | `↑` ✅ | `⌘↑` ✅ | system Volume Up |
| `volumeDown` | `↓` (5 %) ✅ | `↓` ✅ | `⌘↓` ✅ | system Volume Down |
| `toggleMute` | `M` ✅ | `M` ✅ | unsupported | system Mute |
| `toggleFullscreen` | `F` ✅ | `F` ✅ (see note) | `⌃⌘F` ✅ | `⌃⌘F` ✅ |
| `nextItem` | `⇧N` ✅ | unsupported | `⌘→` 🔎 | media Next |
| `previousItem` | `⇧P` ✅ | unsupported | `⌘←` 🔎 | media Previous |
| `skip` | unsupported | `S` ✅ (intro only) | unsupported | unsupported |
| `toggleSubtitles` | `C` ✅ | unsupported | unsupported | unsupported |

✅ listed in the vendor's own shortcut documentation (checked 2026-11-22) ·
🔎 not in the documentation, but present as a key equivalent in the app's own
menu (TV.app 1.7 on macOS 27.0.1: *Controls › Next / Previous*) ·
⚠️ unconfirmed: not documented and not in the app's menu ·
◻️ a convention of many players, not a fact about any particular app.

Sources:

- YouTube — <https://support.google.com/youtube/answer/7631406>
- Netflix — <https://help.netflix.com/en/node/24855>
- Apple TV app — <https://support.apple.com/guide/tvapp-mac/atvc572afcf3/mac>
- macOS full screen — <https://support.apple.com/102650>

Notes on individual entries:

- **YouTube** has no hotkey for skipping an ad, so `skip` is `unsupported`; use the
  trackpad. Google's page says that in the current desktop player you must click
  the video player before shortcuts work, and it describes the arrow-key volume
  shortcut in terms of the player/seek bar having focus: if the page rather than
  the player has focus, `↑`/`↓` scroll the page. `⇧P` only works inside a playlist.
- **Netflix** documents `F` as "Full screen" and `Esc` as "Exit full screen". That
  `F` also leaves full screen is not stated on the page. There is no documented
  shortcut for next/previous episode or for subtitles. `S` is "Skip intro"; recaps
  and credits have no shortcut.
- **Apple TV app**: Apple documents only Space, `⌘↑`/`⌘↓` and `⌃⌘F` for playback.
  Arrow keys for seeking are not documented and could not be confirmed. What
  *Next*/*Previous* do while a stream is playing was not tested. Mute, subtitles
  and "Skip Intro" have no shortcut.
- **generic**: the media keys go to whatever app macOS considers "Now Playing",
  which is not necessarily the frontmost one.

To change a mapping edit `ProfileMap` in `Sources/MyRemoteCore/Profiles.swift`
and the table in `Tests/MyRemoteCoreTests/ProfileTests.swift`.

## Protocol behaviour where the contract leaves room

- **Request path.** The contract's URL is `/ws`. `NWProtocolWebSocket` does not
  show the request path to a server, so the agent accepts a WebSocket upgrade on
  any path.
- **Scroll direction.** Positive `dy` is treated as "wheel down" (the view moves
  down the document), positive `dx` as "wheel right". Fractions are accumulated
  across messages because the system event takes whole pixels.
- **Idle timeout and shutdown** close with code 1001; the contract names no code.
- **Reset pairing** sends `error unauthorized` and closes with 4401, so the phone
  can tell that it has to pair again.
- **Version before token.** A `hello` with an unsupported `v` gets
  `unsupported_version` even if the token is wrong or missing.
- **Malformed messages after authentication.** Unparseable JSON, an unknown
  `type`, and invalid `pointer`/`click`/`scroll`/`ping` get `error bad_request`
  and the connection stays open. Invalid `cmd`/`key`/`text` with a readable `id`
  get `ack bad_request`; with no readable `id` they get `error bad_request`. An
  unknown `action`/`key` without an `id` gets no answer.
- **A second `hello`** on an authenticated connection gets `error bad_request`.
- **`text`** longer than 10 000 UTF-16 units is answered with `bad_request`.
  Line breaks and tabs are sent as the Return and Tab keys. An empty text is
  acknowledged without typing anything.
- **Denied `pointer`/`click`/`scroll`** are dropped silently (they are never
  acknowledged); `state.accessibility` carries the information.
- **Limits**: 256 KiB per message, 32 simultaneous connections, 10 s to complete
  the TLS and WebSocket handshake.
- **Port**: if 47110 (or `--port <n>`) is taken the agent uses any free port.

## Known limitations

- **Real input injection and the menu bar UI are not covered by automated
  tests.** The tests verify which events would be built and that the protocol
  reaches the injector; whether a given app reacts to them is only seen by using it.
- **Keyboard layout.** Shortcuts are posted as physical key positions of a US
  layout. Browsers generally match letter shortcuts by position even when a
  non-Latin layout is active, but this has not been verified here for every
  site/layout combination.
- **Profile detection is title-based** and needs the Accessibility permission.
  A video playing in a background tab or window is not detected.
- **System volume and mute keys do nothing over HDMI** (a macOS limitation); that
  affects the `generic` profile.
- **Pairing address.** The QR code carries the IPv4 of the first active `en*`
  interface. On a multi-homed Mac that may not be the network the phone is on;
  discovery by Bonjour (by agent id) still finds it.
- **Ad-hoc signed builds lose the Accessibility permission on every rebuild**
  (see above).
- **No brute-force throttling.** The token is 256 bits of entropy, so guessing is
  not a practical attack, but nothing slows a flood of bad `hello`s beyond the
  connection limit.
- **Lock screen / login window.** Events posted while the session is locked go
  nowhere.
- **Identity generation depends on `/usr/bin/openssl`** (first start only).
  LibreSSL occasionally (about one key in 256) produces a P-256 key that
  Security.framework silently refuses to import; the agent detects this and
  generates another one before anything is persisted.
