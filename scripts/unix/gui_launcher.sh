#!/usr/bin/env bash
# Native Graphical Launcher for Linux and macOS

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/detect.sh"
source "$SCRIPT_DIR/decide.sh"
source "$SCRIPT_DIR/build_command.sh"
source "$SCRIPT_DIR/display.sh"

detect_host_info "$ROOT_DIR"

VMS_DIR="$ROOT_DIR/vms"
VM_LIST=()
if [ -d "$VMS_DIR" ]; then
    for d in "$VMS_DIR"/*; do
        if [ -d "$d" ]; then
            VM_LIST+=($(basename "$d"))
        fi
    done
fi

# GUI Logic using Zenity (Linux) or osascript (macOS) or CLI fallback
if command -v zenity &>/dev/null; then
    if [ ${#VM_LIST[@]} -eq 0 ]; then
        VM_LIST_OPTS=("[+ New VM]")
    else
        VM_LIST_OPTS=("[+ New VM]" "[- Delete VM]" "${VM_LIST[@]}")
    fi

    SELECTED_VM=$(zenity --list --title="Portable Virtual Computer Launcher" \
        --column="Virtual Machines" "${VM_LIST_OPTS[@]}" \
        --text="Select a VM instance or create a new one:\nHost: $HOST_OS ($HOST_ARCH) | Cores: $HOST_LOGICAL_CORES | RAM: ${HOST_AVAIL_RAM_MB}MB Free")

    [ -z "$SELECTED_VM" ] && exit 0

    if [ "$SELECTED_VM" = "[+ New VM]" ]; then
        source "$SCRIPT_DIR/setup_core.sh"
        
        SETUP_VM_NAME=$(zenity --entry --title="New VM" --text="Enter a name for the new VM:")
        [ -z "$SETUP_VM_NAME" ] && exit 0
        
        VAL_NAME=$(test_vm_name_valid "$SETUP_VM_NAME" "$VMS_DIR")
        if [[ "$VAL_NAME" == false* ]]; then
            zenity --error --title="Invalid Name" --text="${VAL_NAME#*|}"
            exit 1
        fi
        
        SETUP_ISO_PATH=$(zenity --file-selection --title="Select ISO File" --file-filter="*.iso")
        [ -z "$SETUP_ISO_PATH" ] && exit 0
        
        VAL_ISO=$(test_iso_file_valid "$SETUP_ISO_PATH")
        if [[ "$VAL_ISO" == false* ]]; then
            IFS='|' read -ra ARR <<< "$VAL_ISO"
            zenity --error --title="Invalid ISO" --text="${ARR[1]}"
            exit 1
        fi
        
        SETUP_DISK_SIZE=$(zenity --entry --title="Root Disk Size" --text="Enter virtual disk size in GB:" --entry-text="64")
        [ -z "$SETUP_DISK_SIZE" ] && exit 0
        
        VAL_SPACE=$(test_disk_space_available "$SETUP_DISK_SIZE" "$HOST_SSD_FREE_GB")
        if [[ "$VAL_SPACE" == false* ]]; then
            IFS='|' read -ra ARR <<< "$VAL_SPACE"
            zenity --error --title="Not Enough Space" --text="${ARR[2]}"
            exit 1
        fi
        
        zenity --info --title="Creating VM" --text="Creating virtual disk... This may take a moment." --timeout=2
        
        RES_NEW=$(new_vm_instance "$SETUP_VM_NAME" "$VMS_DIR" "$SETUP_DISK_SIZE" "$QEMU_PATH")
        if [[ "$RES_NEW" == false* ]]; then
            IFS='|' read -ra ARR <<< "$RES_NEW"
            zenity --error --title="Error Creating VM" --text="${ARR[1]}"
            exit 1
        fi
        
        IFS='|' read -ra ARR <<< "$RES_NEW"
        TARGET_DIR="${ARR[2]}"
        
        run_decision_engine "$ROOT_DIR" "$TARGET_DIR"
        DECISION_UEFI="false"
        DECISION_ISO="$SETUP_ISO_PATH"
        
        build_qemu_command
        eval "$FULL_COMMAND_STR"
        exit $?
    fi

    if [ "$SELECTED_VM" = "[- Delete VM]" ]; then
        DEL_TARGET=$(zenity --list --title="Delete VM" \
            --column="Virtual Machines" "${VM_LIST[@]}" \
            --text="Select the VM you want to delete:")
        [ -z "$DEL_TARGET" ] && exit 0
        
        "$SCRIPT_DIR/delete_wizard.sh" "$DEL_TARGET" "$VMS_DIR"
        exit 0
    fi

    VM_DIR="$VMS_DIR/$SELECTED_VM"
    run_decision_engine "$ROOT_DIR" "$VM_DIR"

    # Confirm launch with Zenity
    if zenity --question --title="Launch VM" --text="Launch VM '$SELECTED_VM' with:\n- RAM: ${DECISION_RAM_MB} MB\n- Cores: ${DECISION_CORES}\n- Accel: ${DECISION_ACCEL}?"; then
        build_qemu_command
        zenity --info --title="Launching VM" --text="Starting QEMU session..." --timeout=2
        "$QEMU_PATH" "${QEMU_ARGS[@]}"
    fi

elif [ "$(uname -s)" = "Darwin" ]; then
    # macOS native AppleScript dialogs
    if [ ${#VM_LIST[@]} -eq 0 ]; then
        VM_OPTS_STR='"[+ New VM]"'
    else
        VM_OPTS_STR='"[+ New VM]", "[- Delete VM]"'
        for vm in "${VM_LIST[@]}"; do
            VM_OPTS_STR="$VM_OPTS_STR, \"$vm\""
        done
    fi

    SELECTED_VM=$(osascript -e "choose from list {$VM_OPTS_STR} with title \"Portable Virtual Computer\" with prompt \"Host: $HOST_OS ($HOST_ARCH) | Cores: $HOST_LOGICAL_CORES | Free RAM: ${HOST_AVAIL_RAM_MB}MB\nSelect VM instance:\" default items {\"[+ New VM]\"}" 2>/dev/null)
    [ "$SELECTED_VM" = "false" ] || [ -z "$SELECTED_VM" ] && exit 0

    if [ "$SELECTED_VM" = "[+ New VM]" ]; then
        source "$SCRIPT_DIR/setup_core.sh"

        SETUP_VM_NAME=$(osascript -e 'text returned of (display dialog "Enter a name for the new VM:" default answer "" with title "New VM")' 2>/dev/null)
        [ -z "$SETUP_VM_NAME" ] && exit 0

        VAL_NAME=$(test_vm_name_valid "$SETUP_VM_NAME" "$VMS_DIR")
        if [[ "$VAL_NAME" == false* ]]; then
            osascript -e "display alert \"Invalid Name\" message \"${VAL_NAME#*|}\" as critical" 2>/dev/null
            exit 1
        fi

        SETUP_ISO_PATH=$(osascript -e 'POSIX path of (choose file with prompt "Select ISO File:" of type {"iso"})' 2>/dev/null)
        [ -z "$SETUP_ISO_PATH" ] && exit 0

        VAL_ISO=$(test_iso_file_valid "$SETUP_ISO_PATH")
        if [[ "$VAL_ISO" == false* ]]; then
            IFS='|' read -ra ARR <<< "$VAL_ISO"
            osascript -e "display alert \"Invalid ISO\" message \"${ARR[1]}\" as critical" 2>/dev/null
            exit 1
        fi

        SETUP_DISK_SIZE=$(osascript -e 'text returned of (display dialog "Enter virtual disk size in GB:" default answer "64" with title "Root Disk Size")' 2>/dev/null)
        SETUP_DISK_SIZE=${SETUP_DISK_SIZE:-64}

        VAL_SPACE=$(test_disk_space_available "$SETUP_DISK_SIZE" "$HOST_SSD_FREE_GB")
        if [[ "$VAL_SPACE" == false* ]]; then
            IFS='|' read -ra ARR <<< "$VAL_SPACE"
            osascript -e "display alert \"Not Enough Space\" message \"${ARR[2]}\" as critical" 2>/dev/null
            exit 1
        fi

        RES_NEW=$(new_vm_instance "$SETUP_VM_NAME" "$VMS_DIR" "$SETUP_DISK_SIZE" "$QEMU_PATH")
        if [[ "$RES_NEW" == false* ]]; then
            IFS='|' read -ra ARR <<< "$RES_NEW"
            osascript -e "display alert \"Error Creating VM\" message \"${ARR[1]}\" as critical" 2>/dev/null
            exit 1
        fi

        IFS='|' read -ra ARR <<< "$RES_NEW"
        TARGET_DIR="${ARR[2]}"

        run_decision_engine "$ROOT_DIR" "$TARGET_DIR"
        DECISION_UEFI="false"
        DECISION_ISO="$SETUP_ISO_PATH"

        build_qemu_command
        "$QEMU_PATH" "${QEMU_ARGS[@]}"
        exit $?
    fi

    if [ "$SELECTED_VM" = "[- Delete VM]" ]; then
        VM_DEL_OPTS=""
        for vm in "${VM_LIST[@]}"; do
            if [ -n "$VM_DEL_OPTS" ]; then VM_DEL_OPTS="$VM_DEL_OPTS, "; fi
            VM_DEL_OPTS="$VM_DEL_OPTS\"$vm\""
        done

        DEL_TARGET=$(osascript -e "choose from list {$VM_DEL_OPTS} with title \"Delete VM\" with prompt \"Select VM to permanently delete:\"" 2>/dev/null)
        [ "$DEL_TARGET" = "false" ] || [ -z "$DEL_TARGET" ] && exit 0

        CONFIRM=$(osascript -e "button returned of (display dialog \"Are you sure you want to permanently delete '$DEL_TARGET'? All VM disk data will be destroyed.\" with title \"Confirm Deletion\" buttons {\"Cancel\", \"Delete\"} default button \"Cancel\" with icon caution)" 2>/dev/null)
        if [ "$CONFIRM" = "Delete" ]; then
            rm -rf "$VMS_DIR/$DEL_TARGET"
            osascript -e "display notification \"VM '$DEL_TARGET' was deleted successfully.\" with title \"Portable VM\"" 2>/dev/null
        fi
        exit 0
    fi

    VM_DIR="$VMS_DIR/$SELECTED_VM"
    run_decision_engine "$ROOT_DIR" "$VM_DIR"

    CONFIRM_MSG="Launch VM '$SELECTED_VM'?\n\n• RAM: ${DECISION_RAM_MB} MB\n• Cores: ${DECISION_CORES}\n• Hypervisor: ${DECISION_ACCEL}"
    LAUNCH_CONFIRM=$(osascript -e "button returned of (display dialog \"$CONFIRM_MSG\" with title \"Launch VM\" buttons {\"Cancel\", \"Launch\"} default button \"Launch\")" 2>/dev/null)
    if [ "$LAUNCH_CONFIRM" = "Launch" ]; then
        build_qemu_command
        "$QEMU_PATH" "${QEMU_ARGS[@]}"
    fi
else
    # Fallback to Terminal Interactive Launcher
    exec "$SCRIPT_DIR/launcher.sh"
fi
