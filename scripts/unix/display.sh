#!/usr/bin/env bash
# Terminal UI and formatting module for Linux and macOS

COLOR_CYAN='\033[0;36m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[1;33m'
COLOR_RED='\033[0;31m'
COLOR_GRAY='\033[0;90m'
COLOR_RESET='\033[0m'

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
    printf "  %-20s : %s logical cores\n" "Cores" "$HOST_LOGICAL_CORES"
    printf "  %-20s : %d MB total / %d MB available\n" "RAM" "$HOST_TOTAL_RAM_MB" "$HOST_AVAIL_RAM_MB"
    printf "  %-20s : %d GB free\n" "SSD Storage" "$HOST_SSD_FREE_GB"

    local virt_status="Disabled/Unknown"
    local virt_color="$COLOR_YELLOW"
    if [ "$VIRT_HW_SUPPORT" -eq 1 ]; then
        virt_status="Enabled in CPU [OK]"
        virt_color="$COLOR_GREEN"
    fi
    printf "  %-20s : " "Virtualization (CPU)"
    echo -e "${virt_color}${virt_status}${COLOR_RESET}"

    local accel_status="TCG (Software Emulation)"
    local accel_color="$COLOR_YELLOW"
    if [ "$KVM_AVAILABLE" -eq 1 ]; then
        accel_status="KVM Supported [OK]"
        accel_color="$COLOR_GREEN"
    elif [ "$HVF_AVAILABLE" -eq 1 ]; then
        accel_status="HVF Supported (macOS) [OK]"
        accel_color="$COLOR_GREEN"
    elif [ "$HOST_OS" = "Darwin" ] && [ "$HOST_ARCH" = "arm64" ] && [ "$TARGET_ARCH" = "x86_64" ]; then
        accel_status="TCG Emulation (x86_64 guest on Apple Silicon host)"
        accel_color="$COLOR_YELLOW"
    fi
    printf "  %-20s : " "Hypervisor Accel"
    echo -e "${accel_color}${accel_status}${COLOR_RESET}"

    local qemu_disp="NOT FOUND"
    local qemu_color="$COLOR_RED"
    if [ -n "$QEMU_PATH" ]; then
        qemu_disp="$QEMU_VERSION ($QEMU_PATH)"
        qemu_color="$COLOR_RESET"
    fi
    printf "  %-20s : " "QEMU Binary"
    echo -e "${qemu_color}${qemu_disp}${COLOR_RESET}"
    echo ""
}

show_vm_selection() {
    local vms_dir="$1"
    AVAILABLE_VMS=()
    
    echo -e "${COLOR_GREEN}  [+] DETECTED VIRTUAL MACHINES${COLOR_RESET}"
    echo -e "${COLOR_GRAY}  ----------------------------------------------------------------${COLOR_RESET}"

    if [ -d "$vms_dir" ]; then
        for d in "$vms_dir"/*; do
            if [ -d "$d" ]; then
                AVAILABLE_VMS+=("$d")
            fi
        done
    fi

    local count=${#AVAILABLE_VMS[@]}
    if [ "$count" -eq 0 ]; then
        echo -e "${COLOR_YELLOW}  No VM directories found in 'vms/' folder.${COLOR_RESET}"
        echo -e "${COLOR_GRAY}  Please create a folder under 'vms/' (e.g. 'vms/ubuntu/') with 'disk.qcow2'.${COLOR_RESET}"
        echo ""
        SELECTED_VM_PATH=""
        return 1
    fi

    for i in "${!AVAILABLE_VMS[@]}"; do
        local vm_path="${AVAILABLE_VMS[$i]}"
        local vm_name=$(basename "$vm_path")
        local num=$((i + 1))
        local disk_size="No disk file"
        for cand in disk.qcow2 vm.qcow2 disk.raw disk.img; do
            if [ -f "$vm_path/$cand" ]; then
                local sz=$(du -h "$vm_path/$cand" 2>/dev/null | awk '{print $1}')
                disk_size="$sz"
                break
            fi
        done
        printf "   [${COLOR_CYAN}%d${COLOR_RESET}] %-26s (Disk: %s)\n" "$num" "$vm_name" "$disk_size"
    done
    echo ""

    if [ "$count" -eq 1 ]; then
        SELECTED_VM_PATH="${AVAILABLE_VMS[0]}"
        echo -e "  -> Auto-selecting the only available VM: ${COLOR_YELLOW}$(basename "$SELECTED_VM_PATH")${COLOR_RESET}"
        echo ""
        return 0
    fi

    while true; do
        read -r -p "  Select VM number to launch (1-$count) or 'q' to quit: " choice
        if [[ "$choice" =~ ^[Qq]$ ]]; then
            SELECTED_VM_PATH=""
            return 1
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$count" ]; then
            SELECTED_VM_PATH="${AVAILABLE_VMS[$((choice - 1))]}"
            return 0
        fi
        echo -e "${COLOR_RED}  Invalid choice. Please enter a number between 1 and $count.${COLOR_RESET}"
    done
}

show_decision_summary() {
    echo -e "${COLOR_GREEN}  [+] ALLOCATED VM CONFIGURATION${COLOR_RESET}"
    echo -e "${COLOR_GRAY}  ----------------------------------------------------------------${COLOR_RESET}"
    printf "  %-20s : %s\n" "Selected VM" "$DECISION_VM_NAME"
    printf "  %-20s : %s\n" "Virtual Disk" "$DECISION_DISK"
    printf "  %-20s : %d MB [Safe Range: %d - %d MB]\n" "Allocated Memory" "$DECISION_RAM_MB" "$DECISION_MIN_REQUIRED_RAM" "$DECISION_SAFE_MAX_RAM"
    printf "  %-20s : %d Cores [Available: 1 - %d Cores]\n" "Allocated CPU" "$DECISION_CORES" "$DECISION_MAX_HOST_CORES"

    local accel_text="TCG (Software Emulation - Slower)"
    local accel_color="$COLOR_YELLOW"
    if [ "$DECISION_ACCEL" = "kvm" ]; then
        accel_text="KVM (Kernel-based Virtual Machine - Native)"
        accel_color="$COLOR_GREEN"
    elif [ "$DECISION_ACCEL" = "hvf" ]; then
        accel_text="HVF (Hypervisor.framework - Native)"
        accel_color="$COLOR_GREEN"
    fi
    printf "  %-20s : " "Acceleration"
    echo -e "${accel_color}${accel_text}${COLOR_RESET}"

    if [ -n "$DECISION_ACCEL_WARN" ]; then
        echo -e "  ${COLOR_YELLOW}[!] WARNING: $DECISION_ACCEL_WARN${COLOR_RESET}"
    fi

    printf "  %-20s : %s\n" "Display Output" "$DECISION_DISPLAY"
    printf "  %-20s : %s (Guest Port 22 -> Host Port %s)\n" "Network Mode" "$DECISION_NETWORK" "$DECISION_SSH_PORT"
    printf "  %-20s : %s\n" "UEFI Boot" "$DECISION_UEFI"
    echo ""
}

invoke_interactive_config_menu_unix() {
    while true; do
        echo -e "${COLOR_CYAN}  ================================================================${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}                     VM CONFIGURATION REVIEW                      ${COLOR_RESET}"
        echo -e "${COLOR_CYAN}  ================================================================${COLOR_RESET}"
        echo "   [1] Modify Memory (RAM)       - Current: ${DECISION_RAM_MB} MB"
        echo "   [2] Modify CPU Cores          - Current: ${DECISION_CORES} Cores"
        echo "   [3] Modify Display Backend    - Current: ${DECISION_DISPLAY}"
        echo "   [4] Modify SSH Port           - Current: ${DECISION_SSH_PORT}"
        echo -e "${COLOR_GRAY}   --------------------------------------------------------------${COLOR_RESET}"
        echo -e "   [${COLOR_GREEN}R / ENTER${COLOR_RESET}] Run / Launch Virtual Machine"
        echo -e "   [${COLOR_RED}Q${COLOR_RESET}]         Cancel and Exit"
        echo -e "${COLOR_CYAN}  ================================================================${COLOR_RESET}"
        read -r -p "  Choose an option to customize, or press [ENTER/R] to Run: " menu_choice

        if [ -z "$menu_choice" ] || [[ "$menu_choice" =~ ^[Rr]$ ]]; then
            return 0
        fi
        if [[ "$menu_choice" =~ ^[Qq]$ ]]; then
            return 1
        fi

        case "$menu_choice" in
            1)
                echo ""
                echo -e "${COLOR_CYAN}  --- MODIFY MEMORY (RAM) ---${COLOR_RESET}"
                echo -e "  Total Host RAM: ${HOST_TOTAL_RAM_MB} MB | Free RAM: ${HOST_AVAIL_RAM_MB} MB"
                echo -e "  Safe Allocation Range: ${DECISION_MIN_REQUIRED_RAM} MB to ${DECISION_SAFE_MAX_RAM} MB"
                read -r -p "  Enter new RAM amount in MB (or press Enter to keep ${DECISION_RAM_MB} MB): " new_ram_input
                if [[ "$new_ram_input" =~ ^[0-9]+$ ]]; then
                    test_memory_safety_unix "$new_ram_input"
                    if [ ${#WARN_MSGS[@]} -gt 0 ]; then
                        echo ""
                        for w in "${WARN_MSGS[@]}"; do
                            echo -e "${COLOR_YELLOW}  [!] WARNING: $w${COLOR_RESET}"
                        done
                        echo ""
                        read -r -p "  Do you still want to apply this value? (y/n): " confirm_ram
                        if [[ "$confirm_ram" =~ ^[Yy]$ ]]; then
                            DECISION_RAM_MB=$new_ram_input
                            echo -e "${COLOR_GREEN}  [+] Memory updated to ${DECISION_RAM_MB} MB.${COLOR_RESET}"
                        else
                            echo "  [i] Memory change discarded."
                        fi
                    else
                        DECISION_RAM_MB=$new_ram_input
                        echo -e "${COLOR_GREEN}  [+] Memory updated to ${DECISION_RAM_MB} MB.${COLOR_RESET}"
                    fi
                fi
                echo ""
                ;;

            2)
                echo ""
                echo -e "${COLOR_CYAN}  --- MODIFY CPU CORES ---${COLOR_RESET}"
                echo -e "  Host Logical Cores: ${HOST_LOGICAL_CORES}"
                read -r -p "  Enter new core count (or press Enter to keep ${DECISION_CORES} cores): " new_core_input
                if [[ "$new_core_input" =~ ^[0-9]+$ ]]; then
                    test_cpu_safety_unix "$new_core_input"
                    if [ ${#WARN_CPU_MSGS[@]} -gt 0 ]; then
                        echo ""
                        for w in "${WARN_CPU_MSGS[@]}"; do
                            echo -e "${COLOR_YELLOW}  [!] WARNING: $w${COLOR_RESET}"
                        done
                        echo ""
                        read -r -p "  Do you still want to apply this core count? (y/n): " confirm_core
                        if [[ "$confirm_core" =~ ^[Yy]$ ]]; then
                            DECISION_CORES=$new_core_input
                            echo -e "${COLOR_GREEN}  [+] CPU cores updated to ${DECISION_CORES}.${COLOR_RESET}"
                        else
                            echo "  [i] Core change discarded."
                        fi
                    else
                        DECISION_CORES=$new_core_input
                        echo -e "${COLOR_GREEN}  [+] CPU cores updated to ${DECISION_CORES}.${COLOR_RESET}"
                    fi
                fi
                echo ""
                ;;

            3)
                echo ""
                echo -e "${COLOR_CYAN}  --- MODIFY DISPLAY BACKEND ---${COLOR_RESET}"
                echo "  Available: [1] sdl, [2] gtk, [3] vnc, [4] default"
                read -r -p "  Select display option (1-4): " disp_choice
                case "$disp_choice" in
                    1) DECISION_DISPLAY="sdl"; echo -e "${COLOR_GREEN}  [+] Display set to SDL.${COLOR_RESET}" ;;
                    2) DECISION_DISPLAY="gtk"; echo -e "${COLOR_GREEN}  [+] Display set to GTK.${COLOR_RESET}" ;;
                    3) DECISION_DISPLAY="vnc"; echo -e "${COLOR_GREEN}  [+] Display set to VNC (127.0.0.1:0).${COLOR_RESET}" ;;
                    4) DECISION_DISPLAY="default"; echo -e "${COLOR_GREEN}  [+] Display set to default.${COLOR_RESET}" ;;
                esac
                echo ""
                ;;

            4)
                echo ""
                echo -e "${COLOR_CYAN}  --- MODIFY SSH FORWARDING PORT ---${COLOR_RESET}"
                read -r -p "  Enter host port to forward to VM SSH port 22 (Current: ${DECISION_SSH_PORT}): " port_input
                if [[ "$port_input" =~ ^[0-9]+$ ]] && [ "$port_input" -ge 1024 ] && [ "$port_input" -le 65535 ]; then
                    DECISION_SSH_PORT=$port_input
                    echo -e "${COLOR_GREEN}  [+] SSH port updated to ${DECISION_SSH_PORT}.${COLOR_RESET}"
                else
                    echo -e "${COLOR_RED}  [!] Invalid port number (must be 1024-65535).${COLOR_RESET}"
                fi
                echo ""
                ;;

            *)
                echo -e "${COLOR_RED}  Invalid choice. Please select 1-4, R to run, or Q to cancel.${COLOR_RESET}"
                ;;
        esac

        show_decision_summary
    done
}

