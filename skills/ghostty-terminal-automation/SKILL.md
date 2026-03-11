---
name: ghostty-terminal-automation
description: Automate Ghostty terminal sessions via CLI. Use when you need to send commands to terminals, read terminal output, capture screenshots, resize windows, open new tabs/windows, press keys, or interact with TUI apps like Neovim, htop, or any CLI tool running in Ghostty.
---

# Ghostty Terminal Automation

Control Ghostty terminals programmatically using `ghostty +<action>` CLI commands. All IPC actions are built into the Ghostty binary.

## Discovery

```bash
# List all surfaces (human-readable tree)
ghostty +list-surfaces

# List all surfaces (JSON for scripting)
ghostty +list-surfaces --format=json
```

JSON output structure:
```json
{
  "data": {
    "windows": [{
      "id": "0xABC", "focused": true,
      "tabs": [{
        "id": "0xDEF", "title": "zsh", "active": true,
        "surfaces": [{
          "id": "0x153872000", "title": "zsh", "focused": true,
          "pwd": "/home/user", "rows": 24, "cols": 80
        }]
      }]
    }]
  }
}
```

## Reading Screen Content

```bash
# Read visible viewport (raw text)
ghostty +get-screen --surface=<id>

# Read as JSON (includes cursor position)
ghostty +get-screen --surface=<id> --format=json

# Read full scrollback
ghostty +get-screen --surface=<id> --screen=screen

# Read active screen only (no scrollback)
ghostty +get-screen --surface=<id> --screen=active
```

## Sending Input

### Text

```bash
# Send text (no Enter — use \r for Enter)
ghostty +send-text --surface=<id> --text="ls -la\r"

# Type without executing
ghostty +send-text --surface=<id> --text="partial input"

# Send escape character
ghostty +send-text --surface=<id> --text="\e"

# Supported escapes: \n \r \t \\ \e \0 \xNN
```

### Keys

```bash
# Press Enter
ghostty +send-key --surface=<id> --key=Enter

# Press Escape
ghostty +send-key --surface=<id> --key=Escape

# Ctrl+C
ghostty +send-key --surface=<id> --key=KeyC --mods=ctrl

# Ctrl+Z
ghostty +send-key --surface=<id> --key=KeyZ --mods=ctrl

# Arrow keys
ghostty +send-key --surface=<id> --key=ArrowUp
ghostty +send-key --surface=<id> --key=ArrowDown

# Tab completion
ghostty +send-key --surface=<id> --key=Tab

# Function keys
ghostty +send-key --surface=<id> --key=F1

# Ctrl+Shift+A
ghostty +send-key --surface=<id> --key=KeyA --mods=ctrl,shift
```

Key names (W3C standard): `Enter`, `Tab`, `Escape`, `Backspace`, `Delete`, `Space`, `ArrowUp`, `ArrowDown`, `ArrowLeft`, `ArrowRight`, `Home`, `End`, `PageUp`, `PageDown`, `F1`-`F12`, `KeyA`-`KeyZ`, `Digit0`-`Digit9`.

Modifiers: `ctrl`, `shift`, `alt`, `super` (comma-separated).

### Mouse

```bash
# Click at pixel position (press then release)
ghostty +send-mouse --surface=<id> --x=100 --y=200 --button=left --button-action=press
ghostty +send-mouse --surface=<id> --x=100 --y=200 --button=left --button-action=release

# Right-click
ghostty +send-mouse --surface=<id> --x=50 --y=80 --button=right --button-action=press
ghostty +send-mouse --surface=<id> --x=50 --y=80 --button=right --button-action=release
```

### Scrolling

```bash
# Scroll down 3 lines
ghostty +send-scroll --surface=<id> --y=3

# Scroll up 5 lines
ghostty +send-scroll --surface=<id> --y=-5
```

## Screenshots

```bash
ghostty +screenshot-surface --surface=<id> --output=/tmp/terminal.png
# Then use the Read tool on /tmp/terminal.png to view it
```

## Window Management

```bash
# Focus a surface (bring window to front)
ghostty +focus-surface --surface=<id>

# Close a surface
ghostty +close-surface --surface=<id>

# Resize terminal grid
ghostty +resize-surface --surface=<id> --rows=40 --cols=120

# Open new window
ghostty +new-window

# Open new tab
ghostty +new-tab
```

## Core Workflow

1. **Discover**: `ghostty +list-surfaces --format=json` — extract a surface ID
2. **Read state**: `ghostty +get-screen --surface=<id>` — see what's on screen
3. **Send command**: `ghostty +send-text --surface=<id> --text="npm test\r"`
4. **Wait & read**: `sleep 2 && ghostty +get-screen --surface=<id>` — check output
5. **Verify**: Screenshot or read again

## Examples

### Run a Command and Check Output

```bash
# 1. Find surfaces
ghostty +list-surfaces --format=json

# 2. Run a command (note \r for Enter)
ghostty +send-text --surface=0x153872000 --text="echo hello world\r"

# 3. Wait and read result
sleep 1
ghostty +get-screen --surface=0x153872000
```

### Interact with Neovim

```bash
# Open file
ghostty +send-text --surface=<id> --text="nvim file.py\r"
sleep 1

# Enter insert mode
ghostty +send-key --surface=<id> --key=KeyI

# Type code
ghostty +send-text --surface=<id> --text="print('hello')"

# Exit insert mode
ghostty +send-key --surface=<id> --key=Escape

# Save and quit
ghostty +send-text --surface=<id> --text=":wq\r"
```

### Interrupt a Running Process

```bash
ghostty +send-key --surface=<id> --key=KeyC --mods=ctrl
```

### Visual Verification

```bash
ghostty +screenshot-surface --surface=<id> --output=/tmp/check.png
# Then use Read tool on /tmp/check.png
```

## Tips

- **Always discover first**: Run `+list-surfaces` before assuming IDs
- **Use `\r` for Enter**: `+send-text` doesn't auto-append newlines
- **Poll for output**: Read screen after commands; use `sleep` if needed
- **Read before acting**: Check screen state to understand context
- **Screenshot for TUIs**: Visual verification is easier than parsing text
- **Surface IDs are hex pointers**: e.g. `0x153872000`, stable for surface lifetime
- **Exit codes**: 0 = success, 1 = error (error message on stderr)
