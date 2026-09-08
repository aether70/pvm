<#
.SYNOPSIS
    Host hardware and QEMU capability detection for Windows.
.DESCRIPTION
    Every capability reported here is measured rather than assumed. In
    particular WHPX is confirmed by briefly starting the real QEMU binary with
    that accelerator: `-accel help` only says the accelerator was compiled in,
    not that the Windows Hypervisor Platform feature is enabled, and the
    difference between those two is the single most common "it worked on my
    machine" failure on this platform.
#>

function Get-PvmConfig {
    param([string]$RootDir)

    $configFile = Join-Path $RootDir "config.json"
    if (Test-Path $configFile) {
        try {
            return (Get-Content $configFile -Raw -ErrorAction Stop | ConvertFrom-Json)
        } catch {
            Write-Warning "config.json could not be parsed; using built-in defaults. ($_)"
        }
    }
    return $null
}

<#
    Normalises an architecture token. "host"/"native" is accepted as a
    config.json value meaning "whatever this machine is", which is how a VM
    opts into native-speed virtualization on any host.
#>
function ConvertTo-QemuArch {
    param([string]$Arch)

    if ($Arch -match '^(host|native)$') {
        # PROCESSOR_ARCHITEW6432 is what a 32-bit PowerShell on 64-bit Windows
        # sees; PROCESSOR_ARCHITECTURE lies to it. Neither being set at all
        # means we are not on Windows, so resolve to the common case rather
        # than recursing on an empty string.
        $raw = $env:PROCESSOR_ARCHITEW6432
        if (-not $raw) { $raw = $env:PROCESSOR_ARCHITECTURE }
        if (-not $raw) { return "x86_64" }
        $Arch = $raw
    }

    switch -Regex ($Arch) {
        '^(AMD64|x86_64)$'   { return "x86_64" }
        '^(ARM64|aarch64)$'  { return "aarch64" }
        '^(x86|i[3-6]86)$'   { return "i386" }
        default              { return $Arch }
    }
}

<#
    Runs QEMU and reports whether it survived $TimeoutMs. A rejected
    accelerator makes QEMU print to stderr and exit within milliseconds, so
    "still alive" is a reliable proxy for "this accelerator works here".
    -S keeps the CPU stopped so nothing in the guest ever executes.
#>
function Test-QemuAccelerator {
    param(
        [string]$QemuExe,
        [string]$Machine,
        [string]$Accel,
        [int]$TimeoutMs = 4000
    )

    if (-not $QemuExe -or -not (Test-Path $QemuExe)) { return $false }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $QemuExe
    $psi.Arguments = "-machine $Machine,accel=$Accel -m 64 -display none -S -monitor none -serial none -nodefaults"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardOutput = $true
    $psi.CreateNoWindow = $true

    $proc = $null
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        if (-not $proc) { return $false }

        if ($proc.WaitForExit($TimeoutMs)) {
            # Exited on its own inside the window: the accelerator was refused.
            return $false
        }
        return $true
    } catch {
        return $false
    } finally {
        if ($proc -and -not $proc.HasExited) {
            try { $proc.Kill() } catch {}
        }
        if ($proc) { try { $proc.Dispose() } catch {} }
    }
}

<#
    Reads the device list out of `-device help`. This, not `-device NAME,help`,
    is how you test whether a device exists: QEMU exits 0 for `-device
    anything-at-all,help`, so the per-device form always reports success. The
    list is also per-target - qemu-system-aarch64 omits virtio-vga while
    qemu-system-x86_64 includes it.
#>
function Get-QemuDeviceList {
    param([string]$QemuExe)

    $items = @()
    try {
        $output = & $QemuExe -device help 2>&1
    } catch {
        return $items
    }

    foreach ($line in (($output | Out-String) -split "`r?`n")) {
        if ($line -match '^\s*name\s+"([^"]+)"') { $items += $Matches[1] }
    }
    return $items
}

<#
    Parses a `-<thing> help` listing. QEMU prints a header line and then one
    bare token per line, so anything with whitespace or a colon is prose.
#>
function Get-QemuHelpList {
    param(
        [string]$QemuExe,
        [string]$Option
    )

    $items = @()
    try {
        $output = & $QemuExe $Option help 2>&1
    } catch {
        return $items
    }

    foreach ($line in (($output | Out-String) -split "`r?`n")) {
        $trimmed = $line.Trim()
        if (-not $trimmed) { continue }
        if ($trimmed -match '[\s:]') { continue }
        if ($trimmed.StartsWith('-')) { continue }
        $items += $trimmed
    }
    return $items
}

function Find-QemuBinary {
    param(
        [string]$RootDir,
        [string]$Arch,
        [string]$RelativeBackend = "backends\windows\qemu"
    )

    $binName = "qemu-system-$Arch.exe"
    $backendDir = Join-Path $RootDir $RelativeBackend

    $direct = Join-Path $backendDir $binName
    if (Test-Path $direct) { return (Resolve-Path $direct).Path }

    if (Test-Path $backendDir) {
        $found = Get-ChildItem -Path $backendDir -Filter $binName -Recurse -ErrorAction SilentlyContinue |
                 Select-Object -First 1
        if ($found) { return $found.FullName }
    }

    $pathCmd = Get-Command $binName -ErrorAction SilentlyContinue
    if ($pathCmd) { return $pathCmd.Source }

    # QEMU's own Windows installer does not add itself to PATH.
    foreach ($guess in @("$env:ProgramFiles\qemu\$binName", "${env:ProgramFiles(x86)}\qemu\$binName")) {
        if ($guess -and (Test-Path $guess)) { return (Resolve-Path $guess).Path }
    }

    return ""
}

function Get-HostInformation {
    param(
        [Parameter(Mandatory = $false)]
        [string]$RootDir = $PSScriptRoot,

        [Parameter(Mandatory = $false)]
        [string]$GuestArch = ""
    )

    $config = Get-PvmConfig -RootDir $RootDir

    $hostInfo = [PSCustomObject]@{
        OSName               = "Unknown Windows"
        OSVersion            = ""
        Architecture         = ConvertTo-QemuArch $env:PROCESSOR_ARCHITECTURE
        RawArchitecture      = $env:PROCESSOR_ARCHITECTURE
        CPUName              = "Unknown CPU"
        PhysicalCores        = 1
        LogicalCores         = 1
        TotalRamMB           = 2048
        AvailableRamMB       = 1024
        VirtFirmwareEnabled  = $false
        HypervisorPresent    = $false
        WhpxAvailable        = $false
        QemuPath             = ""
        QemuImgPath          = ""
        QemuArch             = ""
        QemuVersion          = "Not Found"
        QemuAccelerators     = @()
        QemuDisplays         = @()
        QemuAudioDevs        = @()
        QemuDevices          = @()
        QemuShareDirs        = @()
        SsdFreeSpaceGB       = 0
        Config               = $config
    }

    try {
        # ---- OS and memory ------------------------------------------------
        # CIM first (the supported API since Win8); WMI is the fallback for
        # hosts where the CIM service is disabled.
        $os = $null
        try { $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue } catch {}
        if (-not $os) { try { $os = Get-WmiObject Win32_OperatingSystem -ErrorAction SilentlyContinue } catch {} }
        if ($os) {
            $hostInfo.OSName = $os.Caption
            $hostInfo.OSVersion = $os.Version
            $hostInfo.TotalRamMB = [math]::Round($os.TotalVisibleMemorySize / 1024)
            $hostInfo.AvailableRamMB = [math]::Round($os.FreePhysicalMemory / 1024)
        }

        # ---- CPU -----------------------------------------------------------
        $cpuList = $null
        try { $cpuList = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue } catch {}
        if (-not $cpuList) { try { $cpuList = Get-WmiObject Win32_Processor -ErrorAction SilentlyContinue } catch {} }
        if ($cpuList) {
            $primaryCpu = $cpuList | Select-Object -First 1
            $hostInfo.CPUName = ($primaryCpu.Name -replace '\s+', ' ').Trim()

            $totalPhysical = ($cpuList | Measure-Object -Property NumberOfCores -Sum).Sum
            $totalLogical  = ($cpuList | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum

            $hostInfo.PhysicalCores = if ($totalPhysical) { [int]$totalPhysical } else { 1 }
            $hostInfo.LogicalCores  = if ($totalLogical) { [int]$totalLogical } else { [System.Environment]::ProcessorCount }

            if ($null -ne $primaryCpu.VirtualizationFirmwareEnabled) {
                $hostInfo.VirtFirmwareEnabled = [bool]$primaryCpu.VirtualizationFirmwareEnabled
            }
        }
        if ($hostInfo.LogicalCores -lt 1) { $hostInfo.LogicalCores = 1 }

        # When Hyper-V or WSL2 owns the machine, Win32_Processor reports
        # VirtualizationFirmwareEnabled as false even though VT-x is on -
        # HypervisorPresent is what tells the truth in that case.
        $compSystem = $null
        try { $compSystem = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue } catch {}
        if (-not $compSystem) { try { $compSystem = Get-WmiObject Win32_ComputerSystem -ErrorAction SilentlyContinue } catch {} }
        if ($compSystem -and $compSystem.HypervisorPresent -eq $true) {
            $hostInfo.HypervisorPresent = $true
            $hostInfo.VirtFirmwareEnabled = $true
        }

        # ---- Which QEMU ----------------------------------------------------
        $configArch = "x86_64"
        if ($config -and $config.vm_defaults -and $config.vm_defaults.arch) {
            $configArch = $config.vm_defaults.arch
        }
        if ($GuestArch) { $configArch = $GuestArch }
        $wantArch = ConvertTo-QemuArch $configArch

        $relBackend = "backends\windows\qemu"
        if ($config -and $config.backends -and $config.backends.windows -and $config.backends.windows.relative_qemu_path) {
            $relBackend = ($config.backends.windows.relative_qemu_path) -replace '/', '\'
        }

        $qemuExe = ""
        foreach ($try in @($wantArch, $hostInfo.Architecture, "x86_64")) {
            if (-not $try) { continue }
            $qemuExe = Find-QemuBinary -RootDir $RootDir -Arch $try -RelativeBackend $relBackend
            if ($qemuExe) { $hostInfo.QemuArch = $try; break }
        }

        if ($qemuExe -and (Test-Path $qemuExe)) {
            $hostInfo.QemuPath = $qemuExe
            $qemuDir = Split-Path $qemuExe -Parent

            $imgCandidate = Join-Path $qemuDir "qemu-img.exe"
            if (Test-Path $imgCandidate) {
                $hostInfo.QemuImgPath = $imgCandidate
            } else {
                $imgCmd = Get-Command "qemu-img.exe" -ErrorAction SilentlyContinue
                if ($imgCmd) { $hostInfo.QemuImgPath = $imgCmd.Source }
            }

            $verOutput = (& $qemuExe --version 2>&1) -join "`n"
            if ($verOutput -match "version\s+([0-9][0-9\.]*)") {
                $hostInfo.QemuVersion = $Matches[1]
            }

            $hostInfo.QemuAccelerators = Get-QemuHelpList -QemuExe $qemuExe -Option "-accel"
            $hostInfo.QemuDisplays     = Get-QemuHelpList -QemuExe $qemuExe -Option "-display"
            $hostInfo.QemuAudioDevs    = Get-QemuHelpList -QemuExe $qemuExe -Option "-audiodev"
            $hostInfo.QemuDevices      = Get-QemuDeviceList -QemuExe $qemuExe

            # Firmware search path, most specific first.
            $shareDirs = @(
                (Join-Path $qemuDir "share")
                $qemuDir
                (Join-Path (Split-Path $qemuDir -Parent) "share\qemu")
                (Join-Path (Split-Path $qemuDir -Parent) "share")
            ) | Where-Object { $_ -and (Test-Path $_) }
            $hostInfo.QemuShareDirs = @($shareDirs)

            # ---- WHPX, for real ------------------------------------------
            # Compiled in is necessary but not sufficient: WHPX also needs the
            # "Windows Hypervisor Platform" optional feature turned on and a
            # reboot. Only an actual launch distinguishes the two.
            if ($hostInfo.QemuAccelerators -contains "whpx") {
                $machine = "q35"
                if ($config -and $config.guest_arch -and $config.guest_arch.$($hostInfo.QemuArch)) {
                    $machine = $config.guest_arch.$($hostInfo.QemuArch).machine
                }
                $hostInfo.WhpxAvailable = Test-QemuAccelerator -QemuExe $qemuExe -Machine $machine -Accel "whpx"
            }
        }

        # ---- Free space on the volume holding the VMs ----------------------
        try {
            $resolved = (Resolve-Path $RootDir -ErrorAction Stop).Path
            $driveLetter = (Split-Path -Qualifier $resolved) -replace ':', ''
            if ($driveLetter) {
                $drive = Get-PSDrive -Name $driveLetter -PSProvider FileSystem -ErrorAction SilentlyContinue
                if ($drive) {
                    $hostInfo.SsdFreeSpaceGB = [math]::Round($drive.Free / 1GB, 2)
                }
            }
        } catch {}
    }
    catch {
        Write-Warning "Detection encountered an issue: $_"
    }

    return $hostInfo
}

# Allow direct execution for standalone testing.
if ($MyInvocation.InvocationName -eq $MyInvocation.MyCommand.Path) {
    $info = Get-HostInformation -RootDir (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent)
    $info | Format-List
}
