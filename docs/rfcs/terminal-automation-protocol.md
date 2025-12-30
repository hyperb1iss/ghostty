# RFC: Terminal Automation Protocol

**Status:** Draft
**Author:** Stefanie Jane
**Created:** 2025-12-29

## Summary

This RFC proposes extending Ghostty's IPC protocol to support comprehensive terminal automation, enabling programmatic control analogous to browser automation tools like Playwright and Puppeteer. The protocol will allow external tools to enumerate surfaces, query screen contents, inject input, capture screenshots, and subscribe to terminal events.

## Motivation

### The Gap in Terminal Automation

Browser automation has mature tooling (Playwright, Puppeteer, Selenium) that enables:
- AI agents to interact with web applications
- Automated testing of complex UIs
- Scriptable workflows across multiple browser contexts

Terminal automation has no equivalent. Current options are limited:

| Tool | Limitations |
|------|-------------|
| tmux control mode | Text-only, fragile parsing, no structured data |
| Kitty remote control | Proprietary, single-terminal, limited screen capture |
| OSC sequences | Unidirectional, no request/response, limited payload |
| expect/pexpect | Pattern matching on raw output, no semantic understanding |

**The killer use case:** Testing TUI applications (Ink, Ratatui, Textual) requires understanding *rendered output*, not just text streams. An AI agent needs to know:
- What's on screen (with colors and attributes)
- Where the cursor is positioned
- What cells contain box-drawing characters vs text
- Whether an element is highlighted or focused

### Why Ghostty?

Ghostty's architecture is uniquely suited for this:

1. **Modern IPC foundation** - Socket-based protocol already supports window/tab creation
2. **Rich cell data** - 64-bit packed cells with styles, colors, hyperlinks, graphemes
3. **Cross-platform** - Single protocol works on Linux, macOS, (future) Windows
4. **Performance-first** - GPU-accelerated rendering means fast screen capture

## Design Principles

1. **JSON-RPC style** - Human-readable, debuggable, widely supported
2. **Stateless queries** - Each request is independent; no session management required
3. **Opt-in write access** - Read operations (screen, scrollback) are separate from write operations (input injection)
4. **Surface addressing** - All operations target specific surfaces via stable identifiers
5. **Incremental adoption** - Start with core operations; extend over time
6. **Socket-first, cross-platform** - One protocol that works identically on all platforms

## Architecture

### Why Unix Sockets Over Platform-Native IPC?

The terminal is inherently a **cross-platform abstraction**. Users SSH from macOS to Linux, run the same commands everywhere, and expect consistent behavior. The automation API should follow this philosophy.

**Considered alternatives:**

| Approach | Pros | Cons |
|----------|------|------|
| D-Bus (Linux) + AppleScript (macOS) | "Platform native" | Fragmented: clients must detect platform, duplicate logic |
| D-Bus only | Standard on Linux | macOS/Windows don't have D-Bus |
| AppleScript only | macOS native | Slow, limited data types, macOS only |
| Unix sockets | Cross-platform, fast, structured JSON | Not "desktop native" |

**Decision: Unix sockets as the single protocol.**

Rationale:
- **Cross-platform**: AF_UNIX works on Linux, macOS, and Windows 10+
- **One client library**: Python/Node/Go code works everywhere without platform detection
- **Structured data**: JSON responses with nested objects, arrays, binary (base64)
- **Performance**: Low latency for high-frequency operations (screen reading)
- **AI/MCP friendly**: Easy to integrate with Model Context Protocol servers

### Transport Unification

All IPC actions use the socket protocol:

```
┌─────────────────────────────────────────────────────────────┐
│                   ghostty +<action>                         │
│     +list-surfaces, +send-text, +new-tab, +screenshot       │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    Socket Protocol                          │
│              JSON over Unix domain socket                   │
│         $XDG_RUNTIME_DIR/ghostty/ghostty.sock              │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    Socket Server                            │
│              Runs inside Ghostty process                    │
│           Handles all actions uniformly                     │
└─────────────────────────────────────────────────────────────┘
```

### D-Bus Deprecation (Linux)

The existing D-Bus implementation for `new_window` and `new_tab` is **deprecated** in favor of the unified socket protocol. D-Bus will be retained only for:

- **Desktop activation**: Launching Ghostty via `.desktop` file
- **Global shortcuts**: System-level keybindings that launch actions

All programmatic automation should use the socket protocol.

## Protocol Specification

### Transport

Unchanged from existing IPC:
- **Unix domain sockets** at `$XDG_RUNTIME_DIR/ghostty/<class>.sock` (Linux) or `$TMPDIR/ghostty-$UID/<class>.sock` (macOS)
- **Length-prefixed frames**: `u32 little-endian length` + JSON payload
- **Max message size**: 16 MB (increased from 1 MB for screenshot data)

### Request Format

```json
{
  "version": 2,
  "id": "optional-request-id",
  "action": "<action_name>",
  "target": "optional-surface-id",
  "params": { ... }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `version` | u32 | Protocol version (2 for automation features) |
| `id` | string? | Optional request ID for correlation |
| `action` | string | Action name (see below) |
| `target` | string? | Surface ID for surface-scoped operations |
| `params` | object? | Action-specific parameters |

### Response Format

```json
{
  "ok": true,
  "id": "echoed-request-id",
  "data": { ... }
}
```

Error response:
```json
{
  "ok": false,
  "id": "echoed-request-id",
  "error": {
    "code": "SURFACE_NOT_FOUND",
    "message": "No surface with ID 0x7fff1234abcd"
  }
}
```

## Actions

### Discovery & Enumeration

#### `list_surfaces`

Returns all windows, tabs, and surfaces with their hierarchy.

**Request:**
```json
{
  "version": 2,
  "action": "list_surfaces"
}
```

**Response:**
```json
{
  "ok": true,
  "data": {
    "windows": [
      {
        "id": "window_0",
        "focused": true,
        "position": { "x": 100, "y": 100 },
        "size": { "width": 1200, "height": 800 },
        "tabs": [
          {
            "id": "tab_0_0",
            "title": "bash",
            "active": true,
            "surfaces": [
              {
                "id": "0x7fff1234abcd",
                "title": "bash",
                "focused": true,
                "pid": 12345,
                "cwd": "/home/user/project",
                "size": { "rows": 24, "cols": 80 },
                "cell_size": { "width": 10, "height": 20 },
                "split": null
              }
            ]
          },
          {
            "id": "tab_0_1",
            "title": "nvim",
            "active": false,
            "surfaces": [
              {
                "id": "0x7fff1234abce",
                "title": "nvim main.rs",
                "focused": false,
                "split": {
                  "direction": "horizontal",
                  "position": 0.5,
                  "sibling": "0x7fff1234abcf"
                }
              },
              {
                "id": "0x7fff1234abcf",
                "title": "cargo watch",
                "focused": false,
                "split": {
                  "direction": "horizontal",
                  "position": 0.5,
                  "sibling": "0x7fff1234abce"
                }
              }
            ]
          }
        ]
      }
    ]
  }
}
```

### Screen Content

#### `get_screen`

Returns the visible screen contents.

**Request:**
```json
{
  "version": 2,
  "action": "get_screen",
  "target": "0x7fff1234abcd",
  "params": {
    "format": "cells",
    "include_cursor": true,
    "include_selection": true
  }
}
```

**Params:**
| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `format` | `"text"` \| `"cells"` \| `"vt"` | `"text"` | Output format |
| `include_cursor` | bool | true | Include cursor position |
| `include_selection` | bool | false | Include selection range |
| `region` | object? | null | Limit to specific region |

**Response (format: "text"):**
```json
{
  "ok": true,
  "data": {
    "size": { "rows": 24, "cols": 80 },
    "lines": [
      "user@host:~/project$ ls -la",
      "total 42",
      "drwxr-xr-x  5 user user 4096 Dec 29 10:00 .",
      ...
    ],
    "cursor": { "x": 28, "y": 0, "visible": true, "style": "block" }
  }
}
```

**Response (format: "cells"):**
```json
{
  "ok": true,
  "data": {
    "size": { "rows": 24, "cols": 80 },
    "rows": [
      {
        "index": 0,
        "wrapped": false,
        "cells": [
          {
            "x": 0,
            "char": "u",
            "width": 1,
            "style": {
              "fg": { "type": "palette", "index": 2 },
              "bg": null,
              "bold": true,
              "italic": false,
              "underline": null,
              "strikethrough": false,
              "inverse": false
            },
            "hyperlink": null
          },
          ...
        ]
      }
    ],
    "cursor": { "x": 28, "y": 0, "visible": true, "style": "block" },
    "palette": [
      { "r": 0, "g": 0, "b": 0 },
      { "r": 205, "g": 49, "b": 49 },
      ...
    ]
  }
}
```

**Response (format: "vt"):**
```json
{
  "ok": true,
  "data": {
    "size": { "rows": 24, "cols": 80 },
    "content": "\u001b[1;32muser\u001b[0m@host:~/project$ ls -la\n...",
    "cursor": { "x": 28, "y": 0 }
  }
}
```

#### `get_scrollback`

Returns scrollback history.

**Request:**
```json
{
  "version": 2,
  "action": "get_scrollback",
  "target": "0x7fff1234abcd",
  "params": {
    "lines": 100,
    "offset": 0,
    "format": "text"
  }
}
```

**Response:**
```json
{
  "ok": true,
  "data": {
    "total_lines": 5000,
    "offset": 0,
    "lines": [
      "$ git status",
      "On branch main",
      ...
    ],
    "has_more": true
  }
}
```

### Input Injection

#### `send_text`

Sends text input (treated as if typed/pasted).

**Request:**
```json
{
  "version": 2,
  "action": "send_text",
  "target": "0x7fff1234abcd",
  "params": {
    "text": "ls -la\n",
    "bracket": true
  }
}
```

**Params:**
| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `text` | string | required | Text to send |
| `bracket` | bool | true | Use bracketed paste mode |

#### `send_key`

Sends a key event (for control sequences, shortcuts).

**Request:**
```json
{
  "version": 2,
  "action": "send_key",
  "target": "0x7fff1234abcd",
  "params": {
    "key": "c",
    "mods": ["ctrl"],
    "action": "press"
  }
}
```

**Params:**
| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `key` | string | required | Key name (W3C standard) |
| `mods` | string[] | [] | Modifiers: `shift`, `ctrl`, `alt`, `super` |
| `action` | `"press"` \| `"release"` | `"press"` | Key action |

**Common key names:**
- Letters: `a`-`z`
- Digits: `0`-`9`
- Function: `f1`-`f25`
- Navigation: `up`, `down`, `left`, `right`, `home`, `end`, `pageup`, `pagedown`
- Control: `escape`, `enter`, `tab`, `backspace`, `delete`, `insert`
- Special: `space`, `minus`, `equal`, `bracket_left`, `bracket_right`

#### `send_keys` (convenience)

Sends a sequence of keys with optional delays.

**Request:**
```json
{
  "version": 2,
  "action": "send_keys",
  "target": "0x7fff1234abcd",
  "params": {
    "sequence": [
      { "key": "escape" },
      { "text": ":wq" },
      { "key": "enter" }
    ],
    "delay_ms": 50
  }
}
```

### Visual Capture

#### `screenshot`

Captures the terminal surface as an image.

**Request:**
```json
{
  "version": 2,
  "action": "screenshot",
  "target": "0x7fff1234abcd",
  "params": {
    "format": "png",
    "scale": 1
  }
}
```

**Response:**
```json
{
  "ok": true,
  "data": {
    "format": "png",
    "width": 800,
    "height": 600,
    "base64": "iVBORw0KGgoAAAANSUhEUgAA..."
  }
}
```

### Synchronization

#### `wait_for`

Waits for a condition to be met (polling with timeout).

**Request:**
```json
{
  "version": 2,
  "action": "wait_for",
  "target": "0x7fff1234abcd",
  "params": {
    "condition": {
      "type": "text_match",
      "pattern": "\\$\\s*$",
      "regex": true
    },
    "timeout_ms": 5000,
    "poll_ms": 100
  }
}
```

**Condition types:**
| Type | Description |
|------|-------------|
| `text_match` | Screen contains pattern (regex or literal) |
| `cursor_idle` | Cursor hasn't moved for N ms |
| `process_exit` | Shell process has exited |
| `title_match` | Window title matches pattern |

**Response (success):**
```json
{
  "ok": true,
  "data": {
    "matched": true,
    "elapsed_ms": 230,
    "match": {
      "line": 5,
      "col": 0,
      "text": "user@host:~$ "
    }
  }
}
```

**Response (timeout):**
```json
{
  "ok": false,
  "error": {
    "code": "TIMEOUT",
    "message": "Condition not met within 5000ms"
  }
}
```

### Window/Tab Management

#### `new_window`, `new_tab` (existing)

Already implemented in current IPC.

#### `close_surface`

Closes a specific surface/tab/window.

**Request:**
```json
{
  "version": 2,
  "action": "close_surface",
  "target": "0x7fff1234abcd",
  "params": {
    "force": false
  }
}
```

#### `focus_surface`

Focuses a specific surface.

**Request:**
```json
{
  "version": 2,
  "action": "focus_surface",
  "target": "0x7fff1234abcd"
}
```

#### `resize_surface`

Resizes a surface.

**Request:**
```json
{
  "version": 2,
  "action": "resize_surface",
  "target": "0x7fff1234abcd",
  "params": {
    "rows": 40,
    "cols": 120
  }
}
```

## Surface Identification

### ID Format

Surface IDs use the pointer address as a hex string:
```
0x7fff1234abcd
```

This approach:
- Requires no additional state management
- Is naturally unique within the process lifetime
- Works across platforms (GTK, macOS, future Windows)
- Remains stable as long as the surface exists

### Hierarchical Aliases

For convenience, surfaces can also be addressed by path:
```
window:0/tab:1/surface:0
```

Or by special names:
```
focused      - Currently focused surface
last         - Most recently active surface
```

### ID Lifetime

IDs are valid for the lifetime of the surface. If a surface is closed:
- Any operation targeting that ID returns `SURFACE_NOT_FOUND`
- Clients should call `list_surfaces` to refresh their surface map

## Security Model

### Access Levels

| Level | Operations | Use Case |
|-------|------------|----------|
| `read` | list_surfaces, get_screen, get_scrollback, screenshot | Monitoring, AI observation |
| `write` | send_text, send_key, send_keys | Automation, input injection |
| `manage` | new_window, new_tab, close_surface, focus_surface, resize_surface | Window management |

### Socket Permissions

Default: Socket file permissions restrict access to the current user only.

```
$XDG_RUNTIME_DIR/ghostty/com.mitchellh.ghostty.sock
Mode: 0600 (owner read/write only)
```

### Peer Validation

On connection, the server validates:
1. **Same UID** - `getpeereid()` on macOS/BSD, `SO_PEERCRED` on Linux
2. **Same user namespace** (Linux) - Prevents container escapes

### Future: Token-Based Auth

For remote access (not in initial implementation):
```json
{
  "version": 2,
  "token": "ghst_xxxx...",
  "action": "get_screen",
  ...
}
```

## Implementation Phases

### Phase 1: Core Read Operations
- `list_surfaces` - Surface enumeration
- `get_screen` (text format) - Basic screen content
- `get_scrollback` (text format) - Scrollback access

### Phase 2: Structured Data
- `get_screen` (cells format) - Full cell data with styles
- `get_screen` (vt format) - VT sequence output
- Cell attribute serialization

### Phase 3: Input Injection
- `send_text` - Text input
- `send_key` - Single keystroke
- `send_keys` - Key sequences

### Phase 4: Visual & Sync
- `screenshot` - PNG capture
- `wait_for` - Condition waiting
- Event subscriptions (future)

### Phase 5: Management
- `close_surface`
- `focus_surface`
- `resize_surface`
- Split management

## MCP Server Integration

This protocol enables building an MCP (Model Context Protocol) server for AI terminal automation:

```typescript
// ghostty-mcp server
const server = new MCPServer({
  tools: [
    {
      name: "ghostty_list_sessions",
      description: "List all open terminal windows and tabs",
      handler: async () => {
        return ghosttyClient.send({ action: "list_surfaces" });
      }
    },
    {
      name: "ghostty_get_screen",
      description: "Get the current terminal screen contents",
      inputSchema: {
        surface_id: { type: "string" },
        format: { enum: ["text", "cells"] }
      },
      handler: async ({ surface_id, format }) => {
        return ghosttyClient.send({
          action: "get_screen",
          target: surface_id,
          params: { format }
        });
      }
    },
    {
      name: "ghostty_send_command",
      description: "Execute a command in the terminal",
      inputSchema: {
        surface_id: { type: "string" },
        command: { type: "string" }
      },
      handler: async ({ surface_id, command }) => {
        await ghosttyClient.send({
          action: "send_text",
          target: surface_id,
          params: { text: command + "\n" }
        });
        // Wait for prompt
        return ghosttyClient.send({
          action: "wait_for",
          target: surface_id,
          params: { condition: { type: "text_match", pattern: "\\$\\s*$" } }
        });
      }
    }
  ]
});
```

## Comparison with Alternatives

| Feature | Ghostty IPC | Kitty Remote | tmux Control |
|---------|-------------|--------------|--------------|
| Structured cell data | Yes (cells format) | No | No |
| Color/style info | Yes | Limited | No |
| Input injection | Yes | Yes | Yes |
| Screenshot | Yes (PNG) | No | No |
| Cross-platform | Yes | Linux/macOS | All |
| Session subscription | Planned | No | Yes (streaming) |
| Window management | Yes | Yes | N/A (own model) |
| Security model | UID + permissions | Password | Implicit |

## Open Questions

1. **Event streaming**: Should we support WebSocket-style event subscriptions for real-time updates?
2. **Binary protocol**: Should high-frequency operations (screen updates) use a binary format?
3. **Remote access**: Should we support network-based access with proper authentication?
4. **Plugin API**: Should automation actions be extensible via plugins?

## References

- [Chrome DevTools Protocol](https://chromedevtools.github.io/devtools-protocol/)
- [WebDriver BiDi](https://w3c.github.io/webdriver-bidi/)
- [Kitty Remote Control](https://sw.kovidgoyal.net/kitty/remote-control/)
- [tmux Control Mode](https://github.com/tmux/tmux/wiki/Control-mode)
- [Ghostty Socket IPC](../src/apprt/socket.zig) (internal)
