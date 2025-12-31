"""Ghostty MCP - Python API and MCP server for Ghostty terminal automation."""

from ghostty_mcp.client import (
    AsyncGhosttyClient,
    ConnectionError,
    GhosttyClient,
    GhosttyError,
    IPCError,
    ScreenContent,
    Surface,
    Tab,
    Window,
)

__all__ = [
    "AsyncGhosttyClient",
    "ConnectionError",
    "GhosttyClient",
    "GhosttyError",
    "IPCError",
    "ScreenContent",
    "Surface",
    "Tab",
    "Window",
]
__version__ = "0.1.0"
