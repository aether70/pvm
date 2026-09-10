<#
.SYNOPSIS
    Native Graphical User Interface Launcher for Windows (Portable VM).
.DESCRIPTION
    Uses built-in System.Windows.Forms in PowerShell to provide a zero-dependency GUI.
#>

param(
    [string]$VmName = ""
)

# Root of the SSD
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (Test-Path (Join-Path $ScriptDir "vms")) {
    $RootDir = $ScriptDir
} elseif (Test-Path (Join-Path (Split-Path (Split-Path $ScriptDir -Parent) -Parent) "vms")) {
    $RootDir = Split-Path (Split-Path $ScriptDir -Parent) -Parent
} else {
    $RootDir = $ScriptDir
}

# Dot-source helper modules
. (Join-Path $ScriptDir "detect.ps1")
. (Join-Path $ScriptDir "decide.ps1")
. (Join-Path $ScriptDir "build_command.ps1")
. (Join-Path $ScriptDir "lock.ps1")

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Enable Visual Styles
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---- Splash Screen --------------------------------------------------------
$splashForm = New-Object System.Windows.Forms.Form
$splashForm.StartPosition = "CenterScreen"
$splashForm.Size = New-Object System.Drawing.Size(250, 250)
$splashForm.FormBorderStyle = "None"
$splashForm.BackColor = [System.Drawing.Color]::FromArgb(15, 23, 42)
$splashForm.ShowInTaskbar = $false
$splashForm.TopMost = $true

$splashLogo = New-Object System.Windows.Forms.PictureBox
$splashLogo.Size = New-Object System.Drawing.Size(120, 120)
$splashLogo.Location = New-Object System.Drawing.Point(65, 40)
$splashLogo.SizeMode = "Zoom"
$logoPath = Join-Path $RootDir "logo\portable_vm_logo.png"
if (Test-Path $logoPath) {
    try { $splashLogo.Image = [System.Drawing.Image]::FromFile($logoPath) } catch {}
}
$splashForm.Controls.Add($splashLogo)

$splashLabel = New-Object System.Windows.Forms.Label
$splashLabel.Text = "Loading PortableVM..."
$splashLabel.ForeColor = [System.Drawing.Color]::White
$splashLabel.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
$splashLabel.TextAlign = "MiddleCenter"
$splashLabel.AutoSize = $false
$splashLabel.Size = New-Object System.Drawing.Size(250, 30)
$splashLabel.Location = New-Object System.Drawing.Point(0, 170)
$splashForm.Controls.Add($splashLabel)

$splashForm.Show()
[System.Windows.Forms.Application]::DoEvents()
# -------------------------------------------------------------------------

# 1. Gather Host Details
$hostInfo = Get-HostInformation -RootDir $RootDir

# 2. Discover VMs
$vmsDir = Join-Path $RootDir "vms"
$vmList = @()
if (Test-Path $vmsDir) {
    $subDirs = Get-ChildItem -Path $vmsDir -Directory
    foreach ($dir in $subDirs) {
        $vmList += $dir.Name
    }
}

# Default initial VM selection
$initialVmName = $null
if ($vmList.Count -gt 0) {
    $initialVmName = if ($VmName -and ($vmList -contains $VmName)) { $VmName } else { $vmList[0] }
}

if ($initialVmName) {
    $initialVmDir = Join-Path $vmsDir $initialVmName
    $initialDecision = Invoke-DecisionEngine -HostInfo $hostInfo -RootDir $RootDir -VmDir $initialVmDir
} else {
    # Placeholder for the empty state. It carries every field the form reads,
    # so binding the controls does not depend on a VM existing yet.
    $initialDecision = [PSCustomObject]@{
        VmName = ""
        VmDir = ""
        Arch = $hostInfo.Architecture
        Machine = "q35"
        CpuModel = "max"
        DiskPath = ""
        DiskFormat = "qcow2"
        DiskCache = "writeback"
        IsoPath = ""
        AllocatedRamMB = 2048
        AllocatedCores = 2
        SafeMaxRamMB = [math]::Max(1024, $hostInfo.AvailableRamMB - 1536)
        MinRequiredRamMB = 1024
        MaxHostCores = $hostInfo.LogicalCores
        DisplayMode = "sdl"
        VgaDevice = ""
        UseGl = $false
        AudioDev = ""
        NetworkMode = "nat"
        SshPort = 2222
        UseUefi = $false
        UefiCode = $null
        UefiVars = $null
        Accelerator = if ($hostInfo.WhpxAvailable) { "whpx" } else { "tcg" }
        AccelWarning = $null
        QemuExe = $hostInfo.QemuPath
        Warnings = @()
        IsValid = $false
        Errors = @("No virtual machines found. Click '+ New VM' to create one.")
    }
}

# Acceleration status string
$accelStatus = "TCG Emulation (Slow)"
if ($hostInfo.WhpxAvailable) { $accelStatus = "WHPX Hardware Accelerated (Fast)" }

# Tracks the VM process, its progress bar and its poll timer while one is
# running; $null the rest of the time.
$script:runState = $null

# Construct Form
$form = New-Object System.Windows.Forms.Form
$form.Text = "Portable Virtual Computer Launcher"
$form.Size = New-Object System.Drawing.Size(620, 680)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)

$iconPath = Join-Path $PSScriptRoot "..\..\logo\portable_vm_logo.ico"
if (Test-Path $iconPath) {
    try { $form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($iconPath) } catch {}
}

# Colors & Fonts
$fontHeader = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
$fontSubHeader = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$fontRegular = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Regular)
$fontSmall = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Regular)

# Title Panel
$titlePanel = New-Object System.Windows.Forms.Panel
$titlePanel.Size = New-Object System.Drawing.Size(620, 60)
$titlePanel.Location = New-Object System.Drawing.Point(0, 0)
$titlePanel.BackColor = [System.Drawing.Color]::FromArgb(30, 41, 59)
$form.Controls.Add($titlePanel)

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = "Portable Virtual Computer Launcher"
$titleLabel.Font = $fontHeader
$titleLabel.ForeColor = [System.Drawing.Color]::White
$titleLabel.AutoSize = $true
$titleLabel.Location = New-Object System.Drawing.Point(20, 15)
$titlePanel.Controls.Add($titleLabel)

# 1. Host Hardware Info GroupBox
$gbHost = New-Object System.Windows.Forms.GroupBox
$gbHost.Text = "Host Hardware Metrics"
$gbHost.Font = $fontSubHeader
$gbHost.Location = New-Object System.Drawing.Point(20, 70)
$gbHost.Size = New-Object System.Drawing.Size(564, 110)
$form.Controls.Add($gbHost)

$hostInfoLines = @(
    "OS: $($hostInfo.OSName) ($($hostInfo.Architecture))"
    "CPU: $($hostInfo.CPUName) | Cores: $($hostInfo.PhysicalCores) Physical / $($hostInfo.LogicalCores) Logical"
    "RAM: $($hostInfo.TotalRamMB) MB Total | $($hostInfo.AvailableRamMB) MB Free"
    "Acceleration: $accelStatus | SSD Free Space: $($hostInfo.SsdFreeSpaceGB) GB"
)

$lblHostInfo = New-Object System.Windows.Forms.Label
$lblHostInfo.Font = $fontSmall
$lblHostInfo.Location = New-Object System.Drawing.Point(15, 25)
$lblHostInfo.Size = New-Object System.Drawing.Size(534, 75)
$lblHostInfo.Text = ($hostInfoLines -join "`r`n")
$gbHost.Controls.Add($lblHostInfo)

# 2. VM Selection & Configuration GroupBox
$gbVm = New-Object System.Windows.Forms.GroupBox
$gbVm.Text = "VM Configuration"
$gbVm.Font = $fontSubHeader
$gbVm.Location = New-Object System.Drawing.Point(20, 190)
$gbVm.Size = New-Object System.Drawing.Size(564, 380)
$form.Controls.Add($gbVm)

# Select VM Dropdown
$lblVmSelect = New-Object System.Windows.Forms.Label
$lblVmSelect.Text = "Select VM Instance:"
$lblVmSelect.Font = $fontRegular
$lblVmSelect.Location = New-Object System.Drawing.Point(20, 30)
$lblVmSelect.AutoSize = $true
$gbVm.Controls.Add($lblVmSelect)

$cmbVm = New-Object System.Windows.Forms.ComboBox
$cmbVm.Font = $fontRegular
$cmbVm.DropDownStyle = "DropDownList"
$cmbVm.Location = New-Object System.Drawing.Point(160, 26)
$cmbVm.Size = New-Object System.Drawing.Size(220, 25)
foreach ($v in $vmList) { $cmbVm.Items.Add($v) | Out-Null }
$cmbVm.SelectedItem = $initialVmName
$gbVm.Controls.Add($cmbVm)

$btnNewVm = New-Object System.Windows.Forms.Button
$btnNewVm.Text = "+ New VM"
$btnNewVm.Location = New-Object System.Drawing.Point(390, 25)
$btnNewVm.Size = New-Object System.Drawing.Size(75, 27)
$btnNewVm.BackColor = [System.Drawing.Color]::FromArgb(59, 130, 246)
$btnNewVm.ForeColor = [System.Drawing.Color]::White
$btnNewVm.FlatStyle = "Flat"
$gbVm.Controls.Add($btnNewVm)

$btnDeleteVm = New-Object System.Windows.Forms.Button
$btnDeleteVm.Text = "- Delete"
$btnDeleteVm.Location = New-Object System.Drawing.Point(475, 25)
$btnDeleteVm.Size = New-Object System.Drawing.Size(70, 27)
$btnDeleteVm.BackColor = [System.Drawing.Color]::Crimson
$btnDeleteVm.ForeColor = [System.Drawing.Color]::White
$btnDeleteVm.FlatStyle = "Flat"
$gbVm.Controls.Add($btnDeleteVm)

$btnNewVm.add_Click({
    $setupRes = & (Join-Path $ScriptDir "setup_wizard.ps1") -VmsDir $vmsDir -HostInfo $hostInfo
    if ($setupRes.ShouldCreate) {
        $cmbVm.Items.Add($setupRes.VmName) | Out-Null
        $cmbVm.SelectedItem = $setupRes.VmName
        
        $script:currentDecision | Add-Member -NotePropertyName IsoPath -NotePropertyValue $setupRes.IsoPath -Force
        $lblStatus.Text = "Target VM: $($script:currentDecision.VmName)`r`nDisk Image: $($script:currentDecision.DiskPath)`r`nStatus: Ready to Install! (ISO attached)"
    }
})

$btnDeleteVm.add_Click({
    $targetVm = $cmbVm.SelectedItem
    if (-not $targetVm) { return }
    
    $delRes = & (Join-Path $ScriptDir "delete_wizard.ps1") -VmName $targetVm -VmsDir $vmsDir
    if ($delRes.Deleted) {
        $cmbVm.Items.Remove($targetVm) | Out-Null
        if ($cmbVm.Items.Count -gt 0) {
            $cmbVm.SelectedIndex = 0
        } else {
            [System.Windows.Forms.MessageBox]::Show("All VMs deleted. Please create a new one.", "Portable VM Launcher", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
            $form.Close()
        }
    }
})

# RAM Allocation (TrackBar + Numeric)
$lblRam = New-Object System.Windows.Forms.Label
$lblRam.Text = "RAM Allocation (MB):"
$lblRam.Font = $fontRegular
$lblRam.Location = New-Object System.Drawing.Point(20, 75)
$lblRam.AutoSize = $true
$gbVm.Controls.Add($lblRam)

$numRam = New-Object System.Windows.Forms.NumericUpDown
$numRam.Font = $fontRegular
$numRam.Minimum = 512
$numRam.Maximum = [math]::Max($hostInfo.TotalRamMB, 32768)
$numRam.Increment = 512
$numRam.Value = $initialDecision.AllocatedRamMB
$numRam.Location = New-Object System.Drawing.Point(160, 72)
$numRam.Size = New-Object System.Drawing.Size(100, 25)
$gbVm.Controls.Add($numRam)

$trackRam = New-Object System.Windows.Forms.TrackBar
$trackRam.Minimum = 512
$trackRam.Maximum = [math]::Max($hostInfo.TotalRamMB, 16384)
$trackRam.TickFrequency = 1024
$trackRam.Value = [math]::Min($initialDecision.AllocatedRamMB, $trackRam.Maximum)
$trackRam.Location = New-Object System.Drawing.Point(270, 70)
$trackRam.Size = New-Object System.Drawing.Size(270, 45)
$gbVm.Controls.Add($trackRam)

# RAM Safety Warning Label
$lblRamWarn = New-Object System.Windows.Forms.Label
$lblRamWarn.Font = $fontSmall
$lblRamWarn.ForeColor = [System.Drawing.Color]::DarkOrange
$lblRamWarn.Location = New-Object System.Drawing.Point(160, 110)
$lblRamWarn.Size = New-Object System.Drawing.Size(380, 30)
$gbVm.Controls.Add($lblRamWarn)

# CPU Cores Allocation
$lblCores = New-Object System.Windows.Forms.Label
$lblCores.Text = "CPU Cores:"
$lblCores.Font = $fontRegular
$lblCores.Location = New-Object System.Drawing.Point(20, 150)
$lblCores.AutoSize = $true
$gbVm.Controls.Add($lblCores)

$numCores = New-Object System.Windows.Forms.NumericUpDown
$numCores.Font = $fontRegular
$numCores.Minimum = 1
$numCores.Maximum = $hostInfo.LogicalCores
$numCores.Value = $initialDecision.AllocatedCores
$numCores.Location = New-Object System.Drawing.Point(160, 147)
$numCores.Size = New-Object System.Drawing.Size(100, 25)
$gbVm.Controls.Add($numCores)

$trackCores = New-Object System.Windows.Forms.TrackBar
$trackCores.Minimum = 1
$trackCores.Maximum = $hostInfo.LogicalCores
$trackCores.Value = [math]::Min($initialDecision.AllocatedCores, $hostInfo.LogicalCores)
$trackCores.Location = New-Object System.Drawing.Point(270, 145)
$trackCores.Size = New-Object System.Drawing.Size(270, 45)
$gbVm.Controls.Add($trackCores)

# CPU Safety Warning Label
$lblCpuWarn = New-Object System.Windows.Forms.Label
$lblCpuWarn.Font = $fontSmall
$lblCpuWarn.ForeColor = [System.Drawing.Color]::DarkOrange
$lblCpuWarn.Location = New-Object System.Drawing.Point(160, 185)
$lblCpuWarn.Size = New-Object System.Drawing.Size(380, 30)
$gbVm.Controls.Add($lblCpuWarn)

# Display Mode
$lblDisplay = New-Object System.Windows.Forms.Label
$lblDisplay.Text = "Display Mode:"
$lblDisplay.Font = $fontRegular
$lblDisplay.Location = New-Object System.Drawing.Point(20, 225)
$lblDisplay.AutoSize = $true
$gbVm.Controls.Add($lblDisplay)

$cmbDisplay = New-Object System.Windows.Forms.ComboBox
$cmbDisplay.Font = $fontRegular
$cmbDisplay.DropDownStyle = "DropDownList"
$cmbDisplay.Location = New-Object System.Drawing.Point(160, 222)
$cmbDisplay.Size = New-Object System.Drawing.Size(120, 25)
# Only the backends this QEMU actually built in - offering one it lacks turns
# the Launch button into an immediate QEMU error. -vnc is always available as
# an option because it is a separate switch, not a -display backend.
$displayOptions = @()
foreach ($d in $hostInfo.QemuDisplays) {
    if ($d -in @("none", "dbus")) { continue }
    $displayOptions += $d
}
$displayOptions += "vnc"
if ($displayOptions.Count -eq 1) { $displayOptions = @("sdl", "gtk", "vnc") }
$cmbDisplay.Items.AddRange($displayOptions)
$cmbDisplay.SelectedItem = $initialDecision.DisplayMode
if (-not $cmbDisplay.SelectedItem) { $cmbDisplay.SelectedIndex = 0 }
$gbVm.Controls.Add($cmbDisplay)

# Accelerator
$lblAccel = New-Object System.Windows.Forms.Label
$lblAccel.Text = "Accelerator:"
$lblAccel.Font = $fontRegular
$lblAccel.Location = New-Object System.Drawing.Point(310, 225)
$lblAccel.AutoSize = $true
$gbVm.Controls.Add($lblAccel)

$cmbAccel = New-Object System.Windows.Forms.ComboBox
$cmbAccel.Font = $fontRegular
$cmbAccel.DropDownStyle = "DropDownList"
$cmbAccel.Location = New-Object System.Drawing.Point(400, 222)
$cmbAccel.Size = New-Object System.Drawing.Size(140, 25)
# Same rule for accelerators, with the extra condition that a hardware
# accelerator is only offered when detection actually managed to start QEMU
# with it - "compiled in" is not the same as "usable on this machine".
$accelOptions = @()
if ($hostInfo.WhpxAvailable) { $accelOptions += "whpx" }
foreach ($a in $hostInfo.QemuAccelerators) {
    if ($a -eq "whpx") { continue }
    $accelOptions += $a
}
if ($accelOptions.Count -eq 0) { $accelOptions = @("tcg") }
$cmbAccel.Items.AddRange($accelOptions)
$cmbAccel.SelectedItem = $initialDecision.Accelerator
if (-not $cmbAccel.SelectedItem) { $cmbAccel.SelectedIndex = 0 }
$gbVm.Controls.Add($cmbAccel)

# Status / Validation Message Box
$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Font = $fontSmall
$lblStatus.Location = New-Object System.Drawing.Point(20, 270)
$lblStatus.Size = New-Object System.Drawing.Size(520, 90)
$lblStatus.ForeColor = [System.Drawing.Color]::DarkBlue
$gbVm.Controls.Add($lblStatus)

# Function to Update Safety Diagnostics & Decision
$script:currentDecision = $initialDecision

function Update-Diagnostics {
    $ramVal = [int]$numRam.Value
    $cpuVal = [int]$numCores.Value

    # Test safety checks
    $ramWarns = Test-MemorySafety -RamMB $ramVal -HostInfo $hostInfo
    if ($ramWarns.Count -gt 0) {
        $lblRamWarn.Text = "[!] " + ($ramWarns -join " ")
        $lblRamWarn.ForeColor = [System.Drawing.Color]::Crimson
    } else {
        $lblRamWarn.Text = "[OK] RAM allocation is within safe limits."
        $lblRamWarn.ForeColor = [System.Drawing.Color]::ForestGreen
    }

    $cpuWarns = Test-CpuSafety -Cores $cpuVal -HostInfo $hostInfo
    if ($cpuWarns.Count -gt 0) {
        $lblCpuWarn.Text = "[!] " + ($cpuWarns -join " ")
        $lblCpuWarn.ForeColor = [System.Drawing.Color]::DarkOrange
    } else {
        $lblCpuWarn.Text = "[OK] CPU allocation is within safe limits."
        $lblCpuWarn.ForeColor = [System.Drawing.Color]::ForestGreen
    }

    # Sync Decision object
    $selectedVm = $cmbVm.SelectedItem
    $existingIso = $script:currentDecision.IsoPath

    if ($selectedVm) {
        $targetVmDir = Join-Path $vmsDir $selectedVm
        $script:currentDecision = Invoke-DecisionEngine -HostInfo $hostInfo -RootDir $RootDir `
                                                        -VmDir $targetVmDir -IsoPath $existingIso
        $script:currentDecision.AllocatedRamMB = $ramVal
        $script:currentDecision.AllocatedCores = $cpuVal
        if ($cmbDisplay.SelectedItem) { $script:currentDecision.DisplayMode = $cmbDisplay.SelectedItem }
        if ($cmbAccel.SelectedItem)   { $script:currentDecision.Accelerator = $cmbAccel.SelectedItem }

        # The accelerator is a user choice in this form, so the CPU model has
        # to follow it: -cpu host is only valid when a hypervisor is passing
        # the real CPU through, and TCG rejects it.
        if ($script:currentDecision.Accelerator -eq "tcg") {
            $script:currentDecision.CpuModel = "max"
        } elseif ($script:currentDecision.Accelerator -eq "whpx") {
            $script:currentDecision.CpuModel = "max,vmx=off"
        }

        $statusMsg = "Ready to Launch."
        if ($existingIso) { $statusMsg = "Ready to Install! (ISO attached)" }
        if (-not $script:currentDecision.IsValid) {
            $statusMsg = "Cannot Launch: $($script:currentDecision.Errors -join '; ')"
            $lblStatus.ForeColor = [System.Drawing.Color]::Crimson
        } else {
            $lblStatus.ForeColor = [System.Drawing.Color]::DarkBlue
        }

        $lblStatus.Text = "Target VM: $($script:currentDecision.VmName)`r`n" +
                          "Disk Image: $($script:currentDecision.DiskPath)`r`n" +
                          "Status: $statusMsg"
    } else {
        $lblStatus.Text = "No virtual machines found. Click '+ New VM' to create one."
        $lblStatus.ForeColor = [System.Drawing.Color]::Crimson
    }
}

# Event Listeners for TrackBars & Numeric Inputs
$numRam.add_ValueChanged({
    $val = [int]$numRam.Value
    if ($val -le $trackRam.Maximum -and $val -ge $trackRam.Minimum) {
        $trackRam.Value = $val
    }
    Update-Diagnostics
})

$trackRam.add_Scroll({
    $numRam.Value = $trackRam.Value
    Update-Diagnostics
})

$numCores.add_ValueChanged({
    $val = [int]$numCores.Value
    if ($val -le $trackCores.Maximum -and $val -ge $trackCores.Minimum) {
        $trackCores.Value = $val
    }
    Update-Diagnostics
})

$trackCores.add_Scroll({
    $numCores.Value = $trackCores.Value
    Update-Diagnostics
})

$cmbVm.add_SelectedIndexChanged({ Update-Diagnostics })
$cmbDisplay.add_SelectedIndexChanged({ Update-Diagnostics })
$cmbAccel.add_SelectedIndexChanged({ Update-Diagnostics })

# Initial Diagnostic Sync
Update-Diagnostics

# 3. Action Buttons
$btnShowCmd = New-Object System.Windows.Forms.Button
$btnShowCmd.Text = "View Command"
$btnShowCmd.Font = $fontRegular
$btnShowCmd.Location = New-Object System.Drawing.Point(20, 585)
$btnShowCmd.Size = New-Object System.Drawing.Size(140, 38)
$btnShowCmd.BackColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
$btnShowCmd.FlatStyle = "Flat"
$form.Controls.Add($btnShowCmd)

$btnShowCmd.add_Click({
    if (-not $cmbVm.SelectedItem -or -not $script:currentDecision.IsValid) {
        [System.Windows.Forms.MessageBox]::Show("Please select a valid VM first.", "Error", 0, 16)
        return
    }
    $cmdSpec = Build-QemuCommand -Decision $script:currentDecision
    [System.Windows.Forms.MessageBox]::Show(
        $cmdSpec.CommandLine,
        "Generated QEMU Command",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    )
})

$btnLaunch = New-Object System.Windows.Forms.Button
$btnLaunch.Text = "Launch VM"
$btnLaunch.Font = $fontSubHeader
$btnLaunch.Location = New-Object System.Drawing.Point(404, 585)
$btnLaunch.Size = New-Object System.Drawing.Size(180, 38)
$btnLaunch.BackColor = [System.Drawing.Color]::FromArgb(16, 185, 129)
$btnLaunch.ForeColor = [System.Drawing.Color]::White
$btnLaunch.FlatStyle = "Flat"
$form.Controls.Add($btnLaunch)

$btnLaunch.add_Click({
    if (-not $cmbVm.SelectedItem -or -not $script:currentDecision.IsValid) {
        [System.Windows.Forms.MessageBox]::Show("Please select a valid VM first.", "Error", 0, 16)
        return
    }

    $vmDir = $script:currentDecision.VmDir

    # Two QEMU processes writing one qcow2 image corrupt it, and the GUI is
    # the easiest way to start a second one: the window stays open while the
    # VM runs, so the Launch button is right there to press again.
    $lock = Lock-PvmVm -VmDir $vmDir
    if (-not $lock.Acquired) {
        [System.Windows.Forms.MessageBox]::Show(
            "This VM is already running (locked by $($lock.Owner))." + [Environment]::NewLine + [Environment]::NewLine +
            "Two QEMU processes sharing one disk image will corrupt it.",
            "Already Running",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        return
    }

    $cmdSpec = Build-QemuCommand -Decision $script:currentDecision

    $btnLaunch.Enabled = $false
    $btnDeleteVm.Enabled = $false
    $btnNewVm.Enabled = $false
    $btnShowCmd.Enabled = $false
    $cmbVm.Enabled = $false
    
    $btnLaunch.Text = "Running..."
    $lblStatus.Text = "Status: VM is currently running..."

    # Marquee animates itself on the UI thread's own timer. The previous
    # version hand-stepped a Continuous bar inside a
    # `while (-not HasExited) { DoEvents; Sleep 20 }` loop, which pinned a core
    # for the entire VM session and froze the window whenever a DoEvents
    # re-entered this same handler.
    $pbRun = New-Object System.Windows.Forms.ProgressBar
    $pbRun.Location = New-Object System.Drawing.Point(20, 560)
    $pbRun.Size = New-Object System.Drawing.Size(564, 15)
    $pbRun.Style = "Marquee"
    $pbRun.MarqueeAnimationSpeed = 30
    $form.Controls.Add($pbRun)

    try {
        # ArgumentString, not Arguments: Windows PowerShell 5.1 joins an
        # -ArgumentList array with plain spaces and adds no quoting of its own,
        # so any path containing a space would reach QEMU split in two.
        $process = Start-Process -FilePath $cmdSpec.Executable `
                                 -ArgumentList $cmdSpec.ArgumentString `
                                 -PassThru -NoNewWindow
    } catch {
        Unlock-PvmVm -VmDir $vmDir
        $form.Controls.Remove($pbRun)
        $pbRun.Dispose()
        $btnLaunch.Enabled = $true
        $btnLaunch.Text = "Launch VM"
        [System.Windows.Forms.MessageBox]::Show(
            "Failed to launch QEMU: $_",
            "Launch Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
        return
    }

    # A WinForms timer polls twice a second on the normal message loop, so the
    # window stays responsive (movable, closable, VM-switchable) for the whole
    # session instead of being blocked until QEMU exits.
    $watcher = New-Object System.Windows.Forms.Timer
    $watcher.Interval = 500
    $script:runState = [PSCustomObject]@{
        Process = $process
        Bar     = $pbRun
        Timer   = $watcher
        VmDir   = $vmDir
    }

    $watcher.add_Tick({
        $state = $script:runState
        if (-not $state -or -not $state.Process.HasExited) { return }

        $state.Timer.Stop()
        $state.Timer.Dispose()
        Unlock-PvmVm -VmDir $state.VmDir

        $form.Controls.Remove($state.Bar)
        $state.Bar.Dispose()
        $btnLaunch.Enabled = $true
        $btnLaunch.Text = "Launch VM"
        $lblStatus.Text = "Status: Idle"

        $exitCode = $state.Process.ExitCode
        $script:runState = $null
        Update-Diagnostics

        [System.Windows.Forms.MessageBox]::Show(
            "Virtual Machine session ended (exit code $exitCode).",
            "Portable VM Session Ended",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
    })
    $watcher.Start()
})

# Closing the window while a VM is running would otherwise strand the lock
# directory, and every later launch would refuse until it was deleted by hand.
$form.add_FormClosing({
    if ($script:runState) {
        $script:runState.Timer.Stop()
        if (-not $script:runState.Process.HasExited) {
            $answer = [System.Windows.Forms.MessageBox]::Show(
                "A virtual machine is still running. Close the launcher anyway?" + [Environment]::NewLine + [Environment]::NewLine +
                "The VM keeps running; its lock is released so you can reattach from a new launcher.",
                "VM Still Running",
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
                $_.Cancel = $true
                $script:runState.Timer.Start()
                return
            }
        }
        Unlock-PvmVm -VmDir $script:runState.VmDir
    }
})

# Show Form
if ($splashForm) {
    $splashForm.Close()
    $splashForm.Dispose()
}
[void]$form.ShowDialog()
