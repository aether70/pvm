#!/usr/bin/env bash
# Host hardware & virtualization capability detector for Linux and macOS

detect_host_info() {
    local root_dir="$1"

    HOST_OS=$(uname -s)
    HOST_ARCH=$(uname -m)
    HOST_CPU_NAME="Unknown CPU"
    HOST_PHYSICAL_CORES=1
    HOST_LOGICAL_CORES=1
    HOST_TOTAL_RAM_MB=2048
    HOST_AVAIL_RAM_MB=1024
    VIRT_HW_SUPPORT=0
    KVM_AVAILABLE=0
    HVF_AVAILABLE=0
    QEMU_PATH=""
    QEMU_VERSION="Not Found"
    QEMU_ACCELS=""

    # 1. OS-specific CPU and Memory detection
    if [ "$HOST_OS" = "Linux" ]; then
        HOST_LOGICAL_CORES=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1)
        HOST_CPU_NAME=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | cut -d: -f2 | sed 's/^[ \t]*//' || echo "Linux CPU")
        
        # Calculate RAM in MB
        if [ -f /proc/meminfo ]; then
            local total_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
            local avail_kb=$(grep -E 'MemAvailable|MemFree' /proc/meminfo | head -n1 | awk '{print $2}')
            HOST_TOTAL_RAM_MB=$(( total_kb / 1024 ))
            HOST_AVAIL_RAM_MB=$(( avail_kb / 1024 ))
        fi

        # Check KVM & Hardware Virtualization
        if grep -qE 'vmx|svm' /proc/cpuinfo 2>/dev/null; then
            VIRT_HW_SUPPORT=1
        fi
        if [ -w /dev/kvm ]; then
            KVM_AVAILABLE=1
        elif [ -e /dev/kvm ]; then
            KVM_AVAILABLE=1
        fi

    elif [ "$HOST_OS" = "Darwin" ]; then
        HOST_LOGICAL_CORES=$(sysctl -n hw.ncpu 2>/dev/null || echo 1)
        HOST_CPU_NAME=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "Apple Silicon / Intel")
        
        local mem_bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 2147483648)
        HOST_TOTAL_RAM_MB=$(( mem_bytes / 1048576 ))
        
        # Approximate free RAM on macOS using vm_stat
        local pages_free=$(vm_stat 2>/dev/null | grep "Pages free" | awk '{print $3}' | tr -d '.')
        local pages_inactive=$(vm_stat 2>/dev/null | grep "Pages inactive" | awk '{print $3}' | tr -d '.')
        if [ -n "$pages_free" ] && [ -n "$pages_inactive" ]; then
            HOST_AVAIL_RAM_MB=$(( (pages_free + pages_inactive) * 4096 / 1048576 ))
        else
            HOST_AVAIL_RAM_MB=$(( HOST_TOTAL_RAM_MB / 2 ))
        fi

        VIRT_HW_SUPPORT=1
    fi

    # 2. Resolve Target Architecture & Locate QEMU Binary
    TARGET_ARCH="x86_64"
    if [ -f "$root_dir/config.json" ]; then
        local cfg_arch
        cfg_arch=$(grep -o '"arch"[^:]*:[^"]*"[^"]*"' "$root_dir/config.json" 2>/dev/null | head -n1 | cut -d'"' -f4)
        if [ -n "$cfg_arch" ]; then
            TARGET_ARCH="$cfg_arch"
        fi
    fi

    # If host is Apple Silicon / ARM64 and target is x86_64, check if native aarch64 binary exists
    if [[ ("$HOST_ARCH" == "arm64" || "$HOST_ARCH" == "aarch64") && "$TARGET_ARCH" == "x86_64" ]]; then
        if ! command -v qemu-system-x86_64 >/dev/null 2>&1 && command -v qemu-system-aarch64 >/dev/null 2>&1; then
            TARGET_ARCH="aarch64"
        fi
    fi

    local qemu_bin="qemu-system-$TARGET_ARCH"
    local qemu_search_paths=(
        "$root_dir/backends/linux/qemu/$qemu_bin"
        "/opt/homebrew/bin/$qemu_bin"
        "/usr/local/bin/$qemu_bin"
        "/usr/bin/$qemu_bin"
    )

    if command -v "$qemu_bin" >/dev/null 2>&1; then
        QEMU_PATH=$(command -v "$qemu_bin")
    else
        for p in "${qemu_search_paths[@]}"; do
            if [ -x "$p" ]; then
                QEMU_PATH="$p"
                break
            fi
        done
    fi

    # Fallback to general qemu-system-x86_64 if TARGET_ARCH was not found
    if [ -z "$QEMU_PATH" ] && [ "$TARGET_ARCH" != "x86_64" ]; then
        if command -v qemu-system-x86_64 >/dev/null 2>&1; then
            QEMU_PATH=$(command -v qemu-system-x86_64)
            TARGET_ARCH="x86_64"
        fi
    fi

    if [ -n "$QEMU_PATH" ]; then
        QEMU_VERSION=$("$QEMU_PATH" --version 2>&1 | head -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "Unknown")
        QEMU_ACCELS=$("$QEMU_PATH" -accel help 2>&1 | tr '\n' ' ')
    fi

    # 3. Virtualization & Hypervisor support check on Darwin
    if [ "$HOST_OS" = "Darwin" ]; then
        # Apple HVF only accelerates guests with matching CPU ISA (arm64 guest on arm64 host, x86_64 on x86_64)
        if [[ "$HOST_ARCH" == "arm64" && "$TARGET_ARCH" == "aarch64" ]]; then
            HVF_AVAILABLE=1
        elif [[ "$HOST_ARCH" == "x86_64" && "$TARGET_ARCH" == "x86_64" ]]; then
            HVF_AVAILABLE=1
        else
            HVF_AVAILABLE=0
        fi
    fi

    # 4. Storage / SSD Free Space (in GB)
    HOST_SSD_FREE_GB=0
    if [ -d "$root_dir" ]; then
        local free_kb
        free_kb=$(df -k "$root_dir" 2>/dev/null | awk 'NR==2 {print $4}')
        if [ -n "$free_kb" ] && [ "$free_kb" -gt 0 ] 2>/dev/null; then
            HOST_SSD_FREE_GB=$(( free_kb / 1048576 ))
        fi
    fi
}
