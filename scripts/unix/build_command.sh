#!/usr/bin/env bash
# Constructs QEMU command line for Linux and macOS

build_qemu_command() {
    QEMU_ARGS=()

    # 1. VM Name
    QEMU_ARGS+=("-name" "$DECISION_VM_NAME")

    # 2. Machine and Accelerator
    local machine_type="q35"
    if [ "$TARGET_ARCH" = "aarch64" ]; then
        machine_type="virt"
    fi

    if [ "$DECISION_ACCEL" = "tcg" ]; then
        QEMU_ARGS+=("-machine" "${machine_type},accel=tcg")
    else
        QEMU_ARGS+=("-machine" "${machine_type},accel=$DECISION_ACCEL")
    fi

    # 3. CPU model
    if [ "$DECISION_ACCEL" = "kvm" ] || [ "$DECISION_ACCEL" = "hvf" ]; then
        QEMU_ARGS+=("-cpu" "host")
    else
        if [ "$TARGET_ARCH" = "aarch64" ]; then
            QEMU_ARGS+=("-cpu" "cortex-a72")
        else
            QEMU_ARGS+=("-cpu" "max")
        fi
    fi

    # 4. SMP & Memory
    QEMU_ARGS+=("-smp" "$DECISION_CORES")
    QEMU_ARGS+=("-m" "$DECISION_RAM_MB")

    # 5. Virtual Disk
    if [ -n "$DECISION_DISK" ]; then
        QEMU_ARGS+=("-drive" "file=$DECISION_DISK,format=$DECISION_DISK_FORMAT,if=virtio,cache=writeback")
    fi

    # 6. UEFI Firmware
    if [ "$DECISION_UEFI" = "true" ] && [ -n "$DECISION_UEFI_FW" ]; then
        QEMU_ARGS+=("-drive" "if=pflash,format=raw,readonly=on,file=$DECISION_UEFI_FW")
    fi

    # 6.5 CD-ROM ISO Boot
    if [ -n "$DECISION_ISO" ]; then
        QEMU_ARGS+=("-cdrom" "$DECISION_ISO" "-boot" "d")
    fi

    # 7. Display
    QEMU_ARGS+=("-vga" "virtio")
    case "$DECISION_DISPLAY" in
        sdl)   QEMU_ARGS+=("-display" "sdl") ;;
        gtk)   QEMU_ARGS+=("-display" "gtk") ;;
        vnc)   QEMU_ARGS+=("-vnc" "127.0.0.1:0") ;;
        *)     QEMU_ARGS+=("-display" "default") ;;
    esac

    # 8. USB Tablet input (prevents cursor grab)
    QEMU_ARGS+=("-device" "qemu-xhci,id=xhci")
    QEMU_ARGS+=("-device" "usb-tablet")

    # 9. Audio
    QEMU_ARGS+=("-device" "intel-hda" "-device" "hda-duplex")

    # 10. Networking
    if [ "$DECISION_NETWORK" = "nat" ]; then
        QEMU_ARGS+=("-netdev" "user,id=net0,hostfwd=tcp::$DECISION_SSH_PORT-:22")
        QEMU_ARGS+=("-device" "virtio-net-pci,netdev=net0")
    fi

    # 11. RTC Sync
    QEMU_ARGS+=("-rtc" "base=utc,clock=host")

    # Construct printable string
    FULL_COMMAND_STR="$QEMU_PATH"
    for arg in "${QEMU_ARGS[@]}"; do
        if [[ "$arg" =~ [[:space:]] ]]; then
            FULL_COMMAND_STR="$FULL_COMMAND_STR \"$arg\""
        else
            FULL_COMMAND_STR="$FULL_COMMAND_STR $arg"
        fi
    done
}
