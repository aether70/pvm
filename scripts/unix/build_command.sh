#!/usr/bin/env bash
# build_command.sh - Assembles the QEMU argv from the decision spec.
#
# QEMU_ARGS is the array that actually gets executed; FULL_COMMAND_STR is a
# shell-quoted rendering of the same thing for display and logging only.
# Nothing should ever `eval` FULL_COMMAND_STR - a VM name or path containing a
# space, a quote or a `$` would be re-split or expanded by the shell.

# pvm_shell_quote <string> - single-quote for safe display/copy-paste.
pvm_shell_quote() {
    case "$1" in
        *[!A-Za-z0-9._/:=@-]*|'')
            printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
            ;;
        *)
            printf '%s' "$1"
            ;;
    esac
}

build_qemu_command() {
    QEMU_ARGS=()

    # ---- Identity -------------------------------------------------------
    QEMU_ARGS+=("-name" "$DECISION_VM_NAME")

    # 1b. Firmware search path
    # QEMU's compiled-in datadir is <bindir>/../share/qemu, which is where a
    # Homebrew or distro install keeps its BIOS blobs and option ROMs. The
    # portable bundle puts them in <bindir>/share instead, so without -L a
    # bundled QEMU cannot find efi-virtio.rom or its VGA BIOS and refuses to
    # start. Only passed when that directory really exists, so a system QEMU
    # keeps using its own datadir.
    local qemu_share
    qemu_share="$(dirname "$QEMU_PATH")/share"
    if [ -d "$qemu_share" ]; then
        QEMU_ARGS+=("-L" "$qemu_share")
    fi

    # 2. Machine and Accelerator
    # DECISION_MACHINE / DECISION_CPU come from config.json via decide.sh and
    # are what the review screen shows the user; recomputing them here from
    # TARGET_ARCH is how the displayed spec and the launched spec drift apart.
    local machine_type="${DECISION_MACHINE:-q35}"

    if [ "$DECISION_ACCEL" = "tcg" ]; then
        QEMU_ARGS+=("-machine" "${machine_type},accel=tcg")
    else
        QEMU_ARGS+=("-machine" "${machine_type},accel=$DECISION_ACCEL")
    fi

    # 3. CPU model
    QEMU_ARGS+=("-cpu" "${DECISION_CPU:-max}")

    # 4. SMP & Memory
    QEMU_ARGS+=("-smp" "$DECISION_CORES")
    QEMU_ARGS+=("-m" "$DECISION_RAM_MB")

    # ---- UEFI firmware --------------------------------------------------
    # Order is load-bearing: pflash unit 0 is the read-only CODE image, unit 1
    # is this VM's writable variable store. Without unit 1 the guest cannot
    # save a boot entry and drops to the EFI shell on the next start.
    if [ "$DECISION_UEFI" = "true" ] && [ -n "$DECISION_UEFI_CODE" ]; then
        QEMU_ARGS+=("-drive" "if=pflash,format=raw,unit=0,readonly=on,file=$DECISION_UEFI_CODE")
        if [ -n "$DECISION_UEFI_VARS" ] && [ -f "$DECISION_UEFI_VARS" ]; then
            QEMU_ARGS+=("-drive" "if=pflash,format=raw,unit=1,file=$DECISION_UEFI_VARS")
        fi
    fi

    # ---- Storage --------------------------------------------------------
    if [ -n "$DECISION_DISK" ]; then
        QEMU_ARGS+=("-drive" "file=$DECISION_DISK,format=$DECISION_DISK_FORMAT,if=virtio,cache=${DECISION_DISK_CACHE:-writeback}")
    fi

    if [ -n "$DECISION_ISO" ]; then
        if pvm_device_exists virtio-scsi-pci; then
            # virtio-scsi rather than -cdrom: aarch64/virt has no IDE
            # controller for -cdrom to attach to, and this form works
            # identically on q35.
            QEMU_ARGS+=("-device" "virtio-scsi-pci,id=scsi0")
            QEMU_ARGS+=("-drive" "file=$DECISION_ISO,format=raw,if=none,id=cd0,media=cdrom,readonly=on")
            QEMU_ARGS+=("-device" "scsi-cd,drive=cd0,bus=scsi0.0,bootindex=0")
        else
            QEMU_ARGS+=("-cdrom" "$DECISION_ISO" "-boot" "d")
        fi
    fi

    # ---- Graphics -------------------------------------------------------
    # Always a -device, never -vga: `-vga virtio` is x86-only and aborts with
    # "Virtio VGA not available" on aarch64/virt.
    if [ -n "$DECISION_VGA_DEVICE" ]; then
        QEMU_ARGS+=("-device" "$DECISION_VGA_DEVICE")
    fi

    case "$DECISION_DISPLAY" in
        vnc)
            QEMU_ARGS+=("-vnc" "127.0.0.1:0")
            ;;
        none)
            QEMU_ARGS+=("-display" "none")
            ;;
        *)
            if [ "$DECISION_GL" = "on" ]; then
                QEMU_ARGS+=("-display" "$DECISION_DISPLAY,gl=on")
            else
                QEMU_ARGS+=("-display" "$DECISION_DISPLAY")
            fi
            ;;
    esac

    # ---- Input ----------------------------------------------------------
    # usb-tablet reports absolute coordinates, so the pointer tracks the host
    # cursor instead of being captured by the guest. The whole block is gated
    # on the controller: usb-tablet with no bus to attach to is a hard error,
    # and a stripped-down QEMU build may not ship qemu-xhci.
    if pvm_device_exists qemu-xhci; then
        QEMU_ARGS+=("-device" "qemu-xhci,id=xhci")
        QEMU_ARGS+=("-device" "usb-tablet,bus=xhci.0")
        QEMU_ARGS+=("-device" "usb-kbd,bus=xhci.0")
    fi

    # ---- Audio ----------------------------------------------------------
    # hda-output rather than hda-duplex: duplex opens a capture stream too,
    # which fails ("Can not open `adc'") on hosts with no microphone or no
    # granted microphone permission.
    if [ -n "$DECISION_AUDIODEV" ]; then
        QEMU_ARGS+=("-audiodev" "$DECISION_AUDIODEV,id=snd0")
        QEMU_ARGS+=("-device" "intel-hda")
        QEMU_ARGS+=("-device" "hda-output,audiodev=snd0")
    fi

    # ---- Network --------------------------------------------------------
    if [ "$DECISION_NETWORK" = "nat" ]; then
        QEMU_ARGS+=("-netdev" "user,id=net0,hostfwd=tcp:127.0.0.1:$DECISION_SSH_PORT-:22")
        QEMU_ARGS+=("-device" "virtio-net-pci,netdev=net0${DECISION_NET_ROM_OPT:-}")
    elif [ "$DECISION_NETWORK" = "none" ]; then
        QEMU_ARGS+=("-nic" "none")
    fi

    # ---- Misc -----------------------------------------------------------
    QEMU_ARGS+=("-rtc" "base=utc,clock=host")
    
    # Hardware RNG: Prevents installers from hanging while waiting for entropy.
    if pvm_device_exists virtio-rng-pci; then
        QEMU_ARGS+=("-device" "virtio-rng-pci")
    fi

    # Lets the host reclaim guest memory that the guest is not using. Optional
    # in every sense, so it is skipped rather than fatal when absent.
    if pvm_device_exists virtio-balloon-pci; then
        QEMU_ARGS+=("-device" "virtio-balloon-pci")
    fi

    # ---- Printable rendering (display only) -----------------------------
    FULL_COMMAND_STR="$(pvm_shell_quote "$QEMU_PATH")"
    local arg
    for arg in "${QEMU_ARGS[@]}"; do
        FULL_COMMAND_STR="$FULL_COMMAND_STR $(pvm_shell_quote "$arg")"
    done
}
