"""Python client for Ghostty IPC protocol.

This module provides a clean Python API for controlling Ghostty terminals
via the Unix socket IPC protocol.

Example:
    >>> from ghostty_mcp import GhosttyClient
    >>>
    >>> with GhosttyClient() as ghostty:
    ...     # List all surfaces
    ...     surfaces = ghostty.list_surfaces()
    ...     for surface in surfaces:
    ...         print(f"{surface.id}: {surface.title}")
    ...
    ...     # Send text to a surface
    ...     ghostty.send_text(surfaces[0].id, "echo hello\\r")
    ...
    ...     # Read screen content
    ...     content = ghostty.get_screen(surfaces[0].id)
    ...     print(content.text)
"""

from __future__ import annotations

import json
import os
import socket
import struct
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, cast


class GhosttyError(Exception):
    """Base exception for Ghostty IPC errors."""


class ConnectionError(GhosttyError):
    """Failed to connect to Ghostty."""


class IPCError(GhosttyError):
    """IPC request failed."""


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


class GhosttyClient:
    """Client for Ghostty IPC protocol.

    Connects to a running Ghostty instance via Unix socket and provides
    methods to control terminals.

    Can be used as a context manager:
        >>> with GhosttyClient() as ghostty:
        ...     surfaces = ghostty.list_surfaces()

    Or manually:
        >>> ghostty = GhosttyClient()
        >>> ghostty.connect()
        >>> surfaces = ghostty.list_surfaces()
        >>> ghostty.close()
    """

    PROTOCOL_VERSION = 1
    MAX_MESSAGE_SIZE = 1024 * 1024  # 1MB

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

    def __exit__(self, *args: Any) -> None:
        pass  # No persistent connection to close

    def connect(self) -> None:
        """Verify connection to Ghostty is possible.

        Note: Each request creates a fresh connection, so this just
        validates the socket exists.
        """
        socket_path = self._resolve_socket_path()
        if not socket_path.exists():
            raise ConnectionError(f"Socket not found: {socket_path}")

    def close(self) -> None:
        """Close the client (no-op, connections are per-request)."""
        pass

    def _resolve_socket_path(self) -> Path:
        """Resolve the socket path."""
        if self._socket_path:
            return Path(self._socket_path)

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

    def _send_request(self, action: str, payload: dict[str, Any] | None = None) -> dict[str, Any]:
        """Send a request to Ghostty and return the response.

        Each request uses a fresh connection since the server closes
        the connection after handling each request.
        """
        # Always create a fresh connection for each request
        socket_path = self._resolve_socket_path()
        if not socket_path.exists():
            raise ConnectionError(f"Socket not found: {socket_path}")

        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(5.0)  # 5 second timeout
        try:
            sock.connect(str(socket_path))

            # Build request - action is nested under "action" key
            request: dict[str, Any] = {
                "version": self.PROTOCOL_VERSION,
                "target": self._app_class,  # null for default instance
                "action": {action: payload if payload else {}},
            }

            # Serialize and send with length prefix
            data = json.dumps(request).encode("utf-8")
            if len(data) > self.MAX_MESSAGE_SIZE:
                raise IPCError("Request too large")

            sock.sendall(struct.pack("<I", len(data)))
            sock.sendall(data)

            # Read response length
            length_bytes = self._recv_exact_from(sock, 4)
            length = struct.unpack("<I", length_bytes)[0]

            if length > self.MAX_MESSAGE_SIZE:
                raise IPCError("Response too large")

            # Read response
            response_data = self._recv_exact_from(sock, length)
            response = cast(dict[str, Any], json.loads(response_data.decode("utf-8")))

            if not response.get("ok", False):
                error = response.get("error", "Unknown error")
                raise IPCError(error)

            return response
        finally:
            sock.close()

    def _recv_exact_from(self, sock: socket.socket, n: int) -> bytes:
        """Receive exactly n bytes from a socket."""
        data = b""
        while len(data) < n:
            chunk = sock.recv(n - len(data))
            if not chunk:
                raise ConnectionError("Connection closed")
            data += chunk
        return data

    # === High-level API ===

    def list_surfaces(self) -> list[Surface]:
        """List all surfaces across all windows and tabs.

        Returns:
            List of all surfaces in the Ghostty instance.
        """
        response = self._send_request("list_surfaces")
        surfaces: list[Surface] = []

        for window_data in response.get("data", {}).get("windows", []):
            window = Window.from_dict(window_data)
            for tab in window.tabs:
                surfaces.extend(tab.surfaces)

        return surfaces

    def list_windows(self) -> list[Window]:
        """List all windows with their tabs and surfaces.

        Returns:
            List of all windows in the Ghostty instance.
        """
        response = self._send_request("list_surfaces")
        return [Window.from_dict(w) for w in response.get("data", {}).get("windows", [])]

    @staticmethod
    def _process_escapes(text: str) -> str:
        """Process escape sequences in text (e.g., \\n, \\r, \\t, \\xNN)."""
        result = []
        i = 0
        while i < len(text):
            if text[i] == "\\" and i + 1 < len(text):
                next_char = text[i + 1]
                # Handle \xNN hex escapes
                if next_char == "x" and i + 3 < len(text):
                    try:
                        byte_val = int(text[i + 2 : i + 4], 16)
                        result.append(chr(byte_val))
                        i += 4
                        continue
                    except ValueError:
                        pass
                # Handle standard escapes
                escape_map = {
                    "n": "\n",
                    "r": "\r",
                    "t": "\t",
                    "a": "\x07",
                    "b": "\x08",
                    "f": "\x0c",
                    "v": "\x0b",
                    "\\": "\\",
                    "0": "\x00",
                    "e": "\x1b",
                }
                if next_char in escape_map:
                    result.append(escape_map[next_char])
                    i += 2
                    continue
            result.append(text[i])
            i += 1
        return "".join(result)

    def send_text(self, surface_id: str, text: str) -> None:
        """Send text to a surface.

        Args:
            surface_id: The surface ID (from list_surfaces).
            text: Text to send. Supports escape sequences like \\r, \\n, \\t, \\xNN.
        """
        processed = self._process_escapes(text)
        self._send_request("send_text", {"surface_id": surface_id, "text": processed})

    def send_text_raw(self, surface_id: str, text: str) -> None:
        """Send raw text to a surface without escape processing.

        Args:
            surface_id: The surface ID (from list_surfaces).
            text: Text to send exactly as-is.
        """
        self._send_request("send_text", {"surface_id": surface_id, "text": text})

    def get_screen(self, surface_id: str, screen_type: str = "viewport") -> ScreenContent:
        """Get the screen content of a surface.

        Args:
            surface_id: The surface ID (from list_surfaces).
            screen_type: "viewport" for visible content, "screen" for full scrollback.

        Returns:
            ScreenContent with text and cursor position.
        """
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
        """Focus a surface (bring its window to front).

        Args:
            surface_id: The surface ID (from list_surfaces).
        """
        self._send_request("focus_surface", {"surface_id": surface_id})

    def close_surface(self, surface_id: str) -> None:
        """Close a surface.

        Args:
            surface_id: The surface ID (from list_surfaces).
        """
        self._send_request("close_surface", {"surface_id": surface_id})

    def resize_surface(
        self, surface_id: str, rows: int | None = None, cols: int | None = None
    ) -> None:
        """Resize a surface.

        Args:
            surface_id: The surface ID (from list_surfaces).
            rows: Number of rows (if None, keep current).
            cols: Number of columns (if None, keep current).
        """
        payload: dict[str, Any] = {"surface_id": surface_id}
        if rows is not None:
            payload["rows"] = rows
        if cols is not None:
            payload["cols"] = cols
        self._send_request("resize_surface", payload)

    def screenshot(self, surface_id: str, output_path: str | Path) -> Path:
        """Take a screenshot of a surface.

        Args:
            surface_id: The surface ID (from list_surfaces).
            output_path: Path to save the PNG screenshot.

        Returns:
            Path to the saved screenshot.
        """
        path = Path(output_path).resolve()
        self._send_request(
            "screenshot_surface",
            {"surface_id": surface_id, "output_path": str(path)},
        )
        return path

    def new_window(self, command: list[str] | None = None) -> None:
        """Open a new window.

        Args:
            command: Optional command to run in the new window.
        """
        payload: dict[str, Any] = {}
        if command:
            payload["arguments"] = command
        self._send_request("new_window", payload if payload else None)

    def new_tab(self, command: list[str] | None = None) -> None:
        """Open a new tab.

        Args:
            command: Optional command to run in the new tab.
        """
        payload: dict[str, Any] = {}
        if command:
            payload["arguments"] = command
        self._send_request("new_tab", payload if payload else None)

    # === Convenience methods ===

    def get_focused_surface(self) -> Surface | None:
        """Get the currently focused surface.

        Returns:
            The focused surface, or None if no surface is focused.
        """
        for surface in self.list_surfaces():
            if surface.focused:
                return surface
        return None

    def run_command(self, surface_id: str, command: str) -> None:
        """Run a shell command in a surface.

        Sends the command followed by a carriage return.

        Args:
            surface_id: The surface ID (from list_surfaces).
            command: The shell command to run.
        """
        self.send_text(surface_id, command + "\r")
