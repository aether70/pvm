#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# setup.sh - PortableVM Initialization Wizard for Linux and macOS
#
# This is the Unix counterpart to setup.bat / setup_installer.ps1.
# It downloads pre-compiled QEMU engine binaries from the project's GitHub
# Releases page and extracts them into the backends/ directory so the USB
# drive becomes a fully portable, universal VM launcher.
#
# Requirements: curl, unzip (both pre-installed on virtually all Linux/macOS)
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_OWNER="aether70"
REPO_NAME="pvm"
DEFAULT_TAG="qemu-engines-v1.0.0"

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# ── Helper Functions ─────────────────────────────────────────────────────────

print_banner() {
    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}${BOLD}║          PortableVM - Initialization Wizard             ║${RESET}"
    echo -e "${CYAN}${BOLD}║          Linux & macOS Setup                            ║${RESET}"
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
    echo ""
}

print_host_info() {
    local os arch
    os="$(uname -s)"
    arch="$(uname -m)"
    echo -e "${DIM}Host OS      : ${RESET}${os}"
    echo -e "${DIM}Architecture : ${RESET}${arch}"
    echo -e "${DIM}Drive Root   : ${RESET}${SCRIPT_DIR}"
    echo ""
}

check_dependencies() {
    local missing=0
    for cmd in curl unzip; do
        if ! command -v "$cmd" &>/dev/null; then
            echo -e "${RED}[!] Required tool '${cmd}' is not installed.${RESET}"
            missing=1
        fi
    done
    if [ "$missing" -eq 1 ]; then
        echo -e "${RED}    Please install the missing tools and re-run this script.${RESET}"
        echo -e "${DIM}    Ubuntu/Debian : sudo apt install curl unzip${RESET}"
        echo -e "${DIM}    Fedora/RHEL   : sudo dnf install curl unzip${RESET}"
        echo -e "${DIM}    macOS         : These are pre-installed on macOS.${RESET}"
        exit 1
    fi
}

prompt_yes_no() {
    local prompt="$1" default="${2:-n}" reply
    if [ "$default" = "y" ]; then
        prompt="$prompt [Y/n]: "
    else
        prompt="$prompt [y/N]: "
    fi
    read -rp "$prompt" reply
    reply="${reply:-$default}"
    case "$reply" in
        [Yy]*) return 0 ;;
        *)     return 1 ;;
    esac
}

# download_and_extract <zip_name> <dest_dir> <base_url>
download_and_extract() {
    local zip_name="$1"
    local dest_dir="$2"
    local base_url="$3"
    local url="${base_url}/${zip_name}"
    local temp_zip="/tmp/${zip_name}"

    echo -e "  ${CYAN}↓${RESET} Downloading ${BOLD}${zip_name}${RESET} ..."
    if ! curl -fSL --progress-bar -o "$temp_zip" "$url"; then
        echo -e "  ${RED}[!] Download failed: ${url}${RESET}"
        echo -e "  ${RED}    Make sure you have uploaded this file to your GitHub Release.${RESET}"
        rm -f "$temp_zip"
        return 1
    fi

    echo -e "  ${CYAN}⤳${RESET} Extracting to ${DIM}${dest_dir}${RESET} ..."
    mkdir -p "$dest_dir"
    unzip -qo "$temp_zip" -d "$dest_dir"

    rm -f "$temp_zip"
    echo -e "  ${GREEN}✓${RESET} ${zip_name} installed successfully."
    echo ""
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    print_banner
    check_dependencies
    print_host_info

    # ── Step 1: Release Tag ──────────────────────────────────────────────────
    echo -e "${BOLD}Step 1: QEMU Release Tag${RESET}"
    echo -e "${DIM}This tag determines which pre-compiled QEMU version to download${RESET}"
    echo -e "${DIM}from the GitHub Releases page of ${REPO_OWNER}/${REPO_NAME}.${RESET}"
    echo ""
    read -rp "Enter release tag [${DEFAULT_TAG}]: " input_tag
    RELEASE_TAG="${input_tag:-$DEFAULT_TAG}"
    BASE_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/${RELEASE_TAG}"
    echo -e "${GREEN}Using tag: ${RELEASE_TAG}${RESET}"
    echo ""

    # ── Step 2: Select Engines ───────────────────────────────────────────────
    echo -e "${BOLD}Step 2: Select QEMU Engines to Install${RESET}"
    echo -e "${DIM}Choose which platform engines to download to this drive.${RESET}"
    echo -e "${DIM}You only need the engine(s) matching the computer(s) you will${RESET}"
    echo -e "${DIM}plug this drive into.${RESET}"
    echo ""

    DO_WIN_X64=false
    DO_LIN_X64=false
    DO_LIN_ARM64=false
    DO_MAC_X64=false
    DO_MAC_ARM64=false

    # Auto-detect the current platform and pre-select it
    local host_os host_arch
    host_os="$(uname -s)"
    host_arch="$(uname -m)"

    local default_win="n" default_lin_x64="n" default_lin_arm="n" default_mac_x64="n" default_mac_arm="n"
    if [ "$host_os" = "Linux" ]; then
        case "$host_arch" in
            x86_64|amd64) default_lin_x64="y" ;;
            aarch64|arm64) default_lin_arm="y" ;;
        esac
    elif [ "$host_os" = "Darwin" ]; then
        case "$host_arch" in
            x86_64) default_mac_x64="y" ;;
            arm64)  default_mac_arm="y" ;;
        esac
    fi

    prompt_yes_no "  Install Windows Engine (x86_64)?"       "$default_win"     && DO_WIN_X64=true
    prompt_yes_no "  Install Linux Engine   (x86_64)?"       "$default_lin_x64" && DO_LIN_X64=true
    prompt_yes_no "  Install Linux Engine   (ARM64)?"        "$default_lin_arm" && DO_LIN_ARM64=true
    prompt_yes_no "  Install macOS Engine   (Apple Silicon)?" "$default_mac_arm" && DO_MAC_ARM64=true
    echo ""

    if ! $DO_WIN_X64 && ! $DO_LIN_X64 && ! $DO_LIN_ARM64 && ! $DO_MAC_ARM64; then
        echo -e "${RED}[!] No engines selected. Nothing to install. Exiting.${RESET}"
        exit 1
    fi

    # ── Step 3: Confirm ──────────────────────────────────────────────────────
    echo -e "${BOLD}Step 3: Confirm Installation${RESET}"
    echo -e "  Release Tag : ${CYAN}${RELEASE_TAG}${RESET}"
    echo -e "  Install To  : ${CYAN}${SCRIPT_DIR}/backends/${RESET}"
    echo ""
    echo "  Engines selected:"
    $DO_WIN_X64   && echo -e "    ${GREEN}✓${RESET} Windows x86_64"
    $DO_LIN_X64   && echo -e "    ${GREEN}✓${RESET} Linux x86_64"
    $DO_LIN_ARM64 && echo -e "    ${GREEN}✓${RESET} Linux ARM64"
    $DO_MAC_ARM64 && echo -e "    ${GREEN}✓${RESET} macOS Apple Silicon (ARM64)"
    echo ""

    if ! prompt_yes_no "  Proceed with download and installation?" "y"; then
        echo -e "${YELLOW}Cancelled by user.${RESET}"
        exit 0
    fi
    echo ""

    # ── Step 4: Download & Extract ───────────────────────────────────────────
    echo -e "${BOLD}Step 4: Downloading & Extracting Engines${RESET}"
    echo ""

    local failed=0

    if $DO_WIN_X64; then
        download_and_extract "qemu-windows-x86_64.zip" "${SCRIPT_DIR}/backends/windows/qemu" "$BASE_URL" || failed=1
    fi
    if $DO_LIN_X64; then
        download_and_extract "qemu-linux-x86_64.zip" "${SCRIPT_DIR}/backends/linux/qemu" "$BASE_URL" || failed=1
    fi
    if $DO_LIN_ARM64; then
        download_and_extract "qemu-linux-arm64.zip" "${SCRIPT_DIR}/backends/linux/qemu" "$BASE_URL" || failed=1
    fi
    if $DO_MAC_ARM64; then
        download_and_extract "qemu-macos-arm64.zip" "${SCRIPT_DIR}/backends/macos/qemu" "$BASE_URL" || failed=1
    fi

    # ── Step 5: Verify ───────────────────────────────────────────────────────
    echo -e "${BOLD}Step 5: Verification${RESET}"
    echo ""

    local verified=0
    for backend_dir in "${SCRIPT_DIR}/backends"/*/qemu; do
        if [ -d "$backend_dir" ]; then
            local bin_count
            bin_count="$(find "$backend_dir" -maxdepth 2 -name 'qemu-system-*' -o -name 'qemu-system-*.exe' 2>/dev/null | wc -l | tr -d ' ')"
            local platform
            platform="$(basename "$(dirname "$backend_dir")")"
            if [ "$bin_count" -gt 0 ]; then
                echo -e "  ${GREEN}✓${RESET} ${platform}: ${bin_count} QEMU binary(ies) found"
                verified=$((verified + 1))
            else
                echo -e "  ${YELLOW}⚠${RESET} ${platform}: directory exists but no QEMU binaries found"
            fi
        fi
    done

    if [ "$verified" -eq 0 ] && [ "$failed" -eq 1 ]; then
        echo -e "  ${RED}[!] No engines were installed successfully.${RESET}"
        echo -e "  ${RED}    Ensure the release '${RELEASE_TAG}' exists on GitHub with the correct .zip files.${RESET}"
        exit 1
    fi

    echo ""
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${GREEN}${BOLD}║          Setup Complete!                                 ║${RESET}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
    echo ""
    echo -e "  You can now launch VMs with:"
    echo -e "    ${CYAN}./launch.sh${RESET}       (Terminal mode)"
    echo -e "    ${CYAN}./launch_gui.sh${RESET}   (GUI mode - requires zenity or macOS)"
    echo ""
}

main "$@"
