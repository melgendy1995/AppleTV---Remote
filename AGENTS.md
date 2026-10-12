# AGENTS.md — guidance for AI agents working on this repo

## What this project is

**Apple TV Remote** — a native macOS SwiftUI app that controls Apple TVs over the LAN.
The Swift app is a shell: all protocol work (discovery, pairing, commands, now-playing,
keyboard) is done by a **FastAPI + pyatv** Python backend under `Vendor/backend/`, which the
app bundles (embedded Python 3.12 in `Vendor/python/`) and spawns automatically via
`BackendController`. They talk over REST (`/api/*`) + one WebSocket (`/ws/state`).

It also mirrors the Apple TV's screen on the `feat/direct-feed` variant: at launch the
app sets CMIO `AllowScreenCaptureDevices` and `AllowWirelessScreenCaptureDevices`, then
opens the Apple TV as an external `AVCaptureDevice` (localized name like "apple tv",
modelID "iOS Device", muxed) with `AVCaptureSession` + `AVCaptureVideoDataOutput`
(420v, which the display layer composites directly — never 32BGRA). That feed drives the
live preview, PNG screenshots, and MP4 recordings
(`Sources/ScreenCapture/CaptureCoordinator.swift`). QuickTime is not launched.
`QuickTimeController.swift` stays in the target but is not on the active path.
The direct-feed app uses bundle ID `com.mahmoudelgendy.AppleTVRemoteDirect` so it can
be installed beside the QuickTime-based build. Camera usage (not Screen Recording) is
the TCC prompt. The device keeps delivering ~60 fps (frame-duration setters throw).
UserDefaults `previewFPS` (30 or 60, default 30) decimates in the sample delegate by
presentation timestamp; recording gets those same kept frames, live, without
rebuilding the session. `VideoRecorder` timestamps frames and drops when the writer
is busy. A hidden window stops preview enqueue and, unless recording, the sample
delegate skips buffer work down to about 2 fps. The preview layer is the view's
backing layer: opaque window, `contentsScale` = backing scale, no stage corner radius.

Repo root = this directory (`swift-app/`). Default branch: `main`. Releases are GitHub
releases, tags `vX.Y.Z`, zip asset `AppleTVRemote-X.Y.Z.zip` + `INSTALL.md`.
The `macOS app` GitHub Action (`.github/workflows/macos-app.yml`) builds that zip
via `ship.sh` on `macos-26` and publishes it on tag push (or as an artifact from
**Run workflow**).

## Layout (current)

```
Sources/
├── AppleTVRemoteApp.swift      # @main, RootView, AppDelegate (window-level key monitor!)
├── Models/Models.swift         # DeviceInfo, PlayingState, KeyboardEvent, SavedDeviceEntry, DTOs
├── Networking/
│   ├── BackendClient.swift     # @MainActor REST+WS client; auto-connect, dedupe, refresh/reconnect
│   └── BackendController.swift # spawns bundled uvicorn on a free port; .failed state must persist
├── ScreenCapture/
│   ├── CaptureCoordinator.swift# AVCaptureSession lifecycle, preview throttle, screenshot, recording
│   ├── QuickTimeController.swift# legacy AX QuickTime automation; not called by the direct feed
│   └── VideoRecorder.swift     # AVAssetWriter wrapper (serial queue, @unchecked Sendable)
└── Views/
    ├── Theme.swift             # black palette + liquid-glass helpers (glassCard/glassCapsule/…)
    ├── ContentView.swift       # cinema layout: capture stage left, control sidebar right (collapsible)
    ├── RemoteControlsView.swift# D-pad/transport buttons — NO keyboardShortcut modifiers here
    ├── DevicePickerView.swift  # network devices only (seeded instantly from saved creds)
    ├── NowPlayingCard.swift, KeyboardView.swift, PairingView.swift, SettingsView.swift
Vendor/backend/app/             # main.py (FastAPI), atv_manager.py (pyatv), pairing.py,
                                # storage.py (credentials, atomic writes), models.py (pydantic)
```

## Build, run, verify

- Build: `xcodebuild -project AppleTVRemote.xcodeproj -scheme AppleTVRemote-macOS -configuration Debug build`
  Products land in `~/Library/Developer/Xcode/DerivedData/AppleTVRemote-*/Build/Products/<Config>/`.
- Python syntax check: `python3.12 -m py_compile Vendor/backend/app/*.py`
  (system `python3` is 3.9 — too old for the codebase's `str | None` syntax).
- Relaunch: kill running instances first (`pkill -f "Apple TV Remote.app"`); stale uvicorns
  can ignore SIGTERM — check with `ps aux | grep uvicorn` and `kill -9` leftovers.
- Verify backend of a running app: find port via `ps aux | grep "[u]vicorn app.main"`,
  then `curl localhost:<port>/api/status`.

## Release process

1. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in
   `AppleTVRemote.xcodeproj/project.pbxproj` (2 occurrences each); commit "Bump version to X".
2. `git tag vX.Y.Z && git push origin main --tags`
3. GitHub Action `macOS app` runs `./ship.sh` on `macos-26`, uploads the zip
   artifact, and creates/updates the GitHub Release (`AppleTVRemote-X.Y.Z.zip` +
   `INSTALL.md`). Manual share without a tag: Actions → **macOS app** → **Run workflow**.
4. Replace `/Applications/Apple TV Remote.app` with the new build (user runs it from there).
5. Local equivalent: `./ship.sh` (ad-hoc-signed zip in `build/dist/`).

Code signing: local self-signed identity `AppleTVRemote-Dev`, `DEVELOPMENT_TEAM=""` (pinned in
project.pbxproj). The app is not notarized; INSTALL.md tells users to strip quarantine.

## Conventions & invariants (don't break these)

- **Keyboard shortcuts live in `AppDelegate`'s NSEvent local monitor**, not on buttons — they
  must work while the remote sidebar is hidden. Guards: key window is main window, no sheet,
  no modifiers, first responder is not a text field. Keys: arrows/return/space/esc/p/n/h (remote,
  require connection), `S`/`R` (screenshot/record, reveal file in Finder after).
- **Liquid glass**: use `Theme.swift` helpers (`glassCard`, `glassCapsule`, `glassCircle`,
  `glassButton`) — they call native macOS 26 `.glassEffect` inside `#available` with an
  `ultraThinMaterial` + hairline-stroke fallback. Theme is true black (`Theme.bg = .black`);
  surfaces use `.ultraThinMaterial`, never `.regularMaterial` (reads gray).
- **`BackendClient` is `@MainActor`.** From nonisolated contexts (event monitor) use
  `MainActor.assumeIsolated` (monitor callbacks are main-thread).
- **Device dedupe**: `~/.appletv-remote/credentials.json` can hold the same physical TV under
  several identifier formats (UUID / MAC ± colons). `BackendClient` dedupes by the hex-decoded
  device UUID in credential field 3 — reuse `physicalKey`/`dedupedSavedDevices`, don't re-list raw.
- **Auto-connect**: after every scan, connect to the first discovered paired device unless the
  user manually disconnected (suppress flag) or a previous attempt failed <60s ago.
- **Capture**: preview enqueue and PNG encode stay off the main actor. The sample
  adapter decimates to `previewFPS` (30 or 60) by presentation timestamp. It never
  writes `activeVideoMinFrameDuration` or `activeVideoMaxFrameDuration`. Hiding the
  window stops preview enqueue and, unless a recording is running, skips most
  buffers. Recording uses the same kept frames as the preview. The sidebar collapse
  is not fullscreen. Do not force 32BGRA, and do not put a corner radius or material
  behind the preview layer.
- **Backend**: no CORS middleware (intentional — native client only, `allow_origins=["*"]` let any
  website drive the TV). Async tasks go through `manager._spawn()` (strong refs). Credentials are
  written atomically (`os.replace`); corrupt files are backed up, never silently overwritten.
- Match existing style; minimal diffs; don't add dependencies without checking they're already used.

## Session history (what was done, v0.2.0 / v0.2.1)

- Fixed 11 critical bugs: backend failure state erased, uvicorn re-entrancy, recorder data race,
  recording surviving stream loss, pairing identifier fallback, WS reconnect spam (now exp.
  backoff), wrong-PIN pairing wedge (+30s finish timeout), non-atomic credential writes,
  get_playing race, GC'd tasks, WS dead-client detection; plus dead-code/CORS/poller cleanups.
- Liquid glass UI + black theme; device picker dedupe + instant seed; auto-connect;
  network-drop recovery (`DeviceListener` backend-side, `refreshAndReconnect` on ↻);
  collapsible remote sidebar; S/R capture shortcuts with Finder reveal; recording timer fix
  (`recordingStartedAt` must be set *after* `startRecordingTimer()`) + live file size.
- v0.2.1: `select_hold` (long-press ●, 0.6s) and `home_double` (double-click ⌂ TV → tvOS app
  switcher) via pyatv `InputAction`, with UI debounce/guard flags.
- v0.2.2: keyboard hold-Return → `select_hold`, double-`h` → `home_double` (keyDown/keyUp
  tracking in the AppDelegate monitor); picker shows ✓ Connected for the active device;
  Rescan clears the list + shows a loader; ↻ refresh reconnects to the LAST connected device
  before falling back to scan, and auto-connect prefers it too.
- v0.2.3: frozen-feed recovery (45s of frame silence while streaming → quit QuickTime, next
  poll starts a fresh share session; tracked via `lastFrameAt` in the stream adapter); losing
  the backend connection now closes QuickTime so reconnect gets a clean session; app window
  re-focuses once per healthy connect (`didFocusOnConnect`, reset on stream stop); glass
  buttons get explicit `contentShape` so their full padded area is clickable.
