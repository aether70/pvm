#!/usr/bin/env bash
# decide.sh - Turns host capabilities + per-VM overrides into a launch spec.
#
# Nothing here shells out to QEMU except to confirm a device exists; all
# capability facts come from detect.sh. Every value has a config.json default,
# and every config.json value has a built-in fallback, so a missing or corrupt
# config degrades rather than fails.

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
    OVERRIDE_ARCH=""
    OVERRIDE_GL=""
    OVERRIDE_AUDIO=""

    [ -f "$conf_file" ] || return 0

    local line key val
    while IFS= read -r line || [ -n "$line" ]; do
        # Strip CRLF from configs written on the Windows side of the SSD.
        line="${line%$'\r'}"
        case "$line" in
            ''|'#'*|';'*) continue ;;
            *'='*) ;;
            *) continue ;;
        esac
        key="${line%%=*}"
        val="${line#*=}"
        key="$(printf '%s' "$key" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
        # Trim surrounding whitespace from the value but keep inner spaces.
        val="$(printf '%s' "$val" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        case "$key" in
            name)      OVERRIDE_NAME="$val" ;;
            memory_mb) OVERRIDE_MEMORY="$val" ;;
            cores)     OVERRIDE_CORES="$val" ;;
            display)   OVERRIDE_DISPLAY="$val" ;;
            network)   OVERRIDE_NETWORK="$val" ;;
            ssh_port)  OVERRIDE_SSH_PORT="$val" ;;
            uefi)      OVERRIDE_UEFI="$val" ;;
            disk)      OVERRIDE_DISK="$val" ;;
            arch)      OVERRIDE_ARCH="$val" ;;
            gl)        OVERRIDE_GL="$val" ;;
            audio)     OVERRIDE_AUDIO="$val" ;;
        esac
    done < "$conf_file"
}

# pvm_bool <value> <default:true|false>
pvm_bool() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        1|true|yes|on)   printf 'true' ;;
        0|false|no|off)  printf 'false' ;;
        *)               printf '%s' "$2" ;;
    esac
}

# pvm_device_exists <device name>
# Membership test against the device list detect.sh read out of this exact
# binary. Never probe with `-device NAME,help`: QEMU exits 0 for names it does
# not know, so that test always passes.
pvm_device_exists() {
    pvm_has "$QEMU_DEVICES" "$1"
}

# pvm_find_firmware <comma-separated names>
# Searches every QEMU share directory, preferring the tree that belongs to the
# binary we are about to launch. Echoes the first hit.
pvm_find_firmware() {
    local names="$1" dir name
    local IFS_SAVE="$IFS"
    while IFS= read -r dir; do
        [ -n "$dir" ] && [ -d "$dir" ] || continue
        IFS=','
        for name in $names; do
            [ -n "$name" ] || continue
            if [ -f "$dir/$name" ]; then
                IFS="$IFS_SAVE"
                printf '%s' "$dir/$name"
                return 0
            fi
        done
        IFS="$IFS_SAVE"
    done <<< "$QEMU_SHARE_DIRS"
    return 1
}

# pvm_find_vars_template <code_path> <comma-separated vars names>
# The VARS image must match the CODE image it was built with, so we try the
# name derived from CODE first and only then fall back to the config list.
pvm_find_vars_template() {
    local code_path="$1" names="$2"
    local code_dir code_file derived

    code_dir="$(dirname "$code_path")"
    code_file="$(basename "$code_path")"

    # edk2-x86_64-code.fd -> edk2-x86_64-vars.fd, OVMF_CODE_4M.fd -> OVMF_VARS_4M.fd
    derived="$(printf '%s' "$code_file" | sed -e 's/code/vars/' -e 's/CODE/VARS/')"
    if [ "$derived" != "$code_file" ] && [ -f "$code_dir/$derived" ]; then
        printf '%s' "$code_dir/$derived"
        return 0
    fi

    local name
    local IFS_SAVE="$IFS"
    IFS=','
    for name in $names; do
        IFS="$IFS_SAVE"
        [ -n "$name" ] || continue
        if [ -f "$code_dir/$name" ]; then
            printf '%s' "$code_dir/$name"
            return 0
        fi
        IFS=','
    done
    IFS="$IFS_SAVE"

    pvm_find_firmware "$names"
}

run_decision_engine() {
    local root_dir="$1"
    local vm_dir="$2"

    parse_vm_conf "$vm_dir/vm.conf"

    DECISION_ERRORS=()
    DECISION_WARNINGS=()
    DECISION_IS_VALID=1

    # ---- 1. Identity ---------------------------------------------------
    DECISION_VM_NAME="${OVERRIDE_NAME:-$(basename "$vm_dir")}"
    DECISION_VM_DIR="$vm_dir"

    # ---- 2. Guest architecture ----------------------------------------
    DECISION_ARCH="${OVERRIDE_ARCH:-$(config_get 'vm_defaults.arch' "$HOST_ARCH")}"
    DECISION_ARCH="$(pvm_norm_arch "$DECISION_ARCH")"

    # A per-VM arch override points at a different QEMU binary than the one
    # detect.sh probed, so re-detect against that binary before reading any
    # capability out of it.
    if [ -n "$DECISION_ARCH" ] && [ "$DECISION_ARCH" != "$QEMU_ARCH" ]; then
        local alt
        if alt="$(pvm_find_qemu "$root_dir" "$DECISION_ARCH")"; then
            QEMU_PATH="$alt"
            QEMU_ARCH="$DECISION_ARCH"
            pvm_probe_qemu "$QEMU_PATH"
            pvm_recompute_accel_flags
        else
            DECISION_WARNINGS+=("No qemu-system-$DECISION_ARCH on this host; falling back to $QEMU_ARCH.")
            DECISION_ARCH="$QEMU_ARCH"
        fi
    fi

    local arch_key="guest_arch.$DECISION_ARCH"
    DECISION_MACHINE="$(config_get "$arch_key.machine" "q35")"

    # ---- 3. Memory -----------------------------------------------------
    local mem_min mem_max mem_percent reserve
    mem_min="$(config_get_int 'vm_defaults.memory_min_mb' 2048)"
    mem_max="$(config_get_int 'vm_defaults.memory_max_mb' 16384)"
    mem_percent="$(config_get_int 'vm_defaults.memory_percent' 50)"
    reserve="$(config_get_int 'vm_defaults.host_reserve_mb' 1536)"

    DECISION_SAFE_MAX_RAM=$(( HOST_AVAIL_RAM_MB - reserve ))
    [ "$DECISION_SAFE_MAX_RAM" -lt 1024 ] && DECISION_SAFE_MAX_RAM=1024
    DECISION_MIN_REQUIRED_RAM=1024

    if [ -n "$OVERRIDE_MEMORY" ] && [ -z "${OVERRIDE_MEMORY//[0-9]/}" ]; then
        # An explicit request is honoured as written; the interactive review
        # and the safety checks are where the user is told it is risky.
        DECISION_RAM_MB="$OVERRIDE_MEMORY"
    else
        DECISION_RAM_MB=$(( HOST_TOTAL_RAM_MB * mem_percent / 100 ))
        [ "$DECISION_RAM_MB" -gt "$DECISION_SAFE_MAX_RAM" ] && DECISION_RAM_MB="$DECISION_SAFE_MAX_RAM"
        [ "$DECISION_RAM_MB" -gt "$mem_max" ] && DECISION_RAM_MB="$mem_max"
        [ "$DECISION_RAM_MB" -lt "$mem_min" ] && DECISION_RAM_MB="$mem_min"
    fi
    [ "$DECISION_RAM_MB" -lt 256 ] && DECISION_RAM_MB=256

    # ---- 4. CPU cores --------------------------------------------------
    local cores_min cores_max cores_percent
    cores_min="$(config_get_int 'vm_defaults.cores_min' 2)"
    cores_max="$(config_get_int 'vm_defaults.cores_max' 8)"
    cores_percent="$(config_get_int 'vm_defaults.cores_percent' 50)"

    DECISION_MAX_HOST_CORES="$HOST_LOGICAL_CORES"
    DECISION_MIN_CORES=1

    if [ -n "$OVERRIDE_CORES" ] && [ -z "${OVERRIDE_CORES//[0-9]/}" ]; then
        DECISION_CORES="$OVERRIDE_CORES"
    else
        DECISION_CORES=$(( HOST_LOGICAL_CORES * cores_percent / 100 ))
        [ "$DECISION_CORES" -lt "$cores_min" ] && DECISION_CORES="$cores_min"
        [ "$DECISION_CORES" -gt "$cores_max" ] && DECISION_CORES="$cores_max"
        [ "$DECISION_CORES" -gt "$HOST_LOGICAL_CORES" ] && DECISION_CORES="$HOST_LOGICAL_CORES"
    fi
    [ "$DECISION_CORES" -lt 1 ] && DECISION_CORES=1

    # ---- 5. Acceleration ------------------------------------------------
    # Three things must all hold: the host exposes the hypervisor, this QEMU
    # binary was built with it, and the guest arch matches the host arch.
    # Apple Silicon is the case that makes the last one non-optional -
    # qemu-system-x86_64 there reports tcg only, and asking for hvf is a hard
    # QEMU error rather than a silent downgrade.
    local preferred fallback
    preferred="$(config_get "host_accel.$HOST_OS" "")"
    fallback="$(config_get "backends.$(printf '%s' "$HOST_OS" | tr '[:upper:]' '[:lower:]' | sed 's/darwin/macos/').fallback_accel" "tcg")"
    [ -n "$fallback" ] || fallback="tcg"

    DECISION_ACCEL="$fallback"
    DECISION_ACCEL_WARN=""

    if [ -z "$preferred" ]; then
        DECISION_ACCEL_WARN="No hypervisor mapping for host OS '$HOST_OS'. Using $fallback software emulation."
    elif [ "$DECISION_ARCH" != "$HOST_ARCH" ]; then
        DECISION_ACCEL_WARN="Guest architecture ($DECISION_ARCH) differs from host ($HOST_ARCH). Hardware acceleration cannot be used; running under $fallback emulation, which is significantly slower."
    elif ! pvm_has "$QEMU_ACCELS" "$preferred"; then
        DECISION_ACCEL_WARN="This QEMU build does not support '$preferred' (offers:$QEMU_ACCELS). Running under $fallback emulation."
    elif [ "$preferred" = "kvm" ] && [ "$KVM_AVAILABLE" -ne 1 ]; then
        if [ "$VIRT_HW_SUPPORT" -ne 1 ]; then
            DECISION_ACCEL_WARN="CPU virtualization (VT-x/AMD-V) is disabled in firmware. Enable it in BIOS/UEFI to use KVM. Running under $fallback emulation."
        else
            DECISION_ACCEL_WARN="/dev/kvm is not readable and writable by this user. Add yourself to the 'kvm' group and re-login. Running under $fallback emulation."
        fi
    elif [ "$preferred" = "hvf" ] && [ "$HVF_AVAILABLE" -ne 1 ]; then
        DECISION_ACCEL_WARN="Hypervisor.framework is unavailable on this Mac. Running under $fallback emulation."
    else
        DECISION_ACCEL="$preferred"
    fi

    # ---- 6. CPU model ---------------------------------------------------
    # -cpu host is only meaningful when a hypervisor is passing the real CPU
    # through; under TCG it is rejected outright on most targets.
    if [ "$DECISION_ACCEL" = "tcg" ]; then
        DECISION_CPU="$(config_get "$arch_key.cpu_emulated" "max")"
    else
        DECISION_CPU="$(config_get "$arch_key.cpu_native" "host")"
    fi

    # ---- 7. Disk --------------------------------------------------------
    DECISION_DISK=""
    DECISION_DISK_FORMAT="qcow2"

    if [ -n "$OVERRIDE_DISK" ] && [ -f "$vm_dir/$OVERRIDE_DISK" ]; then
        DECISION_DISK="$vm_dir/$OVERRIDE_DISK"
        case "$OVERRIDE_DISK" in
            *.raw|*.img) DECISION_DISK_FORMAT="raw" ;;
        esac
    else
        local cand
        for cand in disk.qcow2 vm.qcow2 disk.raw disk.img; do
            if [ -f "$vm_dir/$cand" ]; then
                DECISION_DISK="$vm_dir/$cand"
                case "$cand" in
                    *.raw|*.img) DECISION_DISK_FORMAT="raw" ;;
                esac
                break
            fi
        done
    fi

    # writeback is fast but loses the guest's last writes on host power loss.
    # qcow2 metadata survives that; raw images do not, so they get writethrough.
    DECISION_DISK_CACHE="$(config_get 'vm_defaults.disk_cache' 'auto')"
    if [ "$DECISION_DISK_CACHE" = "auto" ]; then
        if [ "$DECISION_DISK_FORMAT" = "raw" ]; then
            DECISION_DISK_CACHE="writethrough"
        else
            DECISION_DISK_CACHE="writeback"
        fi
    fi

    # ---- 8. Display -----------------------------------------------------
    # Homebrew's macOS QEMU ships cocoa and has neither sdl nor gtk, so the
    # configured default is a request, not a guarantee. Fall back along a
    # per-OS preference list to whatever this binary actually built in.
    DECISION_DISPLAY_REQUESTED="${OVERRIDE_DISPLAY:-$(config_get 'vm_defaults.display' 'sdl')}"
    DECISION_DISPLAY="$DECISION_DISPLAY_REQUESTED"
    DECISION_DISPLAY_WARN=""

    if [ "$DECISION_DISPLAY" != "vnc" ] && [ -n "$QEMU_PATH" ]; then
        if ! pvm_has "$QEMU_DISPLAYS" "$DECISION_DISPLAY"; then
            local pref_list try picked=""
            if [ "$HOST_OS" = "Darwin" ]; then
                pref_list="cocoa sdl gtk"
            else
                pref_list="gtk sdl cocoa"
            fi
            for try in $pref_list; do
                if pvm_has "$QEMU_DISPLAYS" "$try"; then picked="$try"; break; fi
            done
            if [ -n "$picked" ]; then
                DECISION_DISPLAY_WARN="Display backend '$DECISION_DISPLAY_REQUESTED' is not compiled into this QEMU; using '$picked' instead."
                DECISION_DISPLAY="$picked"
            else
                DECISION_DISPLAY_WARN="No graphical display backend in this QEMU build; falling back to VNC on 127.0.0.1:5900."
                DECISION_DISPLAY="vnc"
            fi
            DECISION_WARNINGS+=("$DECISION_DISPLAY_WARN")
        fi
    fi

    # ---- 9. Graphics adapter -------------------------------------------
    # -vga is x86-only; on aarch64/virt it fails with "Virtio VGA not
    # available", so every target gets its GPU as a -device instead.
    DECISION_VGA_DEVICE="$(config_get "$arch_key.vga_device" "virtio-vga")"
    local gl_mode
    gl_mode="$(config_get 'vm_defaults.gl' 'auto')"
    [ -n "$OVERRIDE_GL" ] && gl_mode="$OVERRIDE_GL"

    if [ "$(pvm_bool "$gl_mode" "false")" = "true" ]; then
        local gl_device
        gl_device="$(config_get "$arch_key.vga_device_gl" "")"
        if [ -n "$gl_device" ] && [ -n "$QEMU_PATH" ] && pvm_device_exists "$gl_device"; then
            DECISION_VGA_DEVICE="$gl_device"
            DECISION_GL="on"
        else
            DECISION_GL="off"
            DECISION_WARNINGS+=("OpenGL passthrough requested but unavailable in this QEMU build; using $DECISION_VGA_DEVICE.")
        fi
    else
        DECISION_GL="off"
    fi

    if [ -n "$QEMU_PATH" ] && ! pvm_device_exists "$DECISION_VGA_DEVICE"; then
        local fb
        fb="$(config_get "$arch_key.vga_fallback" "std")"
        DECISION_WARNINGS+=("Graphics device '$DECISION_VGA_DEVICE' is unavailable; using '$fb'.")
        DECISION_VGA_DEVICE="$fb"
    fi

    # ---- 10. Audio -------------------------------------------------------
    # An -audiodev is mandatory: hda-duplex without one prints
    # "Can not open `adc' (no host audio driver)" and starts with no sound.
    DECISION_AUDIODEV=""
    local audio_mode
    audio_mode="$(config_get 'vm_defaults.audio' 'auto')"
    [ -n "$OVERRIDE_AUDIO" ] && audio_mode="$OVERRIDE_AUDIO"

    case "$(printf '%s' "$audio_mode" | tr '[:upper:]' '[:lower:]')" in
        off|none|false|0)
            DECISION_AUDIODEV=""
            ;;
        auto|''|true|on|1)
            local want
            want="$(config_get "host_audio.$HOST_OS" "")"
            if [ -n "$want" ] && pvm_has "$QEMU_AUDIODEVS" "$want"; then
                DECISION_AUDIODEV="$want"
            else
                local a
                for a in coreaudio pipewire pa alsa sdl dsound; do
                    if pvm_has "$QEMU_AUDIODEVS" "$a"; then DECISION_AUDIODEV="$a"; break; fi
                done
            fi
            if [ -z "$DECISION_AUDIODEV" ] && [ -n "$QEMU_PATH" ]; then
                # Silence is a surprising thing to discover after installing an
                # OS, so say so now rather than letting the VM just be mute.
                DECISION_WARNINGS+=("No usable audio backend in this QEMU build (offers:$QEMU_AUDIODEVS). The VM will have no sound.")
            fi
            ;;
        *)
            if pvm_has "$QEMU_AUDIODEVS" "$audio_mode"; then
                DECISION_AUDIODEV="$audio_mode"
            else
                DECISION_WARNINGS+=("Audio backend '$audio_mode' is not available in this QEMU build; sound disabled.")
            fi
            ;;
    esac

    # ---- 11. Network -----------------------------------------------------
    DECISION_NETWORK="${OVERRIDE_NETWORK:-$(config_get 'vm_defaults.network' 'nat')}"
    DECISION_SSH_PORT="${OVERRIDE_SSH_PORT:-$(config_get_int 'vm_defaults.ssh_port' 2222)}"

    # virtio-net-pci loads a PXE option ROM at startup and refuses to be
    # created when it is missing:
    #   failed to find romfile "efi-virtio.rom"
    # That ROM is a separate package (Debian/Ubuntu: ipxe-qemu, pulled in only
    # as a Recommends) and is absent from minimal installs and from stripped
    # portable QEMU builds. PortableVM never network-boots - it boots the disk
    # or the installer ISO - so an empty romfile= is a clean opt-out rather
    # than a lost feature. Only applied when the ROM really is missing, so
    # hosts that have it keep PXE working.
    DECISION_NET_ROM_OPT=""
    if [ -n "$QEMU_PATH" ] && ! pvm_find_firmware "efi-virtio.rom" >/dev/null 2>&1; then
        DECISION_NET_ROM_OPT=",romfile="
    fi

    # ---- 12. UEFI --------------------------------------------------------
    local uefi_required uefi_default
    uefi_required="$(pvm_bool "$(config_get "$arch_key.uefi_required" "false")" "false")"
    uefi_default="$(pvm_bool "$(config_get 'vm_defaults.uefi' 'true')" "true")"
    DECISION_UEFI="$(pvm_bool "$OVERRIDE_UEFI" "$uefi_default")"

    # aarch64/virt has no legacy BIOS at all - without pflash firmware the
    # guest never reaches a bootloader.
    if [ "$uefi_required" = "true" ] && [ "$DECISION_UEFI" != "true" ]; then
        DECISION_UEFI="true"
        DECISION_WARNINGS+=("Architecture '$DECISION_ARCH' has no legacy BIOS; UEFI has been force-enabled.")
    fi

    DECISION_UEFI_CODE=""
    DECISION_UEFI_VARS=""

    if [ "$DECISION_UEFI" = "true" ]; then
        local code_names vars_names vars_template
        code_names="$(config_get "$arch_key.firmware_code" "")"
        vars_names="$(config_get "$arch_key.firmware_vars" "")"

        if DECISION_UEFI_CODE="$(pvm_find_firmware "$code_names")"; then
            # The CODE image is read-only and shared. Each VM needs its own
            # writable VARS image or the guest cannot persist a boot entry,
            # which is why a freshly installed OS "boots to the EFI shell"
            # on the second launch.
            DECISION_UEFI_VARS="$vm_dir/uefi_vars.fd"
            if [ ! -f "$DECISION_UEFI_VARS" ]; then
                if vars_template="$(pvm_find_vars_template "$DECISION_UEFI_CODE" "$vars_names")"; then
                    if ! cp "$vars_template" "$DECISION_UEFI_VARS" 2>/dev/null; then
                        DECISION_UEFI_VARS=""
                        DECISION_WARNINGS+=("Could not create a writable UEFI variable store in '$vm_dir'. Boot entries will not persist.")
                    fi
                else
                    DECISION_UEFI_VARS=""
                    DECISION_WARNINGS+=("UEFI firmware found but no matching variable-store template ($vars_names). Boot entries will not persist.")
                fi
            fi
        else
            DECISION_UEFI_CODE=""
            if [ "$uefi_required" = "true" ]; then
                DECISION_IS_VALID=0
                DECISION_ERRORS+=("UEFI firmware not found (looked for: $code_names). '$DECISION_ARCH' guests cannot boot without it. Install the edk2/OVMF firmware package for QEMU.")
            else
                DECISION_UEFI="false"
                DECISION_WARNINGS+=("UEFI firmware not found (looked for: $code_names). Falling back to legacy BIOS boot.")
            fi
        fi
    fi

    # ---- 13. Validation ---------------------------------------------------
    if [ -z "$QEMU_PATH" ]; then
        DECISION_IS_VALID=0
        DECISION_ERRORS+=("qemu-system-$DECISION_ARCH not found. Install QEMU (Linux: 'apt install qemu-system', macOS: 'brew install qemu') or place a portable build under 'backends/'.")
    fi

    if [ -z "$DECISION_DISK" ]; then
        DECISION_IS_VALID=0
        DECISION_ERRORS+=("No virtual disk found in '$vm_dir'. Expected 'disk.qcow2'.")
    elif [ ! -r "$DECISION_DISK" ]; then
        DECISION_IS_VALID=0
        DECISION_ERRORS+=("Virtual disk '$DECISION_DISK' is not readable.")
    fi

    if [ "$DECISION_RAM_MB" -gt "$HOST_TOTAL_RAM_MB" ]; then
        DECISION_IS_VALID=0
        DECISION_ERRORS+=("Requested ${DECISION_RAM_MB} MB of RAM exceeds the host's total ${HOST_TOTAL_RAM_MB} MB. QEMU would fail to allocate.")
    fi
}

test_memory_safety_unix() {
    local ram_mb="$1"
    WARN_MSGS=()

    if [ "$ram_mb" -lt 1024 ]; then
        WARN_MSGS+=("Requested RAM (${ram_mb} MB) is BELOW the minimum required limit (1024 MB). Guest Linux may encounter Out-Of-Memory (OOM) boot panics.")
    elif [ "$ram_mb" -lt 2048 ]; then
        WARN_MSGS+=("Requested RAM (${ram_mb} MB) is low for full desktop GUI environments (recommended >= 2048 MB).")
    fi

    if [ "$ram_mb" -gt "$HOST_TOTAL_RAM_MB" ]; then
        WARN_MSGS+=("Requested RAM (${ram_mb} MB) EXCEEDS total physical RAM (${HOST_TOTAL_RAM_MB} MB). VM will fail to allocate.")
    elif [ "$ram_mb" -gt "$DECISION_SAFE_MAX_RAM" ]; then
        WARN_MSGS+=("Requested RAM (${ram_mb} MB) EXCEEDS the safe free memory limit (${DECISION_SAFE_MAX_RAM} MB). Existing host applications require memory.")
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
