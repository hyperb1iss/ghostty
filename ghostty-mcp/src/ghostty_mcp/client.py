"""Python client for Ghostty IPC protocol.

This module provides both sync and async Python APIs for controlling Ghostty
terminals via the Unix socket IPC protocol.

Sync Example:
    >>> from ghostty_mcp import GhosttyClient
    >>>
    >>> with GhosttyClient() as ghostty:
    ...     surfaces = ghostty.list_surfaces()
    ...     ghostty.send_text(surfaces[0].id, "echo hello\\r")

Async Example:
    >>> from ghostty_mcp import AsyncGhosttyClient
    >>>
    >>> async with AsyncGhosttyClient() as ghostty:
    ...     surfaces = await ghostty.list_surfaces()
    ...     await ghostty.send_text(surfaces[0].id, "echo hello\\r")
"""

from __future__ import annotations

import json
import os
import socket
import struct
from dataclasses import dataclass, field
from pathlib import Path
from typing import TYPE_CHECKING, Any, cast

if TYPE_CHECKING:
    from anyio.abc import ByteStream

# =============================================================================
# Constants
# =============================================================================

PROTOCOL_VERSION = 1
MAX_MESSAGE_SIZE = 1024 * 1024  # 1MB

# =============================================================================
# Exceptions
# =============================================================================


class GhosttyError(Exception):
    """Base exception for Ghostty IPC errors."""


class ConnectionError(GhosttyError):  # noqa: A001
    """Failed to connect to Ghostty."""


class IPCError(GhosttyError):
    """IPC request failed."""


# =============================================================================
# Data Types
# =============================================================================


@dataclass
class Surface:
    """A terminal surface (a single terminal view)."""

    id: str
    title: str
    pwd: str
    focused: bool
    rows: int
    cols: int

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> Surface:
        return cls(
            id=data["id"],
            title=data.get("title", ""),
            pwd=data.get("pwd", ""),
            focused=data.get("focused", False),
            rows=data.get("rows", 24),
            cols=data.get("cols", 80),
        )


@dataclass
class Tab:
    """A tab containing one or more surfaces."""

    surfaces: list[Surface] = field(default_factory=list)

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> Tab:
        return cls(surfaces=[Surface.from_dict(s) for s in data.get("surfaces", [])])


@dataclass
class Window:
    """A window containing one or more tabs."""

    tabs: list[Tab] = field(default_factory=list)

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> Window:
        return cls(tabs=[Tab.from_dict(t) for t in data.get("tabs", [])])


@dataclass
class ScreenContent:
    """Screen content from a terminal surface."""

    text: str
    cursor_x: int
    cursor_y: int


# =============================================================================
# Shared Utilities
# =============================================================================


def _resolve_socket_path(
    socket_path: str | Path | None = None,
) -> Path:
    """Resolve the Ghostty socket path."""
    if socket_path:
        return Path(socket_path)

    uid = os.getuid()
    socket_name = "ghostty.sock"

    # Try XDG_RUNTIME_DIR first (Linux)
    if xdg_runtime := os.environ.get("XDG_RUNTIME_DIR"):
        return Path(xdg_runtime) / "ghostty" / socket_name

    # Try TMPDIR (macOS)
    if tmpdir := os.environ.get("TMPDIR"):
        return Path(tmpdir) / f"ghostty-{uid}" / socket_name

    # Fallback
    return Path(f"/tmp/ghostty-{uid}/{socket_name}")


def _extract_surfaces(response: dict[str, Any]) -> list[Surface]:
    """Extract surfaces from a list_surfaces response."""
    surfaces: list[Surface] = []
    for window_data in response.get("data", {}).get("windows", []):
        window = Window.from_dict(window_data)
        for tab in window.tabs:
            surfaces.extend(tab.surfaces)
    return surfaces


def _extract_windows(response: dict[str, Any]) -> list[Window]:
    """Extract windows from a list_surfaces response."""
    return [Window.from_dict(w) for w in response.get("data", {}).get("windows", [])]


# =============================================================================
# Sync Client
# =============================================================================


class GhosttyClient:
    """Synchronous client for Ghostty IPC protocol.

    Connects to a running Ghostty instance via Unix socket and provides
    methods to control terminals. Each request creates a fresh connection.

    Example:
        >>> with GhosttyClient() as ghostty:
        ...     surfaces = ghostty.list_surfaces()
        ...     ghostty.send_text(surfaces[0].id, "ls -la\\r")
    """

    def __init__(self, socket_path: str | Path | None = None, app_class: str | None = None):
        """Initialize the client.

        Args:
            socket_path: Path to the Ghostty socket. If None, auto-detected.
            app_class: Custom Ghostty app class to connect to.
        """
        self._socket_path = socket_path
        self._app_class = app_class

    def __enter__(self) -> GhosttyClient:
        return self

    def __exit__(self, *args: object) -> None:
        pass

    def _send_request(self, action: str, payload: dict[str, Any] | None = None) -> dict[str, Any]:
        """Send a request to Ghostty and return the response."""
        socket_path = _resolve_socket_path(self._socket_path)
        if not socket_path.exists():
            raise ConnectionError(f"Socket not found: {socket_path}")

        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(5.0)
        try:
            sock.connect(str(socket_path))

            request: dict[str, Any] = {
                "version": PROTOCOL_VERSION,
                "target": self._app_class,
                "action": {action: payload if payload else {}},
            }

            data = json.dumps(request).encode("utf-8")
            if len(data) > MAX_MESSAGE_SIZE:
                raise IPCError("Request too large")

            sock.sendall(struct.pack("<I", len(data)))
            sock.sendall(data)

            length_bytes = self._recv_exact(sock, 4)
            length = struct.unpack("<I", length_bytes)[0]

            if length > MAX_MESSAGE_SIZE:
                raise IPCError("Response too large")

            response_data = self._recv_exact(sock, length)
            response = cast(dict[str, Any], json.loads(response_data.decode("utf-8")))

            if not response.get("ok", False):
                raise IPCError(response.get("error", "Unknown error"))

            return response
        finally:
            sock.close()

    def _recv_exact(self, sock: socket.socket, n: int) -> bytes:
        """Receive exactly n bytes from a socket."""
        data = b""
        while len(data) < n:
            chunk = sock.recv(n - len(data))
            if not chunk:
                raise ConnectionError("Connection closed")
            data += chunk
        return data

    # === API Methods ===

    def list_surfaces(self) -> list[Surface]:
        """List all surfaces across all windows and tabs."""
        return _extract_surfaces(self._send_request("list_surfaces"))

    def list_windows(self) -> list[Window]:
        """List all windows with their tabs and surfaces."""
        return _extract_windows(self._send_request("list_surfaces"))

    def send_text(self, surface_id: str, text: str) -> None:
        """Send text to a surface.

        Use Python string escapes for control characters: "echo hello\\r"
        """
        self._send_request("send_text", {"surface_id": surface_id, "text": text})

    def get_screen(self, surface_id: str, screen_type: str = "viewport") -> ScreenContent:
        """Get the screen content of a surface."""
        response = self._send_request(
            "get_screen", {"surface_id": surface_id, "screen": screen_type}
        )
        data = response.get("data", {})
        return ScreenContent(
            text=data.get("content", ""),
            cursor_x=data.get("cursor_x", 0),
            cursor_y=data.get("cursor_y", 0),
        )

    def focus_surface(self, surface_id: str) -> None:
        """Focus a surface (bring its window to front)."""
        self._send_request("focus_surface", {"surface_id": surface_id})

    def close_surface(self, surface_id: str) -> None:
        """Close a surface."""
        self._send_request("close_surface", {"surface_id": surface_id})

    def resize_surface(
        self, surface_id: str, rows: int | None = None, cols: int | None = None
    ) -> None:
        """Resize a surface."""
        payload: dict[str, Any] = {"surface_id": surface_id}
        if rows is not None:
            payload["rows"] = rows
        if cols is not None:
            payload["cols"] = cols
        self._send_request("resize_surface", payload)

    def screenshot(self, surface_id: str, output_path: str | Path) -> Path:
        """Take a screenshot of a surface."""
        path = Path(output_path).resolve()
        self._send_request(
            "screenshot_surface", {"surface_id": surface_id, "output_path": str(path)}
        )
        return path

    def new_window(self, command: list[str] | None = None) -> None:
        """Open a new window."""
        payload: dict[str, Any] | None = {"arguments": command} if command else None
        self._send_request("new_window", payload)

    def new_tab(self, command: list[str] | None = None) -> None:
        """Open a new tab."""
        payload: dict[str, Any] | None = {"arguments": command} if command else None
        self._send_request("new_tab", payload)

    def get_focused_surface(self) -> Surface | None:
        """Get the currently focused surface."""
        for surface in self.list_surfaces():
            if surface.focused:
                return surface
        return None

    def run_command(self, surface_id: str, command: str) -> None:
        """Run a shell command in a surface (sends command + Enter)."""
        self.send_text(surface_id, command + "\r")

    def send_mouse(
        self,
        surface_id: str,
        x: float,
        y: float,
        button: str | None = None,
        button_action: str | None = None,
        mods: str | None = None,
    ) -> None:
        """Send a mouse event to a surface.

        Args:
            surface_id: Target surface ID.
            x: X position in pixels (relative to surface origin).
            y: Y position in pixels (relative to surface origin).
            button: Mouse button - "left", "right", "middle", "four", "five", etc.
                    If None, sends a motion-only event.
            button_action: "press" or "release". Required if button is set.
            mods: Comma-separated modifiers - "shift", "ctrl", "alt", "super".
        """
        payload: dict[str, Any] = {"surface_id": surface_id, "x": x, "y": y}
        if button is not None:
            payload["button"] = button
        if button_action is not None:
            payload["button_action"] = button_action
        if mods is not None:
            payload["mods"] = mods
        self._send_request("send_mouse", payload)

    def click(
        self,
        surface_id: str,
        x: float,
        y: float,
        button: str = "left",
        mods: str | None = None,
    ) -> None:
        """Click at a position (press + release).

        Args:
            surface_id: Target surface ID.
            x: X position in pixels.
            y: Y position in pixels.
            button: Mouse button (default: "left").
            mods: Comma-separated modifiers.
        """
        self.send_mouse(surface_id, x, y, button, "press", mods)
        self.send_mouse(surface_id, x, y, button, "release", mods)


# =============================================================================
# Async Client
# =============================================================================


class AsyncGhosttyClient:
    """Asynchronous client for Ghostty IPC protocol.

    Fully async implementation using anyio for non-blocking socket I/O.

    Example:
        >>> async with AsyncGhosttyClient() as ghostty:
        ...     surfaces = await ghostty.list_surfaces()
        ...     await ghostty.send_text(surfaces[0].id, "ls -la\\r")
    """

    def __init__(self, socket_path: str | Path | None = None, app_class: str | None = None):
        """Initialize the client.

        Args:
            socket_path: Path to the Ghostty socket. If None, auto-detected.
            app_class: Custom Ghostty app class to connect to.
        """
        self._socket_path = socket_path
        self._app_class = app_class

    async def __aenter__(self) -> AsyncGhosttyClient:
        return self

    async def __aexit__(self, *args: object) -> None:
        pass

    async def _send_request(
        self, action: str, payload: dict[str, Any] | None = None
    ) -> dict[str, Any]:
        """Send a request to Ghostty and return the response."""
        import anyio

        socket_path = _resolve_socket_path(self._socket_path)
        if not socket_path.exists():
            raise ConnectionError(f"Socket not found: {socket_path}")

        stream: ByteStream = await anyio.connect_unix(str(socket_path))
        try:
            request: dict[str, Any] = {
                "version": PROTOCOL_VERSION,
                "target": self._app_class,
                "action": {action: payload if payload else {}},
            }

            data = json.dumps(request).encode("utf-8")
            if len(data) > MAX_MESSAGE_SIZE:
                raise IPCError("Request too large")

            await stream.send(struct.pack("<I", len(data)) + data)

            length_bytes = await self._recv_exact(stream, 4)
            length = struct.unpack("<I", length_bytes)[0]

            if length > MAX_MESSAGE_SIZE:
                raise IPCError("Response too large")

            response_data = await self._recv_exact(stream, length)
            response = cast(dict[str, Any], json.loads(response_data.decode("utf-8")))

            if not response.get("ok", False):
                raise IPCError(response.get("error", "Unknown error"))

            return response
        finally:
            await stream.aclose()

    async def _recv_exact(self, stream: ByteStream, n: int) -> bytes:
        """Receive exactly n bytes from stream."""
        data = b""
        while len(data) < n:
            chunk = await stream.receive(n - len(data))
            if not chunk:
                raise ConnectionError("Connection closed")
            data += chunk
        return data

    # === API Methods ===

    async def list_surfaces(self) -> list[Surface]:
        """List all surfaces across all windows and tabs."""
        return _extract_surfaces(await self._send_request("list_surfaces"))

    async def list_windows(self) -> list[Window]:
        """List all windows with their tabs and surfaces."""
        return _extract_windows(await self._send_request("list_surfaces"))

    async def send_text(self, surface_id: str, text: str) -> None:
        """Send text to a surface.

        Use Python string escapes for control characters: "echo hello\\r"
        """
        await self._send_request("send_text", {"surface_id": surface_id, "text": text})

    async def get_screen(self, surface_id: str, screen_type: str = "viewport") -> ScreenContent:
        """Get the screen content of a surface."""
        response = await self._send_request(
            "get_screen", {"surface_id": surface_id, "screen": screen_type}
        )
        data = response.get("data", {})
        return ScreenContent(
            text=data.get("content", ""),
            cursor_x=data.get("cursor_x", 0),
            cursor_y=data.get("cursor_y", 0),
        )

    async def focus_surface(self, surface_id: str) -> None:
        """Focus a surface (bring its window to front)."""
        await self._send_request("focus_surface", {"surface_id": surface_id})

    async def close_surface(self, surface_id: str) -> None:
        """Close a surface."""
        await self._send_request("close_surface", {"surface_id": surface_id})

    async def resize_surface(
        self, surface_id: str, rows: int | None = None, cols: int | None = None
    ) -> None:
        """Resize a surface."""
        payload: dict[str, Any] = {"surface_id": surface_id}
        if rows is not None:
            payload["rows"] = rows
        if cols is not None:
            payload["cols"] = cols
        await self._send_request("resize_surface", payload)

    async def screenshot(self, surface_id: str, output_path: str | Path) -> Path:
        """Take a screenshot of a surface."""
        path = Path(output_path).resolve()
        await self._send_request(
            "screenshot_surface", {"surface_id": surface_id, "output_path": str(path)}
        )
        return path

    async def new_window(self, command: list[str] | None = None) -> None:
        """Open a new window."""
        payload: dict[str, Any] | None = {"arguments": command} if command else None
        await self._send_request("new_window", payload)

    async def new_tab(self, command: list[str] | None = None) -> None:
        """Open a new tab."""
        payload: dict[str, Any] | None = {"arguments": command} if command else None
        await self._send_request("new_tab", payload)

    async def get_focused_surface(self) -> Surface | None:
        """Get the currently focused surface."""
        for surface in await self.list_surfaces():
            if surface.focused:
                return surface
        return None

    async def run_command(self, surface_id: str, command: str) -> None:
        """Run a shell command in a surface (sends command + Enter)."""
        await self.send_text(surface_id, command + "\r")

    async def send_mouse(
        self,
        surface_id: str,
        x: float,
        y: float,
        button: str | None = None,
        button_action: str | None = None,
        mods: str | None = None,
    ) -> None:
        """Send a mouse event to a surface.

        Args:
            surface_id: Target surface ID.
            x: X position in pixels (relative to surface origin).
            y: Y position in pixels (relative to surface origin).
            button: Mouse button - "left", "right", "middle", "four", "five", etc.
                    If None, sends a motion-only event.
            button_action: "press" or "release". Required if button is set.
            mods: Comma-separated modifiers - "shift", "ctrl", "alt", "super".
        """
        payload: dict[str, Any] = {"surface_id": surface_id, "x": x, "y": y}
        if button is not None:
            payload["button"] = button
        if button_action is not None:
            payload["button_action"] = button_action
        if mods is not None:
            payload["mods"] = mods
        await self._send_request("send_mouse", payload)

    async def click(
        self,
        surface_id: str,
        x: float,
        y: float,
        button: str = "left",
        mods: str | None = None,
    ) -> None:
        """Click at a position (press + release).

        Args:
            surface_id: Target surface ID.
            x: X position in pixels.
            y: Y position in pixels.
            button: Mouse button (default: "left").
            mods: Comma-separated modifiers.
        """
        await self.send_mouse(surface_id, x, y, button, "press", mods)
        await self.send_mouse(surface_id, x, y, button, "release", mods)
