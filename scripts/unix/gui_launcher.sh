#!/usr/bin/env bash
# gui_launcher.sh - Native graphical front-end for Linux (zenity) and
# macOS (osascript), falling back to the terminal launcher when neither is
# usable.
#
# The dialogs are only a front-end: detection, decision and command assembly
# all come from the same modules the terminal launcher uses, so the two paths
# cannot drift apart.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/detect.sh"
source "$SCRIPT_DIR/decide.sh"
source "$SCRIPT_DIR/build_command.sh"
source "$SCRIPT_DIR/lock.sh"
source "$SCRIPT_DIR/setup_core.sh"

config_load "$ROOT_DIR/config.json"

VMS_DIR="$ROOT_DIR/vms"
DECISION_ISO=""

source "$SCRIPT_DIR/gui_dialogs.sh"
if [ -z "$GUI" ]; then
    # No dialog toolkit: the terminal launcher is a complete front-end, so
    # hand over to it rather than failing.
    exec "$SCRIPT_DIR/launcher.sh" "$@"
fi

# ---- Launch --------------------------------------------------------------
# Runs QEMU with the argv array. FULL_COMMAND_STR is never executed - it is a
# display string, and eval'ing it would re-split any path containing a space.
launch_vm() {
    local vm_dir="$1"

    if ! pvm_lock_guard "$vm_dir"; then
        gui_error "This VM is already running (locked by $PVM_LOCK_OWNER).\n\nTwo QEMU processes sharing one disk image will corrupt it."
        return 1
    fi

    build_qemu_command
    "$QEMU_PATH" "${QEMU_ARGS[@]}"
    local rc=$?
    pvm_lock_release
    return $rc
}

# Renders the decision as a short confirmation body, including anything the
# engine had to downgrade, so surprises show up before launch rather than after.
decision_summary_text() {
    local text
    text="RAM: ${DECISION_RAM_MB} MB
Cores: ${DECISION_CORES}
Guest: ${DECISION_ARCH} (${DECISION_MACHINE})
Acceleration: ${DECISION_ACCEL}
Display: ${DECISION_DISPLAY}
UEFI: ${DECISION_UEFI}"
    if [ -n "$DECISION_ACCEL_WARN" ]; then
        text="$text

Note: $DECISION_ACCEL_WARN"
    fi
    if [ "${#DECISION_WARNINGS[@]}" -gt 0 ]; then
        local w
        for w in "${DECISION_WARNINGS[@]}"; do
            text="$text
Note: $w"
        done
    fi
    printf '%s' "$text"
}

decision_errors_text() {
    local text="" e
    if [ "${#DECISION_ERRORS[@]}" -gt 0 ]; then
        for e in "${DECISION_ERRORS[@]}"; do
            text="$text
- $e"
        done
    fi
    printf '%s' "$text"
}

# ---- Main flow -----------------------------------------------------------
detect_host_info "$ROOT_DIR"

VM_LIST=()
if [ -d "$VMS_DIR" ]; then
    for d in "$VMS_DIR"/*; do
        [ -d "$d" ] || continue
        VM_LIST[${#VM_LIST[@]}]="$(basename "$d")"
    done
fi

MENU=("[+ New VM]")
if [ "${#VM_LIST[@]}" -gt 0 ]; then
    MENU[${#MENU[@]}]="[- Delete VM]"
    for name in "${VM_LIST[@]}"; do
        MENU[${#MENU[@]}]="$name"
    done
fi

PROMPT="Host: $HOST_OS ($HOST_ARCH) | Cores: $HOST_LOGICAL_CORES | Free RAM: ${HOST_AVAIL_RAM_MB} MB | Free disk: ${HOST_SSD_FREE_GB} GB"

SELECTED_VM="$(gui_choose "$PROMPT" "${MENU[@]}")" || exit 0
[ -n "$SELECTED_VM" ] || exit 0

# ---- New VM --------------------------------------------------------------
if [ "$SELECTED_VM" = "[+ New VM]" ]; then
    if [ -z "$QEMU_IMG_PATH" ]; then
        gui_error "qemu-img was not found. Install QEMU, or place a portable build under 'backends/'."
        exit 1
    fi

    SETUP_VM_NAME="$(gui_entry "Name for the new VM:")" || exit 0
    [ -n "$SETUP_VM_NAME" ] || exit 0

    VAL_NAME="$(test_vm_name_valid "$SETUP_VM_NAME" "$VMS_DIR")"
    if [ "${VAL_NAME%%|*}" = "false" ]; then
        gui_error "${VAL_NAME#*|}"
        exit 1
    fi

    SETUP_ISO_PATH="$(gui_pick_iso)" || exit 0
    [ -n "$SETUP_ISO_PATH" ] || exit 0

    VAL_ISO="$(test_iso_file_valid "$SETUP_ISO_PATH")"
    if [ "${VAL_ISO%%|*}" = "false" ]; then
        gui_error "$(printf '%s' "$VAL_ISO" | cut -d'|' -f2)"
        exit 1
    fi

    SETUP_DISK_SIZE="$(gui_entry "Virtual disk size in GB:" "64")" || exit 0
    [ -n "$SETUP_DISK_SIZE" ] || exit 0

    VAL_SPACE="$(test_disk_space_available "$SETUP_DISK_SIZE" "$HOST_SSD_FREE_GB")"
    SPACE_OK="$(printf '%s' "$VAL_SPACE" | cut -d'|' -f1)"
    SPACE_LEVEL="$(printf '%s' "$VAL_SPACE" | cut -d'|' -f2)"
    SPACE_MSG="$(printf '%s' "$VAL_SPACE" | cut -d'|' -f3)"
    if [ "$SPACE_OK" = "false" ]; then
        gui_error "$SPACE_MSG"
        exit 1
    elif [ "$SPACE_LEVEL" = "WARNING" ]; then
        gui_confirm "$SPACE_MSG

Continue anyway?" || exit 0
    fi

    RES_NEW="$(new_vm_instance "$SETUP_VM_NAME" "$VMS_DIR" "$SETUP_DISK_SIZE" "$QEMU_IMG_PATH" "$QEMU_ARCH")"
    if [ "${RES_NEW%%|*}" = "false" ]; then
        gui_error "$(printf '%s' "$RES_NEW" | cut -d'|' -f2-)"
        exit 1
    fi

    TARGET_DIR="$(printf '%s' "$RES_NEW" | cut -d'|' -f3)"

    run_decision_engine "$ROOT_DIR" "$TARGET_DIR"
    DECISION_ISO="$SETUP_ISO_PATH"

    if [ "$DECISION_IS_VALID" -ne 1 ]; then
        gui_error "Cannot start the installer:$(decision_errors_text)"
        exit 1
    fi

    gui_confirm "Install '$SETUP_VM_NAME' from:
$(basename "$SETUP_ISO_PATH")

$(decision_summary_text)" || exit 0

    launch_vm "$TARGET_DIR"
    exit $?
fi

# ---- Delete VM -----------------------------------------------------------
if [ "$SELECTED_VM" = "[- Delete VM]" ]; then
    DEL_TARGET="$(gui_choose "Select the VM to delete:" "${VM_LIST[@]}")" || exit 0
    [ -n "$DEL_TARGET" ] || exit 0
    exec "$SCRIPT_DIR/delete_wizard.sh" "$DEL_TARGET" "$VMS_DIR"
fi

# ---- Launch existing VM --------------------------------------------------
VM_DIR="$VMS_DIR/$SELECTED_VM"
if [ ! -d "$VM_DIR" ]; then
    gui_error "VM '$SELECTED_VM' no longer exists."
    exit 1
fi

run_decision_engine "$ROOT_DIR" "$VM_DIR"

if [ "$DECISION_IS_VALID" -ne 1 ]; then
    gui_error "Cannot launch '$SELECTED_VM':$(decision_errors_text)"
    exit 1
fi

gui_confirm "Launch '$SELECTED_VM'?

$(decision_summary_text)" || exit 0

launch_vm "$VM_DIR"
exit $?
