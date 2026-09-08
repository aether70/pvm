#!/usr/bin/env bash
# setup_core.sh - Validation and creation logic shared by the CLI and GUI
# setup wizards. Every function returns a pipe-delimited record on stdout so
# both front-ends can parse the same result.
#
# No `bc` anywhere: it is absent from minimal container images and from a
# stock macOS-on-Apple-Silicon PATH in some shells, and awk covers the same
# arithmetic.

test_vm_name_valid() {
    local VM_NAME="$1"
    local VMS_DIR="$2"

    if [ -z "$VM_NAME" ]; then
        echo "false|VM Name cannot be empty."
        return
    fi

    # Rejected on every platform, not just the current one: the SSD is meant
    # to be moved between Windows, Linux and macOS, and a name that is legal
    # here can make the directory unopenable there.
    case "$VM_NAME" in
        *[/\\:*?\"\<\>\|]*)
            echo "false|VM Name cannot contain any of: / \\ : * ? \" < > |"
            return ;;
        .|..)
            echo "false|VM Name cannot be '.' or '..'."
            return ;;
        .*)
            echo "false|VM Name cannot start with a dot."
            return ;;
        *[[:space:]])
            echo "false|VM Name cannot end with a space."
            return ;;
    esac

    if [ "${#VM_NAME}" -gt 64 ]; then
        echo "false|VM Name is too long (maximum 64 characters)."
        return
    fi

    if [ -e "$VMS_DIR/$VM_NAME" ]; then
        echo "false|A VM with this name already exists."
        return
    fi

    echo "true|[OK] Name is valid."
}

test_iso_file_valid() {
    local ISO_PATH="$1"

    if [ -z "$ISO_PATH" ]; then
        echo "false|ISO path cannot be empty.|0"
        return
    fi

    if [ ! -f "$ISO_PATH" ]; then
        echo "false|ISO file does not exist.|0"
        return
    fi

    if [ ! -r "$ISO_PATH" ]; then
        echo "false|ISO file is not readable.|0"
        return
    fi

    case "$(printf '%s' "$ISO_PATH" | tr '[:upper:]' '[:lower:]')" in
        *.iso|*.img) ;;
        *) echo "false|Selected file is not an .iso image.|0"; return ;;
    esac

    local SIZE_BYTES SIZE_GB
    SIZE_BYTES="$(wc -c < "$ISO_PATH" | tr -d ' ')"
    SIZE_GB="$(awk -v b="$SIZE_BYTES" 'BEGIN { printf "%.2f", b / 1073741824 }')"

    echo "true|[OK] ISO found ($SIZE_GB GB).|$SIZE_GB"
}

test_disk_space_available() {
    local REQ_GB="$1"
    local FREE_GB="$2"

    case "$REQ_GB" in
        ''|*[!0-9]*) echo "false|ERROR|Disk size must be a whole number of GB."; return ;;
    esac
    case "$FREE_GB" in
        ''|*[!0-9]*) FREE_GB=0 ;;
    esac

    if [ "$REQ_GB" -le 0 ]; then
        echo "false|ERROR|Disk size must be greater than 0."
        return
    fi

    # qcow2 images are sparse, so the requested size is a ceiling rather than
    # an immediate allocation - but a disk that cannot possibly fit is still
    # worth refusing up front.
    if [ "$REQ_GB" -ge "$FREE_GB" ]; then
        echo "false|ERROR|Disk size (${REQ_GB} GB) exceeds available free space (${FREE_GB} GB)."
        return
    fi

    if [ "$REQ_GB" -gt $(( FREE_GB / 2 )) ]; then
        echo "true|WARNING|Requested size (${REQ_GB} GB) is more than half the free space (${FREE_GB} GB)."
        return
    fi

    echo "true|OK|[OK] Space available. Fits in ${FREE_GB} GB free."
}

# new_vm_instance <name> <vms_dir> <disk_gb> <qemu_img_path> [arch]
new_vm_instance() {
    local VM_NAME="$1"
    local VMS_DIR="$2"
    local DISK_GB="$3"
    local QEMU_IMG="${4:-qemu-img}"
    local ARCH="${5:-}"

    local TARGET_DIR="$VMS_DIR/$VM_NAME"

    if [ ! -x "$QEMU_IMG" ] && ! command -v "$QEMU_IMG" >/dev/null 2>&1; then
        echo "false|qemu-img not found. Install QEMU or place a portable build under 'backends/'."
        return
    fi

    if ! mkdir -p "$TARGET_DIR" 2>/dev/null; then
        echo "false|Could not create directory '$TARGET_DIR'."
        return
    fi

    local DISK_PATH="$TARGET_DIR/disk.qcow2"
    local ERR
    if ! ERR="$("$QEMU_IMG" create -f qcow2 "$DISK_PATH" "${DISK_GB}G" 2>&1)"; then
        # Leave nothing half-created behind for the next run to trip over.
        rm -rf "$TARGET_DIR" 2>/dev/null
        echo "false|Failed to create virtual disk: $(printf '%s' "$ERR" | tr '\n' ' ')"
        return
    fi

    {
        echo "# PortableVM per-instance overrides."
        echo "# Anything omitted here falls back to config.json at the SSD root."
        echo "name=$VM_NAME"
        [ -n "$ARCH" ] && echo "arch=$ARCH"
        echo "network=nat"
        echo "# display=  sdl | gtk | cocoa | vnc   (auto-detected when unset)"
        echo "# memory_mb="
        echo "# cores="
        echo "# ssh_port="
    } > "$TARGET_DIR/vm.conf"

    echo "true|VM created successfully.|$TARGET_DIR"
}
