"""In-app pairing: session-based, walks through each pairable protocol.

Flow (per device):
  1. POST /api/pair/start {identifier}
       → backend scans for the device, picks pairable protocols, begins the
         first one. Returns {session_id, protocol, needs_pin, ...}.
  2. POST /api/pair/{session_id}/pin {pin}
       → backend submits PIN to current handler, finishes it, saves
         credentials for that protocol, then begins the next protocol if any
         remain. Returns same shape, or {done: true, ...} when finished.
  3. POST /api/pair/{session_id}/cancel
       → tears down any in-flight handler and drops the session.
"""
from __future__ import annotations

import asyncio
import logging
import uuid
from dataclasses import dataclass, field
from typing import Any

import pyatv
from pyatv.const import Protocol

from . import storage

log = logging.getLogger(__name__)

# Try modern protocols first. Older ones rarely needed and often fail on
# tvOS 15+ — we skip them silently if they can't begin.
PAIRABLE_PROTOCOLS: list[Protocol] = [
    Protocol.AirPlay,
    Protocol.Companion,
    Protocol.MRP,
    Protocol.RAOP,
]


@dataclass
class PairingSession:
    session_id: str
    identifier: str
    name: str
    config: Any
    pending: list[Protocol] = field(default_factory=list)
    completed: list[str] = field(default_factory=list)
    failed: list[dict[str, str]] = field(default_factory=list)
    current_protocol: Protocol | None = None
    current_handler: Any = None


class PairingManager:
    def __init__(self) -> None:
        self._sessions: dict[str, PairingSession] = {}
        self._lock = asyncio.Lock()

    async def start(self, identifier: str) -> dict[str, Any]:
        async with self._lock:
            # Only allow one active pairing session at a time. Drop any others.
            for old in list(self._sessions.values()):
                await self._close_current(old)
            self._sessions.clear()

            loop = asyncio.get_running_loop()
            configs = await pyatv.scan(loop, identifier=identifier, timeout=5)
            if not configs:
                raise RuntimeError(f"Device {identifier} not found on network.")
            config = configs[0]

            available = {svc.protocol for svc in config.services}
            pending = [p for p in PAIRABLE_PROTOCOLS if p in available]
            if not pending:
                raise RuntimeError("This device offers no pairable protocols.")

            session = PairingSession(
                session_id=str(uuid.uuid4()),
                identifier=config.identifier or "",
                name=config.name,
                config=config,
                pending=pending,
            )
            self._sessions[session.session_id] = session
            return await self._begin_next(session)

    async def submit_pin(self, session_id: str, pin: str) -> dict[str, Any]:
        async with self._lock:
            session = self._sessions.get(session_id)
            if not session:
                raise RuntimeError("Unknown or expired pairing session.")
            handler = session.current_handler
            proto = session.current_protocol
            if handler is None or proto is None:
                raise RuntimeError("Session is not awaiting a PIN.")

            paired_ok = False
            err: str | None = None
            try:
                handler.pin(pin)
                await handler.finish()
                if handler.has_paired:
                    creds = handler.service.credentials
                    storage.save_protocol(session.identifier, session.name, proto.name, creds)
                    session.completed.append(proto.name)
                    paired_ok = True
                else:
                    err = f"{proto.name} pairing did not complete."
            except Exception as e:
                err = f"{proto.name} pairing failed: {e}"
                log.warning("pair %s error: %s", proto.name, e)
            finally:
                try:
                    await handler.close()
                except Exception:
                    pass
                session.current_handler = None
                session.current_protocol = None

            if not paired_ok and err:
                session.failed.append({"protocol": proto.name, "error": err})

            if session.pending:
                return await self._begin_next(session)
            return self._finalize(session)

    async def cancel(self, session_id: str) -> None:
        async with self._lock:
            session = self._sessions.pop(session_id, None)
            if session:
                await self._close_current(session)

    async def _begin_next(self, session: PairingSession) -> dict[str, Any]:
        while session.pending:
            proto = session.pending.pop(0)
            try:
                loop = asyncio.get_running_loop()
                handler = await pyatv.pair(session.config, proto, loop)
                await handler.begin()
            except Exception as e:
                log.info("skip pairing %s: %s", proto.name, e)
                session.failed.append({"protocol": proto.name, "error": str(e)})
                continue

            session.current_handler = handler
            session.current_protocol = proto
            return {
                "session_id": session.session_id,
                "identifier": session.identifier,
                "name": session.name,
                "protocol": proto.name,
                "needs_pin": bool(getattr(handler, "device_provides_pin", True)),
                "completed": list(session.completed),
                "failed": list(session.failed),
                "remaining": [p.name for p in session.pending],
                "done": False,
            }

        return self._finalize(session)

    def _finalize(self, session: PairingSession) -> dict[str, Any]:
        result = {
            "done": True,
            "session_id": session.session_id,
            "identifier": session.identifier,
            "name": session.name,
            "paired_protocols": list(session.completed),
            "failed": list(session.failed),
        }
        self._sessions.pop(session.session_id, None)
        if not session.completed:
            # Nothing paired — surface as error so the UI shows a failure.
            details = "; ".join(f["error"] for f in session.failed) or "no protocols paired"
            raise RuntimeError(f"Pairing failed: {details}")
        return result

    async def _close_current(self, session: PairingSession) -> None:
        if session.current_handler is not None:
            try:
                await session.current_handler.close()
            except Exception:
                pass
            session.current_handler = None
            session.current_protocol = None


pair_manager = PairingManager()
