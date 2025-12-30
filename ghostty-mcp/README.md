# ghostty-mcp

MCP server and Python API for Ghostty terminal automation.

## Installation

```bash
# Install with uv (recommended)
uv pip install -e .

# Or with pip
pip install -e .
```

## Python API Usage

```python
from ghostty_mcp import GhosttyClient

# Use as context manager
with GhosttyClient() as ghostty:
    # List all surfaces
    surfaces = ghostty.list_surfaces()
    for surface in surfaces:
        print(f"{surface.id}: {surface.title} ({surface.cols}x{surface.rows})")

    # Send a command to the first surface
    if surfaces:
        ghostty.run_command(surfaces[0].id, "echo hello")

    # Read screen content
    content = ghostty.get_screen(surfaces[0].id)
    print(content.text)

    # Take a screenshot
    ghostty.screenshot(surfaces[0].id, "/tmp/terminal.png")
```

## MCP Server

### Claude Code Integration

Add to `~/.claude/settings.json` under `mcpServers`:

```json
{
  "mcpServers": {
    "ghostty": {
      "command": "uv",
      "args": ["--directory", "/path/to/ghostty-mcp", "run", "ghostty-mcp"]
    }
  }
}
```

Or if installed globally:

```json
{
  "mcpServers": {
    "ghostty": {
      "command": "ghostty-mcp"
    }
  }
}
```

### Available Tools

#### `terminals`

List all Ghostty terminal surfaces. Returns JSON with surface IDs, titles, dimensions, and focus state.

```
Use this first to discover available terminals and get their IDs.
```

#### `terminal`

Interact with a specific terminal. Actions:

| Action | Description | Required Args |
|--------|-------------|---------------|
| `read` | Get screen content | `surface_id` |
| `send` | Send text/keystrokes | `surface_id`, `text` |
| `screenshot` | Capture as PNG | `surface_id`, `output_path` |
| `focus` | Bring window to front | `surface_id` |
| `close` | Close the terminal | `surface_id` |
| `resize` | Change dimensions | `surface_id`, `rows`/`cols` |
| `new_tab` | Open new tab | (optional `command`) |
| `new_window` | Open new window | (optional `command`) |

**Examples:**

```python
# Read screen content
terminal(action="read", surface_id="0x153872000")

# Send a command (note: \r for Enter)
terminal(action="send", surface_id="0x153872000", text="ls -la\r")

# Take a screenshot
terminal(action="screenshot", surface_id="0x153872000", output_path="/tmp/screen.png")

# Resize terminal
terminal(action="resize", surface_id="0x153872000", rows=40, cols=120)
```

## Requirements

- Python 3.10+
- Ghostty with IPC enabled (1.4.0+)
- macOS or Linux

## Development

```bash
# Install dev dependencies
uv pip install -e ".[dev]"

# Run tests
pytest

# Type check
mypy src

# Lint
ruff check src
```
