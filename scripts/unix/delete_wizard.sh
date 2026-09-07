#!/bin/bash
# GUI Delete Wizard for Unix

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <VmName> <VmsDir>"
    exit 1
fi

VM_NAME="$1"
VMS_DIR="$2"
TARGET_DIR="$VMS_DIR/$VM_NAME"

if [ ! -d "$TARGET_DIR" ]; then
    zenity --error --text="VM '$VM_NAME' not found." --title="Error"
    exit 1
fi

# Confirmation
zenity --question \
    --title="Delete Virtual Machine" \
    --text="WARNING: You are about to permanently delete the VM:\n<b>$VM_NAME</b>\n\nThis action cannot be undone. All data will be lost.\n\nAre you sure?" \
    --icon-name=dialog-warning \
    --default-cancel

if [ $? -ne 0 ]; then
    exit 0
fi

# Deletion with progress
(
    echo "10"
    echo "# Analyzing directory..."
    
    # Get total file count
    TOTAL_FILES=$(find "$TARGET_DIR" -type f | wc -l)
    
    if [ "$TOTAL_FILES" -eq 0 ]; then
        TOTAL_FILES=1
    fi
    
    CURRENT=0
    
    find "$TARGET_DIR" -type f | while read -r FILE; do
        FILENAME=$(basename "$FILE")
        echo "# Deleting: $FILENAME"
        rm -f "$FILE"
        
        CURRENT=$((CURRENT + 1))
        PERCENT=$(( (CURRENT * 80) / TOTAL_FILES + 10 ))
        echo "$PERCENT"
        sleep 0.05 # Small delay to make progress visible
    done
    
    echo "95"
    echo "# Removing directory..."
    rm -rf "$TARGET_DIR"
    
    echo "100"
    echo "# Successfully deleted VM '$VM_NAME'."
    sleep 1

) | zenity --progress \
    --title="Deleting VM" \
    --text="Preparing..." \
    --percentage=0 \
    --auto-close \
    --no-cancel

if [ $? -eq 0 ] && [ ! -d "$TARGET_DIR" ]; then
    zenity --info --text="Successfully deleted VM '$VM_NAME'." --title="Deleted"
    exit 0
else
    zenity --error --text="Failed to delete VM '$VM_NAME' completely." --title="Error"
    exit 1
fi
