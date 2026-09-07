#!/usr/bin/env bash
# Portable Virtual Computer - Unix GUI Launcher Entrypoint

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
chmod +x "$SCRIPT_DIR/scripts/unix/gui_launcher.sh"
"$SCRIPT_DIR/scripts/unix/gui_launcher.sh" "$@"
