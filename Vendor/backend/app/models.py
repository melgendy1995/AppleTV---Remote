from __future__ import annotations

from typing import Any

from pydantic import BaseModel


class DeviceInfo(BaseModel):
    identifier: str
    name: str
    address: str
    model: str | None = None
    services: list[str] = []
    is_paired: bool = False


class PlayingState(BaseModel):
    device_state: str | None = None
    media_type: str | None = None
    title: str | None = None
    artist: str | None = None
    album: str | None = None
    app: str | None = None
    position: int | None = None
    total_time: int | None = None
    volume: float | None = None
    artwork_url: str | None = None


class CommandResponse(BaseModel):
    ok: bool
    error: str | None = None
    detail: Any | None = None
