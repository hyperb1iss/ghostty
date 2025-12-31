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

from ghostty_mcp.client import AsyncGhosttyClient, GhosttyError

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
- Use action="send" with text="command" and execute=true to run commands
- Use action="mouse" with x, y, button="left", button_action="press"/"release" for clicks
- Use action="scroll" with scroll_y=-3 to scroll up, scroll_y=3 to scroll down
- Use action="screenshot" to capture terminal state as an image
- Use text_b64 for exact byte sequences (e.g., control characters, binary data)
""",
)


class TerminalAction(str, Enum):
    """Actions that can be performed on a terminal."""

    READ = "read"  # Get screen content
    SEND = "send"  # Send text/keystrokes
    MOUSE = "mouse"  # Send mouse event
    SCROLL = "scroll"  # Send scroll event
    SCREENSHOT = "screenshot"  # Capture as PNG
    FOCUS = "focus"  # Bring window to front
    CLOSE = "close"  # Close the terminal
    RESIZE = "resize"  # Change terminal dimensions
    NEW_TAB = "new_tab"  # Open new tab
    NEW_WINDOW = "new_window"  # Open new window


@mcp.tool()
async def terminals() -> str:
    """List all Ghostty terminal surfaces.

    Returns a list of all open terminals with their IDs, titles, dimensions,
    and focus state. Use the surface IDs with the `terminal` tool to interact
    with specific terminals.

    Returns:
        JSON array of terminal surfaces with id, title, rows, cols, focused, pwd.
    """
    try:
        async with AsyncGhosttyClient() as client:
            surfaces = await client.list_surfaces()
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
async def terminal(
    action: TerminalAction,
    surface_id: str | None = None,
    text: str | None = None,
    text_b64: str | None = None,
    execute: bool = False,
    screen_type: str = "viewport",
    output_path: str | None = None,
    rows: int | None = None,
    cols: int | None = None,
    command: list[str] | None = None,
    x: float | None = None,
    y: float | None = None,
    button: str | None = None,
    button_action: str | None = None,
    mods: str | None = None,
    scroll_x: float | None = None,
    scroll_y: float | None = None,
) -> str:
    """Interact with a Ghostty terminal.

    Actions:
    - read: Get screen content (requires surface_id)
    - send: Send text to terminal (requires surface_id, text or text_b64)
    - mouse: Send mouse event (requires surface_id, x, y; optional button, button_action, mods)
    - scroll: Send scroll event (requires surface_id; scroll_x and/or scroll_y for deltas)
    - screenshot: Capture terminal as PNG (requires surface_id, output_path)
    - focus: Bring terminal window to front (requires surface_id)
    - close: Close the terminal (requires surface_id)
    - resize: Change terminal size (requires surface_id, rows and/or cols)
    - new_tab: Open a new tab (optional command)
    - new_window: Open a new window (optional command)

    Args:
        action: The action to perform
        surface_id: Target terminal ID (from `terminals` tool). Required for most actions.
        text: Text to send (for "send" action). Sent as-is to the terminal.
        text_b64: Base64-encoded text to send (for "send" action). Use for exact byte
            sequences. Takes precedence over text.
        execute: If True, append Enter (carriage return) after text to run as command.
        screen_type: "viewport" for visible content, "screen" for full scrollback
        output_path: Path to save screenshot PNG (for "screenshot" action)
        rows: Number of rows (for "resize" action)
        cols: Number of columns (for "resize" action)
        command: Command to run in new tab/window (for "new_tab"/"new_window" actions)
        x: X position in pixels for mouse action
        y: Y position in pixels for mouse action
        button: Mouse button - "left", "right", "middle". If None, motion-only event.
        button_action: "press" or "release". Required if button is set.
        mods: Comma-separated modifiers - "shift", "ctrl", "alt", "super"
        scroll_x: Horizontal scroll delta (for "scroll" action). Positive = right.
        scroll_y: Vertical scroll delta (for "scroll" action). Positive = down/up varies by app.

    Returns:
        JSON response with result or error.
    """
    try:
        async with AsyncGhosttyClient() as client:
            match action:
                case TerminalAction.READ:
                    if not surface_id:
                        return json.dumps({"error": "surface_id required for read action"})
                    content = await client.get_screen(surface_id, screen_type)
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
                        # Base64 mode: decode and send exact bytes
                        decoded = base64.b64decode(text_b64).decode("utf-8")
                        if execute:
                            decoded += "\r"
                        await client.send_text(surface_id, decoded)
                        return json.dumps({"ok": True, "sent_b64": True, "length": len(decoded)})
                    elif text:
                        to_send = text + "\r" if execute else text
                        await client.send_text(surface_id, to_send)
                        return json.dumps({"ok": True, "sent": text, "executed": execute})
                    else:
                        return json.dumps({"error": "text or text_b64 required for send action"})

                case TerminalAction.MOUSE:
                    if not surface_id:
                        return json.dumps({"error": "surface_id required for mouse action"})
                    if x is None or y is None:
                        return json.dumps({"error": "x and y required for mouse action"})
                    await client.send_mouse(surface_id, x, y, button, button_action, mods)
                    return json.dumps({
                        "ok": True,
                        "x": x,
                        "y": y,
                        "button": button,
                        "button_action": button_action,
                    })

                case TerminalAction.SCROLL:
                    if not surface_id:
                        return json.dumps({"error": "surface_id required for scroll action"})
                    sx = scroll_x if scroll_x is not None else 0.0
                    sy = scroll_y if scroll_y is not None else 0.0
                    await client.send_scroll(surface_id, sx, sy, mods)
                    return json.dumps({
                        "ok": True,
                        "scroll_x": sx,
                        "scroll_y": sy,
                    })

                case TerminalAction.SCREENSHOT:
                    if not surface_id:
                        return json.dumps({"error": "surface_id required for screenshot action"})
                    if not output_path:
                        return json.dumps({"error": "output_path required for screenshot action"})
                    path = await client.screenshot(surface_id, output_path)
                    return json.dumps({"ok": True, "path": str(path)})

                case TerminalAction.FOCUS:
                    if not surface_id:
                        return json.dumps({"error": "surface_id required for focus action"})
                    await client.focus_surface(surface_id)
                    return json.dumps({"ok": True})

                case TerminalAction.CLOSE:
                    if not surface_id:
                        return json.dumps({"error": "surface_id required for close action"})
                    await client.close_surface(surface_id)
                    return json.dumps({"ok": True})

                case TerminalAction.RESIZE:
                    if not surface_id:
                        return json.dumps({"error": "surface_id required for resize action"})
                    if rows is None and cols is None:
                        return json.dumps({"error": "rows and/or cols required for resize action"})
                    await client.resize_surface(surface_id, rows, cols)
                    return json.dumps({"ok": True, "rows": rows, "cols": cols})

                case TerminalAction.NEW_TAB:
                    await client.new_tab(command)
                    return json.dumps({"ok": True, "action": "new_tab"})

                case TerminalAction.NEW_WINDOW:
                    await client.new_window(command)
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
