<#
.SYNOPSIS
    Centralized core logic for VM Setup Wizard (Windows).
.DESCRIPTION
    Provides validation and creation routines for new virtual machines.
#>

function Test-VmNameValid {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$VmName,
        [Parameter(Mandatory = $true)]
        [string]$VmsDir
    )

    $result = [PSCustomObject]@{ IsValid = $false; Message = "" }

    if ([string]::IsNullOrWhiteSpace($VmName)) {
        $result.Message = "VM Name cannot be empty."
        return $result
    }

    if ($VmName -match '[<>:"/\\|?*]') {
        $result.Message = 'VM Name cannot contain any of: / \ : * ? " < > |'
        return $result
    }

    # The SSD is meant to move between Windows, Linux and macOS, so a name has
    # to be legal on all three - and these are the reserved device names that
    # make a directory unopenable on Windows specifically.
    if ($VmName -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)') {
        $result.Message = "'$VmName' is a reserved Windows device name."
        return $result
    }
    if ($VmName -eq "." -or $VmName -eq ".." -or $VmName.StartsWith(".")) {
        $result.Message = "VM Name cannot start with a dot."
        return $result
    }
    if ($VmName.EndsWith(" ") -or $VmName.EndsWith(".")) {
        $result.Message = "VM Name cannot end with a space or a dot."
        return $result
    }
    if ($VmName.Length -gt 64) {
        $result.Message = "VM Name is too long (maximum 64 characters)."
        return $result
    }

    $targetDir = Join-Path $VmsDir $VmName
    if (Test-Path $targetDir) {
        $result.Message = "A VM with this name already exists."
        return $result
    }

    $result.IsValid = $true
    $result.Message = "[OK] Name is valid."
    return $result
}

function Test-IsoFileValid {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$IsoPath
    )

    $result = [PSCustomObject]@{ IsValid = $false; Message = ""; SizeGB = 0 }

    if ([string]::IsNullOrWhiteSpace($IsoPath)) {
        $result.Message = "ISO path cannot be empty."
        return $result
    }

    if (-not (Test-Path $IsoPath)) {
        $result.Message = "ISO file does not exist."
        return $result
    }

    $item = Get-Item $IsoPath
    if ($item.PSIsContainer) {
        $result.Message = "Selected path is a folder, not an image file."
        return $result
    }
    if ($item.Extension -notin @(".iso", ".img")) {
        $result.Message = "Selected file is not an .iso image."
        return $result
    }

    $sizeGB = [math]::Round($item.Length / 1GB, 2)
    $result.IsValid = $true
    $result.SizeGB = $sizeGB
    $result.Message = "[OK] ISO found ($sizeGB GB)."
    return $result
}

function Test-DiskSpaceAvailable {
    param(
        [Parameter(Mandatory = $true)]
        [int]$RequestedGB,
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$HostInfo
    )

    $result = [PSCustomObject]@{ IsValid = $true; Level = "OK"; Message = "" }

    if ($RequestedGB -le 0) {
        $result.IsValid = $false
        $result.Level = "ERROR"
        $result.Message = "Disk size must be greater than 0."
        return $result
    }

    $freeGB = $HostInfo.SsdFreeSpaceGB

    if ($RequestedGB -ge $freeGB) {
        $result.IsValid = $false
        $result.Level = "ERROR"
        $result.Message = "Disk size exceeds available SSD free space ($freeGB GB)."
        return $result
    }

    if ($RequestedGB -gt ($freeGB * 0.5)) {
        $result.Level = "WARNING"
        $result.Message = "Warning: Requested disk size takes more than 50% of available SSD space ($freeGB GB)."
        return $result
    }

    $result.Message = "[OK] Space available. Fits in $freeGB GB free."
    return $result
}

function New-VmInstance {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmName,
        [Parameter(Mandatory = $true)]
        [string]$VmsDir,
        [Parameter(Mandatory = $true)]
        [int]$DiskSizeGB,
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$HostInfo
    )

    $result = [PSCustomObject]@{ Success = $false; Message = ""; VmDir = "" }
    $targetDir = Join-Path $VmsDir $VmName
    $createdDir = $false

    try {
        $qemuImgExe = $HostInfo.QemuImgPath
        if (-not $qemuImgExe -or -not (Test-Path $qemuImgExe)) {
            throw "qemu-img.exe not found. Install QEMU or place a portable build under 'backends\windows\qemu\'."
        }

        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        $createdDir = $true

        $diskPath = Join-Path $targetDir "disk.qcow2"

        # Native invocation, not Start-Process with a hand-quoted string:
        # PowerShell quotes each argument correctly on its way to the process,
        # so a VM path containing a space stays one argument.
        $output = & $qemuImgExe create -f qcow2 $diskPath "${DiskSizeGB}G" 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "qemu-img failed (exit $LASTEXITCODE): $(($output | Out-String).Trim())"
        }

        # Record the architecture at creation time. The disk image is
        # architecture-specific, so a later change to the global default in
        # config.json must not silently repoint an existing VM at a different
        # guest platform.
        $arch = if ($HostInfo.QemuArch) { $HostInfo.QemuArch } else { $HostInfo.Architecture }

        $confPath = Join-Path $targetDir "vm.conf"
        $confContent = @"
# PortableVM per-instance overrides.
# Anything omitted here falls back to config.json at the SSD root.
name=$VmName
arch=$arch
network=nat
# display=  sdl | gtk | cocoa | vnc   (auto-detected when unset)
# memory_mb=
# cores=
# ssh_port=
"@
        Set-Content -Path $confPath -Value $confContent -Encoding ASCII

        $result.Success = $true
        $result.VmDir = $targetDir
        $result.Message = "VM created successfully."
    } catch {
        # Leave nothing half-created behind for the next run to trip over.
        if ($createdDir -and (Test-Path $targetDir)) {
            Remove-Item -Path $targetDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        $result.Message = "Failed to create VM: $_"
    }

    return $result
}
