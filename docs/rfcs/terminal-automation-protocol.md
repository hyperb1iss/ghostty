# Terminal Automation Protocol

**Status:** Accepted
**Version:** 1
**Author:** Stefanie Jane
**Created:** 2025-12-29
**Updated:** 2026-02-12

## Summary

Ghostty's terminal automation protocol enables programmatic control of terminal
sessions over Unix domain sockets. The protocol uses length-prefixed JSON frames
to support surface discovery, screen reading, input injection, visual capture,
and window management — providing the terminal equivalent of browser automation
tools like Playwright.

An MCP (Model Context Protocol) server built on this protocol gives AI agents
direct terminal control: reading screen state, executing commands, interacting
with TUI applications, and capturing screenshots.

## Motivation

### The Gap in Terminal Automation

Browser automation has mature tooling (Playwright, Puppeteer, Selenium) that
enables AI agents, automated testing, and scriptable workflows. Terminal
automation has no equivalent:

| Tool | Limitations |
|------|-------------|
| tmux control mode | Text-only, fragile parsing, no structured data |
| Kitty remote control | Password auth only, no structured cell data, no screenshots |
| OSC sequences | Unidirectional, no request/response, limited payload |
| expect/pexpect | Pattern matching on raw output, no semantic understanding |

**The killer use case:** AI agents and TUI testing need to understand *rendered
output*, not just text streams. An agent interacting with Neovim, htop, or a
Ratatui application needs to know what's on screen with colors and attributes,
where the cursor is, and whether an element is highlighted or focused.

### Why Ghostty?

1. **Rich cell data** — 64-bit packed cells with styles, colors, hyperlinks, graphemes
2. **Cross-platform** — Single protocol works on Linux, macOS, (future) Windows
3. **GPU-accelerated** — Fast screen capture via GL readback
4. **MCP-native** — Designed for AI agent integration from day one

## Design Principles

1. **Document reality** — This RFC describes the implemented protocol, not aspirations
2. **JSON over sockets** — Human-readable, debuggable, widely supported
3. **Stateless requests** — Each request is independent; no session management
4. **Surface addressing** — All operations target specific surfaces via identifiers
5. **Phased delivery** — Core operations first, extensions over time
6. **Cross-platform transport** — One protocol on all platforms

## Architecture

### Transport

All automation actions use Unix domain sockets with JSON payloads:

```
┌──────────────────────────────────────────────────────────┐
│                  Client Layer                             │
│  ghostty +<action>  │  Python client  │  MCP server      │
└──────────────────────────────────────────────────────────┘
                           │
                    JSON over Unix socket
                    Length-prefixed frames
                           │
                           ▼
┌──────────────────────────────────────────────────────────┐
│                  Socket Server                            │
│           Runs inside the Ghostty process                 │
│      GTK: threaded clients + glib.idleAdd dispatch        │
│      macOS: embedded runtime via libghostty               │
└──────────────────────────────────────────────────────────┘
                           │
                           ▼
┌──────────────────────────────────────────────────────────┐
│                  Core Engine                               │
│  Surface • Terminal • Renderer • PTY • Input              │
└──────────────────────────────────────────────────────────┘
```

### Why Unix Sockets?

| Approach | Pros | Cons |
|----------|------|------|
| D-Bus + AppleScript | Platform native | Fragmented clients, duplicated logic |
| D-Bus only | Linux standard | macOS/Windows unsupported |
| Unix sockets | Cross-platform, fast, structured | Not "desktop native" |

**Decision:** Unix sockets as the single automation transport.

- `AF_UNIX` works on Linux, macOS, and Windows 10+
- One client library works everywhere without platform detection
- JSON payloads support nested objects, arrays, and base64 binary
- Low latency for high-frequency operations (screen reading, input injection)

D-Bus is retained on Linux solely for desktop integration (`.desktop` activation,
global shortcuts). All programmatic automation uses the socket protocol.

### Socket Paths

| Platform | Path |
|----------|------|
| Linux | `$XDG_RUNTIME_DIR/ghostty/<instance>.sock` |
| Linux fallback | `/tmp/ghostty-$UID/<instance>.sock` |
| macOS | `$TMPDIR/ghostty-$UID/<instance>.sock` |
| macOS fallback | `/tmp/ghostty-$UID/<instance>.sock` |
| Windows (future) | `\\.\pipe\ghostty-<instance>` |

Default instance name: `ghostty.sock`. Directory permissions: `0700`. Socket
permissions: `0600`.

## Protocol Specification

### Framing

Messages use length-prefixed frames:

```
┌─────────────┬──────────────────────┐
│ u32 LE len  │ JSON payload (UTF-8) │
│  (4 bytes)  │   (len bytes)        │
└─────────────┴──────────────────────┘
```

Maximum message size: **16 MB** (accommodates screenshot data).

### Request Format

```json
{
  "version": 1,
  "target": null,
  "action": {
    "<action_name>": { ...payload... }
  }
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `version` | u32 | Yes | Protocol version. Must be `1`. GTK accepts any value; macOS enforces `1`. |
| `target` | string | No | Ghostty instance class name. Currently ignored by both servers — reserved for multi-instance routing. |
| `action` | object | Yes | Tagged union: single key is the action name, value is the payload. |

The `action` field is a **tagged union** — exactly one key must be present. The
key identifies the action, and the value contains action-specific parameters.
Actions with no parameters use an empty object `{}` or `void`.

> **Note:** The server uses `ignore_unknown_fields` during JSON parsing, so
> clients may include extra fields (e.g., a future `id` field) without breaking
> compatibility.

### Response Format

**Success:**
```json
{
  "ok": true,
  "data": { ... }
}
```

**Error:**
```json
{
  "ok": false,
  "error": "No surface with ID 0x7fff1234abcd"
}
```

| Field | Type | Description |
|-------|------|-------------|
| `ok` | bool | Whether the action succeeded. |
| `data` | object? | Action-specific result data (success only). |
| `error` | string? | Human-readable error message (error only). |

> **Phase 2 addition:** Request `id` (echoed in response) and structured error
> `code` fields are planned additions. See [Protocol Enhancements](#protocol-enhancements).

## Surface Addressing

All surface-scoped actions accept a `surface_id` field in their payload.

### Pointer IDs (Current)

Hex-formatted memory addresses: `"0x153872000"`. These are the canonical surface
identifiers returned by `list_surfaces` and are the **only addressing mode
currently implemented**.

- Naturally unique within the process lifetime
- Zero additional state management
- Stable as long as the surface exists
- Cross-platform (GTK, macOS, future Windows)

### ID Lifetime

IDs are valid for the lifetime of the surface. When a surface is closed, any
operation targeting its ID returns an error. Clients should call `list_surfaces`
to refresh their surface map.

### Planned Aliases (Phase 2)

Phase 2 will add two additional addressing modes, resolved server-side:

**Special names:**

| Name | Resolves to |
|------|-------------|
| `focused` | The currently focused surface. |

The `focused` alias eliminates the common pattern of calling `list_surfaces`
just to find the active terminal.

**Index paths:**

```
window:0/tab:1/surface:0
```

Zero-based indices matching the order returned by `list_surfaces`. Convenient
for scripts targeting fixed layouts but fragile if windows/tabs are reordered.

---

## Actions — Phase 1 (Implemented)

These actions are fully implemented on both GTK (Linux) and macOS.

### Discovery

#### `list_surfaces`

Returns all windows, tabs, and surfaces with their hierarchy.

**Request:**
```json
{
  "version": 1,
  "action": { "list_surfaces": {} }
}
```

**Response:**
```json
{
  "ok": true,
  "data": {
    "windows": [
      {
        "id": "0x7fff1234abcd",
        "focused": true,
        "tabs": [
          {
            "id": "0x7fff1234abce",
            "title": "bash",
            "active": true,
            "surfaces": [
              {
                "id": "0x7fff1234abcf",
                "title": "bash",
                "focused": true,
                "pwd": "/home/user/project",
                "rows": 24,
                "cols": 80
              }
            ]
          }
        ]
      }
    ]
  }
}
```

Surface discovery iterates all windows, all tabs within each window, and all
surfaces within each tab's split tree. Not just the active tab.

### Screen Content

#### `get_screen`

Returns the screen contents of a surface.

**Request:**
```json
{
  "version": 1,
  "action": {
    "get_screen": {
      "surface_id": "0x7fff1234abcf",
      "screen": "viewport"
    }
  }
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `surface_id` | string | required | Target surface. |
| `screen` | string | `"viewport"` | `"viewport"` (visible), `"active"` (no scrollback), or `"screen"` (full scrollback). |

**Response:**
```json
{
  "ok": true,
  "data": {
    "content": "user@host:~/project$ ls -la\ntotal 42\n...",
    "cursor_x": 28,
    "cursor_y": 0
  }
}
```

The `content` field contains the text-format screen content. Cursor position is
returned as separate `cursor_x` and `cursor_y` fields.

**Cells format (macOS only):**

The cells format uses **span-based encoding** — consecutive characters sharing
the same style are grouped into spans. This achieves ~450x compression compared
to per-cell JSON (1.4 KB vs 633 KB for typical content).

> **Platform note:** Cells format is currently available on macOS via an
> extended `format` parameter. GTK always returns text format. The `format`
> field is not part of the shared protocol definition in `socket.zig` — it is
> handled by the macOS IPC layer directly. On macOS, cells data is returned as
> a JSON string within the `content` field, which the client must parse
> separately.

```json
{
  "ok": true,
  "data": {
    "rows": [
      {
        "spans": [
          {
            "x": 0,
            "t": "user@host",
            "fg": 2,
            "bg": null,
            "b": 1,
            "i": 0,
            "f": 0,
            "u": 0,
            "s": 0,
            "inv": 0
          },
          {
            "x": 9,
            "t": ":~/project$ ",
            "fg": null,
            "bg": null,
            "b": 0
          }
        ]
      }
    ],
    "cursor_x": 28,
    "cursor_y": 0
  }
}
```

Span fields:

| Field | Type | Description |
|-------|------|-------------|
| `x` | u32 | Starting column. |
| `t` | string | Text content. |
| `fg` | int or [r,g,b] or null | Foreground: palette index, RGB array, or default. |
| `bg` | int or [r,g,b] or null | Background: palette index, RGB array, or default. |
| `b` | 0/1 | Bold. |
| `i` | 0/1 | Italic. |
| `f` | 0/1 | Faint. |
| `u` | 0/1 | Underline. |
| `s` | 0/1 | Strikethrough. |
| `inv` | 0/1 | Inverse. |

Fields with default values (0, null) may be omitted.

### Input Injection

#### `send_text`

Sends text directly to the surface's PTY (raw write, bypasses bracketed paste).

**Request:**
```json
{
  "version": 1,
  "action": {
    "send_text": {
      "surface_id": "focused",
      "text": "ls -la\n"
    }
  }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `surface_id` | string | Target surface. |
| `text` | string | Text to send. Use `\n` or `\r` for Enter. |

#### `send_key`

Sends a keyboard event.

**Request:**
```json
{
  "version": 1,
  "action": {
    "send_key": {
      "surface_id": "focused",
      "key": "Escape",
      "action": "press",
      "mods": "ctrl,shift"
    }
  }
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `surface_id` | string | required | Target surface. |
| `key` | string | required | Key name in [W3C UI Events](https://www.w3.org/TR/uievents-code/) format. |
| `action` | string | `"press"` | `"press"`, `"release"`, or `"repeat"`. |
| `mods` | string | null | Comma-separated: `"shift"`, `"ctrl"`, `"alt"`, `"super"`. |

**Common key names:**

| Category | Keys |
|----------|------|
| Letters | `KeyA` through `KeyZ` |
| Digits | `Digit0` through `Digit9` |
| Function | `F1` through `F12` |
| Navigation | `ArrowUp`, `ArrowDown`, `ArrowLeft`, `ArrowRight`, `Home`, `End`, `PageUp`, `PageDown` |
| Control | `Escape`, `Enter`, `Tab`, `Backspace`, `Delete`, `Insert` |
| Whitespace | `Space` |

#### `send_mouse`

Sends a mouse event (motion, button press/release).

**Request:**
```json
{
  "version": 1,
  "action": {
    "send_mouse": {
      "surface_id": "focused",
      "x": 150.0,
      "y": 300.0,
      "button": "left",
      "button_action": "press",
      "mods": null
    }
  }
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `surface_id` | string | required | Target surface. |
| `x` | f64 | required | X position in pixels (surface-relative). |
| `y` | f64 | required | Y position in pixels (surface-relative). |
| `button` | string | null | `"left"`, `"right"`, `"middle"`, `"four"`, `"five"`, etc. Null for motion-only. |
| `button_action` | string | null | `"press"` or `"release"`. Required if `button` is set. |
| `mods` | string | null | Comma-separated modifiers. |

To perform a click, send a `press` followed by a `release` at the same
coordinates. The MCP server's `click()` convenience method handles this.

> **Platform note:** When `button` is set without `button_action`, GTK defaults
> to `press`. macOS silently treats it as a motion-only event. For portable
> behavior, always provide both `button` and `button_action` together.

#### `send_scroll`

Sends a scroll event.

**Request:**
```json
{
  "version": 1,
  "action": {
    "send_scroll": {
      "surface_id": "focused",
      "x": 0.0,
      "y": -3.0,
      "mods": null
    }
  }
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `surface_id` | string | required | Target surface. |
| `x` | f64 | `0` | Horizontal scroll delta (positive = right). |
| `y` | f64 | `0` | Vertical scroll delta (positive = down). |
| `mods` | string | null | Reserved for future use. Accepted but currently ignored. |

### Visual Capture

#### `screenshot_surface`

Captures the surface as a PNG image via GL readback.

**Request (file mode):**
```json
{
  "version": 1,
  "action": {
    "screenshot_surface": {
      "surface_id": "focused",
      "output_path": "/tmp/terminal.png"
    }
  }
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `surface_id` | string | required | Target surface. |
| `output_path` | string | required | Absolute path for the PNG file. |

**Response:**
```json
{
  "ok": true
}
```

The server writes the PNG file and returns a success/error response. No path
is echoed in the response data.

**Path validation:** Must be absolute (starts with `/`), must not contain `..`
path components (validated per-component via tokenization). This prevents
directory traversal attacks.

> **Security note:** The current validation is path-string-based and does not
> prevent symlink-following or TOCTOU attacks on the output path. The file is
> written to whatever the OS resolves the path to. A future hardening pass
> should use `O_NOFOLLOW` or write to a temp file and rename.

### Window & Surface Management

#### `new_window`

Opens a new Ghostty window.

```json
{
  "version": 1,
  "action": {
    "new_window": { "arguments": null }
  }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `arguments` | string[]? | Command arguments for the new window's shell. `null` for default shell. |

> **Platform note:** On macOS, `arguments` are passed to the new shell. On GTK,
> `arguments` are accepted but not yet wired through — the action creates a
> window with the default shell and logs a message if arguments were provided.

#### `new_tab`

Opens a new tab in the most recently focused window.

```json
{
  "version": 1,
  "action": {
    "new_tab": { "arguments": null }
  }
}
```

> **Platform note:** Same limitation as `new_window` — GTK does not yet honor
> the `arguments` field.

#### `focus_surface`

Brings a surface's window to front and focuses it.

```json
{
  "version": 1,
  "action": {
    "focus_surface": { "surface_id": "0x7fff1234abcf" }
  }
}
```

#### `close_surface`

Closes a surface (and its containing tab/window if it's the last one).

```json
{
  "version": 1,
  "action": {
    "close_surface": { "surface_id": "0x7fff1234abcf" }
  }
}
```

#### `resize_surface`

Resizes a surface's window by terminal grid dimensions.

```json
{
  "version": 1,
  "action": {
    "resize_surface": {
      "surface_id": "0x7fff1234abcf",
      "rows": 40,
      "cols": 120
    }
  }
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `surface_id` | string | required | Target surface. |
| `rows` | u32 | `0` | New row count. `0` = unchanged. |
| `cols` | u32 | `0` | New column count. `0` = unchanged. |

> **Platform note:** On macOS, both `rows` and `cols` should be provided.
> The macOS handler may require both fields to be present in the JSON payload.

---

## Actions — Phase 2 (Planned)

These actions are designed and ready for implementation.

### Protocol Enhancements

Phase 2 adds two backwards-compatible fields to the request/response format:

**Request `id` field:**
```json
{
  "version": 1,
  "id": "req-001",
  "action": { "get_screen": { "surface_id": "focused", "screen": "viewport" } }
}
```

The `id` is echoed in the response, enabling request correlation for concurrent
clients.

**Response `code` field (errors only):**
```json
{
  "ok": false,
  "id": "req-001",
  "code": "SURFACE_NOT_FOUND",
  "error": "No surface with ID 0x7fff1234abcd"
}
```

Planned error codes:

| Code | Meaning |
|------|---------|
| `SURFACE_NOT_FOUND` | No surface matches the given ID or alias. |
| `INVALID_ACTION` | Unknown action name. |
| `INVALID_KEY` | Unrecognized key name in send_key/send_keys. |
| `INVALID_PARAMETER` | Missing or malformed parameter. |
| `TIMEOUT` | wait_for condition not met within deadline. |
| `INTERNAL_ERROR` | Server-side failure. |

Both fields are additive — existing clients that don't send `id` will receive
responses without it, and clients that don't check `code` can continue using
the `error` string.

### Synchronization

#### `wait_for`

Waits server-side for a condition to be met on a surface. This is the most
important automation primitive — it eliminates client-side polling loops and
enables synchronous command execution patterns.

**Request:**
```json
{
  "version": 1,
  "action": {
    "wait_for": {
      "surface_id": "focused",
      "condition": {
        "type": "text_match",
        "pattern": "\\$\\s*$",
        "regex": true
      },
      "timeout_ms": 5000,
      "poll_ms": 100
    }
  }
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `surface_id` | string | required | Target surface. |
| `condition` | object | required | Condition to wait for (see below). |
| `timeout_ms` | u32 | `5000` | Maximum wait time in milliseconds. |
| `poll_ms` | u32 | `100` | Polling interval in milliseconds. |

**Condition types:**

| Type | Fields | Description |
|------|--------|-------------|
| `text_match` | `pattern` (string), `regex` (bool, default false) | Screen text matches pattern. Regex uses POSIX ERE syntax. |
| `cursor_idle` | `idle_ms` (u32) | Cursor position unchanged for N milliseconds. |
| `process_exit` | (none) | The surface's child process has exited. |
| `title_match` | `pattern` (string), `regex` (bool, default false) | Window/tab title matches pattern. |

**Response (matched):**
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
  "code": "TIMEOUT",
  "error": "Condition not met within 5000ms"
}
```

**Implementation notes:**

The server runs the polling loop internally. For `text_match`, each poll reads
the surface's screen content and applies the pattern. For `cursor_idle`, the
server tracks cursor position changes over time. For `process_exit`, the server
checks the PTY child status.

This is dramatically more efficient than client-side polling — no IPC round-trip
per poll, and the server can access terminal state directly.

**Architecture constraints:**

- **GTK threading model:** The GTK IPC server dispatches handlers to the main
  thread via `glib.idleAdd`. A `wait_for` handler must NOT block the main thread
  during its polling loop. Implementation should run the poll loop on the client
  thread (which is already off-main-thread), dispatching to main thread only for
  each screen content read, then sleeping on the client thread between polls.

- **Concurrent waits:** Each `wait_for` holds a client thread for the duration
  of the wait. A maximum concurrent wait limit (e.g., 8) should be enforced to
  prevent thread exhaustion from misbehaving clients.

- **Surface lifetime:** If the target surface is closed during a wait, the
  server must detect this (null surface pointer) and return an error immediately
  rather than waiting for timeout.

- **Regex safety:** The `text_match` regex should use a bounded execution engine
  (e.g., Zig's `std.regex` or a POSIX `regexec` with `REG_NOSUB`) to prevent
  catastrophic backtracking. Consider a maximum pattern length (e.g., 1024
  bytes) and execution timeout per match.

**Typical usage pattern (MCP agent executing a command):**

```
1. send_text: "make build\r"
2. wait_for: text_match "\\$\\s*$" (wait for prompt to return)
3. get_screen: read the output
```

### Batch Input

#### `send_keys`

Sends a sequence of key and text events with inter-element delays. Essential for
TUI interaction where timing matters (e.g., Neovim mode switches).

**Request:**
```json
{
  "version": 1,
  "action": {
    "send_keys": {
      "surface_id": "focused",
      "sequence": [
        { "key": "Escape" },
        { "text": ":wq" },
        { "key": "Enter" }
      ],
      "delay_ms": 50
    }
  }
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `surface_id` | string | required | Target surface. |
| `sequence` | array | required | Ordered list of key or text events. |
| `delay_ms` | u32 | `0` | Milliseconds to wait between each element. |

Each sequence element is one of:
- `{"key": "Escape", "mods": "ctrl"}` — key event (mods optional)
- `{"text": ":wq"}` — text injection

This replaces 3+ IPC round-trips with a single atomic request.

### Enhanced Screenshots

#### `screenshot_surface` (extended)

Phase 2 adds inline base64 mode alongside the existing file-path mode.

**Request (inline mode — no output_path):**
```json
{
  "version": 1,
  "action": {
    "screenshot_surface": {
      "surface_id": "focused"
    }
  }
}
```

**Response (inline mode):**
```json
{
  "ok": true,
  "data": {
    "format": "png",
    "width": 1200,
    "height": 800,
    "base64": "iVBORw0KGgoAAAANSUhEUgAA..."
  }
}
```

When `output_path` is present, the PNG is written to disk (Phase 1 behavior).
When absent, the PNG data is returned as a base64 string in the response. The
MCP server defaults to inline mode for AI agent convenience.

**Implementation notes:**

- Base64 encoding adds ~33% overhead. A 12 MB PNG would produce a ~16 MB
  response, hitting the frame size limit. Implementation should enforce a
  maximum inline image size (e.g., 10 MB raw PNG) and return an error
  suggesting file-path mode for larger captures.
- GTK's current `screenshotToFile` API writes directly to disk. Inline mode
  requires new plumbing to capture the PNG data in memory (e.g., using GDK's
  `gdk_texture_save_to_png_bytes` or writing to a memory buffer).

### Enriched Discovery

#### `list_surfaces` (extended)

Phase 2 adds richer metadata to the `list_surfaces` response:

```json
{
  "ok": true,
  "data": {
    "windows": [
      {
        "id": "0x7fff1234abcd",
        "focused": true,
        "position": { "x": 100, "y": 100 },
        "size": { "width": 1200, "height": 800 },
        "tabs": [
          {
            "id": "0x7fff1234abce",
            "title": "nvim",
            "active": true,
            "surfaces": [
              {
                "id": "0x7fff1234abcf",
                "title": "nvim main.rs",
                "focused": true,
                "pwd": "/home/user/project",
                "rows": 24,
                "cols": 80,
                "pid": 12345,
                "cell_size": { "width": 10, "height": 20 },
                "split": {
                  "direction": "horizontal",
                  "position": 0.5,
                  "sibling": "0x7fff1234abd0"
                }
              },
              {
                "id": "0x7fff1234abd0",
                "title": "cargo watch",
                "focused": false,
                "pwd": "/home/user/project",
                "rows": 24,
                "cols": 80,
                "pid": 12346,
                "cell_size": { "width": 10, "height": 20 },
                "split": {
                  "direction": "horizontal",
                  "position": 0.5,
                  "sibling": "0x7fff1234abcf"
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

New fields:

| Field | Location | Type | Description |
|-------|----------|------|-------------|
| `position` | window | `{x, y}` | Window position on screen in pixels. |
| `size` | window | `{width, height}` | Window dimensions in pixels. |
| `pid` | surface | u32 | Shell child process ID. |
| `cell_size` | surface | `{width, height}` | Cell dimensions in pixels. |
| `split` | surface | object? | Split info: `direction` (`"horizontal"` or `"vertical"`), `position` (0.0-1.0), `sibling` (surface ID). Null if not in a split. |

These fields are backwards-compatible additions — clients that don't need them
can ignore them.

---

## Actions — Phase 3 (Future)

These features are designed at a high level but not yet scheduled for
implementation. They are documented here to guide future work and ensure
architectural decisions in Phase 1-2 don't preclude them.

### Event Streaming

Real-time notifications when terminal state changes. Uses a long-lived
connection with newline-delimited JSON events.

#### `subscribe`

```json
{
  "version": 1,
  "action": {
    "subscribe": {
      "surface_id": "focused",
      "events": ["screen_change", "title_change", "cursor_move", "process_exit"]
    }
  }
}
```

After subscribing, the server keeps the connection open and sends events:

```json
{"event": "screen_change", "surface_id": "0x...", "timestamp_ms": 1704067200000}
{"event": "title_change", "surface_id": "0x...", "title": "vim main.rs"}
{"event": "process_exit", "surface_id": "0x...", "exit_code": 0}
```

Event connections are separate from request/response connections. A client can
maintain one subscription connection and one request connection simultaneously.

**Design constraints:**
- Events must not block the terminal's rendering pipeline
- The server must handle slow/disconnected subscribers gracefully (drop events)
- Event frequency should be throttled (e.g., screen_change at most every 100ms)

**Architecture impact:** The current transport model is one-request-per-
connection — the server reads a request, sends a response, and closes. Event
streaming requires a fundamentally different connection lifecycle (long-lived,
server-initiated writes). This will require server changes:
- Separate code path for subscription connections vs request connections
- Non-blocking write to subscriber sockets (with drop-on-backpressure)
- Connection cleanup when subscribers disconnect
- Thread-safe event dispatch from render/terminal threads to subscriber I/O

### Scrollback Access

#### `get_scrollback`

Paginated access to scrollback history, separate from the viewport.

```json
{
  "version": 1,
  "action": {
    "get_scrollback": {
      "surface_id": "focused",
      "offset": 0,
      "limit": 100,
      "format": "text"
    }
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
    "lines": ["$ git status", "On branch main", "..."],
    "has_more": true
  }
}
```

Currently, `get_screen` with `screen: "screen"` returns full scrollback, but
without pagination. For large scrollback buffers, a dedicated paginated action
avoids transferring megabytes of text.

### VT Format

#### `get_screen` with `format: "vt"`

Returns screen content as ANSI/VT escape sequences, suitable for terminal
replay or re-rendering in another terminal.

```json
{
  "ok": true,
  "data": {
    "content": "\u001b[1;32muser\u001b[0m@host:~/project$ ls -la\n...",
    "cursor_x": 28,
    "cursor_y": 0
  }
}
```

### Access Levels

Tiered permissions for different client types:

| Level | Operations | Use Case |
|-------|-----------|----------|
| `read` | list_surfaces, get_screen, get_scrollback, screenshot, wait_for | AI observation, monitoring |
| `write` | send_text, send_key, send_keys, send_mouse, send_scroll | Automation, input injection |
| `manage` | new_window, new_tab, close_surface, focus_surface, resize_surface | Window management |

Each level includes all lower levels. Implementation would use a token in the
request:

```json
{
  "version": 1,
  "token": "ghst_read_xxxx...",
  "action": { "get_screen": { "surface_id": "focused", "screen": "viewport" } }
}
```

Tokens would be generated by the Ghostty process and stored in a file readable
only by the owner. This enables scenarios like giving an AI agent read-only
access while preventing it from injecting input.

---

## Security Model

### Current Implementation

**Peer validation:** On every connection, the server verifies the client runs as
the same OS user:

| Platform | Mechanism |
|----------|-----------|
| Linux | `SO_PEERCRED` socket option — extracts peer PID, UID, GID |
| macOS | `getpeereid()` — extracts peer UID, GID |

Connections from different UIDs are rejected immediately.

**Filesystem permissions:**
- Socket directory: `0700` (owner only)
- Socket file: `0600` (owner read/write only)

**Path validation:** Screenshot output paths must be absolute and must not
contain `..` path components (validated per-component, not via substring match).

### Known Gaps

- **Socket startup race:** The server removes existing socket files on startup
  without verifying file type. A symlink at the socket path could cause
  unintended file deletion. Mitigation: verify file is a socket before unlinking.
- **Screenshot TOCTOU:** Path validation and file write are not atomic. A
  symlink placed between validation and write could redirect output. Mitigation:
  use `O_NOFOLLOW` and write-to-temp-then-rename.
- **No rate limiting:** A malicious local client can flood the server with
  requests. The peer UID check ensures same-user, but does not prevent abuse
  from compromised local processes.

### Future Enhancements

- **Token-based auth** for access levels (Phase 3)
- **User namespace validation** on Linux to prevent container escapes
- **Rate limiting** on write operations to prevent automation abuse
- **Socket file type verification** before unlink on startup

## MCP Server Integration

The protocol is designed for seamless MCP (Model Context Protocol) integration,
giving AI agents direct terminal control.

### Tool Design

The MCP server exposes two tools:

**`terminals`** — List all surfaces with IDs, titles, dimensions, focus state.

**`terminal`** — Unified interaction tool with an `action` parameter:

| Action | Description |
|--------|-------------|
| `read` | Get screen content (text format) |
| `send` | Send text to terminal (with optional execute flag for Enter) |
| `key` | Send key event (W3C key codes) |
| `mouse` | Send mouse event (click, drag, motion) |
| `scroll` | Send scroll event |
| `screenshot` | Capture terminal as PNG |
| `focus` | Bring terminal window to front |
| `close` | Close terminal |
| `resize` | Change terminal dimensions |
| `new_tab` | Open new tab |
| `new_window` | Open new window |

### AI Agent Workflow

Typical AI agent interaction pattern:

```
1. terminals()                    → discover surfaces
2. terminal(read, surface_id)     → see what's on screen
3. terminal(send, text="make")    → execute command
4. wait_for(text_match, "$")      → wait for completion (Phase 2)
5. terminal(read, surface_id)     → read output
6. terminal(screenshot)           → capture visual state if needed
```

The `wait_for` action (Phase 2) will transform MCP workflows from polling loops
to clean sequential operations.

### Additional MCP Features

The `terminal` tool also supports:
- `text_b64` parameter for sending exact byte sequences (base64-encoded)
- `execute` flag that appends a carriage return after text (convenience for
  running commands)

### Python Client Convenience Methods

The Python client provides higher-level methods beyond raw IPC:

- `click(surface_id, x, y)` — press + release at coordinates
- `press_key(surface_id, key)` — press + release a key
- `run_command(surface_id, cmd)` — send text + carriage return
- `get_focused_surface()` — find the focused surface without manual filtering

## Comparison with Alternatives

| Feature | Ghostty Automator | Kitty Remote | WezTerm | tmux Control | iTerm2 |
|---------|-------------------|--------------|---------|--------------|--------|
| Structured cell data | Yes (span format) | No | Via Lua | No | Yes (Python API) |
| Color/style info | Yes | Limited | Via Lua | No | Yes (screen API) |
| Input injection | Text + key + mouse + scroll | Text + key + scroll | Via Lua | Text only | Text (Python API) |
| Screenshot | PNG (file + base64) | No | No | No | No |
| AI/MCP integration | Native MCP server | No | No | No | No |
| Cross-platform protocol | Yes (one protocol) | Yes | Yes | Yes | macOS only |
| Wait/sync primitives | Planned (Phase 2) | No | Via Lua | Streaming | No |
| Window management | Yes | Yes | Via Lua | N/A | Yes |
| Security model | UID + permissions | Password + encryption | Process | Implicit | Cookie auth |
| Transport | Unix socket + JSON | Unix socket + JSON | Lua API | Pipe | Unix socket + Python API |
| Auth encryption | No (local only) | ECDH + AES-256 | No | No | No |

**Key differentiators:**
- Only terminal with native MCP/AI agent support
- Mouse and scroll injection (unique for automation)
- Span-based cell format with ~450x compression
- Server-side `wait_for` (planned) — no other terminal has this

## Implementation Status

| Action | Phase | GTK | macOS | CLI | MCP |
|--------|-------|-----|-------|-----|-----|
| `list_surfaces` | 1 | Done | Done | Done | Done |
| `get_screen` (text) | 1 | Done | Done | Done | Done |
| `get_screen` (cells) | 1 | — | Done | Done | — |
| `send_text` | 1 | Done | Done | Done | Done |
| `send_key` | 1 | Done | Done | — | Done |
| `send_mouse` | 1 | Done | Done | — | Done |
| `send_scroll` | 1 | Done | Done | — | Done |
| `screenshot_surface` | 1 | Done | Done | Done | Done |
| `focus_surface` | 1 | Done | Done | Done | Done |
| `close_surface` | 1 | Done | Done | Done | Done |
| `resize_surface` | 1 | Done | Done | Done | Done |
| `new_window` | 1 | Done | Done | Done | Done |
| `new_tab` | 1 | Done | Done | Done | Done |
| `wait_for` | 2 | — | — | — | — |
| `send_keys` | 2 | — | — | — | — |
| `screenshot` (base64) | 2 | — | — | — | — |
| `list_surfaces` (enriched) | 2 | — | — | — | — |
| `focused` alias | 2 | — | — | — | — |
| Index path aliases | 2 | — | — | — | — |
| `subscribe` (events) | 3 | — | — | — | — |
| `get_scrollback` | 3 | — | — | — | — |
| `get_screen` (vt) | 3 | — | — | — | — |
| Access levels | 3 | — | — | — | — |

## References

- [W3C UI Events KeyboardEvent code Values](https://www.w3.org/TR/uievents-code/)
- [Chrome DevTools Protocol](https://chromedevtools.github.io/devtools-protocol/)
- [Kitty Remote Control Protocol](https://sw.kovidgoyal.net/kitty/rc_protocol/)
- [tmux Control Mode](https://github.com/tmux/tmux/wiki/Control-mode)
- [Model Context Protocol](https://modelcontextprotocol.io/)
- [Ghostty Source: socket.zig](../src/apprt/socket.zig)
- [Ghostty Source: ipc.zig](../src/apprt/ipc.zig)
- [Ghostty Source: ipc/server.zig](../src/apprt/ipc/server.zig)
