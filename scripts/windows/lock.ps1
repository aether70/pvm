<#
.SYNOPSIS
    Single-instance guard for a VM directory.
.DESCRIPTION
    Two QEMU processes writing the same qcow2 image corrupt it, usually with
    no error until the guest filesystem stops mounting. The portable-SSD case
    makes this easy to hit: double-click the launcher twice, or plug the drive
    into a second machine.

    A directory is the lock primitive rather than a file or a mutex: creating
    one is atomic on every filesystem the SSD is likely to be formatted as
    (NTFS, exFAT), and unlike a named mutex it is visible to the Unix side of
    the same drive, which uses the identical .pvm-lock convention.
#>

function Get-PvmLockPath {
    param([string]$VmDir)
    return (Join-Path $VmDir ".pvm-lock")
}

<#
    Returns an object with Acquired, plus Owner describing the holder when it
    failed. Release with Unlock-PvmVm.
#>
function Lock-PvmVm {
    param([Parameter(Mandatory = $true)][string]$VmDir)

    $result = [PSCustomObject]@{ Acquired = $false; Owner = ""; LockDir = "" }
    $lockDir = Get-PvmLockPath -VmDir $VmDir
    $infoFile = Join-Path $lockDir "owner"
    $thisHost = $env:COMPUTERNAME
    if (-not $thisHost) { $thisHost = "unknown" }

    $created = $false
    try {
        # -Force would succeed on an existing directory, which would defeat the
        # whole mechanism; without it, an existing lock throws and we fall
        # through to the staleness check.
        New-Item -ItemType Directory -Path $lockDir -ErrorAction Stop | Out-Null
        $created = $true
    } catch {
        $created = $false
    }

    if (-not $created) {
        $ownerHost = ""
        $ownerPid = ""
        $ownerTime = ""
        if (Test-Path $infoFile) {
            $lines = @(Get-Content $infoFile -ErrorAction SilentlyContinue)
            if ($lines.Count -ge 1) { $ownerHost = $lines[0] }
            if ($lines.Count -ge 2) { $ownerPid = $lines[1] }
            if ($lines.Count -ge 3) { $ownerTime = $lines[2] }
        }

        # A lock is only meaningful while its owner is alive, and that can only
        # be checked when the lock was taken on this machine.
        $stale = $false
        # The digit check matters: a truncated or corrupted owner file would
        # otherwise make [int] throw here, turning an unreadable lock into an
        # unhandled exception instead of a clear "already running" message.
        if ($ownerPid -match '^\d+$' -and $ownerHost -eq $thisHost) {
            $proc = Get-Process -Id ([int]$ownerPid) -ErrorAction SilentlyContinue
            if (-not $proc) { $stale = $true }
        }

        if ($stale) {
            try {
                Remove-Item -Path $lockDir -Recurse -Force -ErrorAction Stop
                New-Item -ItemType Directory -Path $lockDir -ErrorAction Stop | Out-Null
                $created = $true
            } catch {
                $created = $false
            }
        }

        if (-not $created) {
            if ($ownerHost) {
                $pidText = if ($ownerPid) { $ownerPid } else { "?" }
                $timeText = if ($ownerTime) { $ownerTime } else { "unknown" }
                $result.Owner = "host '$ownerHost', PID $pidText, since $timeText"
            } else {
                $result.Owner = "an unidentified process"
            }
            return $result
        }
    }

    try {
        Set-Content -Path $infoFile -Value @(
            $thisHost
            "$PID"
            (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        ) -ErrorAction Stop
    } catch {
        # The directory is what enforces the lock; the owner file is only there
        # to make the failure message useful, so losing it is not fatal.
    }

    $result.Acquired = $true
    $result.LockDir = $lockDir
    return $result
}

function Unlock-PvmVm {
    param([string]$VmDir, [string]$LockDir = "")

    if (-not $LockDir -and $VmDir) { $LockDir = Get-PvmLockPath -VmDir $VmDir }
    if ($LockDir -and (Test-Path $LockDir)) {
        Remove-Item -Path $LockDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-PvmVmLocked {
    param([string]$VmDir)
    return (Test-Path (Get-PvmLockPath -VmDir $VmDir))
}
