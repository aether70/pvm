#!/usr/bin/env bash
# Decision Engine for Linux and macOS

parse_vm_conf() {
    local conf_file="$1"
    OVERRIDE_NAME=""
    OVERRIDE_MEMORY=""
    OVERRIDE_CORES=""
    OVERRIDE_DISPLAY=""
    OVERRIDE_NETWORK=""
    OVERRIDE_SSH_PORT=""
    OVERRIDE_UEFI=""
    OVERRIDE_DISK=""

    if [ -f "$conf_file" ]; then
        while IFS='=' read -r key val || [ -n "$key" ]; do
            key=$(echo "$key" | tr -d ' ' | tr '[:upper:]' '[:lower:]')
            val=$(echo "$val" | sed -e 's/^[ \t]*//' -e 's/[ \t]*$//')
            case "$key" in
                name) OVERRIDE_NAME="$val" ;;
                memory_mb) OVERRIDE_MEMORY="$val" ;;
                cores) OVERRIDE_CORES="$val" ;;
                display) OVERRIDE_DISPLAY="$val" ;;
                network) OVERRIDE_NETWORK="$val" ;;
                ssh_port) OVERRIDE_SSH_PORT="$val" ;;
                uefi) OVERRIDE_UEFI="$val" ;;
                disk) OVERRIDE_DISK="$val" ;;
            esac
        done < "$conf_file"
    fi
}

run_decision_engine() {
    local root_dir="$1"
    local vm_dir="$2"

    parse_vm_conf "$vm_dir/vm.conf"

    # 1. VM Name
    DECISION_VM_NAME="${OVERRIDE_NAME:-$(basename "$vm_dir")}"

    # 2. RAM Allocation
    local mem_min=2048
    local mem_max=16384
    local mem_percent=50

    if [ -n "$OVERRIDE_MEMORY" ]; then
        DECISION_RAM_MB="$OVERRIDE_MEMORY"
    else
        local calc_ram=$(( HOST_TOTAL_RAM_MB * mem_percent / 100 ))
        local max_safe=$(( HOST_AVAIL_RAM_MB - 1024 ))
        if [ $max_safe -lt $mem_min ]; then max_safe=$mem_min; fi
        
        DECISION_RAM_MB=$calc_ram
        if [ $DECISION_RAM_MB -gt $max_safe ]; then DECISION_RAM_MB=$max_safe; fi
        if [ $DECISION_RAM_MB -lt $mem_min ]; then DECISION_RAM_MB=$mem_min; fi
        if [ $DECISION_RAM_MB -gt $mem_max ]; then DECISION_RAM_MB=$mem_max; fi
    fi

    # 3. CPU Cores Allocation
    local cores_min=2
    local cores_max=8
    local cores_percent=50

    if [ -n "$OVERRIDE_CORES" ]; then
        DECISION_CORES="$OVERRIDE_CORES"
    else
        local calc_cores=$(( HOST_LOGICAL_CORES * cores_percent / 100 ))
        DECISION_CORES=$calc_cores
        if [ $DECISION_CORES -lt $cores_min ]; then DECISION_CORES=$cores_min; fi
        if [ $DECISION_CORES -gt $cores_max ]; then DECISION_CORES=$cores_max; fi
        if [ $DECISION_CORES -gt $HOST_LOGICAL_CORES ]; then DECISION_CORES=$HOST_LOGICAL_CORES; fi
    fi
    if [ $DECISION_CORES -lt 1 ]; then DECISION_CORES=1; fi

    # 4. Acceleration Selection
    DECISION_ACCEL="tcg"
    DECISION_ACCEL_WARN=""

    if [ "$HOST_OS" = "Linux" ]; then
        if [ "$KVM_AVAILABLE" -eq 1 ]; then
            DECISION_ACCEL="kvm"
        else
            DECISION_ACCEL_WARN="KVM unavailable or /dev/kvm not writable. Running with TCG software emulation."
        fi
    elif [ "$HOST_OS" = "Darwin" ]; then
        if [ "$HVF_AVAILABLE" -eq 1 ]; then
            DECISION_ACCEL="hvf"
        else
            if [[ "$HOST_ARCH" == "arm64" && "$TARGET_ARCH" == "x86_64" ]]; then
                DECISION_ACCEL_WARN="Cross-architecture virtualization (x86_64 guest on Apple Silicon host) does not support HVF. Running with TCG software emulation."
            else
                DECISION_ACCEL_WARN="HVF unavailable. Running with TCG software emulation."
            fi
        fi
    fi

    # 5. Disk Resolution
    DECISION_DISK=""
    DECISION_DISK_FORMAT="qcow2"

    if [ -n "$OVERRIDE_DISK" ] && [ -f "$vm_dir/$OVERRIDE_DISK" ]; then
        DECISION_DISK="$vm_dir/$OVERRIDE_DISK"
    else
        for cand in disk.qcow2 vm.qcow2 disk.raw disk.img; do
            if [ -f "$vm_dir/$cand" ]; then
                DECISION_DISK="$vm_dir/$cand"
                if [[ "$cand" == *.raw || "$cand" == *.img ]]; then
                    DECISION_DISK_FORMAT="raw"
                fi
                break
            fi
        done
    fi

    # 6. Display & Network
    DECISION_DISPLAY="${OVERRIDE_DISPLAY:-sdl}"
    DECISION_NETWORK="${OVERRIDE_NETWORK:-nat}"
    DECISION_SSH_PORT="${OVERRIDE_SSH_PORT:-2222}"
    DECISION_UEFI="${OVERRIDE_UEFI:-true}"

    # 7. UEFI Firmware Discovery
    DECISION_UEFI_FW=""
    if [ "$DECISION_UEFI" = "true" ]; then
        local fw_candidates=(
            "/usr/share/OVMF/OVMF_CODE.fd"
            "/usr/share/edk2-ovmf/x64/OVMF_CODE.fd"
            "/usr/share/edk2/ovmf/OVMF_CODE.fd"
            "/usr/share/qemu/edk2-x86_64-code.fd"
            "/opt/homebrew/share/qemu/edk2-x86_64-code.fd"
            "/usr/local/share/qemu/edk2-x86_64-code.fd"
        )
        for fw in "${fw_candidates[@]}"; do
            if [ -f "$fw" ]; then
                DECISION_UEFI_FW="$fw"
                break
            fi
        done
    fi

    # 8. Safe Limit Boundaries
    DECISION_SAFE_MAX_RAM=$(( HOST_AVAIL_RAM_MB - 1024 ))
    if [ $DECISION_SAFE_MAX_RAM -lt 1024 ]; then DECISION_SAFE_MAX_RAM=1024; fi
    DECISION_MIN_REQUIRED_RAM=1024
    DECISION_MAX_HOST_CORES=$HOST_LOGICAL_CORES
    DECISION_MIN_CORES=1

    # 9. Validation
    DECISION_IS_VALID=1
    DECISION_ERRORS=()

    if [ -z "$QEMU_PATH" ]; then
        DECISION_IS_VALID=0
        DECISION_ERRORS+=("QEMU binary not found. Please install QEMU on host (e.g. 'apt install qemu-system-x86' or 'brew install qemu').")
    fi

    if [ -z "$DECISION_DISK" ]; then
        DECISION_IS_VALID=0
        DECISION_ERRORS+=("No virtual disk found in '$vm_dir'. Expected 'disk.qcow2'.")
    fi
}

test_memory_safety_unix() {
    local ram_mb="$1"
    WARN_MSGS=()

    if [ "$ram_mb" -lt 1024 ]; then
        WARN_MSGS+=("Requested RAM (${ram_mb} MB) is BELOW minimum required limit (1024 MB). Guest Linux may encounter Out-Of-Memory (OOM) boot panics.")
    elif [ "$ram_mb" -lt 2048 ]; then
        WARN_MSGS+=("Requested RAM (${ram_mb} MB) is low for full desktop GUI environments (recommended >= 2048 MB).")
    fi

    if [ "$ram_mb" -gt "$HOST_TOTAL_RAM_MB" ]; then
        WARN_MSGS+=("Requested RAM (${ram_mb} MB) EXCEEDS total physical RAM (${HOST_TOTAL_RAM_MB} MB). VM will fail to allocate.")
    elif [ "$ram_mb" -gt "$DECISION_SAFE_MAX_RAM" ]; then
        WARN_MSGS+=("Requested RAM (${ram_mb} MB) EXCEEDS safe free memory limit (${DECISION_SAFE_MAX_RAM} MB). Existing host applications require memory.")
    fi
}

test_cpu_safety_unix() {
    local cores="$1"
    WARN_CPU_MSGS=()

    if [ "$cores" -lt 1 ]; then
        WARN_CPU_MSGS+=("CPU cores must be at least 1.")
    fi

    if [ "$cores" -gt "$HOST_LOGICAL_CORES" ]; then
        WARN_CPU_MSGS+=("Requested cores ($cores) EXCEED total available host cores ($HOST_LOGICAL_CORES).")
    elif [ "$cores" -eq "$HOST_LOGICAL_CORES" ] && [ "$HOST_LOGICAL_CORES" -gt 2 ]; then
        WARN_CPU_MSGS+=("Allocating 100% of host CPU cores ($cores) may cause host desktop lag during heavy VM load.")
    fi
}

