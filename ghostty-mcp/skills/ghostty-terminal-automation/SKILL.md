---
name: ghostty-terminal-automation
description: Automate Ghostty terminal sessions via MCP. Use when you need to send commands to terminals, read terminal output, capture screenshots, resize windows, open new tabs/windows, or interact with TUI apps like Neovim, htop, or any CLI tool running in Ghostty.
---

# Ghostty Terminal Automation

Control Ghostty terminals programmatically via the MCP server. You can read screens, send keystrokes, take screenshots, and manage terminal windows.

## Available MCP Tools

### `mcp__ghostty__terminals`

List all open terminal surfaces. Returns IDs, titles, dimensions, focus state, and working directory.

```json
[
  {
    "id": "0x13604ba00",
    "title": "~/dev/project",
    "rows": 33,
    "cols": 135,
    "focused": true,
    "pwd": "/Users/bliss/dev/project"
  }
]
```

### `mcp__ghostty__terminal`

Interact with a specific terminal. Actions:

| Action       | Required Params                    | Description                            |
| ------------ | ---------------------------------- | -------------------------------------- |
| `read`       | `surface_id`                       | Get screen content and cursor position |
| `send`       | `surface_id`, `text` or `text_b64` | Send text/keystrokes                   |
| `mouse`      | `surface_id`, `x`, `y`             | Send mouse event (click, move, drag)   |
| `screenshot` | `surface_id`, `output_path`        | Capture terminal as PNG                |
| `focus`      | `surface_id`                       | Bring window to front                  |
| `close`      | `surface_id`                       | Close the terminal                     |
| `resize`     | `surface_id`, `rows`/`cols`        | Change terminal dimensions             |
| `new_tab`    | (optional `command`)               | Open new tab                           |
| `new_window` | (optional `command`)               | Open new window                        |

## Core Workflow

1. **Discover terminals** with `mcp__ghostty__terminals`
2. **Read current state** with `action="read"` to see what's on screen
3. **Send commands** with `action="send"` and `execute=true`
4. **Verify results** by reading again or taking a screenshot

## Sending Text

### Running commands (the easy way)

Use `text` with `execute=true` to run commands — it appends Enter automatically:

```
action: "send"
surface_id: "0x..."
text: "ls -la"
execute: true
```

### Typing without executing

Omit `execute` or set it to `false` to just type text without pressing Enter:

```
action: "send"
surface_id: "0x..."
text: "partial command"
```

### Exact byte sequences

Use `text_b64` for base64-encoded content when you need precise control:

```
action: "send"
surface_id: "0x..."
text_b64: "bHMgLWxhDQ=="  # "ls -la\r"
```

**Important:** The `text` parameter is sent as-is (no escape processing). Use `text_b64` for control characters like `\x1b` (Escape), `\r` (Enter), `\t` (Tab).

## Working with TUI Apps

### Neovim

For pasting code into Neovim, use **bracketed paste mode**:

1. Enter insert mode: `i`
2. Send bracketed paste start: `\x1b[200~`
3. Send content
4. Send bracketed paste end: `\x1b[201~`
5. Escape and save: `\x1b:wq\r`

Example with base64 (combine all in one send):
```
# Base64 of: i + \x1b[200~ + code + \x1b[201~
text_b64: "aRtbMjAwfnByaW50KCJoZWxsbyIpG1syMDF+"
```

Then save:
```
text_b64: "Gzp3cQo="  # \x1b:wq\n
```

### htop, btop, lazygit

These work great — just launch them and read the screen:

```
action: "send"
text: "htop"
execute: true
```

Then read to see process list, or send keys like `q` to quit.

### Interactive prompts

Read the screen first to understand state, then respond appropriately.

## Mouse Events

Many TUI apps support mouse interaction. The `mouse` action lets you click, drag, and hover.

### Clicking

Send a click (press + release) at pixel coordinates:

```
action: "mouse"
surface_id: "0x..."
x: 100
y: 200
button: "left"
button_action: "press"
```

Then immediately:

```
action: "mouse"
surface_id: "0x..."
x: 100
y: 200
button: "left"
button_action: "release"
```

### Available buttons

- `left`, `right`, `middle`
- `four`, `five` (extra mouse buttons)

### Motion events

Omit `button` to send a motion-only event (for hover effects):

```
action: "mouse"
surface_id: "0x..."
x: 150
y: 250
```

### Modifiers

Add `mods` for modified clicks (comma-separated):

```
action: "mouse"
surface_id: "0x..."
x: 100
y: 200
button: "left"
button_action: "press"
mods: "ctrl,shift"
```

### Dragging

Simulate drag by sending:
1. `press` at start position
2. Multiple motion events along the path
3. `release` at end position

### Coordinates

Coordinates are in **pixels** relative to the terminal surface origin (top-left = 0,0). To click on a specific cell, calculate: `x = col * cell_width`, `y = row * cell_height`.

## Screenshots

Capture terminal state as PNG for visual verification or sharing.

### When to use screenshots

- **Complex TUI state**: htop, nvim, lazygit — text reads can be messy
- **Verification**: Confirm a UI looks right after operations
- **Debugging**: See exactly what the user sees
- **Visual diffs**: Compare before/after states

### How to capture

```
action: "screenshot"
surface_id: "0x..."
output_path: "/tmp/capture.png"
```

### Viewing the screenshot

Use the Read tool on the path to view the image:

```
Read tool: /tmp/capture.png
```

Claude can see and analyze the terminal screenshot directly.

## Python Client

For scripting, use the async client directly:

```python
from ghostty_mcp import AsyncGhosttyClient

async with AsyncGhosttyClient() as ghostty:
    surfaces = await ghostty.list_surfaces()
    for s in surfaces:
        print(f"{s.title} ({s.rows}x{s.cols})")

    # Send a command
    await ghostty.send_text(surfaces[0].id, "echo hello\r")

    # Read screen
    content = await ghostty.get_screen(surfaces[0].id)
    print(content.text)

    # Click at position (convenience method does press + release)
    await ghostty.click(surfaces[0].id, x=100, y=200)

    # Or send individual mouse events
    await ghostty.send_mouse(surfaces[0].id, x=100, y=200, button="left", button_action="press")
    await ghostty.send_mouse(surfaces[0].id, x=100, y=200, button="left", button_action="release")
```

A sync client (`GhosttyClient`) is also available.

## Tips

- **Always discover first**: Call `terminals` before assuming surface IDs
- **Read before sending**: Check screen state to understand context
- **Use execute=true for commands**: Cleaner than manually adding `\r`
- **Use text_b64 for control chars**: Escape, tabs, special keys
- **Bracketed paste for TUIs**: Prevents input mangling in editors
- **Screenshot for verification**: Visual confirmation of complex operations

## Example: Write and Run a Script

```
1. terminals                              # Get surface ID
2. send: text="nvim /tmp/demo.py" execute=true
3. send (text_b64): i + bracketed_paste_start + code + bracketed_paste_end
4. send (text_b64): Esc + :wq + Enter
5. send: text="python /tmp/demo.py" execute=true
6. read                                   # See the output
```
