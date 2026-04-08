---
name: ghostty-terminal-automation
description: Automate Ghostty terminal sessions via CLI. Use when you need to send commands to terminals, read terminal output, capture screenshots, resize windows, open new tabs/windows, press keys, or interact with TUI apps like Neovim, htop, or any CLI tool running in Ghostty.
---

# Ghostty Terminal Automation

Control Ghostty terminals programmatically using `ghostty-automator +<action>` CLI commands. All IPC actions are built into the single `ghostty-automator` binary.

## Prerequisites

Verify that `ghostty-automator` is installed and on PATH:

```bash
ghostty-automator --version
```

If the command is not found, install it using one of the methods below.

## Installation

### Homebrew (macOS and Linux)

```bash
brew install hyperb1iss/tap/ghostty-automator
```

### GitHub Releases (direct download)

Download the latest binary for your platform from:
**https://github.com/hyperb1iss/ghostty-automator/releases/latest**

| Platform | Artifact |
|----------|----------|
| macOS ARM64 | `ghostty-automator-macos-arm64.zip` |
| Linux x86_64 | `ghostty-automator-linux-amd64.tar.gz` |
| Linux ARM64 | `ghostty-automator-linux-arm64.tar.gz` |

```bash
# Linux example (x86_64)
curl -fsSL https://github.com/hyperb1iss/ghostty-automator/releases/latest/download/ghostty-automator-linux-amd64.tar.gz | tar xz
sudo mv ghostty-automator-linux-amd64/bin/ghostty-automator /usr/local/bin/

# macOS example (ARM64)
curl -fsSL https://github.com/hyperb1iss/ghostty-automator/releases/latest/download/ghostty-automator-macos-arm64.zip -o ghostty-automator.zip
unzip ghostty-automator.zip -d ghostty-automator-macos
sudo mv ghostty-automator-macos/ghostty-automator /usr/local/bin/
```

## Bootstrap First

Do not assume `+send-text`, `+get-screen`, or other target-specific actions will create a terminal for you. Bootstrap explicitly:

1. Run `ghostty-automator +list-surfaces --format=json`
2. If it succeeds and returns surfaces, pick one and continue
3. If it succeeds but returns no surfaces, run `ghostty-automator +new-window`
4. If it fails because Ghostty is not reachable:
   - Linux/GTK: run `ghostty-automator +new-window` in the background, then retry discovery
   - macOS: run `open -ga Ghostty.app` in the background, wait for Ghostty to come up, then run `ghostty-automator +new-window`
5. Run `ghostty-automator +list-surfaces --format=json` again and use the returned surface ID

Prefer `+new-window` as the bootstrap primitive. Use `+new-tab` only when you already have a reachable instance and want another tab specifically.

## Discovery

```bash
# List all surfaces (human-readable tree)
ghostty-automator +list-surfaces

# List all surfaces (JSON for scripting)
ghostty-automator +list-surfaces --format=json
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
ghostty-automator +get-screen --surface=<id>

# Read as JSON (includes cursor position)
ghostty-automator +get-screen --surface=<id> --format=json

# Read full scrollback
ghostty-automator +get-screen --surface=<id> --screen=screen

# Read active screen only (no scrollback)
ghostty-automator +get-screen --surface=<id> --screen=active
```

## Sending Input

### Text

```bash
# Send text (no Enter — use \r for Enter)
ghostty-automator +send-text --surface=<id> --text="ls -la\r"

# Type without executing
ghostty-automator +send-text --surface=<id> --text="partial input"

# Send escape character
ghostty-automator +send-text --surface=<id> --text="\e"

# Supported escapes: \n \r \t \\ \e \0 \xNN
```

### Keys

```bash
# Press Enter
ghostty-automator +send-key --surface=<id> --key=Enter

# Press Escape
ghostty-automator +send-key --surface=<id> --key=Escape

# Ctrl+C
ghostty-automator +send-key --surface=<id> --key=KeyC --mods=ctrl

# Ctrl+Z
ghostty-automator +send-key --surface=<id> --key=KeyZ --mods=ctrl

# Arrow keys
ghostty-automator +send-key --surface=<id> --key=ArrowUp
ghostty-automator +send-key --surface=<id> --key=ArrowDown

# Tab completion
ghostty-automator +send-key --surface=<id> --key=Tab

# Function keys
ghostty-automator +send-key --surface=<id> --key=F1

# Ctrl+Shift+A
ghostty-automator +send-key --surface=<id> --key=KeyA --mods=ctrl,shift
```

Key names (W3C standard): `Enter`, `Tab`, `Escape`, `Backspace`, `Delete`, `Space`, `ArrowUp`, `ArrowDown`, `ArrowLeft`, `ArrowRight`, `Home`, `End`, `PageUp`, `PageDown`, `F1`-`F12`, `KeyA`-`KeyZ`, `Digit0`-`Digit9`.

Modifiers: `ctrl`, `shift`, `alt`, `super` (comma-separated).

### Mouse

```bash
# Click at pixel position (press then release)
ghostty-automator +send-mouse --surface=<id> --x=100 --y=200 --button=left --button-action=press
ghostty-automator +send-mouse --surface=<id> --x=100 --y=200 --button=left --button-action=release

# Right-click
ghostty-automator +send-mouse --surface=<id> --x=50 --y=80 --button=right --button-action=press
ghostty-automator +send-mouse --surface=<id> --x=50 --y=80 --button=right --button-action=release
```

### Scrolling

```bash
# Scroll down 3 lines
ghostty-automator +send-scroll --surface=<id> --y=3

# Scroll up 5 lines
ghostty-automator +send-scroll --surface=<id> --y=-5
```

## Screenshots

```bash
ghostty-automator +screenshot-surface --surface=<id> --output=/tmp/terminal.png
# Then use the Read tool on /tmp/terminal.png to view it
```

## Window Management

```bash
# Focus a surface (bring window to front)
ghostty-automator +focus-surface --surface=<id>

# Close a surface
ghostty-automator +close-surface --surface=<id>

# Resize terminal grid
ghostty-automator +resize-surface --surface=<id> --rows=40 --cols=120

# Open new window
ghostty-automator +new-window

# Open new tab
ghostty-automator +new-tab
```

## Core Workflow

1. **Check installation**: `ghostty-automator --version` — install if missing
2. **Discover or bootstrap**: `ghostty-automator +list-surfaces --format=json` and create a window if needed
3. **Read state**: `ghostty-automator +get-screen --surface=<id>` — see what's on screen
4. **Send command**: `ghostty-automator +send-text --surface=<id> --text="npm test\r"`
5. **Wait & read**: `sleep 2 && ghostty-automator +get-screen --surface=<id>` — check output
6. **Verify**: Screenshot or read again

## Examples

### Run a Command and Check Output

```bash
# 1. Find surfaces
ghostty-automator +list-surfaces --format=json

# 2. Run a command (note \r for Enter)
ghostty-automator +send-text --surface=0x153872000 --text="echo hello world\r"

# 3. Wait and read result
sleep 1
ghostty-automator +get-screen --surface=0x153872000
```

### Interact with Neovim

```bash
# Open file
ghostty-automator +send-text --surface=<id> --text="nvim file.py\r"
sleep 1

# Enter insert mode
ghostty-automator +send-key --surface=<id> --key=KeyI

# Type code
ghostty-automator +send-text --surface=<id> --text="print('hello')"

# Exit insert mode
ghostty-automator +send-key --surface=<id> --key=Escape

# Save and quit
ghostty-automator +send-text --surface=<id> --text=":wq\r"
```

### Interrupt a Running Process

```bash
ghostty-automator +send-key --surface=<id> --key=KeyC --mods=ctrl
```

### Visual Verification

```bash
ghostty-automator +screenshot-surface --surface=<id> --output=/tmp/check.png
# Then use Read tool on /tmp/check.png
```

## Tips

- **Always discover first**: Run `+list-surfaces` before assuming IDs
- **Creation is explicit**: Bootstrap with `+new-window`; don't expect `+send-text` or `+get-screen` to create a terminal
- **Use `\r` for Enter**: `+send-text` doesn't auto-append newlines
- **Poll for output**: Read screen after commands; use `sleep` if needed
- **Read before acting**: Check screen state to understand context
- **Screenshot for TUIs**: Visual verification is easier than parsing text
- **Surface IDs are hex pointers**: e.g. `0x153872000`, stable for surface lifetime
- **Exit codes**: 0 = success, 1 = error (error message on stderr)
