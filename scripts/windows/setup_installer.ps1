<#
.SYNOPSIS
    First-Time Setup Wizard for Portable Virtual Computer.
.DESCRIPTION
    A multi-step WinForms wizard that bootstraps the portable VM system onto an
    external drive. Handles drive selection, file extraction, QEMU installation,
    system verification, and recovery from errors.
    
    Supports: Windows 10 (all versions) + Windows 11, AMD64 + ARM64.
#>

param(
    # When running from the built .exe, source files are in the temp extraction folder
    [string]$SourceRoot = (Split-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) -Parent),
    [string]$InstallerDir = ""
)
$SourceRoot = $SourceRoot.Trim('"', "'").TrimEnd('\')
if ($InstallerDir) { $InstallerDir = $InstallerDir.Trim('"', "'").TrimEnd('\') }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ─────────────────────────────────────────────
# GLOBAL CONSTANTS
# ─────────────────────────────────────────────
$MIN_FREE_SPACE_GB       = 10
$QEMU_DIR_RELATIVE       = "backends\windows\qemu"
$QEMU_DOWNLOAD_AMD64     = "https://qemu.weilnetz.de/w64/"
$QEMU_DOWNLOAD_ARM64     = "https://qemu.weilnetz.de/w64/"  # ARM section on same page
$REQUIRED_FILES = @(
    "scripts", "config.json", "launch.bat", "launch.sh",
    "launch_gui.bat", "launch_gui.sh", "README.md"
)

# ─────────────────────────────────────────────
# ARCHITECTURE DETECTION
# ─────────────────────────────────────────────
$rawArch = $env:PROCESSOR_ARCHITECTURE
$hostArch = switch ($rawArch) {
    "AMD64"  { "x86_64" }
    "ARM64"  { "aarch64" }
    default  { "x86_64" }  # safe fallback
}
$qemuBinaryName = "qemu-system-$hostArch.exe"
$qemuDownloadUrl = if ($rawArch -eq "ARM64") { $QEMU_DOWNLOAD_ARM64 } else { $QEMU_DOWNLOAD_AMD64 }
$archFriendly = if ($rawArch -eq "ARM64") { "ARM64 (64-bit ARM)" } else { "AMD64 (Intel/AMD 64-bit)" }

# ─────────────────────────────────────────────
# OS VERSION CHECK
# ─────────────────────────────────────────────
function Get-OsInfo {
    try {
        $os = Get-WmiObject Win32_OperatingSystem -ErrorAction SilentlyContinue
        if (-not $os) { $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue }
        if ($os) { return $os }
    } catch {}
    return $null
}

$osInfo = Get-OsInfo
$osCaption = if ($osInfo) { $osInfo.Caption } else { "Unknown Windows" }
$osBuild = if ($osInfo) { [int]$osInfo.BuildNumber } else { 0 }

# Windows 10 = build 10240+, Win11 = 22000+
$isSupported = $osBuild -ge 10240
# WHPX introduced in Win10 1803 = build 17134
$whpxSupported = $osBuild -ge 17134

if (-not $isSupported) {
    [System.Windows.Forms.MessageBox]::Show(
        "This installer requires Windows 10 or later.`nDetected: $osCaption (Build $osBuild)",
        "Unsupported Windows Version",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    )
    exit 1
}

# Only allow 64-bit Windows
if ($rawArch -eq "x86") {
    [System.Windows.Forms.MessageBox]::Show(
        "Portable VM requires a 64-bit version of Windows.`nDetected architecture: 32-bit (x86).`nPlease use a 64-bit PC.",
        "Unsupported Architecture",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    )
    exit 1
}

# ─────────────────────────────────────────────
# STATE OBJECT
# ─────────────────────────────────────────────
$state = [PSCustomObject]@{
    SelectedDriveLetter = ""
    InstallPath         = ""
    ExtractedFiles      = [System.Collections.Generic.List[string]]::new()
    ExtractedDirs       = [System.Collections.Generic.List[string]]::new()
    QemuInstalled       = $false
    CurrentStep         = 0
}

# ─────────────────────────────────────────────
# RECOVERY HELPERS
# ─────────────────────────────────────────────
function Invoke-Revert {
    param([string]$TargetPath)
    try {
        # Delete files in reverse order
        for ($i = $state.ExtractedFiles.Count - 1; $i -ge 0; $i--) {
            $f = $state.ExtractedFiles[$i]
            if (Test-Path $f) { Remove-Item -Path $f -Force -ErrorAction SilentlyContinue }
        }
        # Remove created directories (deepest first)
        $sortedDirs = $state.ExtractedDirs | Sort-Object { $_.Length } -Descending
        foreach ($d in $sortedDirs) {
            if ((Test-Path $d) -and (Get-ChildItem $d -Force).Count -eq 0) {
                Remove-Item -Path $d -Force -ErrorAction SilentlyContinue
            }
        }
        # Also attempt to remove the root TargetPath if it is now completely empty
        if ((Test-Path $TargetPath) -and (Get-ChildItem $TargetPath -Force).Count -eq 0) {
            Remove-Item -Path $TargetPath -Force -ErrorAction SilentlyContinue
        }
    } catch { }
}

function Test-DrivePresent {
    param([string]$Letter)
    if (-not $Letter) { return $false }
    $drives = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue
    return ($null -ne ($drives | Where-Object { $_.Name -eq $Letter }))
}

# ─────────────────────────────────────────────
# DRIVE DISCOVERY
# ─────────────────────────────────────────────
function Get-DriveList {
    $driveItems = @()
    try {
        # Use WMI for Win10 compatibility
        $disks = Get-WmiObject Win32_LogicalDisk -ErrorAction SilentlyContinue |
            Where-Object { $_.DriveType -in @(2, 3) } # 2=Removable, 3=Fixed
        foreach ($d in $disks) {
            $freeGB = [math]::Round($d.FreeSpace / 1GB, 1)
            $totalGB = [math]::Round($d.Size / 1GB, 1)
            $driveType = if ($d.DriveType -eq 2) { "Removable" } else { "Fixed" }
            $label = if ($d.VolumeName) { $d.VolumeName } else { "(No Label)" }
            $letter = $d.DeviceID -replace ":", ""

            $driveItems += [PSCustomObject]@{
                Letter   = $letter
                Label    = $label
                Type     = $driveType
                FreeGB   = $freeGB
                TotalGB  = $totalGB
                Display  = "$($d.DeviceID)  $label  [$driveType]  Free: ${freeGB}GB / ${totalGB}GB"
                HasSpace = $freeGB -ge $MIN_FREE_SPACE_GB
            }
        }
    } catch { }
    return $driveItems
}

# ─────────────────────────────────────────────
# MAIN FORM
# ─────────────────────────────────────────────
$form = New-Object System.Windows.Forms.Form
$form.Text         = "Portable VM Setup"
$form.Size         = New-Object System.Drawing.Size(660, 580)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox  = $false
$form.BackColor    = [System.Drawing.Color]::FromArgb(245, 247, 250)

$iconPath = Join-Path $SourceRoot "logo\portable_vm_logo.ico"
if (Test-Path $iconPath) {
    try { $form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($iconPath) } catch {}
}

# Fonts
$fntTitle   = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Bold)
$fntHeader  = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$fntBody    = New-Object System.Drawing.Font("Segoe UI", 9)
$fntMono    = New-Object System.Drawing.Font("Consolas", 8.5)
$colDark    = [System.Drawing.Color]::FromArgb(30, 41, 59)
$colAccent  = [System.Drawing.Color]::FromArgb(59, 130, 246)
$colGreen   = [System.Drawing.Color]::FromArgb(16, 185, 129)
$colRed     = [System.Drawing.Color]::Crimson
$colOrange  = [System.Drawing.Color]::DarkOrange

# ─── TOP TITLE PANEL ───
$titlePanel = New-Object System.Windows.Forms.Panel
$titlePanel.Size = New-Object System.Drawing.Size(660, 65)
$titlePanel.Location = New-Object System.Drawing.Point(0, 0)
$titlePanel.BackColor = $colDark
$form.Controls.Add($titlePanel)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = "Portable VM Setup"
$lblTitle.Font = $fntTitle
$lblTitle.ForeColor = [System.Drawing.Color]::White
$lblTitle.AutoSize = $true
$lblTitle.Location = New-Object System.Drawing.Point(20, 12)
$titlePanel.Controls.Add($lblTitle)

$lblSubTitle = New-Object System.Windows.Forms.Label
$lblSubTitle.Text = "Step 1 of 7"
$lblSubTitle.Font = $fntBody
$lblSubTitle.ForeColor = [System.Drawing.Color]::FromArgb(148, 163, 184)
$lblSubTitle.AutoSize = $true
$lblSubTitle.Location = New-Object System.Drawing.Point(22, 40)
$titlePanel.Controls.Add($lblSubTitle)

# ─── STEP INDICATOR BAR ───
$stepBar = New-Object System.Windows.Forms.Panel
$stepBar.Size = New-Object System.Drawing.Size(660, 8)
$stepBar.Location = New-Object System.Drawing.Point(0, 65)
$stepBar.BackColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
$form.Controls.Add($stepBar)

$stepProgress = New-Object System.Windows.Forms.Panel
$stepProgress.Size = New-Object System.Drawing.Size(94, 8)  # 660/7 ≈ 94 per step
$stepProgress.Location = New-Object System.Drawing.Point(0, 0)
$stepProgress.BackColor = $colAccent
$stepBar.Controls.Add($stepProgress)

# ─── CONTENT PANEL (swapped per step) ───
$contentPanel = New-Object System.Windows.Forms.Panel
$contentPanel.Location = New-Object System.Drawing.Point(0, 73)
$contentPanel.Size = New-Object System.Drawing.Size(660, 430)
$contentPanel.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)
$form.Controls.Add($contentPanel)

# ─── BOTTOM BUTTON BAR ───
$bottomPanel = New-Object System.Windows.Forms.Panel
$bottomPanel.Size = New-Object System.Drawing.Size(660, 55)
$bottomPanel.Location = New-Object System.Drawing.Point(0, 503)
$bottomPanel.BackColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
$form.Controls.Add($bottomPanel)

$btnBack = New-Object System.Windows.Forms.Button
$btnBack.Text = "< Back"
$btnBack.Font = $fntBody
$btnBack.Location = New-Object System.Drawing.Point(20, 12)
$btnBack.Size = New-Object System.Drawing.Size(90, 32)
$btnBack.FlatStyle = "Flat"
$btnBack.Enabled = $false
$bottomPanel.Controls.Add($btnBack)

$btnNext = New-Object System.Windows.Forms.Button
$btnNext.Text = "Next >"
$btnNext.Font = $fntHeader
$btnNext.Location = New-Object System.Drawing.Point(535, 12)
$btnNext.Size = New-Object System.Drawing.Size(105, 32)
$btnNext.FlatStyle = "Flat"
$btnNext.BackColor = $colAccent
$btnNext.ForeColor = [System.Drawing.Color]::White
$bottomPanel.Controls.Add($btnNext)

$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text = "Cancel"
$btnCancel.Font = $fntBody
$btnCancel.Location = New-Object System.Drawing.Point(120, 12)
$btnCancel.Size = New-Object System.Drawing.Size(90, 32)
$btnCancel.FlatStyle = "Flat"
$bottomPanel.Controls.Add($btnCancel)

$btnCancel.add_Click({
    $r = [System.Windows.Forms.MessageBox]::Show(
        "Cancel setup? Any files already copied will be removed.",
        "Cancel Setup", [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($r -eq "Yes") {
        Invoke-Revert -TargetPath $state.InstallPath
        $form.Close()
    }
})

# ─────────────────────────────────────────────
# HELPER: CLEAR CONTENT PANEL
# ─────────────────────────────────────────────
function Clear-ContentPanel {
    $contentPanel.Controls.Clear()
}

function Add-SectionHeader {
    param([string]$Text, [int]$Y = 15)
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Text
    $lbl.Font = $fntHeader
    $lbl.ForeColor = $colDark
    $lbl.Location = New-Object System.Drawing.Point(25, $Y)
    $lbl.AutoSize = $true
    $contentPanel.Controls.Add($lbl)
    return $lbl
}

function Add-BodyLabel {
    param([string]$Text, [int]$X, [int]$Y, [int]$W = 600, [int]$H = 20)
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Text
    $lbl.Font = $fntBody
    $lbl.Location = New-Object System.Drawing.Point($X, $Y)
    $lbl.Size = New-Object System.Drawing.Size($W, $H)
    $contentPanel.Controls.Add($lbl)
    return $lbl
}

function Set-StepIndicator {
    param([int]$Step, [int]$Total = 7)
    $lblSubTitle.Text = "Step $Step of $Total"
    $stepProgress.Width = [math]::Round(660 * $Step / $Total)
}

# ─────────────────────────────────────────────
# STEP 1: WELCOME & ARCHITECTURE DETECTION
# ─────────────────────────────────────────────
$script:driveList = @()
$script:selectedListViewItem = $null

function Show-Step1 {
    Clear-ContentPanel
    Set-StepIndicator -Step 1
    $btnBack.Enabled = $false
    $btnNext.Enabled = $true
    $btnNext.Text = "Next >"

    Add-SectionHeader -Text "Welcome to Portable VM Setup" -Y 15

    $lblWelcome = Add-BodyLabel -Text @"
This wizard will install the Portable VM system onto an external drive of your choice.
You will need: an external drive with at least 10 GB free, and a network connection.
"@ -X 25 -Y 45 -W 610 -H 40

    # Architecture info panel
    $archPanel = New-Object System.Windows.Forms.Panel
    $archPanel.Location = New-Object System.Drawing.Point(25, 100)
    $archPanel.Size = New-Object System.Drawing.Size(610, 130)
    $archPanel.BackColor = [System.Drawing.Color]::FromArgb(239, 246, 255)
    $archPanel.BorderStyle = "FixedSingle"
    $contentPanel.Controls.Add($archPanel)

    $lblArchTitle = New-Object System.Windows.Forms.Label
    $lblArchTitle.Text = "Detected System Information"
    $lblArchTitle.Font = $fntHeader
    $lblArchTitle.ForeColor = $colDark
    $lblArchTitle.Location = New-Object System.Drawing.Point(12, 10)
    $lblArchTitle.AutoSize = $true
    $archPanel.Controls.Add($lblArchTitle)

    $archLines = @(
        "Operating System  : $osCaption (Build $osBuild)"
        "Host Architecture : $archFriendly"
        "QEMU Binary       : $qemuBinaryName"
        "Hardware Accel    : $(if ($whpxSupported) { 'WHPX available (fast)' } else { 'TCG only (slower - Win10 < 1803 detected)' })"
        "Source of truth   : Processor Architecture = $rawArch"
    )

    $y = 35
    foreach ($line in $archLines) {
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $line
        $l.Font = $fntMono
        $l.Location = New-Object System.Drawing.Point(12, $y)
        $l.Size = New-Object System.Drawing.Size(585, 18)
        $archPanel.Controls.Add($l)
        $y += 18
    }

    if (-not $whpxSupported) {
        $lblWarn = Add-BodyLabel -Text "[!] Your Windows version does not support WHPX acceleration. VMs will run in software emulation mode (TCG). This is slower but fully functional. Consider updating Windows for better performance." -X 25 -Y 245 -W 610 -H 50
        $lblWarn.ForeColor = $colOrange
    }
}

# ─────────────────────────────────────────────
# STEP 2: DRIVE SELECTION
# ─────────────────────────────────────────────
$script:driveListView = $null

function Show-Step2 {
    Clear-ContentPanel
    Set-StepIndicator -Step 2
    $btnBack.Enabled = $true
    $btnNext.Enabled = $false

    Add-SectionHeader -Text "Select External Drive" -Y 15

    Add-BodyLabel -Text "Choose the drive where Portable VM will be installed. Removable drives are highlighted." -X 25 -Y 40 -W 610 -H 20

    # Drive list
    $lvDrives = New-Object System.Windows.Forms.ListView
    $lvDrives.Location = New-Object System.Drawing.Point(25, 68)
    $lvDrives.Size = New-Object System.Drawing.Size(505, 200)
    $lvDrives.View = "Details"
    $lvDrives.FullRowSelect = $true
    $lvDrives.GridLines = $true
    $lvDrives.Font = $fntBody
    $lvDrives.Columns.Add("Drive", 60) | Out-Null
    $lvDrives.Columns.Add("Label", 120) | Out-Null
    $lvDrives.Columns.Add("Type", 90) | Out-Null
    $lvDrives.Columns.Add("Free (GB)", 80) | Out-Null
    $lvDrives.Columns.Add("Total (GB)", 80) | Out-Null
    $lvDrives.Columns.Add("Status", 80) | Out-Null
    $contentPanel.Controls.Add($lvDrives)
    $script:driveListView = $lvDrives

    $btnRefresh = New-Object System.Windows.Forms.Button
    $btnRefresh.Text = "Refresh"
    $btnRefresh.Location = New-Object System.Drawing.Point(540, 68)
    $btnRefresh.Size = New-Object System.Drawing.Size(90, 30)
    $btnRefresh.FlatStyle = "Flat"
    $btnRefresh.BackColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
    $contentPanel.Controls.Add($btnRefresh)

    $lblDriveStatus = Add-BodyLabel -Text "" -X 25 -Y 278 -W 610 -H 20
    $lblDriveStatus.ForeColor = $colRed

    $refreshBlock = {
        $lvDrives.Items.Clear()
        $script:driveList = Get-DriveList
        foreach ($d in $script:driveList) {
            $item = New-Object System.Windows.Forms.ListViewItem($d.Letter + ":")
            $item.SubItems.Add($d.Label) | Out-Null
            $item.SubItems.Add($d.Type) | Out-Null
            $item.SubItems.Add($d.FreeGB.ToString()) | Out-Null
            $item.SubItems.Add($d.TotalGB.ToString()) | Out-Null
            $item.SubItems.Add($(if ($d.HasSpace) { "[OK]" } else { "Need ${MIN_FREE_SPACE_GB}GB+" })) | Out-Null
            if ($d.Type -eq "Removable") { $item.ForeColor = $colAccent }
            if (-not $d.HasSpace) { $item.ForeColor = $colRed }
            $item.Tag = $d
            $lvDrives.Items.Add($item) | Out-Null
        }
        $lblDriveStatus.Text = "Plug in your external drive and click Refresh."
        $btnNext.Enabled = $false
    }.GetNewClosure()

    $btnRefresh.add_Click($refreshBlock)

    $lvDrives.add_SelectedIndexChanged({
        if ($lvDrives.SelectedItems.Count -gt 0) {
            $sel = $lvDrives.SelectedItems[0].Tag
            if ($sel.HasSpace) {
                $state.SelectedDriveLetter = $sel.Letter
                $btnNext.Enabled = $true
                $statusText = "[OK] Selected: " + $sel.Letter + ": " + $sel.Label + " - " + $sel.FreeGB + " GB free"
                $lblDriveStatus.Text = $statusText
                $lblDriveStatus.ForeColor = $colGreen
            } else {
                $btnNext.Enabled = $false
                $lblDriveStatus.Text = "[!] Not enough space. Need at least ${MIN_FREE_SPACE_GB} GB free."
                $lblDriveStatus.ForeColor = $colRed
            }
        }
    }.GetNewClosure())

    & $refreshBlock
}

# ─────────────────────────────────────────────
# STEP 3: FOLDER SELECTION
# ─────────────────────────────────────────────
function Show-Step3 {
    Clear-ContentPanel
    Set-StepIndicator -Step 3
    $btnBack.Enabled = $true
    $btnNext.Enabled = $false

    Add-SectionHeader -Text "Choose Install Folder" -Y 15
    Add-BodyLabel -Text "Select or create the folder on $($state.SelectedDriveLetter): where Portable VM will be installed." -X 25 -Y 40 -W 610 -H 20

    $txtFolder = New-Object System.Windows.Forms.TextBox
    $txtFolder.Location = New-Object System.Drawing.Point(25, 70)
    $txtFolder.Size = New-Object System.Drawing.Size(460, 24)
    $txtFolder.Font = $fntBody
    $txtFolder.Text = "$($state.SelectedDriveLetter):\PortableVM"
    $contentPanel.Controls.Add($txtFolder)

    $btnBrowse = New-Object System.Windows.Forms.Button
    $btnBrowse.Text = "Browse..."
    $btnBrowse.Location = New-Object System.Drawing.Point(495, 69)
    $btnBrowse.Size = New-Object System.Drawing.Size(80, 26)
    $btnBrowse.FlatStyle = "Flat"
    $contentPanel.Controls.Add($btnBrowse)

    $btnCreateFolder = New-Object System.Windows.Forms.Button
    $btnCreateFolder.Text = "Create Folder"
    $btnCreateFolder.Location = New-Object System.Drawing.Point(25, 105)
    $btnCreateFolder.Size = New-Object System.Drawing.Size(110, 28)
    $btnCreateFolder.FlatStyle = "Flat"
    $btnCreateFolder.BackColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
    $contentPanel.Controls.Add($btnCreateFolder)

    $lblFolderStatus = Add-BodyLabel -Text "" -X 25 -Y 145 -W 610 -H 40
    $lblSpaceInfo = Add-BodyLabel -Text "" -X 25 -Y 190 -W 610 -H 20
    $lblSpaceInfo.Font = $fntMono

    $validateBlock = {
        $path = $txtFolder.Text.Trim()
        if (-not $path) {
            $lblFolderStatus.Text = "Please enter or browse to a folder path."
            $lblFolderStatus.ForeColor = $colRed
            $btnNext.Enabled = $false
            return
        }
        $driveLetter = (Split-Path -Qualifier $path) -replace ":", ""
        if ($driveLetter -ne $state.SelectedDriveLetter) {
            $lblFolderStatus.Text = "[!] Folder must be on drive $($state.SelectedDriveLetter):."
            $lblFolderStatus.ForeColor = $colRed
            $btnNext.Enabled = $false
            return
        }
        try {
            $drive = Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='$($state.SelectedDriveLetter):'" -ErrorAction SilentlyContinue
            if ($drive) {
                $freeGB = [math]::Round($drive.FreeSpace / 1GB, 1)
                $lblSpaceInfo.Text = "Free space on $($state.SelectedDriveLetter): = $freeGB GB"
                $lblSpaceInfo.ForeColor = if ($freeGB -ge $MIN_FREE_SPACE_GB) { $colGreen } else { $colRed }
            }
        } catch {}
        
        $state.InstallPath = $path
        
        if (Test-Path (Join-Path $path "config.json")) {
            $state | Add-Member -NotePropertyName IsUpgrade -NotePropertyValue $true -Force
            $lblFolderStatus.Text = "[OK] Existing installation detected. Proceeding with Upgrade."
            $lblFolderStatus.ForeColor = $colOrange
        } else {
            $state | Add-Member -NotePropertyName IsUpgrade -NotePropertyValue $false -Force
            $lblFolderStatus.Text = "[OK] Install path: $path"
            $lblFolderStatus.ForeColor = $colGreen
        }
        
        $btnNext.Enabled = $true
    }.GetNewClosure()

    $btnBrowse.add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.SelectedPath = "$($state.SelectedDriveLetter):\"
        $dlg.Description = "Select install folder for Portable VM"
        if ($dlg.ShowDialog() -eq "OK") {
            $txtFolder.Text = $dlg.SelectedPath
            & $validateBlock
        }
    }.GetNewClosure())

    $btnCreateFolder.add_Click({
        $path = $txtFolder.Text.Trim()
        try {
            New-Item -Path $path -ItemType Directory -Force | Out-Null
            $lblFolderStatus.Text = "[OK] Folder created: $path"
            $lblFolderStatus.ForeColor = $colGreen
            & $validateBlock
        } catch {
            $lblFolderStatus.Text = "[!] Could not create folder: $_"
            $lblFolderStatus.ForeColor = $colRed
        }
    }.GetNewClosure())

    $txtFolder.add_TextChanged($validateBlock)
    & $validateBlock
}

# ─────────────────────────────────────────────
# STEP 4: FILE EXTRACTION
# ─────────────────────────────────────────────
function Show-Step4 {
    Clear-ContentPanel
    Set-StepIndicator -Step 4
    $btnBack.Enabled = $false
    $btnNext.Enabled = $false

    Add-SectionHeader -Text "Extracting Files" -Y 15
    Add-BodyLabel -Text "Copying Portable VM files to: $($state.InstallPath)" -X 25 -Y 40 -W 610 -H 20

    $progressBar = New-Object System.Windows.Forms.ProgressBar
    $progressBar.Location = New-Object System.Drawing.Point(25, 70)
    $progressBar.Size = New-Object System.Drawing.Size(610, 22)
    $progressBar.Style = "Blocks"
    $contentPanel.Controls.Add($progressBar)

    $lstLog = New-Object System.Windows.Forms.ListBox
    $lstLog.Location = New-Object System.Drawing.Point(25, 100)
    $lstLog.Size = New-Object System.Drawing.Size(610, 230)
    $lstLog.Font = $fntMono
    $lstLog.BackColor = [System.Drawing.Color]::Black
    $lstLog.ForeColor = [System.Drawing.Color]::LimeGreen
    $contentPanel.Controls.Add($lstLog)

    $lblExtractStatus = Add-BodyLabel -Text "Starting..." -X 25 -Y 340 -W 610 -H 20

    function Log-Line {
        param([string]$Msg, [System.Drawing.Color]$Color = [System.Drawing.Color]::LimeGreen)
        $lstLog.Items.Add($Msg) | Out-Null
        $lstLog.TopIndex = $lstLog.Items.Count - 1
        [System.Windows.Forms.Application]::DoEvents()
    }

    function Copy-Tree {
        param([string]$Src, [string]$Dst)
        if (-not (Test-Path $Dst)) {
            New-Item -Path $Dst -ItemType Directory -Force | Out-Null
            $state.ExtractedDirs.Add($Dst)
        }
        $items = Get-ChildItem -Path $Src -Force
        foreach ($item in $items) {
            if ($item.Name -eq ".git" -or $item.Name -eq "_install_manifest.json") { continue }
            $destPath = Join-Path $Dst $item.Name
            if ($item.PSIsContainer) {
                $state.ExtractedDirs.Add($destPath)
                Copy-Tree -Src $item.FullName -Dst $destPath
            } else {
                Copy-Item -Path $item.FullName -Destination $destPath -Force
                $state.ExtractedFiles.Add($destPath)
                return $destPath
            }
        }
    }

    # Collect all source files to copy
    $allFiles = @()
    foreach ($entry in $REQUIRED_FILES) {
        $srcPath = Join-Path $SourceRoot $entry
        if (Test-Path $srcPath) {
            if ((Get-Item $srcPath).PSIsContainer) {
                Get-ChildItem -Path $srcPath -Recurse -File | ForEach-Object {
                    $allFiles += [PSCustomObject]@{
                        Source = $_.FullName
                        Relative = $_.FullName.Substring($SourceRoot.Length).TrimStart("\")
                    }
                }
            } else {
                $allFiles += [PSCustomObject]@{
                    Source = $srcPath
                    Relative = $srcPath.Substring($SourceRoot.Length).TrimStart("\")
                }
            }
        }
    }

    if ($InstallerDir) {
        $vmsSrc = Join-Path $InstallerDir "vms"
        if (Test-Path $vmsSrc) {
            Get-ChildItem -Path $vmsSrc -Recurse -File | ForEach-Object {
                $allFiles += [PSCustomObject]@{
                    Source = $_.FullName
                    Relative = "vms\" + $_.FullName.Substring($vmsSrc.Length).TrimStart("\")
                }
            }
        }
    }

    # Also create empty dirs
    $emptyDirs = @("vms", "backends\windows\qemu")

    $total = $allFiles.Count + $emptyDirs.Count
    if ($total -eq 0) { $total = 1 }
    $progressBar.Maximum = $total
    $current = 0
    $hasError = $false

    try {
        # Create empty structure first
        foreach ($rel in $emptyDirs) {
            $dst = Join-Path $state.InstallPath $rel
            if (-not (Test-Path $dst)) {
                New-Item -Path $dst -ItemType Directory -Force | Out-Null
                $state.ExtractedDirs.Add($dst)
            }
            Log-Line "[DIR] $rel"
            $current++
            $progressBar.Value = $current
        }

        # Copy files
        foreach ($fileObj in $allFiles) {
            # Check drive still present
            if (-not (Test-DrivePresent -Letter $state.SelectedDriveLetter)) {
                throw "Drive $($state.SelectedDriveLetter): was disconnected during extraction."
            }

            $dstFile = Join-Path $state.InstallPath $fileObj.Relative
            $dstDir = Split-Path $dstFile -Parent
            if (-not (Test-Path $dstDir)) {
                New-Item -Path $dstDir -ItemType Directory -Force | Out-Null
                $state.ExtractedDirs.Add($dstDir)
            }
            
            # Upgrade logic: Do not overwrite config.json if it exists
            if ($state.IsUpgrade -and $fileObj.Relative -eq "config.json" -and (Test-Path $dstFile)) {
                Log-Line "  [~] Skipped config.json (preserved user config)"
            } else {
                Copy-Item -Path $fileObj.Source -Destination $dstFile -Force -ErrorAction Stop
                $state.ExtractedFiles.Add($dstFile)
                Log-Line "  [+] $($fileObj.Relative)"
            }
            $current++
            $progressBar.Value = $current
        }

        # Write install manifest for recovery
        $manifest = @{ Files = $state.ExtractedFiles; Dirs = $state.ExtractedDirs }
        $manifest | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $state.InstallPath "_install_manifest.json")

        $lblExtractStatus.Text = "[OK] All files extracted successfully."
        $lblExtractStatus.ForeColor = $colGreen
        Log-Line "[DONE] Extraction complete."
        $btnNext.Enabled = $true

    } catch {
        $hasError = $true
        $errMsg = $_.ToString()
        Log-Line "[ERROR] $_" 
        $lblExtractStatus.Text = "[!] Error: $errMsg"
        $lblExtractStatus.ForeColor = $colRed

        $choice = [System.Windows.Forms.MessageBox]::Show(
            "An error occurred during file extraction:`n`n$errMsg`n`nChoose:`n[Retry] - Try the failed operation again.`n[No] - Revert all changes and cancel.",
            "Extraction Error",
            [System.Windows.Forms.MessageBoxButtons]::RetryCancel,
            [System.Windows.Forms.MessageBoxIcon]::Error)

        if ($choice -eq "Retry") {
            Show-Step4
        } else {
            Log-Line "[*] Reverting changes..."
            Invoke-Revert -TargetPath $state.InstallPath
            Log-Line "[OK] Changes reverted. Drive is clean."
            $lblExtractStatus.Text = "Reverted. No changes remain on drive."
            $btnBack.Enabled = $true
        }
    }
}

# ─────────────────────────────────────────────
# STEP 5: QEMU INSTALLATION
# ─────────────────────────────────────────────
function Show-Step5 {
    Clear-ContentPanel
    Set-StepIndicator -Step 5
    $btnBack.Enabled = $false
    $btnNext.Enabled = $false

    Add-SectionHeader -Text "Install QEMU Hypervisor" -Y 15

    # Architecture explanation panel
    $infoPanel = New-Object System.Windows.Forms.Panel
    $infoPanel.Location = New-Object System.Drawing.Point(25, 40)
    $infoPanel.Size = New-Object System.Drawing.Size(610, 85)
    $infoPanel.BackColor = [System.Drawing.Color]::FromArgb(239, 246, 255)
    $infoPanel.BorderStyle = "FixedSingle"
    $contentPanel.Controls.Add($infoPanel)

    $archInfoLines = @(
        "Your architecture : $archFriendly"
        "Binary to install : $qemuBinaryName"
        "Reason            : QEMU must match your host CPU to enable hardware-accelerated"
        "                    virtualization. Mismatched binaries will silently fail."
        "Download source   : $qemuDownloadUrl"
    )
    $y = 8
    foreach ($line in $archInfoLines) {
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $line
        $l.Font = $fntMono
        $l.Location = New-Object System.Drawing.Point(10, $y)
        $l.Size = New-Object System.Drawing.Size(590, 16)
        $infoPanel.Controls.Add($l)
        $y += 16
    }

    $lblTag = New-Object System.Windows.Forms.Label
    $lblTag.Text = "QEMU Release Tag:"
    $lblTag.Location = New-Object System.Drawing.Point(25, 135)
    $lblTag.Size = New-Object System.Drawing.Size(120, 20)
    $contentPanel.Controls.Add($lblTag)

    $txtTag = New-Object System.Windows.Forms.TextBox
    $txtTag.Text = "qemu-engines-v1.0.0"
    $txtTag.Location = New-Object System.Drawing.Point(150, 132)
    $txtTag.Size = New-Object System.Drawing.Size(150, 20)
    $contentPanel.Controls.Add($txtTag)

    $chkWin_x64 = New-Object System.Windows.Forms.CheckBox
    $chkWin_x64.Text = "Windows Engine (x86_64)"
    $chkWin_x64.Location = New-Object System.Drawing.Point(25, 160)
    $chkWin_x64.Size = New-Object System.Drawing.Size(250, 20)
    $chkWin_x64.Checked = $true
    $contentPanel.Controls.Add($chkWin_x64)

    $chkLin_x64 = New-Object System.Windows.Forms.CheckBox
    $chkLin_x64.Text = "Linux Engine (x86_64)"
    $chkLin_x64.Location = New-Object System.Drawing.Point(25, 185)
    $chkLin_x64.Size = New-Object System.Drawing.Size(250, 20)
    $contentPanel.Controls.Add($chkLin_x64)

    $chkLin_arm64 = New-Object System.Windows.Forms.CheckBox
    $chkLin_arm64.Text = "Linux Engine (ARM64)"
    $chkLin_arm64.Location = New-Object System.Drawing.Point(25, 210)
    $chkLin_arm64.Size = New-Object System.Drawing.Size(250, 20)
    $contentPanel.Controls.Add($chkLin_arm64)

    $chkMac_arm64 = New-Object System.Windows.Forms.CheckBox
    $chkMac_arm64.Text = "macOS Engine (Apple Silicon)"
    $chkMac_arm64.Location = New-Object System.Drawing.Point(300, 160)
    $chkMac_arm64.Size = New-Object System.Drawing.Size(250, 20)
    $contentPanel.Controls.Add($chkMac_arm64)

    $btnDownload = New-Object System.Windows.Forms.Button
    $btnDownload.Text = "Download & Extract Engines"
    $btnDownload.Location = New-Object System.Drawing.Point(25, 240)
    $btnDownload.Size = New-Object System.Drawing.Size(250, 32)
    $btnDownload.BackColor = [System.Drawing.Color]::FromArgb(16, 185, 129)
    $btnDownload.ForeColor = [System.Drawing.Color]::White
    $btnDownload.FlatStyle = "Flat"
    $contentPanel.Controls.Add($btnDownload)

    $pbQemuExtract = New-Object System.Windows.Forms.ProgressBar
    $pbQemuExtract.Location = New-Object System.Drawing.Point(25, 280)
    $pbQemuExtract.Size = New-Object System.Drawing.Size(580, 18)
    $pbQemuExtract.Style = "Blocks"
    $pbQemuExtract.Visible = $false
    $contentPanel.Controls.Add($pbQemuExtract)

    $lblQemuStatus = New-Object System.Windows.Forms.Label
    $lblQemuStatus.Font = $fntMono
    $lblQemuStatus.Location = New-Object System.Drawing.Point(25, 305)
    $lblQemuStatus.Size = New-Object System.Drawing.Size(580, 40)
    $contentPanel.Controls.Add($lblQemuStatus)

    $btnDownload.add_Click({
        $btnDownload.Enabled = $false
        $btnBack.Enabled = $false
        $pbQemuExtract.Visible = $true
        $pbQemuExtract.Value = 0
        
        $tag = $txtTag.Text.Trim()
        $repoUrl = "https://github.com/aether70/pvm/releases/download/$tag"
        
        $engines = @()
        if ($chkWin_x64.Checked)   { $engines += @{ Name="Windows x86_64"; Zip="qemu-windows-x86_64.zip"; Dir="backends\windows\qemu" } }
        if ($chkLin_x64.Checked)   { $engines += @{ Name="Linux x86_64";   Zip="qemu-linux-x86_64.zip";   Dir="backends\linux\qemu" } }
        if ($chkLin_arm64.Checked) { $engines += @{ Name="Linux ARM64";    Zip="qemu-linux-arm64.zip";    Dir="backends\linux\qemu" } }
        if ($chkMac_arm64.Checked) { $engines += @{ Name="macOS ARM64";    Zip="qemu-macos-arm64.zip";    Dir="backends\macos\qemu" } }

        if ($engines.Count -eq 0) {
            $lblQemuStatus.Text = "[!] Please select at least one engine."
            $lblQemuStatus.ForeColor = $colRed
            $btnDownload.Enabled = $true
            $btnBack.Enabled = $true
            return
        }

        # Ensure .NET compression assembly is loaded
        Add-Type -AssemblyName System.IO.Compression.FileSystem

        try {
            foreach ($engine in $engines) {
                $lblQemuStatus.Text = "Downloading $($engine.Name) engine..."
                $lblQemuStatus.ForeColor = $colDarkText
                [System.Windows.Forms.Application]::DoEvents()
                
                $url = "$repoUrl/$($engine.Zip)"
                $tempZip = Join-Path $env:TEMP $engine.Zip
                
                # Download
                Invoke-WebRequest -Uri $url -OutFile $tempZip -UseBasicParsing
                
                $destDir = Join-Path $state.InstallPath $engine.Dir
                if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
                
                $lblQemuStatus.Text = "Extracting $($engine.Name) engine... (High-Speed .NET)"
                [System.Windows.Forms.Application]::DoEvents()
                
                # Native fast extraction with progress
                $zip = [System.IO.Compression.ZipFile]::OpenRead($tempZip)
                $total = $zip.Entries.Count
                $count = 0
                
                foreach ($entry in $zip.Entries) {
                    $entryPath = Join-Path $destDir $entry.FullName
                    if ($entry.FullName.EndsWith("/") -or $entry.FullName.EndsWith("\")) {
                        if (-not (Test-Path $entryPath)) { New-Item -ItemType Directory -Path $entryPath -Force | Out-Null }
                    } else {
                        $parent = Split-Path $entryPath
                        if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
                        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $entryPath, $true)
                    }
                    $count++
                    $percent = [math]::Floor(($count / $total) * 100)
                    if ($percent -ne $pbQemuExtract.Value) {
                        $pbQemuExtract.Value = $percent
                        [System.Windows.Forms.Application]::DoEvents()
                    }
                }
                $zip.Dispose()
                Remove-Item $tempZip -Force
            }
            
            $state.QemuInstalled = $true
            $btnNext.Enabled = $true
            $btnBack.Enabled = $true
            $lblQemuStatus.Text = "[OK] All selected engines successfully installed!"
            $lblQemuStatus.ForeColor = $colGreen
            $btnDownload.Text = "Installed"
            
        } catch {
            $lblQemuStatus.Text = "[!] Error: $($_.Exception.Message)`nEnsure you have uploaded the .zip files to your GitHub Releases!"
            $lblQemuStatus.ForeColor = $colRed
            $btnDownload.Enabled = $true
            $btnBack.Enabled = $true
        }
    }.GetNewClosure())
}

# ─────────────────────────────────────────────
# STEP 6: SYSTEM VERIFICATION
# ─────────────────────────────────────────────
function Show-Step6 {
    Clear-ContentPanel
    Set-StepIndicator -Step 6
    $btnBack.Enabled = $false
    $btnNext.Enabled = $false

    Add-SectionHeader -Text "System Verification" -Y 15
    Add-BodyLabel -Text "Running system checks to ensure everything is configured correctly..." -X 25 -Y 40 -W 610 -H 20

    $checksPanel = New-Object System.Windows.Forms.Panel
    $checksPanel.Location = New-Object System.Drawing.Point(25, 70)
    $checksPanel.Size = New-Object System.Drawing.Size(610, 260)
    $checksPanel.BackColor = [System.Drawing.Color]::White
    $checksPanel.BorderStyle = "FixedSingle"
    $contentPanel.Controls.Add($checksPanel)

    $lblVerifyStatus = Add-BodyLabel -Text "Running checks..." -X 25 -Y 345 -W 610 -H 20

    # Source detect.ps1 from the installed location
    $detectScript = Join-Path $state.InstallPath "scripts\windows\detect.ps1"
    if (-not (Test-Path $detectScript)) {
        $detectScript = Join-Path $SourceRoot "scripts\windows\detect.ps1"
    }
    . $detectScript
    $hi = Get-HostInformation -RootDir $state.InstallPath

    $checks = @(
        @{
            Name = "QEMU binary found"
            Pass = ($hi.QemuPath -ne "")
            Detail = if ($hi.QemuPath) { $hi.QemuPath } else { "Not found in $QEMU_DIR_RELATIVE" }
        }
        @{
            Name = "QEMU version detected"
            Pass = ($hi.QemuVersion -ne "Not Found" -and $hi.QemuVersion -ne "")
            Detail = "Version: $($hi.QemuVersion)"
        }
        @{
            Name = "Architecture match"
            Pass = ($hi.QemuPath -like "*$hostArch*" -or $hi.QemuPath -like "*$qemuBinaryName*")
            Detail = "Host: $archFriendly | Binary: $qemuBinaryName"
        }
        @{
            Name = "Hardware virtualization"
            Pass = $true  # Not critical - TCG is fallback
            Detail = $(if ($hi.WhpxAvailable) { "WHPX available (fast hardware acceleration)" } elseif ($whpxSupported) { "WHPX not detected - TCG fallback (check BIOS settings)" } else { "TCG only (Windows version limitation)" })
        }
        @{
            Name = "Sufficient disk space"
            Pass = ($hi.SsdFreeSpaceGB -ge 5)
            Detail = "$($hi.SsdFreeSpaceGB) GB remaining on drive"
        }
        @{
            Name = "Config file valid"
            Pass = (Test-Path (Join-Path $state.InstallPath "config.json"))
            Detail = $(if (Test-Path (Join-Path $state.InstallPath "config.json")) { "config.json present" } else { "config.json missing!" })
        }
    )

    $allPass = $true
    $y = 12
    foreach ($chk in $checks) {
        $icon = if ($chk.Pass) { "[OK]" } else { "[FAIL]"; $allPass = $false }
        $color = if ($chk.Pass) { $colGreen } else { $colRed }
        if ($chk.Name -eq "Hardware virtualization") { $color = $colOrange }

        $lblName = New-Object System.Windows.Forms.Label
        $lblName.Text = "$icon  $($chk.Name)"
        $lblName.Font = $fntHeader
        $lblName.ForeColor = $color
        $lblName.Location = New-Object System.Drawing.Point(12, $y)
        $lblName.Size = New-Object System.Drawing.Size(280, 18)
        $checksPanel.Controls.Add($lblName)

        $lblDetail = New-Object System.Windows.Forms.Label
        $lblDetail.Text = $chk.Detail
        $lblDetail.Font = $fntMono
        $lblDetail.ForeColor = [System.Drawing.Color]::FromArgb(71, 85, 105)
        $lblDetail.Location = New-Object System.Drawing.Point(295, $y)
        $lblDetail.Size = New-Object System.Drawing.Size(310, 18)
        $checksPanel.Controls.Add($lblDetail)

        $y += 38
    }

    if ($allPass) {
        $lblVerifyStatus.Text = "[OK] All checks passed. Ready to finish!"
        $lblVerifyStatus.ForeColor = $colGreen
        $btnNext.Enabled = $true
        $btnNext.Text = "Finish >"
    } else {
        $lblVerifyStatus.Text = "[!] Some checks failed. Review the items above before continuing."
        $lblVerifyStatus.ForeColor = $colRed
        # Still allow to proceed with warning
        $btnNext.Enabled = $true
        $btnNext.Text = "Finish Anyway >"
    }
}

# ─────────────────────────────────────────────
# STEP 7: FINISH & LAUNCH
# ─────────────────────────────────────────────
function Show-Step7 {
    Clear-ContentPanel
    Set-StepIndicator -Step 7
    $btnBack.Enabled = $false
    $btnNext.Enabled = $false
    $btnCancel.Enabled = $false

    Add-SectionHeader -Text "Setup Complete!" -Y 15

    $lblDone = Add-BodyLabel -Text "Portable VM has been successfully installed to:" -X 25 -Y 45 -W 610 -H 20
    $lblPath = Add-BodyLabel -Text $state.InstallPath -X 25 -Y 65 -W 610 -H 20
    $lblPath.Font = $fntMono
    $lblPath.ForeColor = $colAccent

    Add-BodyLabel -Text "How would you like to launch Portable VM?" -X 25 -Y 110 -W 610 -H 20

    $rbGui = New-Object System.Windows.Forms.RadioButton
    $rbGui.Text = "Launch GUI (recommended for most users)"
    $rbGui.Font = $fntBody
    $rbGui.Location = New-Object System.Drawing.Point(40, 138)
    $rbGui.AutoSize = $true
    $rbGui.Checked = $true
    $contentPanel.Controls.Add($rbGui)

    $rbCli = New-Object System.Windows.Forms.RadioButton
    $rbCli.Text = "Launch CLI (for advanced users)"
    $rbCli.Font = $fntBody
    $rbCli.Location = New-Object System.Drawing.Point(40, 165)
    $rbCli.AutoSize = $true
    $contentPanel.Controls.Add($rbCli)

    $rbNone = New-Object System.Windows.Forms.RadioButton
    $rbNone.Text = "Exit setup without launching"
    $rbNone.Font = $fntBody
    $rbNone.Location = New-Object System.Drawing.Point(40, 192)
    $rbNone.AutoSize = $true
    $contentPanel.Controls.Add($rbNone)

    $btnFinish = New-Object System.Windows.Forms.Button
    $btnFinish.Text = "Finish"
    $btnFinish.Font = $fntHeader
    $btnFinish.Location = New-Object System.Drawing.Point(25, 240)
    $btnFinish.Size = New-Object System.Drawing.Size(160, 38)
    $btnFinish.FlatStyle = "Flat"
    $btnFinish.BackColor = $colGreen
    $btnFinish.ForeColor = [System.Drawing.Color]::White
    $contentPanel.Controls.Add($btnFinish)

    $btnFinish.add_Click({
        if ($rbGui.Checked) {
            $guiScript = Join-Path $state.InstallPath "scripts\windows\gui_launcher.ps1"
            if (Test-Path $guiScript) {
                Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -File `"$guiScript`""
            }
        } elseif ($rbCli.Checked) {
            $cliScript = Join-Path $state.InstallPath "scripts\windows\launcher.ps1"
            if (Test-Path $cliScript) {
                Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -File `"$cliScript`""
            }
        }
        $form.Close()
    }.GetNewClosure())

    Add-BodyLabel -Text "To run again in future: launch.bat (CLI) or launch_gui.bat (GUI) from $($state.InstallPath)" -X 25 -Y 295 -W 610 -H 40
}

# ─────────────────────────────────────────────
# STEP NAVIGATION
# ─────────────────────────────────────────────
$steps = @(
    { Show-Step1 },
    { Show-Step2 },
    { Show-Step3 },
    { Show-Step4 },
    { Show-Step5 },
    { Show-Step6 },
    { Show-Step7 }
)
$state.CurrentStep = 0
& $steps[0]

$btnNext.add_Click({
    $state.CurrentStep++
    if ($state.CurrentStep -ge $steps.Count) { $state.CurrentStep = $steps.Count - 1; return }
    & $steps[$state.CurrentStep]
})

$btnBack.add_Click({
    if ($state.CurrentStep -gt 0) {
        $state.CurrentStep--
        & $steps[$state.CurrentStep]
    }
})

[void]$form.ShowDialog()
