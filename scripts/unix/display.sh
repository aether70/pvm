#!/usr/bin/env bash
# display.sh - Terminal UI for the Unix launcher.
#
# Written for bash 3.2, which is what /bin/bash still is on macOS: every array
# expansion is guarded by a count check, because `"${arr[@]}"` on an empty
# array is a fatal "unbound variable" there under `set -u`.

COLOR_CYAN='\033[0;36m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[1;33m'
COLOR_RED='\033[0;31m'
COLOR_GRAY='\033[0;90m'
COLOR_RESET='\033[0m'

# Strip colour entirely when stdout is not a terminal, so piping the output to
# a file or a log does not fill it with escape sequences.
if [ ! -t 1 ]; then
    COLOR_CYAN=''; COLOR_GREEN=''; COLOR_YELLOW=''
    COLOR_RED=''; COLOR_GRAY=''; COLOR_RESET=''
fi

show_banner() {
    echo ""
    echo -e "${COLOR_CYAN}  ================================================================${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}               PORTABLE VIRTUAL MACHINE LAUNCHER                  ${COLOR_RESET}"
    echo -e "${COLOR_GRAY}         Cross-Platform VM Environment from External SSD          ${COLOR_RESET}"
    echo -e "${COLOR_CYAN}  ================================================================${COLOR_RESET}"
    echo ""
}

show_host_info() {
    echo -e "${COLOR_GREEN}  [+] HOST HARDWARE & ENVIRONMENT${COLOR_RESET}"
    echo -e "${COLOR_GRAY}  ----------------------------------------------------------------${COLOR_RESET}"
    printf "  %-20s : %s (%s)\n" "Host OS" "$HOST_OS" "$HOST_ARCH"
    printf "  %-20s : %s\n" "CPU" "$HOST_CPU_NAME"
    printf "  %-20s : %s logical / %s physical\n" "Cores" "$HOST_LOGICAL_CORES" "$HOST_PHYSICAL_CORES"
    printf "  %-20s : %d MB total / %d MB available\n" "RAM" "$HOST_TOTAL_RAM_MB" "$HOST_AVAIL_RAM_MB"
    printf "  %-20s : %d GB free\n" "SSD Storage" "$HOST_SSD_FREE_GB"

    local virt_status="Disabled / Unknown"
    local virt_color="$COLOR_YELLOW"
    if [ "$VIRT_HW_SUPPORT" -eq 1 ]; then
        virt_status="Enabled in CPU [OK]"
        virt_color="$COLOR_GREEN"
    fi
    printf "  %-20s : " "Virtualization"
    echo -e "${virt_color}${virt_status}${COLOR_RESET}"

    local accel_status accel_color
    if [ "$KVM_AVAILABLE" -eq 1 ]; then
        accel_status="KVM available [OK]"; accel_color="$COLOR_GREEN"
    elif [ "$HVF_AVAILABLE" -eq 1 ]; then
        accel_status="HVF Supported (macOS) [OK]"
        accel_color="$COLOR_GREEN"
    elif [ "$HOST_OS" = "Darwin" ] && [ "$HOST_ARCH" = "arm64" ] && [ "$TARGET_ARCH" = "x86_64" ]; then
        accel_status="TCG Emulation (x86_64 guest on Apple Silicon host)"
        accel_color="$COLOR_YELLOW"
    fi
    printf "  %-20s : " "Hypervisor"
    echo -e "${accel_color}${accel_status}${COLOR_RESET}"

    local qemu_disp qemu_color
    if [ -n "$QEMU_PATH" ]; then
        qemu_disp="$QEMU_VERSION ($QEMU_PATH)"; qemu_color="$COLOR_RESET"
    else
        qemu_disp="NOT FOUND"; qemu_color="$COLOR_RED"
    fi
    printf "  %-20s : " "QEMU ($QEMU_ARCH)"
    echo -e "${qemu_color}${qemu_disp}${COLOR_RESET}"

    if [ -n "$QEMU_PATH" ]; then
        # These are the probed capabilities the decision engine reasons over -
        # showing them makes "why is it using TCG?" answerable at a glance.
        printf "  %-20s :%s\n" "  Accelerators" "$QEMU_ACCELS"
        printf "  %-20s :%s\n" "  Displays" "$QEMU_DISPLAYS"
    fi
    echo ""
}

# show_vm_selection <vms_dir> [--list-only]
# Sets SELECTED_VM_PATH. Returns 1 when nothing was selected.
show_vm_selection() {
    local vms_dir="$1"
    local list_only="${2:-}"
    AVAILABLE_VMS=()
    SELECTED_VM_PATH=""

    echo -e "${COLOR_GREEN}  [+] DETECTED VIRTUAL MACHINES${COLOR_RESET}"
    echo -e "${COLOR_GRAY}  ----------------------------------------------------------------${COLOR_RESET}"

    if [ -d "$vms_dir" ]; then
        local d
        for d in "$vms_dir"/*; do
            [ -d "$d" ] || continue
            AVAILABLE_VMS[${#AVAILABLE_VMS[@]}]="$d"
        done
    fi

    local count=${#AVAILABLE_VMS[@]}
    if [ "$count" -eq 0 ]; then
        echo -e "${COLOR_YELLOW}  No VM directories found under 'vms/'.${COLOR_RESET}"
        echo -e "${COLOR_GRAY}  Run with --setup to create one, or place a 'disk.qcow2' in vms/<name>/.${COLOR_RESET}"
        echo ""
        return 1
    fi

    local i
    for (( i = 0; i < count; i++ )); do
        local vm_path="${AVAILABLE_VMS[$i]}"
        local vm_name disk_size="no disk image" running=""
        vm_name="$(basename "$vm_path")"

        local cand
        for cand in disk.qcow2 vm.qcow2 disk.raw disk.img; do
            if [ -f "$vm_path/$cand" ]; then
                disk_size="$(du -h "$vm_path/$cand" 2>/dev/null | awk '{ print $1 }')"
                break
            fi
        done

        [ -d "$vm_path/.pvm-lock" ] && running=" ${COLOR_YELLOW}[running]${COLOR_RESET}"
        printf "   [${COLOR_CYAN}%d${COLOR_RESET}] %-26s (disk: %s)" "$(( i + 1 ))" "$vm_name" "$disk_size"
        echo -e "$running"
    done
    echo ""

    [ "$list_only" = "--list-only" ] && return 0

    if [ "$count" -eq 1 ]; then
        SELECTED_VM_PATH="${AVAILABLE_VMS[0]}"
        echo -e "  -> Auto-selecting the only available VM: ${COLOR_YELLOW}$(basename "$SELECTED_VM_PATH")${COLOR_RESET}"
        echo ""
        return 0
    fi

    local choice
    while true; do
        read -r -p "  Select VM number to launch (1-$count) or 'q' to quit: " choice
        case "$choice" in
            [Qq]) return 1 ;;
            ''|*[!0-9]*)
                echo -e "${COLOR_RED}  Invalid choice. Enter a number between 1 and $count.${COLOR_RESET}" ;;
            *)
                if [ "$choice" -ge 1 ] && [ "$choice" -le "$count" ]; then
                    SELECTED_VM_PATH="${AVAILABLE_VMS[$(( choice - 1 ))]}"
                    return 0
                fi
                echo -e "${COLOR_RED}  Invalid choice. Enter a number between 1 and $count.${COLOR_RESET}" ;;
        esac
    done
}

show_decision_summary() {
    echo -e "${COLOR_GREEN}  [+] ALLOCATED VM CONFIGURATION${COLOR_RESET}"
    echo -e "${COLOR_GRAY}  ----------------------------------------------------------------${COLOR_RESET}"
    printf "  %-20s : %s\n" "Selected VM" "$DECISION_VM_NAME"
    printf "  %-20s : %s (machine %s, cpu %s)\n" "Guest Platform" "$DECISION_ARCH" "$DECISION_MACHINE" "$DECISION_CPU"
    printf "  %-20s : %s\n" "Virtual Disk" "${DECISION_DISK:-<none>}"
    printf "  %-20s : %d MB [safe range: %d - %d MB]\n" "Allocated Memory" "$DECISION_RAM_MB" "$DECISION_MIN_REQUIRED_RAM" "$DECISION_SAFE_MAX_RAM"
    printf "  %-20s : %d cores [available: 1 - %d]\n" "Allocated CPU" "$DECISION_CORES" "$DECISION_MAX_HOST_CORES"

    local accel_text accel_color
    case "$DECISION_ACCEL" in
        kvm) accel_text="KVM (native)";              accel_color="$COLOR_GREEN" ;;
        hvf) accel_text="HVF (native)";              accel_color="$COLOR_GREEN" ;;
        tcg) accel_text="TCG (software - slower)";   accel_color="$COLOR_YELLOW" ;;
        *)   accel_text="$DECISION_ACCEL";           accel_color="$COLOR_YELLOW" ;;
    esac
    printf "  %-20s : " "Acceleration"
    echo -e "${accel_color}${accel_text}${COLOR_RESET}"

    printf "  %-20s : %s\n" "Graphics" "$DECISION_VGA_DEVICE"
    printf "  %-20s : %s\n" "Display Output" "$DECISION_DISPLAY"
    printf "  %-20s : %s\n" "Audio" "${DECISION_AUDIODEV:-disabled}"
    if [ "$DECISION_NETWORK" = "nat" ]; then
        printf "  %-20s : NAT (ssh to 127.0.0.1:%s -> guest :22)\n" "Network" "$DECISION_SSH_PORT"
    else
        printf "  %-20s : %s\n" "Network" "$DECISION_NETWORK"
    fi

    if [ "$DECISION_UEFI" = "true" ]; then
        printf "  %-20s : enabled\n" "UEFI Boot"
        printf "  %-20s : %s\n" "  Firmware" "${DECISION_UEFI_CODE:-<none>}"
        printf "  %-20s : %s\n" "  Variables" "${DECISION_UEFI_VARS:-<not persisted>}"
    else
        printf "  %-20s : disabled (legacy BIOS)\n" "UEFI Boot"
    fi
    echo ""

    if [ -n "$DECISION_ACCEL_WARN" ]; then
        echo -e "  ${COLOR_YELLOW}[!] $DECISION_ACCEL_WARN${COLOR_RESET}"
    fi
    if [ "${#DECISION_WARNINGS[@]}" -gt 0 ]; then
        local w
        for w in "${DECISION_WARNINGS[@]}"; do
            echo -e "  ${COLOR_YELLOW}[!] $w${COLOR_RESET}"
        done
    fi
    if [ -n "$DECISION_ACCEL_WARN" ] || [ "${#DECISION_WARNINGS[@]}" -gt 0 ]; then
        echo ""
    fi
    return 0
}

invoke_interactive_config_menu_unix() {
    local menu_choice
    while true; do
        echo -e "${COLOR_CYAN}  ================================================================${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}                     VM CONFIGURATION REVIEW                      ${COLOR_RESET}"
        echo -e "${COLOR_CYAN}  ================================================================${COLOR_RESET}"
        echo "   [1] Modify Memory (RAM)       - Current: ${DECISION_RAM_MB} MB"
        echo "   [2] Modify CPU Cores          - Current: ${DECISION_CORES} cores"
        echo "   [3] Modify Display Backend    - Current: ${DECISION_DISPLAY}"
        echo "   [4] Modify SSH Port           - Current: ${DECISION_SSH_PORT}"
        echo -e "${COLOR_GRAY}   --------------------------------------------------------------${COLOR_RESET}"
        echo -e "   [${COLOR_GREEN}R / ENTER${COLOR_RESET}] Run / Launch Virtual Machine"
        echo -e "   [${COLOR_RED}Q${COLOR_RESET}]         Cancel and Exit"
        echo -e "${COLOR_CYAN}  ================================================================${COLOR_RESET}"
        read -r -p "  Choose an option, or press [ENTER/R] to run: " menu_choice

        case "$menu_choice" in
            ''|[Rr]) return 0 ;;
            [Qq])    return 1 ;;
        esac

        case "$menu_choice" in
            1)
                echo ""
                echo -e "${COLOR_CYAN}  --- MODIFY MEMORY (RAM) ---${COLOR_RESET}"
                echo -e "  Total host RAM: ${HOST_TOTAL_RAM_MB} MB | Free: ${HOST_AVAIL_RAM_MB} MB"
                echo -e "  Safe allocation range: ${DECISION_MIN_REQUIRED_RAM} - ${DECISION_SAFE_MAX_RAM} MB"
                local new_ram
                read -r -p "  New RAM in MB (Enter keeps ${DECISION_RAM_MB}): " new_ram
                if [ -n "$new_ram" ]; then
                    case "$new_ram" in
                        *[!0-9]*|'')
                            echo -e "${COLOR_RED}  [!] Not a number - unchanged.${COLOR_RESET}" ;;
                        *)
                            test_memory_safety_unix "$new_ram"
                            if [ "${#WARN_MSGS[@]}" -gt 0 ]; then
                                echo ""
                                local w
                                for w in "${WARN_MSGS[@]}"; do
                                    echo -e "${COLOR_YELLOW}  [!] $w${COLOR_RESET}"
                                done
                                echo ""
                                local confirm
                                read -r -p "  Apply anyway? (y/N): " confirm
                                case "$confirm" in
                                    [Yy]|[Yy][Ee][Ss])
                                        DECISION_RAM_MB="$new_ram"
                                        echo -e "${COLOR_GREEN}  [+] Memory set to ${DECISION_RAM_MB} MB.${COLOR_RESET}" ;;
                                    *)  echo "  [i] Memory change discarded." ;;
                                esac
                            else
                                DECISION_RAM_MB="$new_ram"
                                echo -e "${COLOR_GREEN}  [+] Memory set to ${DECISION_RAM_MB} MB.${COLOR_RESET}"
                            fi ;;
                    esac
                fi
                echo "" ;;

            2)
                echo ""
                echo -e "${COLOR_CYAN}  --- MODIFY CPU CORES ---${COLOR_RESET}"
                echo -e "  Host logical cores: ${HOST_LOGICAL_CORES}"
                local new_cores
                read -r -p "  New core count (Enter keeps ${DECISION_CORES}): " new_cores
                if [ -n "$new_cores" ]; then
                    case "$new_cores" in
                        *[!0-9]*|'')
                            echo -e "${COLOR_RED}  [!] Not a number - unchanged.${COLOR_RESET}" ;;
                        *)
                            test_cpu_safety_unix "$new_cores"
                            if [ "${#WARN_CPU_MSGS[@]}" -gt 0 ]; then
                                echo ""
                                local w
                                for w in "${WARN_CPU_MSGS[@]}"; do
                                    echo -e "${COLOR_YELLOW}  [!] $w${COLOR_RESET}"
                                done
                                echo ""
                                local confirm
                                read -r -p "  Apply anyway? (y/N): " confirm
                                case "$confirm" in
                                    [Yy]|[Yy][Ee][Ss])
                                        DECISION_CORES="$new_cores"
                                        echo -e "${COLOR_GREEN}  [+] CPU cores set to ${DECISION_CORES}.${COLOR_RESET}" ;;
                                    *)  echo "  [i] Core change discarded." ;;
                                esac
                            else
                                DECISION_CORES="$new_cores"
                                echo -e "${COLOR_GREEN}  [+] CPU cores set to ${DECISION_CORES}.${COLOR_RESET}"
                            fi ;;
                    esac
                fi
                echo "" ;;

            3)
                echo ""
                echo -e "${COLOR_CYAN}  --- MODIFY DISPLAY BACKEND ---${COLOR_RESET}"
                # Only the backends this QEMU actually built in are offered;
                # picking one it lacks is an immediate launch failure.
                local opts=() opt n=0
                for opt in $QEMU_DISPLAYS; do
                    case "$opt" in
                        none|dbus) continue ;;
                    esac
                    opts[${#opts[@]}]="$opt"
                done
                opts[${#opts[@]}]="vnc"
                for (( n = 0; n < ${#opts[@]}; n++ )); do
                    printf "   [%d] %s\n" "$(( n + 1 ))" "${opts[$n]}"
                done
                local disp_choice
                read -r -p "  Select display option (1-${#opts[@]}): " disp_choice
                case "$disp_choice" in
                    ''|*[!0-9]*)
                        echo -e "${COLOR_RED}  [!] Invalid choice - unchanged.${COLOR_RESET}" ;;
                    *)
                        if [ "$disp_choice" -ge 1 ] && [ "$disp_choice" -le "${#opts[@]}" ]; then
                            DECISION_DISPLAY="${opts[$(( disp_choice - 1 ))]}"
                            echo -e "${COLOR_GREEN}  [+] Display set to ${DECISION_DISPLAY}.${COLOR_RESET}"
                        else
                            echo -e "${COLOR_RED}  [!] Invalid choice - unchanged.${COLOR_RESET}"
                        fi ;;
                esac
                echo "" ;;

            4)
                echo ""
                echo -e "${COLOR_CYAN}  --- MODIFY SSH FORWARDING PORT ---${COLOR_RESET}"
                local port_input
                read -r -p "  Host port forwarded to guest :22 (current ${DECISION_SSH_PORT}): " port_input
                case "$port_input" in
                    ''|*[!0-9]*)
                        echo -e "${COLOR_RED}  [!] Invalid port (must be 1024-65535).${COLOR_RESET}" ;;
                    *)
                        if [ "$port_input" -ge 1024 ] && [ "$port_input" -le 65535 ]; then
                            DECISION_SSH_PORT="$port_input"
                            echo -e "${COLOR_GREEN}  [+] SSH port set to ${DECISION_SSH_PORT}.${COLOR_RESET}"
                        else
                            echo -e "${COLOR_RED}  [!] Invalid port (must be 1024-65535).${COLOR_RESET}"
                        fi ;;
                esac
                echo "" ;;

            *)
                echo -e "${COLOR_RED}  Invalid choice. Select 1-4, R to run, or Q to cancel.${COLOR_RESET}" ;;
        esac

        show_decision_summary
    done
}
