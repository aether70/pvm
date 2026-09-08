#!/usr/bin/env bash
# lock.sh - Single-instance guard for a VM directory.
#
# Two QEMU processes writing the same qcow2 image corrupt it, usually without
# any error until the guest filesystem is unmountable. The portable-SSD case
# makes this easy to hit: plug the drive into a second machine, or just
# double-click the launcher twice.
#
# mkdir is the primitive rather than flock or a plain file: it is atomic on
# every filesystem the SSD is likely to be formatted as (exFAT, APFS, ext4,
# NTFS-3G), and flock is a no-op on some of them.

PVM_LOCK_DIR=""

# pvm_lock_acquire <vm_dir>
# Returns 0 on success. On failure, sets PVM_LOCK_OWNER to a human-readable
# description of who holds the lock and returns 1.
pvm_lock_acquire() {
    local vm_dir="$1"
    local lock_dir="$vm_dir/.pvm-lock"
    local info_file="$lock_dir/owner"
    PVM_LOCK_OWNER=""

    if mkdir "$lock_dir" 2>/dev/null; then
        printf '%s\n%s\n%s\n' "$(hostname 2>/dev/null || echo unknown)" "$$" "$(date '+%Y-%m-%d %H:%M:%S')" > "$info_file"
        PVM_LOCK_DIR="$lock_dir"
        return 0
    fi

    # The lock exists. It is only meaningful if the owning process is still
    # alive, and we can only check that when it was taken on this machine.
    local owner_host="" owner_pid="" owner_time=""
    if [ -f "$info_file" ]; then
        { read -r owner_host; read -r owner_pid; read -r owner_time; } < "$info_file" 2>/dev/null
    fi

    local this_host
    this_host="$(hostname 2>/dev/null || echo unknown)"

    if [ -n "$owner_pid" ] && [ "$owner_host" = "$this_host" ] && ! kill -0 "$owner_pid" 2>/dev/null; then
        # Stale: the launcher died without cleaning up (crash, SIGKILL, or a
        # yanked SSD). Take it over.
        rm -rf "$lock_dir" 2>/dev/null
        if mkdir "$lock_dir" 2>/dev/null; then
            printf '%s\n%s\n%s\n' "$this_host" "$$" "$(date '+%Y-%m-%d %H:%M:%S')" > "$info_file"
            PVM_LOCK_DIR="$lock_dir"
            return 0
        fi
    fi

    if [ -n "$owner_host" ]; then
        PVM_LOCK_OWNER="host '$owner_host', PID ${owner_pid:-?}, since ${owner_time:-unknown}"
    else
        PVM_LOCK_OWNER="an unidentified process"
    fi
    return 1
}

# pvm_lock_release - safe to call when no lock is held.
pvm_lock_release() {
    if [ -n "$PVM_LOCK_DIR" ] && [ -d "$PVM_LOCK_DIR" ]; then
        rm -rf "$PVM_LOCK_DIR" 2>/dev/null
    fi
    PVM_LOCK_DIR=""
}

# pvm_lock_guard <vm_dir>
# Acquires the lock and arms the traps that release it, including on the
# signals a terminal user is most likely to send.
pvm_lock_guard() {
    pvm_lock_acquire "$1" || return 1
    trap 'pvm_lock_release' EXIT
    trap 'pvm_lock_release; trap - INT; kill -INT $$' INT
    trap 'pvm_lock_release; trap - TERM; kill -TERM $$' TERM
    trap 'pvm_lock_release; trap - HUP; kill -HUP $$' HUP
    return 0
}
