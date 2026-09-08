<#
.SYNOPSIS
    Main Windows Orchestrator for the Portable VM Launcher.
.DESCRIPTION
    Integrates host detection, multi-VM selection, resource decision, command synthesis, and execution.
#>

param(
    [switch]$DetectOnly,
    [switch]$DryRun,
    [switch]$ListVMs,
    [switch]$Setup,
    [switch]$Delete,
    [string]$VmName = "",
    [switch]$NoPrompt
)

# Root of the SSD (two levels up from scripts\windows)
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path (Split-Path $ScriptDir -Parent) -Parent

# Dot-source helper modules
. (Join-Path $ScriptDir "detect.ps1")
. (Join-Path $ScriptDir "decide.ps1")
. (Join-Path $ScriptDir "build_command.ps1")
. (Join-Path $ScriptDir "display.ps1")
. (Join-Path $ScriptDir "lock.ps1")

Show-Banner

# 1. Host Detection
$hostInfo = Get-HostInformation -RootDir $RootDir
Show-HostInfo -HostInfo $hostInfo

if ($DetectOnly) {
    Write-Host "  [i] Detection completed (-DetectOnly flag specified)." -ForegroundColor Cyan
    exit 0
}

# Setup Mode Logic
if ($Setup) {
    . (Join-Path $ScriptDir "setup_core.ps1")
    Write-Host "`n  [+] NEW VM SETUP" -ForegroundColor Green
    $vmsDir = Join-Path $RootDir "vms"
    
    $vmNameSetup = Read-Host "  VM Name"
    $val = Test-VmNameValid -VmName $vmNameSetup -VmsDir $vmsDir
    if (-not $val.IsValid) { Write-Host "  [!] $($val.Message)" -ForegroundColor Red; exit 1 }

    $isoPath = Read-Host "  ISO File Path (e.g. C:\path\to\ubuntu.iso)"
    $valIso = Test-IsoFileValid -IsoPath $isoPath
    if (-not $valIso.IsValid) { Write-Host "  [!] $($valIso.Message)" -ForegroundColor Red; exit 1 }

    $diskSizeStr = Read-Host "  Root Disk Size (GB) [64]"
    if ([string]::IsNullOrWhiteSpace($diskSizeStr)) { $diskSizeStr = "64" }
    $diskSizeSetup = [int]$diskSizeStr

    $valSpace = Test-DiskSpaceAvailable -RequestedGB $diskSizeSetup -HostInfo $hostInfo
    if (-not $valSpace.IsValid) { Write-Host "  [!] $($valSpace.Message)" -ForegroundColor Red; exit 1 }
    if ($valSpace.Level -eq "WARNING") { Write-Host "  [!] $($valSpace.Message)" -ForegroundColor Yellow }

    Write-Host "  Creating VM..." -NoNewline
    $res = New-VmInstance -VmName $vmNameSetup -VmsDir $vmsDir -DiskSizeGB $diskSizeSetup -HostInfo $hostInfo
    if (-not $res.Success) {
        Write-Host " Failed." -ForegroundColor Red
        Write-Host "  [!] $($res.Message)" -ForegroundColor Red
        exit 1
    }
    Write-Host " Done." -ForegroundColor Green

    # Boot the installer. Firmware mode is left exactly as it will be on every
    # later boot: installing under BIOS and then booting under UEFI (or the
    # reverse) leaves a disk the firmware cannot boot.
    $decisionSetup = Invoke-DecisionEngine -HostInfo $hostInfo -RootDir $RootDir -VmDir $res.VmDir -IsoPath $isoPath
    Show-DecisionSummary -Decision $decisionSetup -HostInfo $hostInfo

    if (-not $decisionSetup.IsValid) {
        Write-Host "  [X] Cannot start the installer:" -ForegroundColor Red
        foreach ($err in $decisionSetup.Errors) {
            Write-Host "      - $err" -ForegroundColor Red
        }
        exit 1
    }

    $lockSetup = Lock-PvmVm -VmDir $res.VmDir
    if (-not $lockSetup.Acquired) {
        Write-Host "  [!] VM '$vmNameSetup' is already running (locked by $($lockSetup.Owner))." -ForegroundColor Red
        exit 1
    }

    $cmdSpecSetup = Build-QemuCommand -Decision $decisionSetup
    Write-Host "  [*] Launching installer for '$vmNameSetup'..." -ForegroundColor Green
    try {
        $processSetup = Start-Process -FilePath $cmdSpecSetup.Executable -ArgumentList $cmdSpecSetup.ArgumentString -Wait -PassThru -NoNewWindow
        exit $processSetup.ExitCode
    } catch {
        Write-Host "  [X] Failed to launch QEMU: $_" -ForegroundColor Red
        exit 1
    } finally {
        Unlock-PvmVm -VmDir $res.VmDir
    }
}

# Delete Mode Logic
if ($Delete) {
    if (-not $VmName) {
        Write-Host "  [!] Please specify the VM to delete using -VmName <name>" -ForegroundColor Red
        exit 1
    }

    $vmsDir = Join-Path $RootDir "vms"
    $targetDir = Join-Path $vmsDir $VmName

    if (-not (Test-Path $targetDir)) {
        Write-Host "  [!] VM '$VmName' not found." -ForegroundColor Red
        exit 1
    }

    # Deleting the backing image out from under a live QEMU is the one
    # destructive race the instance lock exists to prevent, so this path takes
    # the lock too rather than only checking for it.
    $lockDel = Lock-PvmVm -VmDir $targetDir
    if (-not $lockDel.Acquired) {
        Write-Host "  [!] VM '$VmName' appears to be running (locked by $($lockDel.Owner)). Shut it down first." -ForegroundColor Red
        exit 1
    }

    Write-Host "`n  [-] DELETE VM" -ForegroundColor Red
    Write-Host "  This permanently deletes '$VmName' and every file in it." -ForegroundColor Yellow
    $sizeBytes = (Get-ChildItem -Path $targetDir -Recurse -File -ErrorAction SilentlyContinue |
                  Measure-Object -Property Length -Sum).Sum
    if ($sizeBytes) {
        Write-Host ("  Size on disk: {0:N2} GB" -f ($sizeBytes / 1GB)) -ForegroundColor Yellow
    }

    if (-not $NoPrompt) {
        # Typing the name is deliberate friction: a bare y/N is too easy to
        # answer on autopilot for something with no undo.
        $confirm = Read-Host "  Type the VM name to confirm deletion"
        if ($confirm -cne $VmName) {
            Unlock-PvmVm -VmDir $targetDir
            Write-Host "  Aborted - name did not match." -ForegroundColor Cyan
            exit 0
        }
    }

    Write-Host "  Removing..." -ForegroundColor Gray
    # Release first: the lock directory lives inside the tree being deleted.
    Unlock-PvmVm -VmDir $targetDir
    Remove-Item -Path $targetDir -Recurse -Force -ErrorAction SilentlyContinue

    if (Test-Path $targetDir) {
        Write-Host "  [!] Failed to fully delete '$targetDir'." -ForegroundColor Red
        exit 1
    }

    Write-Host "  [+] Deleted VM '$VmName'." -ForegroundColor Green
    exit 0
}

# 2. Discover Virtual Machines in vms/
$vmsDir = Join-Path $RootDir "vms"
$vmList = @()

if (Test-Path $vmsDir) {
    $subDirs = Get-ChildItem -Path $vmsDir -Directory
    foreach ($dir in $subDirs) {
        $diskSize = 0
        $diskCandidates = @("disk.qcow2", "vm.qcow2", "disk.raw", "disk.img")
        foreach ($cand in $diskCandidates) {
            $candPath = Join-Path $dir.FullName $cand
            if (Test-Path $candPath) {
                $diskItem = Get-Item $candPath
                $diskSize = $diskItem.Length
                break
            }
        }

        $vmList += [PSCustomObject]@{
            Name          = $dir.Name
            FullPath      = $dir.FullName
            DiskSizeBytes = $diskSize
            IsRunning     = (Test-PvmVmLocked -VmDir $dir.FullName)
        }
    }
}

if ($ListVMs) {
    Show-VmSelectionMenu -VmList $vmList | Out-Null
    exit 0
}

# 3. Select VM
$selectedVm = $null
if ($VmName) {
    $selectedVm = $vmList | Where-Object { $_.Name -eq $VmName } | Select-Object -First 1
    if (-not $selectedVm) {
        Write-Host "  [!] Error: VM '$VmName' not found in '$vmsDir'." -ForegroundColor Red
        exit 1
    }
} else {
    $selectedVm = Show-VmSelectionMenu -VmList $vmList
    if (-not $selectedVm) {
        Write-Host "  [i] Exiting launcher." -ForegroundColor Gray
        exit 0
    }
}

# 4. Decision Engine
$decision = Invoke-DecisionEngine -HostInfo $hostInfo -RootDir $RootDir -VmDir $selectedVm.FullPath
Show-DecisionSummary -Decision $decision -HostInfo $hostInfo

if (-not $decision.IsValid) {
    Write-Host "  [X] CANNOT LAUNCH VM DUE TO CONFIGURATION ERRORS:" -ForegroundColor Red
    foreach ($err in $decision.Errors) {
        Write-Host "      - $err" -ForegroundColor Red
    }
    Write-Host ""
    exit 1
}

# 5. Single-instance lock.
# Taken before the interactive review, not just before launch: there is no
# point walking the user through a configuration menu for a VM they cannot
# start. A dry run never launches anything, so it never takes the lock.
if (-not $DryRun) {
    $lock = Lock-PvmVm -VmDir $selectedVm.FullPath
    if (-not $lock.Acquired) {
        Write-Host "  [!] VM '$($decision.VmName)' is already running (locked by $($lock.Owner))." -ForegroundColor Red
        Write-Host "      Two QEMU processes sharing one disk image will corrupt it." -ForegroundColor DarkGray
        exit 1
    }
}

# 6. Interactive Configuration Review (if not in non-interactive/dry-run mode)
if (-not $NoPrompt -and -not $DryRun) {
    $proceed = Invoke-InteractiveConfigMenu -Decision $decision -HostInfo $hostInfo
    if (-not $proceed) {
        Write-Host "  [i] Launch cancelled by user." -ForegroundColor Gray
        exit 0
    }
}

# 7. Build QEMU Command Line
$cmdSpec = Build-QemuCommand -Decision $decision

Write-Host "  [+] GENERATED QEMU COMMAND" -ForegroundColor Green
Write-Host "  ----------------------------------------------------------------" -ForegroundColor DarkGray
Write-Host "  $($cmdSpec.CommandLine)" -ForegroundColor DarkGray
Write-Host ""

if ($DryRun) {
    Write-Host "  [i] Dry-run completed (-DryRun flag specified). VM will not be launched." -ForegroundColor Cyan
    Write-Host ""
    exit 0
}

Write-Host "  [*] Launching Virtual Machine '$($decision.VmName)'..." -ForegroundColor Green
Write-Host ""

# 8. Execute QEMU process
try {
    # ArgumentString, not Arguments: Windows PowerShell 5.1 joins an
    # -ArgumentList array with plain spaces and adds no quoting, so any path
    # containing a space would arrive at QEMU split into two arguments.
    $process = Start-Process -FilePath $cmdSpec.Executable -ArgumentList $cmdSpec.ArgumentString -Wait -PassThru -NoNewWindow
    Write-Host "  [+] Virtual Machine session terminated with exit code $($process.ExitCode)." -ForegroundColor Cyan
    exit $process.ExitCode
} catch {
    Write-Host "  [X] Failed to launch QEMU: $_" -ForegroundColor Red
    exit 1
} finally {
    Unlock-PvmVm -VmDir $selectedVm.FullPath
}

