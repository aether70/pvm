<#
.SYNOPSIS
    GUI Delete Wizard for removing a Virtual Machine on Windows.
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$VmName,
    [Parameter(Mandatory = $true)]
    [string]$VmsDir
)

. (Join-Path $PSScriptRoot "lock.ps1")

$targetDir = Join-Path $VmsDir $VmName

$result = [PSCustomObject]@{
    Deleted = $false
}

if (-not (Test-Path $targetDir)) {
    [System.Windows.Forms.MessageBox]::Show("VM '$VmName' not found.", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    return $result
}

# Refuse while the VM is running: deleting the backing image out from under a
# live QEMU is the exact race the instance lock exists to prevent.
$lock = Lock-PvmVm -VmDir $targetDir
if (-not $lock.Acquired) {
    [System.Windows.Forms.MessageBox]::Show(
        "VM '$VmName' appears to be running (locked by $($lock.Owner))." + [Environment]::NewLine + [Environment]::NewLine +
        "Shut it down before deleting it.",
        "VM Running",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    return $result
}

$wizardForm = New-Object System.Windows.Forms.Form
$wizardForm.Text = "Delete Virtual Machine"
$wizardForm.Size = New-Object System.Drawing.Size(500, 470)
$wizardForm.StartPosition = "CenterParent"
$wizardForm.FormBorderStyle = "FixedDialog"
$wizardForm.MaximizeBox = $false

$fontRegular = New-Object System.Drawing.Font("Segoe UI", 9)
$fontBold = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)

# Warning Label
$lblWarn = New-Object System.Windows.Forms.Label
$lblWarn.Text = "WARNING: You are about to permanently delete the VM:`r`n'$VmName'`r`n`r`nThis action cannot be undone. All data will be lost."
$lblWarn.Location = New-Object System.Drawing.Point(20, 20)
$lblWarn.Size = New-Object System.Drawing.Size(440, 60)
$lblWarn.Font = $fontBold
$lblWarn.ForeColor = [System.Drawing.Color]::Crimson
$wizardForm.Controls.Add($lblWarn)

# Progress Bar
$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(20, 90)
$progressBar.Size = New-Object System.Drawing.Size(440, 25)
$progressBar.Style = "Blocks"
$wizardForm.Controls.Add($progressBar)

# ListBox for file details
$lblFiles = New-Object System.Windows.Forms.Label
$lblFiles.Text = "Deletion Progress:"
$lblFiles.Location = New-Object System.Drawing.Point(20, 130)
$lblFiles.AutoSize = $true
$lblFiles.Font = $fontBold
$wizardForm.Controls.Add($lblFiles)

$lstFiles = New-Object System.Windows.Forms.ListBox
$lstFiles.Location = New-Object System.Drawing.Point(20, 155)
$lstFiles.Size = New-Object System.Drawing.Size(440, 160)
$lstFiles.Font = $fontRegular
$lstFiles.BackColor = [System.Drawing.Color]::Black
$lstFiles.ForeColor = [System.Drawing.Color]::LimeGreen
$wizardForm.Controls.Add($lstFiles)

# Typing the name is deliberate friction: a single red button is too easy to
# press on autopilot for something with no undo, and the disk image is usually
# the only copy of the guest.
$lblConfirm = New-Object System.Windows.Forms.Label
$lblConfirm.Text = "Type the VM name to enable deletion:"
$lblConfirm.Location = New-Object System.Drawing.Point(20, 325)
$lblConfirm.Size = New-Object System.Drawing.Size(230, 20)
$lblConfirm.Font = $fontRegular
$wizardForm.Controls.Add($lblConfirm)

$txtConfirm = New-Object System.Windows.Forms.TextBox
$txtConfirm.Location = New-Object System.Drawing.Point(20, 345)
$txtConfirm.Size = New-Object System.Drawing.Size(220, 25)
$txtConfirm.Font = $fontRegular
$wizardForm.Controls.Add($txtConfirm)

# Buttons
$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text = "Cancel"
$btnCancel.Location = New-Object System.Drawing.Point(250, 342)
$btnCancel.Size = New-Object System.Drawing.Size(100, 35)
$wizardForm.Controls.Add($btnCancel)
$btnCancel.add_Click({ $wizardForm.Close() })

$btnDelete = New-Object System.Windows.Forms.Button
$btnDelete.Text = "Delete VM"
$btnDelete.Location = New-Object System.Drawing.Point(360, 342)
$btnDelete.Size = New-Object System.Drawing.Size(100, 35)
$btnDelete.BackColor = [System.Drawing.Color]::Crimson
$btnDelete.ForeColor = [System.Drawing.Color]::White
$btnDelete.FlatStyle = "Flat"
$btnDelete.Enabled = $false
$wizardForm.Controls.Add($btnDelete)

# Case-sensitive: "Ubuntu" should not unlock deletion of "ubuntu".
$txtConfirm.add_TextChanged({
    $btnDelete.Enabled = ($txtConfirm.Text -ceq $VmName)
})

$btnDelete.add_Click({
    $btnDelete.Enabled = $false
    $btnCancel.Enabled = $false
    $txtConfirm.Enabled = $false

    $lstFiles.Items.Add("[*] Analyzing directory...") | Out-Null
    [System.Windows.Forms.Application]::DoEvents()

    $files = @(Get-ChildItem -Path $targetDir -Recurse -File -ErrorAction SilentlyContinue)
    $progressBar.Maximum = [math]::Max(1, $files.Count + 1)
    $progressBar.Value = 0

    $i = 0
    foreach ($f in $files) {
        try {
            Remove-Item -Path $f.FullName -Force -ErrorAction Stop
            $lstFiles.Items.Add("[-] Deleted: $($f.Name)") | Out-Null
        } catch {
            $lstFiles.Items.Add("[!] Could not delete $($f.Name)") | Out-Null
        }

        $i++
        $progressBar.Value = $i
        $lstFiles.TopIndex = $lstFiles.Items.Count - 1

        # Repaint every 25 files rather than every file, and with no artificial
        # sleep. The old version slept 20 ms per file, which turned deleting a
        # VM with a few thousand files into a minutes-long wait purely for
        # visual effect.
        if (($i % 25) -eq 0) { [System.Windows.Forms.Application]::DoEvents() }
    }

    $lstFiles.Items.Add("[*] Removing directory...") | Out-Null
    $lstFiles.TopIndex = $lstFiles.Items.Count - 1
    [System.Windows.Forms.Application]::DoEvents()

    # Release first: the lock directory lives inside the tree being deleted.
    Unlock-PvmVm -VmDir $targetDir

    try {
        Remove-Item -Path $targetDir -Recurse -Force -ErrorAction Stop
        $progressBar.Value = $progressBar.Maximum
        $lstFiles.Items.Add("[+] Deleted VM '$VmName'.") | Out-Null
        $result.Deleted = $true
    } catch {
        $lstFiles.Items.Add("[!] Could not remove the directory: $_") | Out-Null
    }

    $lstFiles.TopIndex = $lstFiles.Items.Count - 1
    $btnCancel.Text = "Close"
    $btnCancel.Enabled = $true
})

$wizardForm.ShowDialog() | Out-Null

# Cancelling out of the dialog must not leave the lock behind, or every later
# launch of this VM would refuse until it was deleted by hand.
if (-not $result.Deleted) {
    Unlock-PvmVm -VmDir $targetDir
}

return $result
