# ── ghostty-automator justfile ──────────────────────────────────
# https://github.com/hyperb1iss/ghostty-automator

# List available recipes
default:
    @just --list --unsorted

# ── Build ───────────────────────────────────────────────────────

# Build (debug)
build:
    zig build

# Build (release)
build-release:
    zig build -Doptimize=ReleaseFast -Dsentry=false -Dxcframework-target=native

# Build CLI only (skip macOS app bundle)
build-cli:
    zig build -Demit-macos-app=false

# Build with Nix devshell (matches CI)
build-nix:
    nix develop -c zig build -Doptimize=ReleaseFast

# ── Run ─────────────────────────────────────────────────────────

# Run ghostty-automator
run *args:
    zig build run -- {{args}}

# List all surfaces (JSON)
surfaces:
    ghostty-automator +list-surfaces --format=json

# Read screen from a surface
screen surface:
    ghostty-automator +get-screen --surface={{surface}}

# Send text to a surface (include \r for Enter)
send surface text:
    ghostty-automator +send-text --surface={{surface}} --text="{{text}}"

# Send a key event to a surface
key surface key *mods:
    #!/usr/bin/env bash
    if [ -n "{{mods}}" ]; then
        ghostty-automator +send-key --surface={{surface}} --key={{key}} --mods={{mods}}
    else
        ghostty-automator +send-key --surface={{surface}} --key={{key}}
    fi

# Screenshot a surface
screenshot surface output="/tmp/ghostty-screenshot.png":
    ghostty-automator +screenshot-surface --surface={{surface}} --output={{output}}

# Open a new window
new-window:
    ghostty-automator +new-window

# Open a new tab
new-tab:
    ghostty-automator +new-tab

# ── Quality ─────────────────────────────────────────────────────

# Run all checks (fmt + test)
check: fmt-check test

# Format Zig code
fmt:
    zig fmt .

# Check formatting without modifying
fmt-check:
    zig fmt --check .

# ── Test ────────────────────────────────────────────────────────

# Run all tests (slow — prefer test-one)
test:
    zig build test

# Run a specific test by name
test-one name:
    zig build test -Dtest-filter={{name}}

# Run tests with Nix devshell
test-nix:
    nix develop -c zig build test

# ── Install ─────────────────────────────────────────────────────

# Install to /usr/local/bin
install: build-release
    cp -R zig-out/Ghostty.app "/Applications/Ghostty Automator.app"
    sudo ln -sf "/Applications/Ghostty Automator.app/Contents/MacOS/ghostty" /usr/local/bin/ghostty-automator

# Install skills to Claude Code plugin directory
install-skills dest="~/.claude/skills":
    mkdir -p {{dest}}/ghostty-terminal-automation
    cp skills/ghostty-terminal-automation/SKILL.md {{dest}}/ghostty-terminal-automation/

# ── Clean ───────────────────────────────────────────────────────

# Remove all build artifacts
clean:
    rm -rf zig-out .zig-cache macos/build macos/GhosttyKit.xcframework
