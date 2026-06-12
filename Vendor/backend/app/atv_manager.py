"""Wraps pyatv: scan, connect, send commands, stream now-playing updates."""
from __future__ import annotations

import asyncio
import logging
from typing import Any, Callable

import pyatv
from pyatv.const import OperatingSystem, Protocol
from pyatv.interface import AppleTV, KeyboardListener, PushListener

from . import storage
from .models import DeviceInfo, PlayingState

log = logging.getLogger(__name__)

# Commands that map 1:1 to RemoteControl methods (no args).
SIMPLE_COMMANDS = {
    "up", "down", "left", "right", "select",
    "menu", "home", "home_hold", "top_menu",
    "play", "pause", "play_pause", "stop",
    "next", "previous",
    "volume_up", "volume_down",
    "skip_forward", "skip_backward",
    "screensaver", "suspend",
    "turn_on", "turn_off",
}


class _Listener(PushListener):
    def __init__(self, manager: "ATVManager"):
        self.manager = manager

    def playstatus_update(self, updater, playstatus) -> None:
        asyncio.create_task(self.manager._broadcast_playing())

    def playstatus_error(self, updater, exception) -> None:
        log.warning("push update error: %s", exception)


class _KeyboardListener(KeyboardListener):
    def __init__(self, manager: "ATVManager"):
        self.manager = manager

    def focusstate_update(self, old_state, new_state) -> None:
        asyncio.create_task(self.manager._broadcast_keyboard(new_state))


class ATVManager:
    def __init__(self) -> None:
        self._atv: AppleTV | None = None
        self._identifier: str | None = None
        self._device_info: DeviceInfo | None = None
        self._loop: asyncio.AbstractEventLoop | None = None
        self._listeners: set[Callable[[dict[str, Any]], Any]] = set()
        self._listener_impl: _Listener | None = None
        self._kbd_listener: _KeyboardListener | None = None
        self._kbd_poll_task: asyncio.Task | None = None
        self._kbd_last_focus: str | None = None
        self._kbd_last_text: str | None = None
        self._lock = asyncio.Lock()

    @property
    def connected(self) -> bool:
        return self._atv is not None

    @property
    def current_identifier(self) -> str | None:
        return self._identifier

    async def scan(self, timeout: int = 5) -> list[DeviceInfo]:
        loop = asyncio.get_running_loop()
        configs = await pyatv.scan(loop, timeout=timeout)
        saved = storage.load_all()
        devices: list[DeviceInfo] = []
        for cfg in configs:
            if not cfg.device_info or cfg.device_info.operating_system != OperatingSystem.TvOS:
                continue
            ident = cfg.identifier or ""
            devices.append(
                DeviceInfo(
                    identifier=ident,
                    name=cfg.name,
                    address=str(cfg.address),
                    model=str(cfg.device_info.model),
                    services=[s.protocol.name for s in cfg.services],
                    is_paired=ident in saved,
                )
            )
        return devices

    async def connect(self, identifier: str) -> DeviceInfo:
        async with self._lock:
            if self._atv and self._identifier == identifier and self._device_info:
                return self._device_info

            await self._disconnect_locked()

            creds = storage.get(identifier)
            if not creds:
                raise RuntimeError(f"No saved credentials for {identifier}. Run pairing first.")

            loop = asyncio.get_running_loop()
            configs = await pyatv.scan(loop, identifier=identifier, timeout=5)
            if not configs:
                raise RuntimeError(f"Device {identifier} not found on network.")
            config = configs[0]

            for proto_name, cred_str in creds["credentials"].items():
                try:
                    proto = Protocol[proto_name]
                except KeyError:
                    continue
                config.set_credentials(proto, cred_str)

            atv = await pyatv.connect(config, loop)
            try:
                listener = _Listener(self)
                try:
                    atv.push_updater.listener = listener
                    atv.push_updater.start()
                except Exception as e:
                    # Push updates aren't supported on every device/protocol combo.
                    # Don't fail the whole connect for it.
                    log.warning("push_updater unavailable: %s", e)

                kbd_listener = _KeyboardListener(self)
                try:
                    atv.keyboard.listener = kbd_listener
                except Exception as e:
                    log.warning("keyboard listener unavailable: %s", e)
                    kbd_listener = None

                info = DeviceInfo(
                    identifier=identifier,
                    name=config.name,
                    address=str(config.address),
                    model=str(config.device_info.model) if config.device_info else None,
                    services=[s.protocol.name for s in config.services],
                    is_paired=True,
                )

                # Commit only after everything we can do has succeeded.
                self._atv = atv
                self._identifier = identifier
                self._device_info = info
                self._loop = loop
                self._listener_impl = listener
                self._kbd_listener = kbd_listener

                # Fallback: poll focus state because not every protocol pushes
                # keyboard updates (notably Companion on tvOS 15+).
                self._kbd_last_focus = None
                self._kbd_last_text = None
                self._kbd_poll_task = asyncio.create_task(self._poll_keyboard())

                log.info("connected to %s (%s)", config.name, identifier)
                return info
            except Exception:
                try:
                    atv.close()
                except Exception:
                    pass
                raise

    async def disconnect(self) -> None:
        async with self._lock:
            await self._disconnect_locked()

    async def _disconnect_locked(self) -> None:
        if self._atv is None:
            return
        if self._kbd_poll_task and not self._kbd_poll_task.done():
            self._kbd_poll_task.cancel()
            try:
                await self._kbd_poll_task
            except (asyncio.CancelledError, Exception):
                pass
        self._kbd_poll_task = None
        try:
            self._atv.push_updater.stop()
        except Exception:
            pass
        try:
            self._atv.close()
        except Exception as e:
            log.warning("close error: %s", e)
        self._atv = None
        self._identifier = None
        self._device_info = None
        self._listener_impl = None
        self._kbd_listener = None

    async def send(self, command: str, **kwargs: Any) -> None:
        if self._atv is None:
            raise RuntimeError("Not connected to any Apple TV.")
        rc = self._atv.remote_control

        if command in SIMPLE_COMMANDS:
            method = getattr(rc, command, None)
            if method is None:
                raise RuntimeError(f"Command '{command}' not supported by this device.")
            await method()
            return

        if command == "set_volume":
            level = float(kwargs.get("level", 0))
            await self._atv.audio.set_volume(level)
            return

        if command == "set_position":
            position = int(kwargs.get("position", 0))
            await rc.set_position(position)
            return

        if command == "channel_up":
            await rc.channel_up()
            return
        if command == "channel_down":
            await rc.channel_down()
            return

        raise RuntimeError(f"Unknown command: {command}")

    async def get_playing(self) -> PlayingState:
        if self._atv is None:
            return PlayingState()

        playing = await self._atv.metadata.playing()
        state = PlayingState(
            device_state=playing.device_state.name if playing.device_state else None,
            media_type=playing.media_type.name if playing.media_type else None,
            title=playing.title,
            artist=playing.artist,
            album=playing.album,
            app=self._atv.metadata.app.name if self._atv.metadata.app else None,
            position=playing.position,
            total_time=playing.total_time,
        )
        try:
            state.volume = await self._atv.audio.volume
        except Exception:
            pass
        if self._identifier:
            state.artwork_url = f"/api/artwork?ts={playing.hash}"
        return state

    async def get_artwork(self) -> tuple[bytes, str] | None:
        if self._atv is None:
            return None
        art = await self._atv.metadata.artwork()
        if art is None or art.bytes is None:
            return None
        return art.bytes, art.mimetype or "image/jpeg"

    # --- Keyboard ---------------------------------------------------------

    async def keyboard_state(self) -> dict[str, Any]:
        """Current focus state and text shown in the focused field, if any.

        See :meth:`_poll_keyboard` for why we use ``text_get`` as the source
        of truth instead of the (stale) ``text_focus_state`` property.
        """
        if self._atv is None:
            return {"connected": False, "focused": False, "text": None}
        try:
            text = await asyncio.wait_for(
                self._atv.keyboard.text_get(), timeout=2
            )
        except Exception as e:
            log.warning("keyboard_state text_get error: %s", e)
            return {"connected": True, "focused": False, "text": None, "error": str(e)}
        focused = text is not None
        return {
            "connected": True,
            "focused": focused,
            "focus_state": "Focused" if focused else "Unfocused",
            "text": text,
        }

    async def keyboard_set(self, text: str) -> None:
        if self._atv is None:
            raise RuntimeError("Not connected to any Apple TV.")
        await self._atv.keyboard.text_set(text)

    async def keyboard_append(self, text: str) -> None:
        if self._atv is None:
            raise RuntimeError("Not connected to any Apple TV.")
        await self._atv.keyboard.text_append(text)

    async def keyboard_clear(self) -> None:
        if self._atv is None:
            raise RuntimeError("Not connected to any Apple TV.")
        await self._atv.keyboard.text_clear()

    def subscribe(self, callback: Callable[[dict[str, Any]], Any]) -> None:
        self._listeners.add(callback)

    def unsubscribe(self, callback: Callable[[dict[str, Any]], Any]) -> None:
        self._listeners.discard(callback)

    async def _emit(self, payload: dict[str, Any]) -> None:
        for cb in list(self._listeners):
            try:
                res = cb(payload)
                if asyncio.iscoroutine(res):
                    await res
            except Exception as e:
                log.warning("listener error: %s", e)

    async def _broadcast_playing(self) -> None:
        if not self._listeners:
            return
        try:
            state = (await self.get_playing()).model_dump()
        except Exception as e:
            log.warning("broadcast playing error: %s", e)
            return
        await self._emit({"type": "playing", "state": state})

    async def _poll_keyboard(self) -> None:
        """Periodically check keyboard focus + text.

        pyatv's Companion keyboard subscription on a long-lived connection
        appears to go stale: ``text_focus_state`` caches at the value seen
        right after connect and stops reflecting reality. ``text_get()`` is
        more reliable — it returns a string (possibly empty) when a field is
        focused and ``None`` otherwise — so we use its result as the source
        of truth and ignore the cached focus state.
        """
        log.info("keyboard poll started")
        tick = 0
        try:
            while self._atv is not None:
                await asyncio.sleep(0.6)
                tick += 1
                if self._atv is None:
                    return
                text: str | None = None
                try:
                    text = await asyncio.wait_for(
                        self._atv.keyboard.text_get(), timeout=2
                    )
                except asyncio.TimeoutError:
                    log.warning("poll text_get timed out")
                    continue
                except Exception as e:
                    log.warning("poll text_get error: %s", e)
                    continue
                focus_name = "Focused" if text is not None else "Unfocused"
                if tick % 10 == 1:
                    log.info("kbd poll tick=%d focus=%s text=%r listeners=%d",
                             tick, focus_name, text, len(self._listeners))
                if focus_name != self._kbd_last_focus or text != self._kbd_last_text:
                    log.info("kbd state change: %s/%r → %s/%r (listeners=%d)",
                             self._kbd_last_focus, self._kbd_last_text,
                             focus_name, text, len(self._listeners))
                    self._kbd_last_focus = focus_name
                    self._kbd_last_text = text
                    await self._emit({
                        "type": "keyboard",
                        "focused": focus_name == "Focused",
                        "focus_state": focus_name,
                        "text": text,
                    })
        except asyncio.CancelledError:
            log.info("keyboard poll cancelled")
            raise
        except Exception as e:
            log.exception("keyboard poll loop error: %s", e)
        finally:
            log.info("keyboard poll exited")

    async def _broadcast_keyboard(self, new_state) -> None:
        if not self._listeners:
            return
        focus_name = getattr(new_state, "name", str(new_state))
        focused = focus_name == "Focused"
        text: str | None = None
        if focused and self._atv is not None:
            try:
                text = await self._atv.keyboard.text_get()
            except Exception:
                text = None
        await self._emit({
            "type": "keyboard",
            "focused": focused,
            "focus_state": focus_name,
            "text": text,
        })


manager = ATVManager()
