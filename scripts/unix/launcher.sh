#!/usr/bin/env bash
# launcher.sh - Terminal orchestrator for the Portable VM Launcher (Unix).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/detect.sh"
source "$SCRIPT_DIR/decide.sh"
source "$SCRIPT_DIR/build_command.sh"
source "$SCRIPT_DIR/display.sh"
source "$SCRIPT_DIR/lock.sh"

config_load "$ROOT_DIR/config.json"

DETECT_ONLY=0
DRY_RUN=0
LIST_VMS=0
SETUP_MODE=0
DELETE_MODE=0
TARGET_VM_NAME=""
NO_PROMPT=0
TARGET_VM_NAME=""
DECISION_ISO=""

usage() {
    cat <<'USAGE'
Usage: launch.sh [options]

  -d, --detect-only     Print host detection results and exit.
  -n, --dry-run         Build and print the QEMU command without launching.
  -l, --list-vms        List the VMs found under vms/ and exit.
  -s, --setup           Create a new VM and boot it from an installer ISO.
      --delete          Delete a VM (requires --vm-name).
  -v, --vm-name NAME    Operate on this VM instead of prompting.
  -y, --no-prompt       Skip all interactive confirmation.
  -h, --help            Show this message.
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --detect-only|-d) DETECT_ONLY=1; shift ;;
        --dry-run|-n)     DRY_RUN=1; shift ;;
        --list-vms|-l)    LIST_VMS=1; shift ;;
        --setup|-s)       SETUP_MODE=1; shift ;;
        --delete)         DELETE_MODE=1; shift ;;
        --no-prompt|-y)   NO_PROMPT=1; shift ;;
        --help|-h)        usage; exit 0 ;;
        --vm-name|-v)
            if [ $# -lt 2 ]; then
                echo "  [!] --vm-name requires an argument." >&2
                exit 2
            fi
            TARGET_VM_NAME="$2"; shift 2 ;;
        *)
            echo "  [!] Unknown option: $1" >&2
            usage >&2
            exit 2 ;;
    esac
done

VMS_DIR="$ROOT_DIR/vms"

show_banner

# ---- 1. Host detection --------------------------------------------------
detect_host_info "$ROOT_DIR"
show_host_info

if [ "$DETECT_ONLY" -eq 1 ]; then
    echo "  [i] Detection completed (--detect-only specified)."
    exit 0
fi

# ---- 2. Setup mode ------------------------------------------------------
if [ "$SETUP_MODE" -eq 1 ]; then
    source "$SCRIPT_DIR/setup_core.sh"
    echo -e "\n${COLOR_GREEN}  [+] NEW VM SETUP${COLOR_RESET}"

    if [ -z "$QEMU_IMG_PATH" ]; then
        echo -e "${COLOR_RED}  [!] qemu-img not found. Install QEMU before creating a VM.${COLOR_RESET}"
        exit 1
    fi

    read -r -p "  VM Name: " SETUP_VM_NAME
    VAL_NAME="$(test_vm_name_valid "$SETUP_VM_NAME" "$VMS_DIR")"
    if [ "${VAL_NAME%%|*}" = "false" ]; then
        echo -e "${COLOR_RED}  [!] ${VAL_NAME#*|}${COLOR_RESET}"
        exit 1
    fi

    read -r -p "  Installer ISO path: " SETUP_ISO_PATH
    VAL_ISO="$(test_iso_file_valid "$SETUP_ISO_PATH")"
    if [ "${VAL_ISO%%|*}" = "false" ]; then
        IFS='|' read -r _ MSG _ <<< "$VAL_ISO"
        echo -e "${COLOR_RED}  [!] $MSG${COLOR_RESET}"
        exit 1
    fi
    IFS='|' read -r _ MSG _ <<< "$VAL_ISO"
    echo -e "${COLOR_GRAY}      $MSG${COLOR_RESET}"

    read -r -p "  Root disk size in GB [64]: " SETUP_DISK_SIZE
    SETUP_DISK_SIZE="${SETUP_DISK_SIZE:-64}"

    VAL_SPACE="$(test_disk_space_available "$SETUP_DISK_SIZE" "$HOST_SSD_FREE_GB")"
    IFS='|' read -r OK LEVEL MSG <<< "$VAL_SPACE"
    if [ "$OK" = "false" ]; then
        echo -e "${COLOR_RED}  [!] $MSG${COLOR_RESET}"
        exit 1
    elif [ "$LEVEL" = "WARNING" ]; then
        echo -e "${COLOR_YELLOW}  [!] $MSG${COLOR_RESET}"
    fi

    printf "  Creating VM... "
    RES_NEW="$(new_vm_instance "$SETUP_VM_NAME" "$VMS_DIR" "$SETUP_DISK_SIZE" "$QEMU_IMG_PATH" "$QEMU_ARCH")"
    if [ "${RES_NEW%%|*}" = "false" ]; then
        echo -e "${COLOR_RED}Failed.${COLOR_RESET}"
        echo -e "${COLOR_RED}  [!] $(printf '%s' "$RES_NEW" | cut -d'|' -f2-)${COLOR_RESET}"
        exit 1
    fi
    echo -e "${COLOR_GREEN}Done.${COLOR_RESET}"

    TARGET_DIR="$(printf '%s' "$RES_NEW" | cut -d'|' -f3)"

    run_decision_engine "$ROOT_DIR" "$TARGET_DIR"
    # The installer boots from the ISO; firmware mode stays exactly as it will
    # be on every later boot, because installing under BIOS and then booting
    # under UEFI (or the reverse) leaves an unbootable disk.
    DECISION_ISO="$SETUP_ISO_PATH"

    show_decision_summary

    if [ "$DECISION_IS_VALID" -ne 1 ]; then
        echo -e "${COLOR_RED}  [X] Cannot start the installer:${COLOR_RESET}"
        if [ "${#DECISION_ERRORS[@]}" -gt 0 ]; then
            for err in "${DECISION_ERRORS[@]}"; do
                echo -e "${COLOR_RED}      - $err${COLOR_RESET}"
            done
        fi
        exit 1
    fi

    if ! pvm_lock_guard "$TARGET_DIR"; then
        echo -e "${COLOR_RED}  [!] VM '$SETUP_VM_NAME' is already running (locked by $PVM_LOCK_OWNER).${COLOR_RESET}"
        exit 1
    fi

    build_qemu_command
    echo -e "${COLOR_GREEN}  [*] Launching installer for '$SETUP_VM_NAME'...${COLOR_RESET}"
    "$QEMU_PATH" "${QEMU_ARGS[@]}"
    EXIT_CODE=$?
    pvm_lock_release
    exit $EXIT_CODE
fi

# ---- 3. Delete mode -----------------------------------------------------
if [ "$DELETE_MODE" -eq 1 ]; then
    if [ -z "$TARGET_VM_NAME" ]; then
        echo -e "${COLOR_RED}  [!] Specify the VM to delete with --vm-name <name>.${COLOR_RESET}"
        exit 1
    fi

    TARGET_DIR="$VMS_DIR/$TARGET_VM_NAME"
    if [ ! -d "$TARGET_DIR" ]; then
        echo -e "${COLOR_RED}  [!] VM '$TARGET_VM_NAME' not found.${COLOR_RESET}"
        exit 1
    fi

    # Deleting the disk out from under a running QEMU is the one destructive
    # race the lock exists to prevent, so this path takes the lock too.
    if ! pvm_lock_guard "$TARGET_DIR"; then
        echo -e "${COLOR_RED}  [!] VM '$TARGET_VM_NAME' appears to be running (locked by $PVM_LOCK_OWNER). Shut it down first.${COLOR_RESET}"
        exit 1
    fi

    echo -e "\n${COLOR_RED}  [-] DELETE VM${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}  This permanently deletes '$TARGET_VM_NAME' and every file in it.${COLOR_RESET}"
    du -sh "$TARGET_DIR" 2>/dev/null | awk '{ printf "  Size on disk: %s\n", $1 }'

    if [ "$NO_PROMPT" -eq 0 ]; then
        # Typing the name is deliberate friction: a bare y/N is too easy to
        # answer on autopilot for something with no undo.
        read -r -p "  Type the VM name to confirm deletion: " CONFIRM
        if [ "$CONFIRM" != "$TARGET_VM_NAME" ]; then
            echo -e "${COLOR_CYAN}  Aborted - name did not match.${COLOR_RESET}"
            exit 0
        fi
    fi

    echo "  Removing..."
    # The lock directory has to go last, and rm -rf on the parent handles it.
    pvm_lock_release
    if rm -rf "$TARGET_DIR"; then
        echo -e "${COLOR_GREEN}  [+] Deleted VM '$TARGET_VM_NAME'.${COLOR_RESET}"
        exit 0
    else
        echo -e "${COLOR_RED}  [!] Failed to fully delete '$TARGET_DIR'.${COLOR_RESET}"
        exit 1
    fi
fi

# ---- 4. VM selection ----------------------------------------------------
SELECTED_VM_PATH=""

if [ "$LIST_VMS" -eq 1 ]; then
    show_vm_selection "$VMS_DIR" --list-only
    exit 0
fi

if [ -n "$TARGET_VM_NAME" ]; then
    if [ -d "$VMS_DIR/$TARGET_VM_NAME" ]; then
        SELECTED_VM_PATH="$VMS_DIR/$TARGET_VM_NAME"
    else
        echo -e "${COLOR_RED}  [!] VM '$TARGET_VM_NAME' not found in '$VMS_DIR'.${COLOR_RESET}"
        exit 1
    fi
else
    show_vm_selection "$VMS_DIR" || true
    if [ -z "$SELECTED_VM_PATH" ]; then
        echo "  [i] Exiting launcher."
        exit 0
    fi
fi

# ---- 5. Decision engine -------------------------------------------------
run_decision_engine "$ROOT_DIR" "$SELECTED_VM_PATH"
show_decision_summary

if [ "$DECISION_IS_VALID" -ne 1 ]; then
    echo -e "${COLOR_RED}  [X] CANNOT LAUNCH VM DUE TO CONFIGURATION ERRORS:${COLOR_RESET}"
    if [ "${#DECISION_ERRORS[@]}" -gt 0 ]; then
        for err in "${DECISION_ERRORS[@]}"; do
            echo -e "${COLOR_RED}      - $err${COLOR_RESET}"
        done
    fi
    echo ""
    exit 1
fi

# ---- 6. Single-instance lock --------------------------------------------
# Taken before the interactive review, not just before exec: there is no point
# walking the user through a configuration menu for a VM they cannot start.
# A dry run never launches anything, so it never takes the lock.
if [ "$DRY_RUN" -eq 0 ]; then
    if ! pvm_lock_guard "$SELECTED_VM_PATH"; then
        echo -e "${COLOR_RED}  [!] VM '$DECISION_VM_NAME' is already running (locked by $PVM_LOCK_OWNER).${COLOR_RESET}"
        echo -e "${COLOR_GRAY}      Two QEMU processes sharing one disk image will corrupt it.${COLOR_RESET}"
        exit 1
    fi
fi

# ---- 7. Interactive review ----------------------------------------------
if [ "$NO_PROMPT" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
    if ! invoke_interactive_config_menu_unix; then
        echo "  [i] Launch cancelled by user."
        exit 0
    fi
fi

# ---- 8. Build ------------------------------------------------------------
build_qemu_command

echo -e "${COLOR_GREEN}  [+] GENERATED QEMU COMMAND${COLOR_RESET}"
echo -e "${COLOR_GRAY}  ----------------------------------------------------------------${COLOR_RESET}"
echo -e "${COLOR_GRAY}  $FULL_COMMAND_STR${COLOR_RESET}"
echo ""

if [ "$DRY_RUN" -eq 1 ]; then
    echo "  [i] Dry-run completed (--dry-run specified). VM will not be launched."
    exit 0
fi

# ---- 9. Launch -----------------------------------------------------------
echo -e "${COLOR_GREEN}  [*] Launching virtual machine '$DECISION_VM_NAME'...${COLOR_RESET}"
echo ""

"$QEMU_PATH" "${QEMU_ARGS[@]}"
EXIT_CODE=$?
pvm_lock_release

echo ""
echo "  [+] Virtual machine session terminated with exit code $EXIT_CODE."
exit $EXIT_CODE
