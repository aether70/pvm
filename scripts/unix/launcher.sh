#!/usr/bin/env bash
# Main Unix Orchestrator for Portable VM Launcher

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source helper modules
source "$SCRIPT_DIR/detect.sh"
source "$SCRIPT_DIR/decide.sh"
source "$SCRIPT_DIR/build_command.sh"
source "$SCRIPT_DIR/display.sh"

DETECT_ONLY=0
DRY_RUN=0
LIST_VMS=0
SETUP_MODE=0
DELETE_MODE=0
TARGET_VM_NAME=""
NO_PROMPT=0

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --detect-only|-d) DETECT_ONLY=1; shift ;;
        --dry-run|-n)     DRY_RUN=1; shift ;;
        --list-vms|-l)    LIST_VMS=1; shift ;;
        --setup|-s)       SETUP_MODE=1; shift ;;
        --delete)         DELETE_MODE=1; shift ;;
        --vm-name|-v)     TARGET_VM_NAME="$2"; shift 2 ;;
        --no-prompt|-y)   NO_PROMPT=1; shift ;;
        *)                echo "Unknown option: $1"; exit 1 ;;
    esac
done

show_banner

# 1. Host Detection
detect_host_info "$ROOT_DIR"
show_host_info

if [ "$DETECT_ONLY" -eq 1 ]; then
    echo "  [i] Detection completed (--detect-only specified)."
    exit 0
fi

if [ "$SETUP_MODE" -eq 1 ]; then
    source "$SCRIPT_DIR/setup_core.sh"
    echo -e "\n${COLOR_GREEN}  [+] NEW VM SETUP${COLOR_RESET}"
    VMS_DIR="$ROOT_DIR/vms"
    
    read -p "  VM Name: " SETUP_VM_NAME
    VAL_NAME=$(test_vm_name_valid "$SETUP_VM_NAME" "$VMS_DIR")
    if [[ "$VAL_NAME" == false* ]]; then
        echo -e "${COLOR_RED}  [!] ${VAL_NAME#*|}${COLOR_RESET}"
        exit 1
    fi
    
    read -p "  ISO File Path: " SETUP_ISO_PATH
    VAL_ISO=$(test_iso_file_valid "$SETUP_ISO_PATH")
    if [[ "$VAL_ISO" == false* ]]; then
        IFS='|' read -ra ARR <<< "$VAL_ISO"
        echo -e "${COLOR_RED}  [!] ${ARR[1]}${COLOR_RESET}"
        exit 1
    fi
    
    read -p "  Root Disk Size (GB) [64]: " SETUP_DISK_SIZE
    SETUP_DISK_SIZE=${SETUP_DISK_SIZE:-64}
    
    VAL_SPACE=$(test_disk_space_available "$SETUP_DISK_SIZE" "$HOST_SSD_FREE_GB")
    if [[ "$VAL_SPACE" == false* ]]; then
        IFS='|' read -ra ARR <<< "$VAL_SPACE"
        echo -e "${COLOR_RED}  [!] ${ARR[2]}${COLOR_RESET}"
        exit 1
    elif [[ "$VAL_SPACE" == true*WARNING* ]]; then
        IFS='|' read -ra ARR <<< "$VAL_SPACE"
        echo -e "${COLOR_YELLOW}  [!] ${ARR[2]}${COLOR_RESET}"
    fi
    
    echo -n "  Creating VM... "
    RES_NEW=$(new_vm_instance "$SETUP_VM_NAME" "$VMS_DIR" "$SETUP_DISK_SIZE" "$QEMU_PATH")
    if [[ "$RES_NEW" == false* ]]; then
        echo -e "${COLOR_RED}Failed.${COLOR_RESET}"
        IFS='|' read -ra ARR <<< "$RES_NEW"
        echo -e "${COLOR_RED}  [!] ${ARR[1]}${COLOR_RESET}"
        exit 1
    fi
    echo -e "${COLOR_GREEN}Done.${COLOR_RESET}"
    
    IFS='|' read -ra ARR <<< "$RES_NEW"
    TARGET_DIR="${ARR[2]}"
    
    run_decision_engine "$ROOT_DIR" "$TARGET_DIR"
    DECISION_UEFI="false"
    DECISION_ISO="$SETUP_ISO_PATH"
    
    build_qemu_command
    echo -e "${COLOR_GREEN}  [*] Launching Installer for '$SETUP_VM_NAME'...${COLOR_RESET}"
    "$QEMU_PATH" "${QEMU_ARGS[@]}"
    exit $?
fi

# Delete Mode Logic
if [ "$DELETE_MODE" -eq 1 ]; then
    if [ -z "$TARGET_VM_NAME" ]; then
        echo -e "${COLOR_RED}  [!] Please specify the VM to delete using --vm-name <name>${COLOR_RESET}"
        exit 1
    fi

    VMS_DIR="$ROOT_DIR/vms"
    TARGET_DIR="$VMS_DIR/$TARGET_VM_NAME"

    if [ ! -d "$TARGET_DIR" ]; then
        echo -e "${COLOR_RED}  [!] VM '$TARGET_VM_NAME' not found.${COLOR_RESET}"
        exit 1
    fi

    echo -e "\n${COLOR_RED}  [-] DELETE VM${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}  WARNING: You are about to permanently delete the VM '$TARGET_VM_NAME'.${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}  All data will be lost. This action cannot be undone.${COLOR_RESET}"
    
    if [ "$NO_PROMPT" -eq 0 ]; then
        read -p "  Are you sure? (y/N) " CONFIRM
        if [[ ! "$CONFIRM" =~ ^[Yy](es)?$ ]]; then
            echo -e "${COLOR_CYAN}  Aborted.${COLOR_RESET}"
            exit 0
        fi
    fi

    TOTAL_FILES=$(find "$TARGET_DIR" -type f | wc -l)
    CURRENT=0

    find "$TARGET_DIR" -type f | while read -r FILE; do
        FILENAME=$(basename "$FILE")
        CURRENT=$((CURRENT + 1))
        
        # Simple terminal progress indicator
        printf "\r  Removing: %-30s [%d/%d]" "$FILENAME" "$CURRENT" "$TOTAL_FILES"
        rm -f "$FILE"
    done
    
    echo -e "\n  Removing directory..."
    rm -rf "$TARGET_DIR"
    
    echo -e "${COLOR_GREEN}  [+] Successfully deleted VM '$TARGET_VM_NAME'.${COLOR_RESET}"
    exit 0
fi

# 2. VM Selection
VMS_DIR="$ROOT_DIR/vms"
SELECTED_VM_PATH=""

if [ "$LIST_VMS" -eq 1 ]; then
    show_vm_selection "$VMS_DIR" >/dev/null
    exit 0
fi

if [ -n "$TARGET_VM_NAME" ]; then
    if [ -d "$VMS_DIR/$TARGET_VM_NAME" ]; then
        SELECTED_VM_PATH="$VMS_DIR/$TARGET_VM_NAME"
    else
        echo -e "${COLOR_RED}  [!] Error: VM '$TARGET_VM_NAME' not found in '$VMS_DIR'.${COLOR_RESET}"
        exit 1
    fi
else
    show_vm_selection "$VMS_DIR"
    if [ -z "$SELECTED_VM_PATH" ]; then
        echo "  [i] Exiting launcher."
        exit 0
    fi
fi

# 3. Decision Engine
run_decision_engine "$ROOT_DIR" "$SELECTED_VM_PATH"
show_decision_summary

if [ "$DECISION_IS_VALID" -ne 1 ]; then
    echo -e "${COLOR_RED}  [X] CANNOT LAUNCH VM DUE TO CONFIGURATION ERRORS:${COLOR_RESET}"
    for err in "${DECISION_ERRORS[@]}"; do
        echo -e "${COLOR_RED}      - $err${COLOR_RESET}"
    done
    echo ""
    exit 1
fi

# 4. Interactive Configuration Review (if not in dry-run or non-interactive mode)
if [ "$NO_PROMPT" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
    invoke_interactive_config_menu_unix
    if [ $? -ne 0 ]; then
        echo "  [i] Launch cancelled by user."
        exit 0
    fi
fi

# 5. Build QEMU Command Line
build_qemu_command

echo -e "${COLOR_GREEN}  [+] GENERATED QEMU COMMAND${COLOR_RESET}"
echo -e "${COLOR_GRAY}  ----------------------------------------------------------------${COLOR_RESET}"
echo -e "${COLOR_GRAY}  $FULL_COMMAND_STR${COLOR_RESET}"
echo ""

if [ "$DRY_RUN" -eq 1 ]; then
    echo "  [i] Dry-run completed (--dry-run specified). VM will not be launched."
    exit 0
fi

echo -e "${COLOR_GREEN}  [*] Launching Virtual Machine '$DECISION_VM_NAME'...${COLOR_RESET}"
echo ""

# 6. Execute QEMU process
"$QEMU_PATH" "${QEMU_ARGS[@]}"
EXIT_CODE=$?

echo ""
echo "  [+] Virtual Machine session terminated with exit code $EXIT_CODE."

