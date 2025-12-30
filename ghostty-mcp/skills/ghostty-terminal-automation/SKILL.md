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
| `screenshot` | `surface_id`, `output_path`        | Capture terminal as PNG                |
| `focus`      | `surface_id`                       | Bring window to front                  |
| `close`      | `surface_id`                       | Close the terminal                     |
| `resize`     | `surface_id`, `rows`/`cols`        | Change terminal dimensions             |
| `new_tab`    | (optional `command`)               | Open new tab                           |
| `new_window` | (optional `command`)               | Open new window                        |

## Core Workflow

1. **Discover terminals** with `mcp__ghostty__terminals`
2. **Read current state** with `action="read"` to see what's on screen
3. **Send commands** with `action="send"`
4. **Verify results** by reading again or taking a screenshot

## Sending Text

### Simple commands

Use the `text` parameter with `\r` for Enter:

```
text: "ls -la\r"
```

### Complex text (code, special chars)

Use `text_b64` for base64-encoded content to avoid escape issues:

```bash
# Compute base64 first
base64 -i /path/to/script.py
```

Then send via `text_b64` parameter.

### Special keys

- `\r` - Enter/Return
- `\x1b` - Escape (for vim normal mode)
- `\t` - Tab

## Working with TUI Apps

### Neovim

When typing code into Neovim:

1. Send `:set paste\r` first to disable auto-indent
2. Enter insert mode with `i`
3. Send content via `text_b64` (prevents escape mangling)
4. Exit with `\x1b` then save with `:wq\r`

Example flow:

```
send: ":set paste\ri"           # paste mode + insert
send (text_b64): <base64 code>  # the actual content
send: "\x1bGdd:wq\r"            # esc, go to end, delete blank line, save
```

### Interactive prompts

Read the screen first to understand state, then respond appropriately.

## Screenshots

Capture terminal state as PNG:

```
action: "screenshot"
surface_id: "0x..."
output_path: "/tmp/capture.png"
```

Then use the Read tool to view the image.

## Tips

- **Always discover first**: Call `terminals` before assuming surface IDs
- **Read before sending**: Check screen state to understand context
- **Use base64 for code**: Prevents JSON escape sequence corruption
- **Set paste in vim**: Avoids auto-indent disasters
- **Screenshot for verification**: Visual confirmation of complex operations

## Example: Write and Run a Script

```
1. terminals                          # Get surface ID
2. send: "nvim /tmp/demo.py\r"        # Open editor
3. send: ":set paste\ri"              # Paste mode + insert
4. bash: base64 -i script.py          # Get encoded content
5. send (text_b64): <base64>          # Type the code
6. send: "\x1bGdd:wq\r"               # Save and exit
7. send: "python /tmp/demo.py\r"      # Run it
8. screenshot                         # Capture the magic
```
