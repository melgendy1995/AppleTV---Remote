"""FastAPI app: REST + WebSocket for controlling Apple TVs via pyatv."""
from __future__ import annotations

import asyncio
import json
import logging
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import Response
from fastapi.staticfiles import StaticFiles

from . import storage
from .atv_manager import SIMPLE_COMMANDS, manager
from .models import CommandResponse, DeviceInfo, PlayingState
from .pairing import pair_manager

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("appletv-remote")

FRONTEND_DIR = Path(__file__).resolve().parents[2] / "frontend"


@asynccontextmanager
async def lifespan(app: FastAPI):
    log.info("starting up")
    yield
    log.info("shutting down")
    await manager.disconnect()


app = FastAPI(title="Apple TV Remote", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/api/status")
async def status() -> dict[str, Any]:
    return {
        "connected": manager.connected,
        "identifier": manager.current_identifier,
        "supported_commands": sorted(SIMPLE_COMMANDS) + ["set_volume", "set_position", "channel_up", "channel_down"],
    }


@app.get("/api/devices", response_model=list[DeviceInfo])
async def scan_devices(timeout: int = 5) -> list[DeviceInfo]:
    return await manager.scan(timeout=timeout)


@app.get("/api/devices/saved")
async def saved_devices() -> dict[str, Any]:
    return storage.load_all()


@app.delete("/api/devices/{identifier}")
async def forget_device(identifier: str) -> CommandResponse:
    if manager.current_identifier == identifier:
        await manager.disconnect()
    removed = storage.remove(identifier)
    return CommandResponse(ok=removed, error=None if removed else "not found")


@app.post("/api/connect/{identifier}", response_model=DeviceInfo)
async def connect(identifier: str) -> DeviceInfo:
    try:
        return await manager.connect(identifier)
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))


@app.post("/api/disconnect")
async def disconnect() -> CommandResponse:
    await manager.disconnect()
    return CommandResponse(ok=True)


# --- In-app pairing -------------------------------------------------------

@app.post("/api/pair/start")
async def pair_start(body: dict[str, Any]) -> dict[str, Any]:
    identifier = (body or {}).get("identifier")
    if not identifier:
        raise HTTPException(status_code=400, detail="identifier required")
    try:
        return await pair_manager.start(identifier)
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))


@app.post("/api/pair/{session_id}/pin")
async def pair_pin(session_id: str, body: dict[str, Any]) -> dict[str, Any]:
    pin = (body or {}).get("pin", "")
    try:
        return await pair_manager.submit_pin(session_id, pin)
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))


@app.post("/api/pair/{session_id}/cancel")
async def pair_cancel(session_id: str) -> CommandResponse:
    await pair_manager.cancel(session_id)
    return CommandResponse(ok=True)


@app.post("/api/command/{command}", response_model=CommandResponse)
async def send_command(command: str, body: dict[str, Any] | None = None) -> CommandResponse:
    try:
        await manager.send(command, **(body or {}))
        return CommandResponse(ok=True)
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))


@app.get("/api/playing", response_model=PlayingState)
async def get_playing() -> PlayingState:
    return await manager.get_playing()


# --- Keyboard -------------------------------------------------------------

@app.get("/api/keyboard")
async def keyboard_state() -> dict[str, Any]:
    return await manager.keyboard_state()


@app.post("/api/keyboard", response_model=CommandResponse)
async def keyboard_set(body: dict[str, Any]) -> CommandResponse:
    text = (body or {}).get("text", "")
    try:
        await manager.keyboard_set(text)
        return CommandResponse(ok=True)
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))


@app.post("/api/keyboard/append", response_model=CommandResponse)
async def keyboard_append(body: dict[str, Any]) -> CommandResponse:
    text = (body or {}).get("text", "")
    try:
        await manager.keyboard_append(text)
        return CommandResponse(ok=True)
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))


@app.post("/api/keyboard/clear", response_model=CommandResponse)
async def keyboard_clear() -> CommandResponse:
    try:
        await manager.keyboard_clear()
        return CommandResponse(ok=True)
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))


@app.get("/api/artwork")
async def get_artwork() -> Response:
    art = await manager.get_artwork()
    if art is None:
        raise HTTPException(status_code=404, detail="No artwork")
    data, mime = art
    return Response(content=data, media_type=mime, headers={"Cache-Control": "no-store"})


@app.websocket("/ws/state")
async def state_socket(ws: WebSocket) -> None:
    await ws.accept()
    queue: asyncio.Queue[dict[str, Any]] = asyncio.Queue()

    async def push(state: dict[str, Any]) -> None:
        await queue.put(state)

    manager.subscribe(push)

    try:
        if manager.connected:
            try:
                initial = (await manager.get_playing()).model_dump()
                await ws.send_text(json.dumps({"type": "playing", "state": initial}))
            except Exception as e:
                log.warning("initial state error: %s", e)
            try:
                kbd = await manager.keyboard_state()
                await ws.send_text(json.dumps({
                    "type": "keyboard",
                    "focused": kbd.get("focused", False),
                    "focus_state": kbd.get("focus_state"),
                    "text": kbd.get("text"),
                }))
            except Exception as e:
                log.warning("initial keyboard state error: %s", e)

        while True:
            payload = await queue.get()
            await ws.send_text(json.dumps(payload))
    except WebSocketDisconnect:
        pass
    finally:
        manager.unsubscribe(push)


if FRONTEND_DIR.exists():
    app.mount("/", StaticFiles(directory=str(FRONTEND_DIR), html=True), name="frontend")
