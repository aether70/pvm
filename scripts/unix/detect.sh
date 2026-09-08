#!/usr/bin/env bash
# detect.sh - Host hardware and QEMU capability detection for Linux and macOS.
#
# Everything here is a measurement, never a guess: accelerators, display
# backends and audio backends are read out of the QEMU binary that will
# actually be launched, because a binary that lists "hvf" for aarch64 guests
# lists only "tcg" for x86_64 guests on the same Apple Silicon host.

# pvm_norm_arch <uname -m output or config token> -> qemu arch token
# "host" is accepted as a config value meaning "whatever this machine is",
# which is how a VM opts into native-speed virtualization on any host.
pvm_norm_arch() {
    case "$1" in
        host|native)           printf '%s' "${HOST_ARCH:-$(pvm_norm_arch "$(uname -m)")}" ;;
        x86_64|amd64)          printf 'x86_64' ;;
        aarch64|arm64)         printf 'aarch64' ;;
        i386|i486|i586|i686)   printf 'i386' ;;
        *)                     printf '%s' "$1" ;;
    esac
}

# pvm_backend_dir <root_dir> - platform-specific bundled QEMU directory
pvm_backend_dir() {
    local root_dir="$1" key
    case "$(uname -s)" in
        Darwin) key="macos" ;;
        Linux)  key="linux" ;;
        *)      key="linux" ;;
    esac
    printf '%s/%s' "$root_dir" "$(config_get "backends.$key.relative_qemu_path" "backends/$key/qemu")"
}

# pvm_find_qemu <root_dir> <arch>
# Bundled backend first (portable SSD use case), then PATH, then the usual
# Homebrew / /usr/local prefixes.
pvm_find_qemu() {
    local root_dir="$1" arch="$2"
    local bin="qemu-system-$arch"
    local backend
    backend="$(pvm_backend_dir "$root_dir")"

    local cand
    for cand in \
        "$backend/$bin" \
        "$backend/bin/$bin"
    do
        [ -x "$cand" ] && { printf '%s' "$cand"; return 0; }
    done

    if command -v "$bin" >/dev/null 2>&1; then
        command -v "$bin"
        return 0
    fi

    for cand in \
        "/opt/homebrew/bin/$bin" \
        "/usr/local/bin/$bin" \
        "/usr/bin/$bin" \
        "/usr/libexec/$bin"
    do
        [ -x "$cand" ] && { printf '%s' "$cand"; return 0; }
    done

    return 1
}

# pvm_find_qemu_img <root_dir>
pvm_find_qemu_img() {
    local root_dir="$1" backend cand
    backend="$(pvm_backend_dir "$root_dir")"
    for cand in "$backend/qemu-img" "$backend/bin/qemu-img"; do
        [ -x "$cand" ] && { printf '%s' "$cand"; return 0; }
    done
    if command -v qemu-img >/dev/null 2>&1; then
        command -v qemu-img
        return 0
    fi
    for cand in /opt/homebrew/bin/qemu-img /usr/local/bin/qemu-img /usr/bin/qemu-img; do
        [ -x "$cand" ] && { printf '%s' "$cand"; return 0; }
    done
    return 1
}

# pvm_probe_qemu <qemu_path>
# Sets QEMU_VERSION / QEMU_ACCELS / QEMU_DISPLAYS / QEMU_AUDIODEVS / QEMU_SHARE_DIRS.
# Each list is space-delimited and space-padded so callers can test membership
# with a plain `case` glob instead of spawning grep.
pvm_probe_qemu() {
    local qemu="$1"
    QEMU_VERSION="Unknown"
    QEMU_ACCELS=" "
    QEMU_DISPLAYS=" "
    QEMU_AUDIODEVS=" "
    QEMU_DEVICES=" "
    QEMU_SHARE_DIRS=""

    [ -x "$qemu" ] || return 1

    QEMU_VERSION="$("$qemu" --version 2>/dev/null | head -n1 \
        | sed -n 's/.*version \([0-9][0-9.]*\).*/\1/p')"
    [ -n "$QEMU_VERSION" ] || QEMU_VERSION="Unknown"

    # `-accel help` prints a header line then one accelerator per line and
    # exits 0. Anything with whitespace or a colon is a header, not a name.
    QEMU_ACCELS=" $("$qemu" -accel help 2>&1 \
        | awk 'NR > 1 && NF == 1 && $1 !~ /:/ { printf "%s ", $1 }')"

    QEMU_DISPLAYS=" $("$qemu" -display help 2>&1 \
        | awk 'NR > 1 && NF == 1 && $1 !~ /:/ && $1 !~ /^-/ { printf "%s ", $1 }')"

    QEMU_AUDIODEVS=" $("$qemu" -audiodev help 2>&1 \
        | awk 'NR > 1 && NF == 1 && $1 !~ /:/ { printf "%s ", $1 }')"

    # `-device NAME,help` cannot be used to test for a device: QEMU exits 0
    # even for a name it has never heard of. `-device help` is the real list,
    # and it is per-target - qemu-system-aarch64 correctly omits virtio-vga
    # while qemu-system-x86_64 includes it.
    QEMU_DEVICES=" $("$qemu" -device help 2>&1 \
        | sed -n 's/^name "\([^"]*\)".*/\1/p' | tr '\n' ' ')"

    # Firmware lives next to the binary on a portable/Homebrew install and in
    # distro-specific directories on Linux. Order matters: prefer the tree that
    # belongs to this exact binary.
    local bindir prefix
    bindir="$(cd "$(dirname "$qemu")" && pwd)"
    prefix="$(dirname "$bindir")"
    QEMU_SHARE_DIRS="$bindir
$bindir/share
$prefix/share/qemu
$prefix/share
/usr/share/qemu
/usr/share/OVMF
/usr/share/ovmf
/usr/share/edk2/ovmf
/usr/share/edk2-ovmf/x64
/usr/share/edk2/x64
/usr/share/AAVMF
/usr/share/edk2/aarch64
/usr/share/qemu-efi-aarch64
/opt/homebrew/share/qemu
/usr/local/share/qemu"
}

# pvm_has <space-padded list> <token>
pvm_has() {
    case "$1" in
        *" $2 "*) return 0 ;;
        *)        return 1 ;;
    esac
}

detect_host_info() {
    local root_dir="$1"
    local guest_arch="${2:-}"

    HOST_OS="$(uname -s)"
    HOST_ARCH_RAW="$(uname -m)"
    HOST_ARCH="$(pvm_norm_arch "$HOST_ARCH_RAW")"
    HOST_CPU_NAME="Unknown CPU"
    HOST_LOGICAL_CORES=1
    HOST_PHYSICAL_CORES=1
    HOST_TOTAL_RAM_MB=2048
    HOST_AVAIL_RAM_MB=1024
    HOST_SSD_FREE_GB=0
    VIRT_HW_SUPPORT=0
    HOST_KVM_OK=0
    HOST_HVF_OK=0
    KVM_AVAILABLE=0
    HVF_AVAILABLE=0
    QEMU_PATH=""
    QEMU_IMG_PATH=""
    QEMU_ARCH=""
    QEMU_VERSION="Not Found"
    QEMU_ACCELS=" "
    QEMU_DISPLAYS=" "
    QEMU_AUDIODEVS=" "
    QEMU_DEVICES=" "
    QEMU_SHARE_DIRS=""

    if [ "$HOST_OS" = "Linux" ]; then
        HOST_LOGICAL_CORES="$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)"
        HOST_PHYSICAL_CORES="$(awk -F: '/^core id/ { print $2 }' /proc/cpuinfo 2>/dev/null | sort -u | wc -l | tr -d ' ')"
        [ "${HOST_PHYSICAL_CORES:-0}" -ge 1 ] 2>/dev/null || HOST_PHYSICAL_CORES="$HOST_LOGICAL_CORES"
        HOST_CPU_NAME="$(awk -F: '/model name/ { sub(/^[ \t]+/, "", $2); print $2; exit }' /proc/cpuinfo 2>/dev/null)"
        [ -n "$HOST_CPU_NAME" ] || HOST_CPU_NAME="Linux CPU"

        if [ -r /proc/meminfo ]; then
            HOST_TOTAL_RAM_MB="$(awk '/^MemTotal:/ { print int($2 / 1024); exit }' /proc/meminfo)"
            HOST_AVAIL_RAM_MB="$(awk '/^MemAvailable:/ { print int($2 / 1024); exit }' /proc/meminfo)"
            # Pre-3.14 kernels have no MemAvailable; MemFree is the closest proxy.
            [ -n "$HOST_AVAIL_RAM_MB" ] || \
                HOST_AVAIL_RAM_MB="$(awk '/^MemFree:/ { print int($2 / 1024); exit }' /proc/meminfo)"
        fi

        grep -qE '^flags.*(vmx|svm)' /proc/cpuinfo 2>/dev/null && VIRT_HW_SUPPORT=1
        # /dev/kvm existing is not enough - QEMU needs it open for read/write.
        if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
            HOST_KVM_OK=1
        fi

    elif [ "$HOST_OS" = "Darwin" ]; then
        HOST_LOGICAL_CORES="$(sysctl -n hw.logicalcpu 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)"
        HOST_PHYSICAL_CORES="$(sysctl -n hw.physicalcpu 2>/dev/null || echo "$HOST_LOGICAL_CORES")"
        HOST_CPU_NAME="$(sysctl -n machdep.cpu.brand_string 2>/dev/null)"
        [ -n "$HOST_CPU_NAME" ] || HOST_CPU_NAME="$(sysctl -n hw.model 2>/dev/null || echo 'Apple Silicon / Intel')"

        local mem_bytes
        mem_bytes="$(sysctl -n hw.memsize 2>/dev/null || echo 2147483648)"
        HOST_TOTAL_RAM_MB=$(( mem_bytes / 1048576 ))

        # "Available" on macOS = free + inactive + speculative + purgeable,
        # since the kernel hands those back under pressure.
        local page_size
        page_size="$(sysctl -n hw.pagesize 2>/dev/null || echo 4096)"
        HOST_AVAIL_RAM_MB="$(vm_stat 2>/dev/null | awk -v ps="$page_size" '
            /Pages free/            { gsub(/\./, "", $3); f  = $3 }
            /Pages inactive/        { gsub(/\./, "", $3); ia = $3 }
            /Pages speculative/     { gsub(/\./, "", $3); sp = $3 }
            /Pages purgeable/       { gsub(/\./, "", $3); pu = $3 }
            END { print int((f + ia + sp + pu) * ps / 1048576) }')"
        [ "${HOST_AVAIL_RAM_MB:-0}" -gt 0 ] 2>/dev/null || \
            HOST_AVAIL_RAM_MB=$(( HOST_TOTAL_RAM_MB / 2 ))

        # Hypervisor.framework is present on every supported macOS, but only
        # for guests matching the host architecture. sysctl reports whether the
        # CPU can host it at all; the per-guest answer comes from -accel help.
        if [ "$(sysctl -n kern.hv_support 2>/dev/null || echo 0)" = "1" ]; then
            VIRT_HW_SUPPORT=1
            HOST_HVF_OK=1
        fi
    fi

    [ "${HOST_LOGICAL_CORES:-0}" -ge 1 ] 2>/dev/null || HOST_LOGICAL_CORES=1
    [ "${HOST_TOTAL_RAM_MB:-0}" -ge 1 ] 2>/dev/null || HOST_TOTAL_RAM_MB=2048
    [ "${HOST_AVAIL_RAM_MB:-0}" -ge 1 ] 2>/dev/null || HOST_AVAIL_RAM_MB=1024

    # Free space on the volume holding the VM images, in GB. -P forces the
    # single-line POSIX format so the awk column index is stable.
    HOST_SSD_FREE_GB="$(df -Pk "$root_dir" 2>/dev/null | awk 'NR == 2 { print int($4 / 1048576) }')"
    [ -n "$HOST_SSD_FREE_GB" ] || HOST_SSD_FREE_GB=0

    # QEMU for the guest architecture we intend to run. Falls back to the host
    # architecture, then to x86_64, so a config typo still finds something.
    [ -n "$guest_arch" ] || guest_arch="$(config_get 'vm_defaults.arch' "$HOST_ARCH")"
    local try
    for try in "$guest_arch" "$HOST_ARCH" x86_64; do
        [ -n "$try" ] || continue
        if QEMU_PATH="$(pvm_find_qemu "$root_dir" "$try")"; then
            QEMU_ARCH="$try"
            break
        fi
        QEMU_PATH=""
    done

    QEMU_IMG_PATH="$(pvm_find_qemu_img "$root_dir")" || QEMU_IMG_PATH=""

    if [ -n "$QEMU_PATH" ]; then
        pvm_probe_qemu "$QEMU_PATH"
    fi
    pvm_recompute_accel_flags
}

# pvm_recompute_accel_flags
# An accelerator is usable only when the host exposes it AND the specific QEMU
# binary was built with it. HOST_KVM_OK / HOST_HVF_OK hold the host half, which
# never changes; the binary half does, because switching guest architecture
# switches binary - qemu-system-x86_64 on Apple Silicon offers tcg only while
# qemu-system-aarch64 on the same machine offers hvf. Recompute rather than
# clear, so re-probing a different binary can turn a flag back on.
pvm_recompute_accel_flags() {
    KVM_AVAILABLE=0
    HVF_AVAILABLE=0
    [ "${HOST_KVM_OK:-0}" -eq 1 ] && pvm_has "$QEMU_ACCELS" kvm && KVM_AVAILABLE=1
    [ "${HOST_HVF_OK:-0}" -eq 1 ] && pvm_has "$QEMU_ACCELS" hvf && HVF_AVAILABLE=1
    return 0
}
