"""Persist pairing credentials to ~/.appletv-remote/credentials.json."""
from __future__ import annotations

import json
import os
import time
from pathlib import Path
from typing import Any

CONFIG_DIR = Path.home() / ".appletv-remote"
CREDENTIALS_FILE = CONFIG_DIR / "credentials.json"


def _ensure_dir() -> None:
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)


def _write_atomic(data: dict[str, Any]) -> None:
    """Write via temp file + os.replace so a crash mid-write can't truncate
    the credentials file."""
    _ensure_dir()
    tmp = CREDENTIALS_FILE.with_name(CREDENTIALS_FILE.name + ".tmp")
    tmp.write_text(json.dumps(data, indent=2))
    os.chmod(tmp, 0o600)
    os.replace(tmp, CREDENTIALS_FILE)


def load_all() -> dict[str, dict[str, Any]]:
    if not CREDENTIALS_FILE.exists():
        return {}
    try:
        return json.loads(CREDENTIALS_FILE.read_text())
    except (json.JSONDecodeError, OSError):
        # Preserve the corrupt file instead of letting the next save silently
        # overwrite it and permanently erase all paired credentials.
        try:
            backup = CREDENTIALS_FILE.with_name(
                f"{CREDENTIALS_FILE.name}.corrupt-{int(time.time())}"
            )
            os.replace(CREDENTIALS_FILE, backup)
        except OSError:
            pass
        return {}


def get(identifier: str) -> dict[str, Any] | None:
    return load_all().get(identifier)


def save(identifier: str, name: str, credentials: dict[str, str]) -> None:
    """Overwrite all credentials for a device. Used by the CLI pair script."""
    data = load_all()
    data[identifier] = {"name": name, "credentials": credentials}
    _write_atomic(data)


def save_protocol(identifier: str, name: str, protocol: str, credential: str) -> None:
    """Merge a single protocol's credential into the device's saved entry."""
    data = load_all()
    entry = data.get(identifier) or {"name": name, "credentials": {}}
    entry["name"] = name
    entry.setdefault("credentials", {})[protocol] = credential
    data[identifier] = entry
    _write_atomic(data)


def remove(identifier: str) -> bool:
    data = load_all()
    if identifier not in data:
        return False
    del data[identifier]
    _write_atomic(data)
    return True
