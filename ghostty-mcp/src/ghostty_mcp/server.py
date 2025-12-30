"""MCP server for Ghostty terminal automation.

This server exposes Ghostty's IPC capabilities to AI assistants via MCP.
It provides two tools:
  - `terminals`: List all terminal surfaces
  - `terminal`: Interact with a specific terminal (read, write, control)

Example usage with Claude Code:
    Add to ~/.claude/mcp_settings.json:
    {
      "mcpServers": {
        "ghostty": {
          "command": "ghostty-mcp"
        }
      }
    }
"""

from __future__ import annotations

import base64
import json
from enum import Enum

from fastmcp import FastMCP

from ghostty_mcp.client import GhosttyClient, GhosttyError

# Create the MCP server
mcp = FastMCP(
    name="ghostty",
    instructions="""Ghostty Terminal Automation Server

This server provides control over Ghostty terminal windows via IPC.

Workflow:
1. Use `terminals` to discover available terminal surfaces
2. Use `terminal` with a surface_id to interact with specific terminals

Each surface has a unique ID like "0x153872000". Use these IDs to target
specific terminals for commands.

Tips:
- Use action="read" to see what's on screen before sending commands
- Use action="send" with text ending in "\\r" to execute commands
- Use action="screenshot" to capture terminal state as an image
""",
)


class TerminalAction(str, Enum):
    """Actions that can be performed on a terminal."""

    READ = "read"  # Get screen content
    SEND = "send"  # Send text/keystrokes
    SCREENSHOT = "screenshot"  # Capture as PNG
    FOCUS = "focus"  # Bring window to front
    CLOSE = "close"  # Close the terminal
    RESIZE = "resize"  # Change terminal dimensions
    NEW_TAB = "new_tab"  # Open new tab
    NEW_WINDOW = "new_window"  # Open new window


def _get_client() -> GhosttyClient:
    """Get a connected Ghostty client."""
    client = GhosttyClient()
    client.connect()
    return client


@mcp.tool()
def terminals() -> str:
    """List all Ghostty terminal surfaces.

    Returns a list of all open terminals with their IDs, titles, dimensions,
    and focus state. Use the surface IDs with the `terminal` tool to interact
    with specific terminals.

    Returns:
        JSON array of terminal surfaces with id, title, rows, cols, focused, pwd.
    """
    try:
        with GhosttyClient() as client:
            surfaces = client.list_surfaces()
            result = [
                {
                    "id": s.id,
                    "title": s.title,
                    "rows": s.rows,
                    "cols": s.cols,
                    "focused": s.focused,
                    "pwd": s.pwd,
                }
                for s in surfaces
            ]
            return json.dumps(result, indent=2)
    except GhosttyError as e:
        return json.dumps({"error": str(e)})


@mcp.tool()
def terminal(
    action: TerminalAction,
    surface_id: str | None = None,
    text: str | None = None,
    text_b64: str | None = None,
    screen_type: str = "viewport",
    output_path: str | None = None,
    rows: int | None = None,
    cols: int | None = None,
    command: list[str] | None = None,
) -> str:
    """Interact with a Ghostty terminal.

    Actions:
    - read: Get screen content (requires surface_id)
    - send: Send text to terminal (requires surface_id, text or text_b64)
    - screenshot: Capture terminal as PNG (requires surface_id, output_path)
    - focus: Bring terminal window to front (requires surface_id)
    - close: Close the terminal (requires surface_id)
    - resize: Change terminal size (requires surface_id, rows and/or cols)
    - new_tab: Open a new tab (optional command)
    - new_window: Open a new window (optional command)

    Args:
        action: The action to perform
        surface_id: Target terminal ID (from `terminals` tool). Required for most actions.
        text: Text to send (for "send" action). Use \\r for Enter, \\n for newline.
        text_b64: Base64-encoded text to send (for "send" action). Use this for exact byte
            sequences without escape processing. Takes precedence over text.
        screen_type: "viewport" for visible content, "screen" for full scrollback
        output_path: Path to save screenshot PNG (for "screenshot" action)
        rows: Number of rows (for "resize" action)
        cols: Number of columns (for "resize" action)
        command: Command to run in new tab/window (for "new_tab"/"new_window" actions)

    Returns:
        JSON response with result or error.
    """
    try:
        with GhosttyClient() as client:
            match action:
                case TerminalAction.READ:
                    if not surface_id:
                        return json.dumps({"error": "surface_id required for read action"})
                    content = client.get_screen(surface_id, screen_type)
                    return json.dumps(
                        {
                            "content": content.text,
                            "cursor": {"x": content.cursor_x, "y": content.cursor_y},
                        },
                        indent=2,
                    )

                case TerminalAction.SEND:
                    if not surface_id:
                        return json.dumps({"error": "surface_id required for send action"})
                    if text_b64:
                        # Base64 mode: decode and send raw bytes (no escape processing)
                        decoded = base64.b64decode(text_b64).decode("utf-8")
                        client.send_text_raw(surface_id, decoded)
                        return json.dumps({"ok": True, "sent_b64": True, "length": len(decoded)})
                    elif text:
                        # Legacy mode: process escape sequences
                        client.send_text(surface_id, text)
                        return json.dumps({"ok": True, "sent": text})
                    else:
                        return json.dumps({"error": "text or text_b64 required for send action"})

                case TerminalAction.SCREENSHOT:
                    if not surface_id:
                        return json.dumps({"error": "surface_id required for screenshot action"})
                    if not output_path:
                        return json.dumps({"error": "output_path required for screenshot action"})
                    path = client.screenshot(surface_id, output_path)
                    return json.dumps({"ok": True, "path": str(path)})

                case TerminalAction.FOCUS:
                    if not surface_id:
                        return json.dumps({"error": "surface_id required for focus action"})
                    client.focus_surface(surface_id)
                    return json.dumps({"ok": True})

                case TerminalAction.CLOSE:
                    if not surface_id:
                        return json.dumps({"error": "surface_id required for close action"})
                    client.close_surface(surface_id)
                    return json.dumps({"ok": True})

                case TerminalAction.RESIZE:
                    if not surface_id:
                        return json.dumps({"error": "surface_id required for resize action"})
                    if rows is None and cols is None:
                        return json.dumps({"error": "rows and/or cols required for resize action"})
                    client.resize_surface(surface_id, rows, cols)
                    return json.dumps({"ok": True, "rows": rows, "cols": cols})

                case TerminalAction.NEW_TAB:
                    client.new_tab(command)
                    return json.dumps({"ok": True, "action": "new_tab"})

                case TerminalAction.NEW_WINDOW:
                    client.new_window(command)
                    return json.dumps({"ok": True, "action": "new_window"})

                case _:
                    return json.dumps({"error": f"Unknown action: {action}"})

    except GhosttyError as e:
        return json.dumps({"error": str(e)})


def main() -> None:
    """Run the MCP server."""
    mcp.run()


if __name__ == "__main__":
    main()
