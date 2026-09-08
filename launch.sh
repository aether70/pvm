#!/usr/bin/env bash
# Root entry point for Linux and macOS
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
chmod +x "$SCRIPT_DIR/scripts/unix/"*.sh 2>/dev/null
exec "$SCRIPT_DIR/scripts/unix/launcher.sh" "$@"
