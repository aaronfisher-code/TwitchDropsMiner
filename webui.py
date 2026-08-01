from __future__ import annotations

import logging
import os
from base64 import b64decode
from collections import deque
from datetime import datetime, timezone
from hmac import compare_digest
from pathlib import Path
from typing import Any, TYPE_CHECKING

from aiohttp import web

from constants import PriorityMode, State

if TYPE_CHECKING:
    from inventory import DropsCampaign, TimedDrop
    from twitch import Twitch


class _DashboardLogHandler(logging.Handler):
    def __init__(self, dashboard: WebUI):
        super().__init__(logging.WARNING)
        self._dashboard = dashboard

    def emit(self, record: logging.LogRecord) -> None:
        try:
            message = self.format(record)
            self._dashboard.add_message(message, level=record.levelname, source="log")
        except Exception:
            self.handleError(record)


class WebUI:
    """Small, dependency-free dashboard served by the app's aiohttp runtime."""

    def __init__(self, twitch: Twitch):
        self._twitch = twitch
        self._host = os.environ.get("TDM_WEBUI_HOST", "127.0.0.1")
        try:
            self._port = int(os.environ.get("TDM_WEBUI_PORT", "18473"))
        except ValueError as exc:
            raise ValueError("TDM_WEBUI_PORT must be an integer") from exc
        if not 1 <= self._port <= 65535:
            raise ValueError("TDM_WEBUI_PORT must be between 1 and 65535")

        self._username = os.environ.get("TDM_WEBUI_USERNAME", "admin")
        self._password = os.environ.get("TDM_WEBUI_PASSWORD", "")
        try:
            self._novnc_port = int(os.environ.get("TDM_NOVNC_PORT", "6080"))
        except ValueError as exc:
            raise ValueError("TDM_NOVNC_PORT must be an integer") from exc
        self._started_at = datetime.now(timezone.utc)
        self._phase = "starting"
        self._fatal_error: str | None = None
        self._last_watch_at: datetime | None = None
        self._last_watch_success: bool | None = None
        self._consecutive_watch_failures = 0
        self._last_progress_at: datetime | None = None
        self._events: deque[dict[str, str]] = deque(maxlen=250)
        self._runner: web.AppRunner | None = None
        self._site: web.TCPSite | None = None
        self._log_handler = _DashboardLogHandler(self)
        self._log_handler.setFormatter(logging.Formatter("%(name)s: %(message)s"))

    @property
    def address(self) -> str:
        return f"http://{self._host}:{self._port}"

    def add_message(self, message: str, *, level: str = "INFO", source: str = "app") -> None:
        message = str(message).strip()
        if not message:
            return
        self._events.append(
            {
                "timestamp": datetime.now(timezone.utc).isoformat(timespec="seconds"),
                "level": level.upper(),
                "source": source,
                "message": message[-12000:],
            }
        )

    def mark_running(self) -> None:
        self._phase = "running"
        self._fatal_error = None
        self.add_message("Web dashboard started", source="webui")

    def mark_error(self, message: str) -> None:
        self._phase = "error"
        self._fatal_error = str(message).strip()[-12000:]
        self.add_message(self._fatal_error, level="ERROR", source="runtime")

    def mark_stopping(self) -> None:
        if self._phase != "error":
            self._phase = "stopping"

    def record_watch(self, succeeded: bool) -> None:
        self._last_watch_at = datetime.now(timezone.utc)
        self._last_watch_success = succeeded
        if succeeded:
            self._consecutive_watch_failures = 0
        else:
            self._consecutive_watch_failures += 1

    def record_progress(self) -> None:
        self._last_progress_at = datetime.now(timezone.utc)

    async def start(self) -> None:
        app = web.Application(middlewares=[self._security_middleware])
        app.router.add_get("/", self._index)
        app.router.add_get("/api/health", self._health)
        app.router.add_get("/api/status", self._status)
        app.router.add_get("/api/settings", self._get_settings)
        app.router.add_put("/api/settings", self._update_settings)
        app.router.add_post("/api/actions/reload", self._reload)

        self._runner = web.AppRunner(app, access_log=None)
        await self._runner.setup()
        self._site = web.TCPSite(self._runner, self._host, self._port)
        await self._site.start()
        logging.getLogger("TwitchDrops").addHandler(self._log_handler)

    async def stop(self) -> None:
        logging.getLogger("TwitchDrops").removeHandler(self._log_handler)
        if self._runner is not None:
            await self._runner.cleanup()
            self._runner = None
            self._site = None

    def _is_authorized(self, request: web.Request) -> bool:
        if not self._password:
            return True
        scheme, _, encoded = request.headers.get("Authorization", "").partition(" ")
        if scheme.lower() != "basic" or not encoded:
            return False
        try:
            decoded = b64decode(encoded, validate=True).decode("utf8")
            username, separator, password = decoded.partition(":")
        except (ValueError, UnicodeDecodeError):
            return False
        return bool(separator) and compare_digest(username, self._username) and compare_digest(
            password, self._password
        )

    @web.middleware
    async def _security_middleware(
        self, request: web.Request, handler: Any
    ) -> web.StreamResponse:
        if request.path != "/api/health" and not self._is_authorized(request):
            response: web.StreamResponse = web.Response(
                status=401,
                text="Authentication required",
                headers={"WWW-Authenticate": 'Basic realm="Twitch Drops Miner"'},
            )
        else:
            response = await handler(request)
        response.headers["Cache-Control"] = "no-store"
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["X-Frame-Options"] = "DENY"
        response.headers["Referrer-Policy"] = "no-referrer"
        response.headers["Content-Security-Policy"] = (
            "default-src 'self'; style-src 'self' 'unsafe-inline'; "
            "script-src 'self' 'unsafe-inline'; img-src 'self' data:; "
            "connect-src 'self'; frame-ancestors 'none'"
        )
        return response

    async def _index(self, request: web.Request) -> web.FileResponse:
        return web.FileResponse(Path(__file__).with_name("webui.html"))

    async def _health(self, request: web.Request) -> web.Response:
        healthy = self._phase == "running"
        payload = {
            "healthy": healthy,
            "phase": self._phase,
            "state": self._twitch._state.name.lower(),
            "logged_in": self._twitch._auth_state._logged_in.is_set(),
            "watching": self._twitch.watching_channel.has_value(),
            "error": self._fatal_error,
        }
        return web.json_response(payload, status=200 if healthy else 503)

    async def _status(self, request: web.Request) -> web.Response:
        return web.json_response(self._snapshot())

    async def _get_settings(self, request: web.Request) -> web.Response:
        return web.json_response(self._settings_snapshot())

    async def _reload(self, request: web.Request) -> web.Response:
        self._twitch.change_state(State.INVENTORY_FETCH)
        self.add_message("Inventory reload requested from the web dashboard", source="webui")
        return web.json_response({"ok": True})

    async def _update_settings(self, request: web.Request) -> web.Response:
        if request.content_type != "application/json":
            raise web.HTTPUnsupportedMediaType(text="Expected application/json")
        try:
            data = await request.json()
        except ValueError as exc:
            raise web.HTTPBadRequest(text="Invalid JSON") from exc
        if not isinstance(data, dict):
            raise web.HTTPBadRequest(text="Settings must be a JSON object")

        allowed = {
            "priority",
            "exclude",
            "priority_mode",
            "connection_quality",
            "dark_mode",
            "tray_notifications",
            "enable_badges_emotes",
            "available_drops_check",
        }
        unknown = set(data).difference(allowed)
        if unknown:
            raise web.HTTPBadRequest(text=f"Unknown settings: {', '.join(sorted(unknown))}")

        settings = self._twitch.settings
        if "priority" in data:
            settings.priority = self._string_list(data["priority"], "priority")
        if "exclude" in data:
            settings.exclude = set(self._string_list(data["exclude"], "exclude"))
        if "priority_mode" in data:
            mode = data["priority_mode"]
            try:
                settings.priority_mode = PriorityMode[str(mode)]
            except KeyError as exc:
                raise web.HTTPBadRequest(text="Invalid priority_mode") from exc
        if "connection_quality" in data:
            quality = data["connection_quality"]
            if isinstance(quality, bool) or not isinstance(quality, int) or not 1 <= quality <= 6:
                raise web.HTTPBadRequest(text="connection_quality must be an integer from 1 to 6")
            settings.connection_quality = quality

        for field in (
            "dark_mode",
            "tray_notifications",
            "enable_badges_emotes",
            "available_drops_check",
        ):
            if field in data:
                if not isinstance(data[field], bool):
                    raise web.HTTPBadRequest(text=f"{field} must be a boolean")
                setattr(settings, field, data[field])

        settings.save(force=True)
        self._twitch.gui.settings.sync_from_settings()
        self._twitch.gui.apply_theme(settings.dark_mode)
        self.add_message("Settings saved from the web dashboard; restarting miner", source="webui")
        self._twitch.change_state(State.RESTART)
        return web.json_response({"ok": True, "settings": self._settings_snapshot()})

    @staticmethod
    def _string_list(value: Any, field: str) -> list[str]:
        if not isinstance(value, list) or len(value) > 200:
            raise web.HTTPBadRequest(text=f"{field} must be a list with at most 200 items")
        result: list[str] = []
        for item in value:
            if not isinstance(item, str):
                raise web.HTTPBadRequest(text=f"Every {field} item must be a string")
            item = item.strip()
            if not item or len(item) > 100:
                raise web.HTTPBadRequest(text=f"Every {field} item must be 1-100 characters")
            if item not in result:
                result.append(item)
        return result

    def _settings_snapshot(self) -> dict[str, Any]:
        settings = self._twitch.settings
        return {
            "priority": list(settings.priority),
            "exclude": sorted(settings.exclude),
            "priority_mode": settings.priority_mode.name,
            "priority_modes": [mode.name for mode in PriorityMode],
            "connection_quality": settings.connection_quality,
            "dark_mode": settings.dark_mode,
            "tray_notifications": settings.tray_notifications,
            "enable_badges_emotes": settings.enable_badges_emotes,
            "available_drops_check": settings.available_drops_check,
            "language": settings.language,
            "proxy_configured": bool(settings.proxy),
        }

    def _snapshot(self) -> dict[str, Any]:
        twitch = self._twitch
        watching = twitch.watching_channel.get_with_default(None)
        drop = twitch.gui.progress._drop
        websockets = twitch.websocket.websockets

        try:
            desktop_status = str(twitch.gui.status._label.cget("text"))
        except Exception:
            desktop_status = ""

        campaigns = sorted(
            twitch.inventory,
            key=lambda campaign: (not campaign.active, campaign.ends_at),
        )
        return {
            "timestamp": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "uptime_seconds": int(
                (datetime.now(timezone.utc) - self._started_at).total_seconds()
            ),
            "phase": self._phase,
            "healthy": self._phase == "running",
            "fatal_error": self._fatal_error,
            "state": twitch._state.name,
            "desktop_status": desktop_status,
            "logged_in": twitch._auth_state._logged_in.is_set(),
            "user_id": getattr(twitch._auth_state, "user_id", None),
            "watching": self._channel_snapshot(watching),
            "active_drop": self._drop_snapshot(drop),
            "channels": {
                "total": len(twitch.channels),
                "online": sum(channel.online for channel in twitch.channels.values()),
                "wanted_games": [game.name for game in twitch.wanted_games],
            },
            "activity": {
                "last_watch_at": (
                    self._last_watch_at.isoformat() if self._last_watch_at is not None else None
                ),
                "last_watch_success": self._last_watch_success,
                "consecutive_watch_failures": self._consecutive_watch_failures,
                "last_progress_at": (
                    self._last_progress_at.isoformat()
                    if self._last_progress_at is not None
                    else None
                ),
            },
            "websockets": {
                "running": twitch.websocket.running,
                "connected": sum(socket.connected for socket in websockets),
                "total": len(websockets),
                "topics": sum(len(socket.topics) for socket in websockets),
            },
            "campaigns": [self._campaign_snapshot(campaign) for campaign in campaigns[:60]],
            "events": list(self._events),
            "settings": self._settings_snapshot(),
            "novnc_port": self._novnc_port,
        }

    @staticmethod
    def _channel_snapshot(channel: Any) -> dict[str, Any] | None:
        if channel is None:
            return None
        return {
            "id": channel.id,
            "name": channel.name,
            "url": str(channel.url),
            "online": channel.online,
            "game": channel.game.name if channel.game is not None else None,
            "viewers": channel.viewers,
            "drops_enabled": channel.drops_enabled,
        }

    @staticmethod
    def _drop_snapshot(drop: TimedDrop | None) -> dict[str, Any] | None:
        if drop is None:
            return None
        return {
            "id": drop.id,
            "name": drop.name,
            "rewards": drop.rewards_text(),
            "progress": drop.progress,
            "current_minutes": drop.current_minutes,
            "required_minutes": drop.required_minutes,
            "remaining_minutes": max(drop.remaining_minutes, 0),
            "claimed": drop.is_claimed,
            "can_claim": drop.can_claim,
            "campaign": drop.campaign.name,
            "game": drop.campaign.game.name,
            "campaign_progress": drop.campaign.progress,
            "campaign_claimed": drop.campaign.claimed_drops,
            "campaign_total": drop.campaign.total_drops,
            "campaign_remaining_minutes": max(drop.campaign.remaining_minutes, 0),
            "ends_at": drop.ends_at.isoformat(),
        }

    @classmethod
    def _campaign_snapshot(cls, campaign: DropsCampaign) -> dict[str, Any]:
        return {
            "id": campaign.id,
            "name": campaign.name,
            "game": campaign.game.name,
            "active": campaign.active,
            "upcoming": campaign.upcoming,
            "expired": campaign.expired,
            "linked": campaign.linked,
            "eligible": campaign.eligible,
            "progress": campaign.progress,
            "claimed_drops": campaign.claimed_drops,
            "total_drops": campaign.total_drops,
            "remaining_minutes": max(campaign.remaining_minutes, 0),
            "starts_at": campaign.starts_at.isoformat(),
            "ends_at": campaign.ends_at.isoformat(),
            "drops": [cls._drop_snapshot(drop) for drop in campaign.drops],
        }
