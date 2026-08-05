# AGENTS.md — guidance for AI agents working on this repo

## What this project is

**Apple TV Remote** — a native macOS SwiftUI app that controls Apple TVs over the LAN.
The Swift app is a shell: all protocol work (discovery, pairing, commands, now-playing,
keyboard) is done by a **FastAPI + pyatv** Python backend under `Vendor/backend/`, which the
app bundles (embedded Python 3.12 in `Vendor/python/`) and spawns automatically via
`BackendController`. They talk over REST (`/api/*`) + one WebSocket (`/ws/state`).

It also mirrors the Apple TV's screen: ScreenCaptureKit captures the QuickTime Player
"Movie Recording" window (the only public API path to wireless-Apple-TV frames) into a live
preview, PNG screenshots, and MP4 recordings (`Sources/ScreenCapture/`). QuickTime is
driven automatically (`QuickTimeController.swift`): on connect the app opens the recording
window and selects the connected TV via the accessibility tree (needs the Accessibility
TCC grant — deliberately NOT Apple Events, whose consent prompt never appears for this
self-signed app). QuickTime rejects AX while busy/launching (`kAXErrorCannotComplete`),
so all state probes are three-state (present/missing/unknown) and recovery never quits
QuickTime on a failed open; real restarts are capped at 2 per device/refresh.

Repo root = this directory (`swift-app/`). Default branch: `main`. Releases are GitHub
releases (`gh`), tags `vX.Y.Z`, zip asset `AppleTVRemote-X.Y.Z.zip` + `INSTALL.md`.

## Layout (current)

```
Sources/
├── AppleTVRemoteApp.swift      # @main, RootView, AppDelegate (window-level key monitor!)
├── Models/Models.swift         # DeviceInfo, PlayingState, KeyboardEvent, SavedDeviceEntry, DTOs
├── Networking/
│   ├── BackendClient.swift     # @MainActor REST+WS client; auto-connect, dedupe, refresh/reconnect
│   └── BackendController.swift # spawns bundled uvicorn on a free port; .failed state must persist
├── ScreenCapture/
│   ├── CaptureCoordinator.swift# SCStream lifecycle, preview throttle, screenshot, recording;
│   │                           #  managed QuickTime flow (probe → open → select source → stream)
│   ├── QuickTimeController.swift# AX-driven QuickTime automation (open/select source/health)
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

## Release process (as done for v0.2.x)

1. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in
   `AppleTVRemote.xcodeproj/project.pbxproj` (2 occurrences each); commit "Bump version to X".
2. Release build (configuration Release) → zip:
   `ditto -c -k --keepParent "<Release>/Apple TV Remote.app" AppleTVRemote-X.Y.Z.zip`
3. `git tag vX.Y.Z && git push origin main --tags`
4. `gh release create vX.Y.Z <zip> INSTALL.md --title … --notes …`
   (reuse `INSTALL.md` from the previous release: `gh release download <prev> -p INSTALL.md`)
5. Replace `/Applications/Apple TV Remote.app` with the new build (user runs it from there).
6. `ship.sh` is the older alternative: ad-hoc-signed zip + generated INSTALL.md, no gh step.

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
- **Capture**: preview render/PNG encode stay off-main (10 fps coalesced in the adapter).
  Never take the app window real fullscreen to "give the stream space" — fullscreen moves the app
  to its own Space, the QuickTime window gets occluded, and the capture freezes.
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
