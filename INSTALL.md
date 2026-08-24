# Apple TV Remote — install

This `.app` is unsigned (no Apple Developer Program), so macOS Gatekeeper
will refuse to launch it normally. Run the steps below once and it'll work.

Requires an **Apple silicon Mac** (M1 or later). The bundled Python runtime
is arm64-only.

## 1. Unzip and move

Unzip `AppleTVRemote-*.zip`, then drag `Apple TV Remote.app` into
`~/Applications` (or `/Applications` if you prefer — `~/Applications` doesn't
need admin).

## 2. Remove the quarantine flag

macOS marks downloaded apps as quarantined. For an unsigned app this shows up
as "Apple TV Remote.app is damaged and can't be opened." Strip the flag with:

```bash
xattr -dr com.apple.quarantine ~/Applications/"Apple TV Remote.app"
```

(Adjust the path if you put it elsewhere.)

## 3. First launch

```bash
open ~/Applications/"Apple TV Remote.app"
```

If macOS still complains, right-click the app → **Open** → **Open** in the
confirmation dialog. After that it launches normally from the Dock.

## What it does on first run

- Starts a small Python backend bundled inside the app (no install needed).
- Scans your Wi-Fi for Apple TVs.
- Pair each Apple TV once (PIN flow), then connect and control it.

Backend logs and pairing credentials live in `~/.appletv-remote/`.
