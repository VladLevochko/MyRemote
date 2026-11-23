# MyRemote for Android

The phone half of MyRemote: a remote control for media playing on a Mac that is plugged into a
TV. It talks to the Mac agent (`../mac/`) over the protocol in [`../docs/PROTOCOL.md`](../docs/PROTOCOL.md).

- Kotlin, Jetpack Compose (Material 3), single activity, dark theme only.
- Application id `dev.myremote.app`, minSdk 28, compile/target SDK 36.
- UI strings in English and Ukrainian.

## Requirements

- JDK 17 or newer on `PATH` (built and tested with JDK 25).
- Android SDK with platform `android-36` and build-tools 36. Point Gradle at it with either
  `ANDROID_HOME` or an untracked `local.properties` next to this file:

  ```
  sdk.dir=/Users/you/Library/Android/sdk
  ```

Gradle itself comes from the wrapper (`./gradlew`).

## Build, test, install

Run everything from this directory.

```sh
./gradlew testDebugUnitTest    # JVM unit tests, no device needed
./gradlew assembleDebug        # app/build/outputs/apk/debug/app-debug.apk
./gradlew lintDebug            # Android lint; report in app/build/reports/
./gradlew installDebug         # install on the connected device or emulator
adb shell am start -n dev.myremote.app/.MainActivity
```

### What the unit tests cover

All protocol logic is plain Kotlin under `app/src/main/kotlin/dev/myremote/app/core` (a test
fails if anything there imports Android) and is tested on the JVM:

- **Contract fixtures** (`FixtureContractTest`, `PairingUriParserTest`): every file in
  `../protocol/fixtures/client` and `/server` decodes to its typed model and re-encodes to the
  same JSON; every pairing case is accepted or rejected as the fixtures say. The directory is
  passed in by Gradle as a path relative to the project and is a declared test input, so editing
  a fixture reruns the tests.
- **`RemoteClient`** against a real TLS WebSocket server (OkHttp MockWebServer with a generated
  self-signed certificate): pinning, handshake, `unauthorized`, ack correlation and timeout,
  heartbeat, the reconnect backoff sequence, state pushes, unknown messages. Protocol timers run
  on a virtual clock, so no test sleeps through a timeout.
- **Trackpad maths**, **reconnect target resolution** (mDNS first, last known address after 3 s).

### End-to-end test against a live Mac agent

`LiveAgentE2ETest` is skipped unless `MYREMOTE_E2E_URI` holds a pairing URI. Start the agent
headless (see PROTOCOL.md section 6), copy the URI from its `PAIRING ...` line, then:

```sh
MYREMOTE_E2E_URI='myremote://pair?v=1&host=127.0.0.1&port=...&id=...&name=...&fp=...&token=...' \
  ./gradlew testDebugUnitTest --tests '*LiveAgentE2ETest'
```

Use the agent's `--dry-run --loopback` flags unless you want a real play/pause, Enter and typed
text on the Mac. While the variable is set the test task is never treated as up to date, so it
really runs every time. The printed results are in
`app/build/test-results/testDebugUnitTest/TEST-dev.myremote.app.core.net.LiveAgentE2ETest.xml`.

### Trying the app without the Mac agent

The tests include a small fake agent. It can be run as a server for an emulator:

```sh
MYREMOTE_FAKE_AGENT_DIR=/tmp/fake-agent MYREMOTE_FAKE_AGENT_PORT=47110 \
  ./gradlew testDebugUnitTest --tests '*FakeAgentDevServer' --rerun
```

It writes `pairing-uri.txt` into that directory (with host `10.0.2.2`, the emulator's name for
the host machine) and logs what it receives to `received.log`. See `FakeAgentDevServer.kt` for
how to push a state, simulate "Reset pairing" and stop it. It holds the Gradle project lock
while running, so stop it before running other Gradle tasks here.

## Pairing

1. Put the phone and the Mac on the same Wi-Fi network.
2. On the Mac, open the MyRemote agent and show the pairing QR code.
3. In the app tap **Scan QR code** and point the camera at it. The scanner is Google's code
   scanner from Play services, so the app asks for no camera permission.

Without a camera or Play services (for example on an emulator), paste the `myremote://pair?...`
link into **Pairing link** instead. From a terminal:

```sh
adb shell input tap 540 1085     # focus the field; coordinates depend on the screen
adb shell "input text 'myremote://pair?v=1&host=10.0.2.2&port=47110&...'"
```

On an emulator mDNS does not work and the host machine is `10.0.2.2`, so replace the host in
the agent's URI with `10.0.2.2`.

To pair with a different Mac, or after "Reset pairing" on the Mac: **⋮ → Forget this Mac**, or
the **Pair again** button the app shows when the Mac rejects it.

## Using the remote

The layout is built for one-handed use: what you need while watching sits in the lower part of
the screen under the thumb, and is symmetric so it works in either hand.

- Bottom: a ring with play/pause in the middle, seek back and forward to the sides, volume up
  and down above and below. Seek and volume repeat while held.
- In the four corners around the ring: back (Esc), fullscreen, mute, and a keyboard button that
  opens a text box for typing on the Mac (with Enter and Backspace).
- The **⋮** menu at the top holds what is rarely needed: subtitles, skip, next, previous, and
  forgetting the Mac.
- Above the ring, the trackpad: drag to move the pointer, tap to click, double tap to double-click, two-finger tap
  to right-click, two-finger drag to scroll.
- The phone's volume buttons change the Mac's volume while the remote is on screen.
- The screen stays on while connected. The connection is dropped when the app goes to the
  background and re-established when it comes back.

If the current app on the Mac has no equivalent for a button, the app says so briefly; use the
trackpad for that action.

## Permissions and network

- `INTERNET` is the only permission. It covers the TLS WebSocket to the Mac and NsdManager
  (mDNS) discovery.
- **Android 17 local network permission.** Android 17 gates LAN access behind the runtime
  permission `ACCESS_LOCAL_NETWORK`, but only for apps that target SDK 37 or higher. This app
  targets SDK 36, where access is granted implicitly and Google's guidance is not to declare or
  request the permission. When `targetSdk` is raised to 37, declare `ACCESS_LOCAL_NETWORK` and
  request it before connecting; until it is granted, connections to the Mac will time out.
- The agent's certificate is self-signed. The app does not use the system trust store for it:
  it accepts exactly the certificate whose SHA-256 fingerprint was in the pairing QR code and
  nothing else, and skips hostname verification because the fingerprint is the identity.
  Cleartext traffic is disabled.
- The pairing (including the token) is stored in app-private DataStore and excluded from
  backup and device transfer.

## Known limitations

- **Single tap has a 250 ms delay.** A tap is only sent once it is clear that no second tap
  follows, so that a double tap is sent as one `click` with `count: 2` and not as a click
  followed by a double click.
- **3 s wait before each reconnect when mDNS finds nothing.** The protocol says to look the
  agent up over mDNS first and fall back to the last known address after 3 s. On a network
  where mDNS is blocked, and on the emulator, every reconnect therefore starts 3 s late. The
  first connection right after pairing skips this.
- No play/pause state: the protocol does not report whether media is playing, so the button
  shows a combined play/pause glyph.
- Portrait only.
- Volume buttons are not intercepted while the text box is open (a dialog has its own window).
- There are no arrow-key or Enter buttons on the remote screen; use the trackpad to navigate
  (Enter is in the text box).
- Pointer acceleration and scroll speed are fixed constants (`TrackpadConfig`), chosen by
  reasoning rather than by tuning on a real TV.
- IPv6 link-local addresses from mDNS are ignored (a URL cannot carry the scope id); IPv4 is
  preferred.
- One paired Mac at a time.

## Layout

```
app/src/main/kotlin/dev/myremote/app/
  core/                 plain Kotlin, no Android imports
    protocol/           message models and JSON codec
    pairing/            pairing URI parser
    net/                RemoteClient, certificate pinning, connection state, backoff
    discovery/          reconnect target resolution, AgentDiscovery interface
    trackpad/           gesture processor, acceleration, coalescing
  data/                 PairingStore (DataStore)
  discovery/            NsdAgentDiscovery (NsdManager)
  ui/                   Compose screens
  RemoteViewModel.kt, MainActivity.kt
```
