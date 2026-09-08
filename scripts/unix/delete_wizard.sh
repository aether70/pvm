#!/usr/bin/env bash
# delete_wizard.sh - Graphical VM deletion for Linux and macOS.
#
# The confirmation asks the user to retype the VM name. A yes/no dialog is too
# easy to dismiss on autopilot for an action with no undo, and the disk image
# is usually the only copy of the guest.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/gui_dialogs.sh"
source "$SCRIPT_DIR/lock.sh"

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <VmName> <VmsDir>" >&2
    exit 2
fi

VM_NAME="$1"
VMS_DIR="$2"
TARGET_DIR="$VMS_DIR/$VM_NAME"

if [ -z "$GUI" ]; then
    echo "No graphical dialog toolkit available. Use: launch.sh --delete --vm-name '$VM_NAME'" >&2
    exit 1
fi

if [ ! -d "$TARGET_DIR" ]; then
    gui_error "VM '$VM_NAME' was not found."
    exit 1
fi

# Refuse while the VM is running: deleting the backing image out from under a
# live QEMU is the exact race the instance lock exists to prevent.
if ! pvm_lock_acquire "$TARGET_DIR"; then
    gui_error "VM '$VM_NAME' appears to be running (locked by $PVM_LOCK_OWNER).

Shut it down before deleting it."
    exit 1
fi

SIZE="$(du -sh "$TARGET_DIR" 2>/dev/null | awk '{ print $1 }')"
[ -n "$SIZE" ] || SIZE="unknown"

TYPED="$(gui_entry "Permanently delete '$VM_NAME' ($SIZE on disk)?

This cannot be undone. Type the VM name to confirm:")" || { pvm_lock_release; exit 0; }

if [ "$TYPED" != "$VM_NAME" ]; then
    pvm_lock_release
    gui_error "The name did not match. Nothing was deleted."
    exit 1
fi

# Release before removing: the lock directory lives inside the tree we are
# about to delete, and the EXIT trap would otherwise try to clean up a path
# that no longer exists.
pvm_lock_release

if rm -rf "$TARGET_DIR" && [ ! -d "$TARGET_DIR" ]; then
    gui_info "Deleted VM '$VM_NAME'."
    exit 0
fi

gui_error "Failed to fully delete '$VM_NAME'. Some files may remain in:
$TARGET_DIR"
exit 1
