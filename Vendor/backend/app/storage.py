"""Persist pairing credentials to ~/.appletv-remote/credentials.json."""
from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

CONFIG_DIR = Path.home() / ".appletv-remote"
CREDENTIALS_FILE = CONFIG_DIR / "credentials.json"


def _ensure_dir() -> None:
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)


def load_all() -> dict[str, dict[str, Any]]:
    if not CREDENTIALS_FILE.exists():
        return {}
    try:
        return json.loads(CREDENTIALS_FILE.read_text())
    except (json.JSONDecodeError, OSError):
        return {}


def get(identifier: str) -> dict[str, Any] | None:
    return load_all().get(identifier)


def save(identifier: str, name: str, credentials: dict[str, str]) -> None:
    """Overwrite all credentials for a device. Used by the CLI pair script."""
    _ensure_dir()
    data = load_all()
    data[identifier] = {"name": name, "credentials": credentials}
    CREDENTIALS_FILE.write_text(json.dumps(data, indent=2))
    os.chmod(CREDENTIALS_FILE, 0o600)


def save_protocol(identifier: str, name: str, protocol: str, credential: str) -> None:
    """Merge a single protocol's credential into the device's saved entry."""
    _ensure_dir()
    data = load_all()
    entry = data.get(identifier) or {"name": name, "credentials": {}}
    entry["name"] = name
    entry.setdefault("credentials", {})[protocol] = credential
    data[identifier] = entry
    CREDENTIALS_FILE.write_text(json.dumps(data, indent=2))
    os.chmod(CREDENTIALS_FILE, 0o600)


def remove(identifier: str) -> bool:
    data = load_all()
    if identifier not in data:
        return False
    del data[identifier]
    CREDENTIALS_FILE.write_text(json.dumps(data, indent=2))
    return True
