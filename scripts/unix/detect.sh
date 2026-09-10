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

# pvm_recompute_accel_flags
# Re-derives KVM_AVAILABLE / HVF_AVAILABLE from the three facts that have to
# hold together: the host exposes the hypervisor (HOST_KVM_OK / Darwin), the
# QEMU binary currently selected was built with it (QEMU_ACCELS), and the guest
# ISA matches the host ISA. decide.sh calls this after switching QEMU_PATH for
# a per-VM arch override, because "hvf" on qemu-system-aarch64 says nothing
# about qemu-system-x86_64 on the same Apple Silicon Mac.
pvm_recompute_accel_flags() {
    local guest="${QEMU_ARCH:-$TARGET_ARCH}"

    KVM_AVAILABLE=0
    HVF_AVAILABLE=0
    HOST_HVF_OK=0

    [ "$guest" = "$HOST_ARCH" ] || return 0

    case "$HOST_OS" in
        Linux)
            if [ "$HOST_KVM_OK" -eq 1 ] && pvm_has "$QEMU_ACCELS" "kvm"; then
                KVM_AVAILABLE=1
            fi
            ;;
        Darwin)
            # Every Mac since 10.10 ships Hypervisor.framework; the binary
            # having been built with it is the part that actually varies.
            HOST_HVF_OK=1
            if pvm_has "$QEMU_ACCELS" "hvf"; then
                HVF_AVAILABLE=1
            fi
            ;;
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

        VIRT_HW_SUPPORT=1
    fi

    # 2. Resolve Target Architecture & Locate QEMU Binary
    # An explicit guest_arch argument wins over config.json: callers that
    # already know which VM they are about to launch pass it so the probe runs
    # against the binary that will actually be executed.
    TARGET_ARCH="x86_64"
    if [ -n "$guest_arch" ]; then
        TARGET_ARCH="$(pvm_norm_arch "$guest_arch")"
    elif [ -f "$root_dir/config.json" ]; then
        local cfg_arch
        cfg_arch=$(grep -o '"arch"[^:]*:[^"]*"[^"]*"' "$root_dir/config.json" 2>/dev/null | head -n1 | cut -d'"' -f4)
        if [ -n "$cfg_arch" ]; then
            TARGET_ARCH="$(pvm_norm_arch "$cfg_arch")"
        fi
    fi

    # If host is Apple Silicon / ARM64 and target is x86_64, check if native aarch64 binary exists
    if [ "$HOST_ARCH" = "aarch64" ] && [ "$TARGET_ARCH" = "x86_64" ]; then
        if ! pvm_find_qemu "$root_dir" x86_64 >/dev/null 2>&1 \
           && pvm_find_qemu "$root_dir" aarch64 >/dev/null 2>&1; then
            TARGET_ARCH="aarch64"
        fi
    fi

    # pvm_find_qemu searches the bundled backend for THIS platform first, which
    # is the whole point of a portable install: a Homebrew QEMU on the developer
    # machine must not shadow the binary that ships on the SSD.
    if QEMU_PATH="$(pvm_find_qemu "$root_dir" "$TARGET_ARCH")"; then
        QEMU_ARCH="$TARGET_ARCH"
    else
        QEMU_PATH=""
        # Fall back to the host's own architecture before giving up entirely -
        # an x86_64-only config on an Apple Silicon Mac still gets a working
        # (emulating) launcher rather than "QEMU NOT FOUND".
        local alt_arch
        for alt_arch in "$HOST_ARCH" x86_64; do
            [ "$alt_arch" = "$TARGET_ARCH" ] && continue
            if QEMU_PATH="$(pvm_find_qemu "$root_dir" "$alt_arch")"; then
                TARGET_ARCH="$alt_arch"
                QEMU_ARCH="$alt_arch"
                break
            fi
            QEMU_PATH=""
        done
    fi

    if [ -n "$QEMU_PATH" ]; then
        pvm_probe_qemu "$QEMU_PATH"
    fi

    QEMU_IMG_PATH="$(pvm_find_qemu_img "$root_dir" || true)"

    # 3. Hypervisor availability
    # Both KVM and HVF only accelerate a guest whose ISA matches the host's, so
    # this is one shared rule rather than a per-OS special case. Note HOST_ARCH
    # is normalised ("arm64" -> "aarch64"), which is why the comparison is
    # against TARGET_ARCH in QEMU's own spelling.
    pvm_recompute_accel_flags

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
