<#
.SYNOPSIS
    Builds the QEMU command line from a decision specification.
.DESCRIPTION
    Returns three related but distinct things, and using the wrong one is the
    bug this module exists to prevent:

      Arguments      - string[], one element per argv entry, NO quote
                       characters embedded in the values. Pass this to native
                       invocation (`& $exe @Arguments`), which quotes each
                       element correctly on its way to the process.
      ArgumentString - the same list rendered into a single command line using
                       the CommandLineToArgvW escaping rules. This is what
                       Start-Process needs, because Windows PowerShell 5.1
                       joins an -ArgumentList array with plain spaces and adds
                       no quoting of its own - so any path containing a space
                       silently becomes two arguments.
      CommandLine    - ArgumentString with the executable prefixed, for display.

    The previous version embedded literal `"` characters inside individual
    array elements. Those quotes were then escaped again by the process
    launcher, and QEMU received a file= path with quote marks in it.
#>

<#
    Escapes one argument per the rules CommandLineToArgvW parses, which is
    what QEMU (and every other MSVCRT program) uses to split its command line:
    backslashes are literal except when they immediately precede a quote, and
    a run of backslashes before the closing quote must be doubled.
#>
function ConvertTo-Win32Argument {
    param([string]$Argument)

    if ($Argument -eq $null) { $Argument = "" }

    if ($Argument.Length -gt 0 -and $Argument -notmatch '[ \t\n\v"]') {
        return $Argument
    }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')

    $backslashes = 0
    foreach ($ch in $Argument.ToCharArray()) {
        if ($ch -eq '\') {
            $backslashes++
            continue
        }
        if ($ch -eq '"') {
            # Double the run, then escape the quote itself.
            [void]$sb.Append('\' * ($backslashes * 2 + 1))
            [void]$sb.Append('"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            [void]$sb.Append('\' * $backslashes)
            $backslashes = 0
        }
        [void]$sb.Append($ch)
    }

    [void]$sb.Append('\' * ($backslashes * 2))
    [void]$sb.Append('"')
    return $sb.ToString()
}

function ConvertTo-Win32ArgumentString {
    param([string[]]$Arguments)

    if (-not $Arguments -or $Arguments.Count -eq 0) { return "" }
    return (($Arguments | ForEach-Object { ConvertTo-Win32Argument $_ }) -join " ")
}

function Build-QemuCommand {
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Decision
    )

    $argsList = [System.Collections.Generic.List[string]]::new()

    # ---- Identity --------------------------------------------------------
    $argsList.Add("-name")
    $argsList.Add($Decision.VmName)

    # ---- Machine and accelerator -----------------------------------------
    # kernel-irqchip=off is required for WHPX: the in-kernel irqchip has no
    # WHPX implementation and QEMU refuses to start without it.
    $accelOption = if ($Decision.Accelerator -eq "whpx") { "whpx,kernel-irqchip=off" } else { $Decision.Accelerator }
    $argsList.Add("-machine")
    $argsList.Add("$($Decision.Machine),accel=$accelOption")

    $argsList.Add("-cpu")
    $argsList.Add($Decision.CpuModel)

    $argsList.Add("-smp")
    $argsList.Add("$($Decision.AllocatedCores)")

    $argsList.Add("-m")
    $argsList.Add("$($Decision.AllocatedRamMB)")

    # ---- UEFI firmware ----------------------------------------------------
    # unit=0 is the read-only CODE image shared by every VM; unit=1 is this
    # VM's own writable variable store. Without unit=1 the guest cannot save a
    # boot entry, which is why an installed OS drops to the EFI shell on its
    # second start.
    if ($Decision.UseUefi -and $Decision.UefiCode) {
        $argsList.Add("-drive")
        $argsList.Add("if=pflash,format=raw,unit=0,readonly=on,file=$($Decision.UefiCode)")

        if ($Decision.UefiVars -and (Test-Path $Decision.UefiVars)) {
            $argsList.Add("-drive")
            $argsList.Add("if=pflash,format=raw,unit=1,file=$($Decision.UefiVars)")
        }
    }

    # ---- Storage -----------------------------------------------------------
    if ($Decision.DiskPath) {
        $argsList.Add("-drive")
        $argsList.Add("file=$($Decision.DiskPath),format=$($Decision.DiskFormat),if=virtio,cache=$($Decision.DiskCache)")
    }

    if ($Decision.IsoPath) {
        if (Test-QemuDevice -HostInfo $Decision.HostInfo -DeviceName "virtio-scsi-pci") {
            # virtio-scsi rather than -cdrom: aarch64/virt has no IDE
            # controller for -cdrom to attach to, and this form behaves
            # identically on q35.
            $argsList.Add("-device")
            $argsList.Add("virtio-scsi-pci,id=scsi0")
            $argsList.Add("-drive")
            $argsList.Add("file=$($Decision.IsoPath),format=raw,if=none,id=cd0,media=cdrom,readonly=on")
            $argsList.Add("-device")
            $argsList.Add("scsi-cd,drive=cd0,bus=scsi0.0,bootindex=0")
        } else {
            $argsList.Add("-cdrom")
            $argsList.Add($Decision.IsoPath)
            $argsList.Add("-boot")
            $argsList.Add("d")
        }
    }

    # ---- Graphics ----------------------------------------------------------
    # A -device, never -vga: `-vga virtio` is x86-only and aborts with
    # "Virtio VGA not available" on aarch64/virt.
    if ($Decision.VgaDevice) {
        $argsList.Add("-device")
        $argsList.Add($Decision.VgaDevice)
    }

    switch ($Decision.DisplayMode) {
        "vnc" {
            $argsList.Add("-vnc")
            $argsList.Add("127.0.0.1:0")
        }
        "none" {
            $argsList.Add("-display")
            $argsList.Add("none")
        }
        default {
            $argsList.Add("-display")
            if ($Decision.UseGl) {
                $argsList.Add("$($Decision.DisplayMode),gl=on")
            } else {
                $argsList.Add($Decision.DisplayMode)
            }
        }
    }

    # ---- Input --------------------------------------------------------------
    # usb-tablet reports absolute coordinates, so the pointer tracks the host
    # cursor instead of being captured by the guest window. The whole block is
    # gated on the controller: usb-tablet with no bus to attach to is a hard
    # error, and a stripped-down QEMU build may not ship qemu-xhci.
    if (Test-QemuDevice -HostInfo $Decision.HostInfo -DeviceName "qemu-xhci") {
        $argsList.Add("-device")
        $argsList.Add("qemu-xhci,id=xhci")
        $argsList.Add("-device")
        $argsList.Add("usb-tablet,bus=xhci.0")
        $argsList.Add("-device")
        $argsList.Add("usb-kbd,bus=xhci.0")
    }

    # ---- Audio ---------------------------------------------------------------
    # An -audiodev is mandatory; hda devices without one fail to open a host
    # stream. hda-output rather than hda-duplex, so no capture device (and no
    # microphone permission) is required just to get sound out.
    if ($Decision.AudioDev) {
        $argsList.Add("-audiodev")
        $argsList.Add("$($Decision.AudioDev),id=snd0")
        $argsList.Add("-device")
        $argsList.Add("intel-hda")
        $argsList.Add("-device")
        $argsList.Add("hda-output,audiodev=snd0")
    }

    # ---- Network -------------------------------------------------------------
    if ($Decision.NetworkMode -eq "nat") {
        # Bound to 127.0.0.1 so the guest's SSH port is not exposed to the
        # local network from whatever machine the SSD happens to be plugged in.
        $argsList.Add("-netdev")
        $argsList.Add("user,id=net0,hostfwd=tcp:127.0.0.1:$($Decision.SshPort)-:22")
        $argsList.Add("-device")
        $argsList.Add("virtio-net-pci,netdev=net0$($Decision.NetRomOption)")
    } elseif ($Decision.NetworkMode -eq "none") {
        $argsList.Add("-nic")
        $argsList.Add("none")
    }

    # ---- Misc ----------------------------------------------------------------
    $argsList.Add("-rtc")
    $argsList.Add("base=utc,clock=host")

    # Lets the host reclaim guest memory the guest is not using. Optional in
    # every sense, so it is skipped rather than fatal when absent.
    if (Test-QemuDevice -HostInfo $Decision.HostInfo -DeviceName "virtio-balloon-pci") {
        $argsList.Add("-device")
        $argsList.Add("virtio-balloon-pci")
    }

    $argArray = $argsList.ToArray()
    $argString = ConvertTo-Win32ArgumentString -Arguments $argArray

    return [PSCustomObject]@{
        Executable     = $Decision.QemuExe
        Arguments      = $argArray
        ArgumentString = $argString
        CommandLine    = "$(ConvertTo-Win32Argument $Decision.QemuExe) $argString"
    }
}
