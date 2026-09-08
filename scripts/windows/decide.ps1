<#
.SYNOPSIS
    Decision engine: host capabilities + per-VM overrides -> launch spec.
.DESCRIPTION
    Reads config.json for every default and never hard-codes a device name, so
    the Windows and Unix trees stay in step through one shared file. Anything
    the engine had to downgrade (an unavailable accelerator, a display backend
    this QEMU lacks) is reported in Warnings rather than silently applied.
#>

function Read-VMConfig {
    param([string]$VmDir)

    $vmConfFile = Join-Path $VmDir "vm.conf"
    $overrides = @{}

    if (Test-Path $vmConfFile) {
        foreach ($rawLine in (Get-Content $vmConfFile -ErrorAction SilentlyContinue)) {
            $line = $rawLine.Trim()
            if (-not $line) { continue }
            if ($line.StartsWith("#") -or $line.StartsWith(";")) { continue }

            $parts = $line -split "=", 2
            if ($parts.Count -eq 2) {
                $key = $parts[0].Trim().ToLower()
                $val = $parts[1].Trim()
                if ($key) { $overrides[$key] = $val }
            }
        }
    }

    return $overrides
}

<#
    Tolerant boolean parse. [bool]::Parse throws on "yes"/"1"/"on", which are
    exactly what a human hand-editing vm.conf writes, and an exception here
    would abort the whole launch over a spelling preference.
#>
function ConvertTo-PvmBool {
    param([string]$Value, [bool]$Default)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $Default }
    switch ($Value.Trim().ToLower()) {
        "true"  { return $true }
        "yes"   { return $true }
        "on"    { return $true }
        "1"     { return $true }
        "false" { return $false }
        "no"    { return $false }
        "off"   { return $false }
        "0"     { return $false }
        default { return $Default }
    }
}

function Get-ConfigValue {
    param($Node, [string]$Name, $Default)

    if ($null -eq $Node) { return $Default }
    $prop = $Node.PSObject.Properties[$Name]
    if ($null -eq $prop -or $null -eq $prop.Value -or "$($prop.Value)" -eq "") { return $Default }
    return $prop.Value
}

<#
    Membership test against the device list detect.ps1 read out of this exact
    binary. Never probe with `-device NAME,help`: QEMU exits 0 for names it
    does not know, so that test always passes.
#>
function Test-QemuDevice {
    param([PSCustomObject]$HostInfo, [string]$DeviceName)

    if (-not $DeviceName) { return $false }
    if (-not $HostInfo.QemuDevices -or $HostInfo.QemuDevices.Count -eq 0) {
        # Nothing was probed (no QEMU, or an unreadable listing); assume the
        # configured device is fine rather than rewriting it on no evidence.
        return $true
    }
    return ($HostInfo.QemuDevices -contains $DeviceName)
}

<#
    Finds the first of $Names present in any of $Dirs. Directory order is
    significant: the tree belonging to the QEMU binary we are about to launch
    comes first, so a system-wide OVMF cannot shadow the bundled firmware.
#>
function Find-Firmware {
    param([string[]]$Dirs, [string]$Names)

    if (-not $Names) { return $null }
    $nameList = $Names -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ }

    foreach ($dir in $Dirs) {
        if (-not $dir -or -not (Test-Path $dir)) { continue }
        foreach ($name in $nameList) {
            $candidate = Join-Path $dir $name
            if (Test-Path $candidate) { return (Resolve-Path $candidate).Path }
        }
    }
    return $null
}

<#
    The VARS image must match the CODE image it was built alongside - a
    mismatched pair either refuses to map or boots with a corrupt variable
    store - so the name derived from CODE wins over the configured list.
#>
function Find-VarsTemplate {
    param([string]$CodePath, [string]$Names, [string[]]$Dirs)

    $codeDir = Split-Path $CodePath -Parent
    $codeFile = Split-Path $CodePath -Leaf

    $derived = $codeFile -replace 'code', 'vars' -replace 'CODE', 'VARS'
    if ($derived -ne $codeFile) {
        $candidate = Join-Path $codeDir $derived
        if (Test-Path $candidate) { return (Resolve-Path $candidate).Path }
    }

    $sameDir = Find-Firmware -Dirs @($codeDir) -Names $Names
    if ($sameDir) { return $sameDir }

    return (Find-Firmware -Dirs $Dirs -Names $Names)
}

function Invoke-DecisionEngine {
    param(
        [Parameter(Mandatory = $true)] [PSCustomObject]$HostInfo,
        [Parameter(Mandatory = $true)] [string]$RootDir,
        [Parameter(Mandatory = $true)] [string]$VmDir,
        [Parameter(Mandatory = $false)] [string]$IsoPath = ""
    )

    $config = $HostInfo.Config
    if (-not $config) { $config = Get-PvmConfig -RootDir $RootDir }

    $vmDefaults = if ($config) { $config.vm_defaults } else { $null }
    $warnings = @()
    $errors = @()
    $isValid = $true

    # ---- Defaults + per-VM overrides -------------------------------------
    $memPercent   = [int](Get-ConfigValue $vmDefaults "memory_percent" 50)
    $memMin       = [int](Get-ConfigValue $vmDefaults "memory_min_mb" 2048)
    $memMax       = [int](Get-ConfigValue $vmDefaults "memory_max_mb" 16384)
    $hostReserve  = [int](Get-ConfigValue $vmDefaults "host_reserve_mb" 1536)
    $coresPercent = [int](Get-ConfigValue $vmDefaults "cores_percent" 50)
    $coresMin     = [int](Get-ConfigValue $vmDefaults "cores_min" 2)
    $coresMax     = [int](Get-ConfigValue $vmDefaults "cores_max" 8)

    $display   = [string](Get-ConfigValue $vmDefaults "display" "sdl")
    $network   = [string](Get-ConfigValue $vmDefaults "network" "nat")
    $sshPort   = [int](Get-ConfigValue $vmDefaults "ssh_port" 2222)
    $arch      = [string](Get-ConfigValue $vmDefaults "arch" $HostInfo.Architecture)
    $diskCache = [string](Get-ConfigValue $vmDefaults "disk_cache" "auto")
    $glMode    = [string](Get-ConfigValue $vmDefaults "gl" "auto")
    $audioMode = [string](Get-ConfigValue $vmDefaults "audio" "auto")
    $uefi      = ConvertTo-PvmBool ([string](Get-ConfigValue $vmDefaults "uefi" "true")) $true

    $overrides = Read-VMConfig -VmDir $VmDir

    $vmName = if ($overrides.ContainsKey("name")) { $overrides["name"] } else { (Split-Path $VmDir -Leaf) }
    # TryParse needs an already-typed target: [ref] to an uninitialised
    # variable fails to bind to the int out-parameter. 0 doubles as "unset",
    # since neither value is meaningful at zero.
    [int]$targetMemory = 0
    [int]$targetCores = 0
    if ($overrides.ContainsKey("memory_mb")) { [void][int]::TryParse($overrides["memory_mb"], [ref]$targetMemory) }
    if ($overrides.ContainsKey("cores"))     { [void][int]::TryParse($overrides["cores"], [ref]$targetCores) }
    if ($overrides.ContainsKey("display"))   { $display = $overrides["display"] }
    if ($overrides.ContainsKey("network"))   { $network = $overrides["network"] }
    if ($overrides.ContainsKey("ssh_port"))  { [int]::TryParse($overrides["ssh_port"], [ref]$sshPort) | Out-Null }
    if ($overrides.ContainsKey("uefi"))      { $uefi = ConvertTo-PvmBool $overrides["uefi"] $uefi }
    if ($overrides.ContainsKey("arch"))      { $arch = $overrides["arch"] }
    if ($overrides.ContainsKey("gl"))        { $glMode = $overrides["gl"] }
    if ($overrides.ContainsKey("audio"))     { $audioMode = $overrides["audio"] }

    $arch = ConvertTo-QemuArch $arch

    # A per-VM arch override points at a different QEMU binary than the one
    # already probed, and its capabilities differ - so re-detect against it
    # rather than reusing answers that belong to another target.
    if ($arch -and $HostInfo.QemuArch -and $arch -ne $HostInfo.QemuArch) {
        $reprobed = Get-HostInformation -RootDir $RootDir -GuestArch $arch
        if ($reprobed.QemuPath -and $reprobed.QemuArch -eq $arch) {
            $HostInfo = $reprobed
        } else {
            $warnings += "No qemu-system-$arch.exe on this host; falling back to $($HostInfo.QemuArch)."
            $arch = $HostInfo.QemuArch
        }
    }

    $archNode = $null
    if ($config -and $config.guest_arch) {
        $archNode = $config.guest_arch.PSObject.Properties[$arch]
        if ($archNode) { $archNode = $archNode.Value }
    }

    $machine = [string](Get-ConfigValue $archNode "machine" "q35")

    # ---- Memory -------------------------------------------------------------
    $safeMaxRamMB = [math]::Max(1024, $HostInfo.AvailableRamMB - $hostReserve)
    $minRequiredRamMB = 1024

    if ($targetMemory -gt 0) {
        # An explicit request is honoured as written; the review screen and the
        # safety checks are where the user is told it is risky.
        $allocatedRam = $targetMemory
    } else {
        $calcRam = [math]::Round(($HostInfo.TotalRamMB * $memPercent) / 100)
        $allocatedRam = [math]::Min($calcRam, $safeMaxRamMB)
        $allocatedRam = [math]::Min($allocatedRam, $memMax)
        $allocatedRam = [math]::Max($allocatedRam, $memMin)
    }
    $allocatedRam = [int][math]::Max(256, $allocatedRam)

    # ---- Cores ---------------------------------------------------------------
    $hostCores = [math]::Max(1, $HostInfo.LogicalCores)
    if ($targetCores -gt 0) {
        $allocatedCores = $targetCores
    } else {
        $calcCores = [math]::Round(($hostCores * $coresPercent) / 100)
        $allocatedCores = [math]::Max($coresMin, [math]::Min($calcCores, $coresMax))
        $allocatedCores = [math]::Min($allocatedCores, $hostCores)
    }
    $allocatedCores = [int][math]::Max(1, $allocatedCores)

    # ---- Acceleration ---------------------------------------------------------
    # Three conditions, all required: the host exposes the hypervisor, this
    # QEMU build includes it, and the guest architecture matches the host's.
    # An x86_64 guest on an ARM64 Windows host can only ever run under TCG,
    # and asking for whpx there is a hard QEMU error rather than a downgrade.
    $fallbackAccel = "tcg"
    if ($config -and $config.backends -and $config.backends.windows) {
        $fallbackAccel = [string](Get-ConfigValue $config.backends.windows "fallback_accel" "tcg")
    }
    $preferred = ""
    if ($config -and $config.host_accel) {
        $preferred = [string](Get-ConfigValue $config.host_accel "Windows" "whpx")
    } else {
        $preferred = "whpx"
    }

    $selectedAccel = $fallbackAccel
    $accelWarning = $null

    if ($arch -ne $HostInfo.Architecture) {
        $accelWarning = "Guest architecture ($arch) differs from host ($($HostInfo.Architecture)). Hardware acceleration cannot be used; running under $fallbackAccel emulation, which is significantly slower."
    } elseif ($HostInfo.QemuAccelerators -notcontains $preferred) {
        $accelWarning = "This QEMU build does not include '$preferred'. Running under $fallbackAccel emulation."
    } elseif ($preferred -eq "whpx" -and -not $HostInfo.WhpxAvailable) {
        if (-not $HostInfo.VirtFirmwareEnabled) {
            $accelWarning = "CPU virtualization is disabled in firmware. Enable Intel VT-x / AMD-V in BIOS/UEFI. Running under $fallbackAccel emulation."
        } else {
            $accelWarning = "WHPX is compiled in but refused to start. Enable the 'Windows Hypervisor Platform' Windows feature and reboot. Running under $fallbackAccel emulation."
        }
    } else {
        $selectedAccel = $preferred
    }

    # -cpu host only means something when a hypervisor is passing the real CPU
    # through; under TCG it is rejected on most targets.
    if ($selectedAccel -eq "tcg") {
        $cpuModel = [string](Get-ConfigValue $archNode "cpu_emulated" "max")
    } else {
        $cpuModel = [string](Get-ConfigValue $archNode "cpu_native" "host")
    }
    # WHPX does not implement -cpu host, and it cannot expose nested
    # virtualization - a guest that sees vmx advertised will try to use it and
    # fault. `max,vmx=off` is the combination this project has shipped and run
    # on Windows since v0.1; do not "upgrade" it to host without testing on a
    # real WHPX host first.
    if ($selectedAccel -eq "whpx") { $cpuModel = "max,vmx=off" }

    # ---- Disk ------------------------------------------------------------------
    $selectedDisk = $null
    $diskFormat = "qcow2"

    if ($overrides.ContainsKey("disk")) {
        $customDisk = Join-Path $VmDir $overrides["disk"]
        if (Test-Path $customDisk) {
            $selectedDisk = (Resolve-Path $customDisk).Path
            if ($customDisk -match '\.(raw|img)$') { $diskFormat = "raw" }
        }
    }

    if (-not $selectedDisk) {
        foreach ($candidate in @("disk.qcow2", "vm.qcow2", "disk.raw", "disk.img")) {
            $candidatePath = Join-Path $VmDir $candidate
            if (Test-Path $candidatePath) {
                $selectedDisk = (Resolve-Path $candidatePath).Path
                if ($candidate -match '\.(raw|img)$') { $diskFormat = "raw" }
                break
            }
        }
    }

    # writeback is fast but loses the guest's last writes on host power loss.
    # qcow2 metadata survives that; raw images do not.
    if ($diskCache -eq "auto") {
        $diskCache = if ($diskFormat -eq "raw") { "writethrough" } else { "writeback" }
    }

    # ---- Display ----------------------------------------------------------------
    # The configured default is a request, not a guarantee: which backends were
    # compiled in varies by QEMU build even on the same OS.
    $requestedDisplay = $display
    if ($display -ne "vnc" -and $HostInfo.QemuDisplays -and $HostInfo.QemuDisplays.Count -gt 0) {
        if ($HostInfo.QemuDisplays -notcontains $display) {
            $picked = $null
            foreach ($try in @("sdl", "gtk", "cocoa")) {
                if ($HostInfo.QemuDisplays -contains $try) { $picked = $try; break }
            }
            if ($picked) {
                $warnings += "Display backend '$requestedDisplay' is not compiled into this QEMU; using '$picked' instead."
                $display = $picked
            } else {
                $warnings += "No graphical display backend in this QEMU build; falling back to VNC on 127.0.0.1:5900."
                $display = "vnc"
            }
        }
    }

    # ---- Graphics adapter --------------------------------------------------------
    $vgaDevice = [string](Get-ConfigValue $archNode "vga_device" "virtio-vga")
    $useGl = $false

    if (ConvertTo-PvmBool $glMode $false) {
        $glDevice = [string](Get-ConfigValue $archNode "vga_device_gl" "")
        if ($glDevice -and (Test-QemuDevice -HostInfo $HostInfo -DeviceName $glDevice)) {
            $vgaDevice = $glDevice
            $useGl = $true
        } else {
            $warnings += "OpenGL passthrough requested but unavailable in this QEMU build; using $vgaDevice."
        }
    }

    if ($HostInfo.QemuPath -and -not (Test-QemuDevice -HostInfo $HostInfo -DeviceName $vgaDevice)) {
        $fb = [string](Get-ConfigValue $archNode "vga_fallback" "std")
        $warnings += "Graphics device '$vgaDevice' is unavailable; using '$fb'."
        $vgaDevice = $fb
    }

    # ---- Audio ---------------------------------------------------------------------
    # An -audiodev is mandatory: hda devices without one start with no sound
    # and an "unable to open host audio" message buried in stderr.
    $audioDev = ""
    $audioLower = if ($audioMode) { $audioMode.ToLower() } else { "auto" }

    if ($audioLower -in @("off", "none", "false", "0")) {
        $audioDev = ""
    } elseif ($audioLower -in @("auto", "", "on", "true", "1")) {
        $want = ""
        if ($config -and $config.host_audio) { $want = [string](Get-ConfigValue $config.host_audio "Windows" "dsound") }
        if ($want -and $HostInfo.QemuAudioDevs -contains $want) {
            $audioDev = $want
        } else {
            foreach ($a in @("dsound", "wasapi", "sdl")) {
                if ($HostInfo.QemuAudioDevs -contains $a) { $audioDev = $a; break }
            }
            if (-not $audioDev -and $HostInfo.QemuAudioDevs.Count -gt 0) {
                # Silence is a surprising thing to discover after installing an
                # OS, so say so now rather than letting the VM just be mute.
                $warnings += "No usable audio backend in this QEMU build (offers: $($HostInfo.QemuAudioDevs -join ', ')). The VM will have no sound."
            }
        }
    } else {
        if ($HostInfo.QemuAudioDevs -contains $audioMode) {
            $audioDev = $audioMode
        } else {
            $warnings += "Audio backend '$audioMode' is not available in this QEMU build; sound disabled."
        }
    }

    # virtio-net-pci loads a PXE option ROM at startup and refuses to be
    # created when it is missing:
    #   failed to find romfile "efi-virtio.rom"
    # That ROM ships separately (Debian/Ubuntu: ipxe-qemu, only a Recommends)
    # and is absent from minimal installs and stripped portable QEMU builds.
    # PortableVM never network-boots - it boots the disk or the installer ISO -
    # so an empty romfile= is a clean opt-out rather than a lost feature. Only
    # applied when the ROM really is missing, so hosts that have it keep PXE.
    $netRomOpt = ""
    if ($HostInfo.QemuPath -and -not (Find-Firmware -Dirs @($HostInfo.QemuShareDirs) -Names "efi-virtio.rom")) {
        $netRomOpt = ",romfile="
    }

    # ---- UEFI -----------------------------------------------------------------------
    $uefiRequired = ConvertTo-PvmBool ([string](Get-ConfigValue $archNode "uefi_required" "false")) $false
    if ($uefiRequired -and -not $uefi) {
        # aarch64/virt has no legacy BIOS at all - without pflash firmware the
        # guest never reaches a bootloader.
        $uefi = $true
        $warnings += "Architecture '$arch' has no legacy BIOS; UEFI has been force-enabled."
    }

    $uefiCode = $null
    $uefiVars = $null

    if ($uefi) {
        $codeNames = [string](Get-ConfigValue $archNode "firmware_code" "")
        $varsNames = [string](Get-ConfigValue $archNode "firmware_vars" "")
        $searchDirs = @($HostInfo.QemuShareDirs)

        $uefiCode = Find-Firmware -Dirs $searchDirs -Names $codeNames

        if ($uefiCode) {
            # The CODE image is read-only and shared between VMs. Each VM needs
            # its own writable VARS image, or the guest cannot persist a boot
            # entry - which is what makes a freshly installed OS drop to the
            # EFI shell on its second start.
            $varsPath = Join-Path $VmDir "uefi_vars.fd"
            if (Test-Path $varsPath) {
                $uefiVars = (Resolve-Path $varsPath).Path
            } else {
                $template = Find-VarsTemplate -CodePath $uefiCode -Names $varsNames -Dirs $searchDirs
                if ($template) {
                    try {
                        Copy-Item -Path $template -Destination $varsPath -ErrorAction Stop
                        $uefiVars = (Resolve-Path $varsPath).Path
                    } catch {
                        $warnings += "Could not create a writable UEFI variable store in '$VmDir'. Boot entries will not persist. ($_)"
                    }
                } else {
                    $warnings += "UEFI firmware found but no matching variable-store template ($varsNames). Boot entries will not persist."
                }
            }
        } else {
            if ($uefiRequired) {
                $isValid = $false
                $errors += "UEFI firmware not found (looked for: $codeNames). '$arch' guests cannot boot without it. Place the edk2/OVMF .fd files next to the QEMU binary or in its share directory."
            } else {
                $uefi = $false
                $warnings += "UEFI firmware not found (looked for: $codeNames). Falling back to legacy BIOS boot."
            }
        }
    }

    # ---- Validation --------------------------------------------------------------------
    if (-not $HostInfo.QemuPath) {
        $isValid = $false
        $errors += "qemu-system-$arch.exe not found. Place a portable QEMU under 'backends\windows\qemu\' or add QEMU to PATH."
    }

    if (-not $selectedDisk) {
        $isValid = $false
        $errors += "No virtual disk found in '$VmDir'. Please place 'disk.qcow2' in this directory."
    }

    if ($allocatedRam -gt $HostInfo.TotalRamMB) {
        $isValid = $false
        $errors += "Requested $allocatedRam MB of RAM exceeds the host's total $($HostInfo.TotalRamMB) MB. QEMU would fail to allocate."
    }

    return [PSCustomObject]@{
        VmName            = $vmName
        VmDir             = $VmDir
        Arch              = $arch
        Machine           = $machine
        CpuModel          = $cpuModel
        DiskPath          = $selectedDisk
        DiskFormat        = $diskFormat
        DiskCache         = $diskCache
        IsoPath           = $IsoPath
        AllocatedRamMB    = $allocatedRam
        AllocatedCores    = $allocatedCores
        SafeMaxRamMB      = $safeMaxRamMB
        MinRequiredRamMB  = $minRequiredRamMB
        MaxHostCores      = $hostCores
        MinRequiredCores  = 1
        Accelerator       = $selectedAccel
        AccelWarning      = $accelWarning
        DisplayMode       = $display
        NetRomOption      = $netRomOpt
        RequestedDisplay  = $requestedDisplay
        VgaDevice         = $vgaDevice
        UseGl             = $useGl
        AudioDev          = $audioDev
        NetworkMode       = $network
        SshPort           = $sshPort
        UseUefi           = $uefi
        UefiCode          = $uefiCode
        UefiVars          = $uefiVars
        QemuExe           = $HostInfo.QemuPath
        QemuImg           = $HostInfo.QemuImgPath
        HostInfo          = $HostInfo
        Warnings          = $warnings
        IsValid           = $isValid
        Errors            = $errors
    }
}

function Test-MemorySafety {
    param([int]$RamMB, [PSCustomObject]$HostInfo, [int]$SafeMaxRamMB = 0)

    $warnings = @()
    if ($SafeMaxRamMB -le 0) { $SafeMaxRamMB = [math]::Max(1024, $HostInfo.AvailableRamMB - 1024) }

    if ($RamMB -lt 1024) {
        $warnings += "Requested RAM ($RamMB MB) is BELOW the minimum required limit (1024 MB). The guest OS may crash with Out-Of-Memory errors during boot."
    } elseif ($RamMB -lt 2048) {
        $warnings += "Requested RAM ($RamMB MB) is low for desktop environments. Recommended minimum for a desktop GUI is 2048 MB."
    }

    if ($RamMB -gt $HostInfo.TotalRamMB) {
        $warnings += "Requested RAM ($RamMB MB) EXCEEDS total physical host RAM ($($HostInfo.TotalRamMB) MB). The VM cannot start."
    } elseif ($RamMB -gt $SafeMaxRamMB) {
        $warnings += "Requested RAM ($RamMB MB) EXCEEDS the safe free RAM limit ($SafeMaxRamMB MB). Programs already running on the host need memory; this may freeze or slow the host."
    }

    return $warnings
}

function Test-CpuSafety {
    param([int]$Cores, [PSCustomObject]$HostInfo)

    $warnings = @()
    $maxCores = [math]::Max(1, $HostInfo.LogicalCores)

    if ($Cores -lt 1) {
        $warnings += "CPU cores must be at least 1."
    }
    if ($Cores -gt $maxCores) {
        $warnings += "Requested cores ($Cores) EXCEED total available host logical cores ($maxCores). Over-committing cores degrades performance."
    } elseif ($Cores -eq $maxCores -and $maxCores -gt 2) {
        $warnings += "Allocating 100% of host CPU cores ($Cores) may cause host desktop stuttering while the VM is under load."
    }

    return $warnings
}
