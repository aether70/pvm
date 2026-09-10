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

# pvm_probe_nested_virt <qemu_path> <accel> <machine>
# Can this host expose EL2 (aarch64) to its guest, so that guest can itself run
# a hypervisor? There is no sysctl or cpuinfo bit that answers this - Apple
# gates it on M3+ at the Hypervisor.framework level, and QEMU only finds out by
# asking. So ask: start the machine paused and quit immediately. ~200ms, and it
# only runs when a VM has actually requested nested virtualization.
pvm_probe_nested_virt() {
    local qemu="$1" accel="$2" machine="${3:-virt}"
    [ -x "$qemu" ] || return 1

    # -cpu host is only valid under a hypervisor; TCG needs a named model.
    local cpu="host"
    [ "$accel" = "tcg" ] && cpu="max"

    # -nic none matters: the default virt NIC pulls in efi-virtio.rom, and a
    # missing option ROM would fail this probe for a reason that has nothing
    # to do with EL2.
    printf '{"execute":"qmp_capabilities"}\n{"execute":"quit"}\n' \
        | "$qemu" -machine "${machine},accel=${accel},virtualization=on" \
            -cpu "$cpu" -m 128 -nic none -display none -serial none \
            -S -qmp stdio >/dev/null 2>&1
}

# pvm_detect_virtual_host
# Sets HOST_IS_VIRTUAL (0/1) and HOST_VIRT_KIND. This is what tells the rest of
# the launcher that "free space" and "hypervisor available" mean something
# different from what they mean on bare metal: df inside a guest reports the
# VIRTUAL disk, which on a sparse image can be orders of magnitude larger than
# the backing store that actually has to hold the bytes.
pvm_detect_virtual_host() {
    HOST_IS_VIRTUAL=0
    HOST_VIRT_KIND="none"

    case "$(uname -s)" in
        Linux)
            if command -v systemd-detect-virt >/dev/null 2>&1; then
                local d
                d="$(systemd-detect-virt 2>/dev/null)"
                if [ -n "$d" ] && [ "$d" != "none" ]; then
                    HOST_IS_VIRTUAL=1; HOST_VIRT_KIND="$d"; return 0
                fi
            fi
            # DMI is absent on the aarch64 "virt" machine, which identifies
            # itself through the device tree instead.
            local dmi
            for dmi in /sys/class/dmi/id/product_name /sys/class/dmi/id/sys_vendor; do
                [ -r "$dmi" ] || continue
                case "$(cat "$dmi" 2>/dev/null)" in
                    *QEMU*|*KVM*|*VMware*|*VirtualBox*|*Xen*|*Hyper-V*|*Parallels*)
                        HOST_IS_VIRTUAL=1; HOST_VIRT_KIND="qemu/other"; return 0 ;;
                esac
            done
            local dt
            for dt in /proc/device-tree/compatible /sys/firmware/devicetree/base/compatible; do
                [ -r "$dt" ] || continue
                if tr -d '\0' < "$dt" 2>/dev/null | grep -qi 'dummy-virt\|qemu'; then
                    HOST_IS_VIRTUAL=1; HOST_VIRT_KIND="qemu"; return 0
                fi
            done
            ;;
        Darwin)
            # 1 when macOS itself is running as a guest.
            if [ "$(sysctl -n kern.hv_vmm_present 2>/dev/null || echo 0)" = "1" ]; then
                HOST_IS_VIRTUAL=1; HOST_VIRT_KIND="apple-hv-guest"
            fi
            ;;
    esac
    return 0
}

# pvm_linux_cpu_name - /proc/cpuinfo has no "model name" on ARM64
pvm_linux_cpu_name() {
    local name
    name="$(awk -F: '/model name/ { sub(/^[ \t]+/, "", $2); print $2; exit }' /proc/cpuinfo 2>/dev/null)"
    [ -n "$name" ] || \
        name="$(awk -F: '/^Model name/ { sub(/^[ \t]+/, "", $2); print $2; exit }' <(lscpu 2>/dev/null) 2>/dev/null)"
    # Single-board machines name themselves in the device tree.
    if [ -z "$name" ]; then
        local m
        for m in /proc/device-tree/model /sys/firmware/devicetree/base/model; do
            [ -r "$m" ] || continue
            name="$(tr -d '\0' < "$m" 2>/dev/null)"
            [ -n "$name" ] && break
        done
    fi
    # Last resort on ARM64: the implementer/part pair that IS always present.
    if [ -z "$name" ]; then
        local impl part
        impl="$(awk -F': ' '/^CPU implementer/ { print $2; exit }' /proc/cpuinfo 2>/dev/null)"
        part="$(awk -F': ' '/^CPU part/ { print $2; exit }' /proc/cpuinfo 2>/dev/null)"
        if [ -n "$impl" ] && [ -n "$part" ]; then
            case "$impl" in
                0x41) name="ARM" ;;
                0x42) name="Broadcom" ;;
                0x43) name="Cavium" ;;
                0x4e) name="NVIDIA" ;;
                0x50) name="Ampere" ;;
                0x51) name="Qualcomm" ;;
                0xc0) name="Ampere" ;;
                *)    name="ARM64" ;;
            esac
            name="$name CPU (part $part)"
        fi
    fi
    printf '%s' "$name"
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
    HOST_IS_VIRTUAL=0
    HOST_VIRT_KIND="none"
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

    pvm_detect_virtual_host

    if [ "$HOST_OS" = "Linux" ]; then
        HOST_LOGICAL_CORES="$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)"
        HOST_PHYSICAL_CORES="$(awk -F: '/^core id/ { print $2 }' /proc/cpuinfo 2>/dev/null | sort -u | wc -l | tr -d ' ')"
        [ "${HOST_PHYSICAL_CORES:-0}" -ge 1 ] 2>/dev/null || HOST_PHYSICAL_CORES="$HOST_LOGICAL_CORES"
        HOST_CPU_NAME="$(pvm_linux_cpu_name)"
        [ -n "$HOST_CPU_NAME" ] || HOST_CPU_NAME="Linux CPU"

        if [ -r /proc/meminfo ]; then
            HOST_TOTAL_RAM_MB="$(awk '/^MemTotal:/ { print int($2 / 1024); exit }' /proc/meminfo)"
            HOST_AVAIL_RAM_MB="$(awk '/^MemAvailable:/ { print int($2 / 1024); exit }' /proc/meminfo)"
            # Pre-3.14 kernels have no MemAvailable; MemFree is the closest proxy.
            [ -n "$HOST_AVAIL_RAM_MB" ] || \
                HOST_AVAIL_RAM_MB="$(awk '/^MemFree:/ { print int($2 / 1024); exit }' /proc/meminfo)"
        fi

        # x86 advertises the hypervisor extension as a cpuinfo flag. ARM64 does
        # not: there is no vmx/svm equivalent, EL2 is not listed in Features,
        # and the kernel consumes EL2 itself to implement KVM. /dev/kvm
        # existing IS the capability signal there - grepping for vmx on ARM64
        # reports "virtualization disabled" on a machine where KVM works fine.
        case "$HOST_ARCH" in
            x86_64|i386)
                grep -qE '^flags.*(vmx|svm)' /proc/cpuinfo 2>/dev/null && VIRT_HW_SUPPORT=1
                ;;
            aarch64)
                [ -e /dev/kvm ] && VIRT_HW_SUPPORT=1
                ;;
            *)
                [ -e /dev/kvm ] && VIRT_HW_SUPPORT=1
                ;;
        esac
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
