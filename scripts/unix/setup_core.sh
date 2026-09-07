#!/usr/bin/env bash
# Centralized core logic for VM Setup Wizard (Unix)

test_vm_name_valid() {
    local VM_NAME="$1"
    local VMS_DIR="$2"
    
    if [ -z "$VM_NAME" ]; then
        echo "false|VM Name cannot be empty."
        return
    fi
    
    if [[ "$VM_NAME" =~ [/\*?\"\<\>\|] ]]; then
        echo "false|VM Name contains invalid characters."
        return
    fi
    
    if [ -d "$VMS_DIR/$VM_NAME" ]; then
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
    
    if [[ ! "$ISO_PATH" == *.iso ]]; then
        echo "false|Selected file is not an .iso file.|0"
        return
    fi
    
    # Calculate size in GB
    local SIZE_BYTES=$(wc -c <"$ISO_PATH")
    local SIZE_GB=$(echo "scale=2; $SIZE_BYTES / 1073741824" | bc)
    
    echo "true|[OK] ISO found ($SIZE_GB GB).|$SIZE_GB"
}

test_disk_space_available() {
    local REQ_GB="$1"
    local FREE_GB="$2"
    
    if [ "$REQ_GB" -le 0 ]; then
        echo "false|ERROR|Disk size must be greater than 0."
        return
    fi
    
    if [ "$REQ_GB" -ge "$FREE_GB" ]; then
        echo "false|ERROR|Disk size exceeds available free space ($FREE_GB GB)."
        return
    fi
    
    local HALF_FREE=$(echo "$FREE_GB / 2" | bc)
    if [ "$REQ_GB" -gt "$HALF_FREE" ]; then
        echo "true|WARNING|Warning: Requested size takes more than 50% of free space ($FREE_GB GB)."
        return
    fi
    
    echo "true|OK|[OK] Space available. Fits in $FREE_GB GB free."
}

new_vm_instance() {
    local VM_NAME="$1"
    local VMS_DIR="$2"
    local DISK_GB="$3"
    local QEMU_DIR="$4"
    
    local TARGET_DIR="$VMS_DIR/$VM_NAME"
    mkdir -p "$TARGET_DIR"
    
    local QEMU_IMG="qemu-img"
    if [ -x "$QEMU_DIR/qemu-img" ]; then
        QEMU_IMG="$QEMU_DIR/qemu-img"
    fi
    
    local DISK_PATH="$TARGET_DIR/disk.qcow2"
    if ! "$QEMU_IMG" create -f qcow2 "$DISK_PATH" "${DISK_GB}G" > /dev/null 2>&1; then
        echo "false|Failed to create virtual disk."
        return
    fi
    
    cat <<EOF > "$TARGET_DIR/vm.conf"
# VM Configuration Overrides
name=$VM_NAME
display=sdl
network=nat
uefi=false
EOF
    
    echo "true|VM created successfully.|$TARGET_DIR"
}
