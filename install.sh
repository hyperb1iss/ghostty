#!/usr/bin/env bash
# Ghostty Automator — Install Script
# Usage: curl -fsSL https://raw.githubusercontent.com/hyperb1iss/ghostty-automator/automator/install.sh | bash
#
# Options (via env vars):
#   INSTALL_DIR   — where to install (default: ~/.local)
#   VERSION       — version to install (default: latest)
#   SKILL_DIR     — where to install the skill (default: ~/.claude/skills)

set -euo pipefail

REPO="hyperb1iss/ghostty-automator"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local}"
SKILL_DIR="${SKILL_DIR:-$HOME/.claude/skills}"
VERSION="${VERSION:-latest}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

info()  { echo -e "${CYAN}▸${RESET} $*"; }
ok()    { echo -e "${GREEN}✓${RESET} $*"; }
warn()  { echo -e "${YELLOW}!${RESET} $*"; }
error() { echo -e "${RED}✗${RESET} $*" >&2; exit 1; }

# --- Detect platform ---
detect_platform() {
    local os arch
    os="$(uname -s)"
    arch="$(uname -m)"

    case "$os" in
        Darwin) OS="macos" ;;
        Linux)  OS="linux" ;;
        *)      error "Unsupported OS: $os" ;;
    esac

    case "$arch" in
        x86_64|amd64)   ARCH="x86_64" ;;
        arm64|aarch64)   ARCH="arm64" ;;
        *)               error "Unsupported architecture: $arch" ;;
    esac
}

# --- Resolve version ---
resolve_version() {
    if [ "$VERSION" = "latest" ]; then
        info "Fetching latest release..."
        VERSION="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
            | grep '"tag_name"' | head -1 | sed 's/.*"v\([^"]*\)".*/\1/')"
        [ -n "$VERSION" ] || error "Could not determine latest version"
    fi
    ok "Version: ${BOLD}v${VERSION}${RESET}"
}

# --- Download & install ---
install_binary() {
    local url artifact tmpdir

    if [ "$OS" = "macos" ]; then
        artifact="ghostty-automator-macos-${ARCH}.zip"
    else
        artifact="ghostty-automator-linux-${ARCH}.tar.gz"
    fi

    url="https://github.com/${REPO}/releases/download/v${VERSION}/${artifact}"
    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' EXIT

    info "Downloading ${artifact}..."
    curl -fSL --progress-bar -o "${tmpdir}/${artifact}" "$url" \
        || error "Download failed. Check that v${VERSION} exists at ${REPO}"

    info "Extracting..."
    if [ "$OS" = "macos" ]; then
        unzip -qo "${tmpdir}/${artifact}" -d "${tmpdir}/extract"

        # Install the .app bundle
        local app_dest="/Applications/Ghostty Automator.app"
        if [ -d "$app_dest" ]; then
            warn "Replacing existing ${app_dest}"
            rm -rf "$app_dest"
        fi
        cp -R "${tmpdir}/extract/Ghostty.app" "$app_dest"
        ok "Installed ${BOLD}${app_dest}${RESET}"

        # Also install CLI binary for direct use
        if [ -f "${tmpdir}/extract/ghostty" ]; then
            mkdir -p "${INSTALL_DIR}/bin"
            cp "${tmpdir}/extract/ghostty" "${INSTALL_DIR}/bin/ghostty-automator"
            chmod +x "${INSTALL_DIR}/bin/ghostty-automator"
            ok "Installed CLI to ${BOLD}${INSTALL_DIR}/bin/ghostty-automator${RESET}"
        fi

        # Install skill from archive
        if [ -d "${tmpdir}/extract/skills" ]; then
            install_skill_from "${tmpdir}/extract/skills"
        fi
    else
        mkdir -p "${tmpdir}/extract"
        tar xzf "${tmpdir}/${artifact}" -C "${tmpdir}/extract"

        # Install binary
        mkdir -p "${INSTALL_DIR}/bin"
        cp "${tmpdir}/extract/bin/ghostty" "${INSTALL_DIR}/bin/ghostty-automator"
        chmod +x "${INSTALL_DIR}/bin/ghostty-automator"
        ok "Installed CLI to ${BOLD}${INSTALL_DIR}/bin/ghostty-automator${RESET}"

        # Install terminfo, shell integration, etc.
        if [ -d "${tmpdir}/extract/share" ]; then
            cp -R "${tmpdir}/extract/share" "${INSTALL_DIR}/"
            ok "Installed share data to ${INSTALL_DIR}/share"
        fi

        # Install skill from archive
        if [ -d "${tmpdir}/extract/skills" ]; then
            install_skill_from "${tmpdir}/extract/skills"
        fi
    fi
}

# --- Install Claude Code skill ---
install_skill_from() {
    local src="$1"
    if [ -d "${src}/ghostty-terminal-automation" ]; then
        mkdir -p "${SKILL_DIR}"
        cp -R "${src}/ghostty-terminal-automation" "${SKILL_DIR}/"
        ok "Installed skill to ${BOLD}${SKILL_DIR}/ghostty-terminal-automation${RESET}"
    fi
}

# --- PATH check ---
check_path() {
    local bin_dir="${INSTALL_DIR}/bin"
    if [[ ":$PATH:" != *":${bin_dir}:"* ]]; then
        echo ""
        warn "${bin_dir} is not in your PATH"
        echo -e "  Add it to your shell profile:"
        echo -e "    ${CYAN}export PATH=\"${bin_dir}:\$PATH\"${RESET}"
        echo ""
    fi
}

# --- Main ---
main() {
    echo -e "${BOLD}${CYAN}"
    echo "  ╔══════════════════════════════════════╗"
    echo "  ║    Ghostty Automator — Installer     ║"
    echo "  ╚══════════════════════════════════════╝"
    echo -e "${RESET}"

    detect_platform
    info "Platform: ${BOLD}${OS}-${ARCH}${RESET}"

    resolve_version
    install_binary
    check_path

    echo ""
    echo -e "${GREEN}${BOLD}Installation complete!${RESET}"
    echo ""
    echo -e "  ${BOLD}Usage:${RESET}"
    if [ "$OS" = "macos" ]; then
        echo -e "    Open ${CYAN}Ghostty Automator.app${RESET} from Applications"
        echo -e "    Or use the CLI: ${CYAN}ghostty-automator +list-surfaces${RESET}"
    else
        echo -e "    ${CYAN}ghostty-automator +list-surfaces${RESET}"
    fi
    echo ""
    echo -e "  ${BOLD}Skill:${RESET} Installed to ${CYAN}${SKILL_DIR}/ghostty-terminal-automation${RESET}"
    echo -e "  Claude Code will automatically discover it."
    echo ""
}

main "$@"
