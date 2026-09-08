<div align="center">
  <h1>🚀 PortableVM (v0.2)</h1>
  <p><strong>Your entire operating system in your pocket. Plug it in. Run it anywhere.</strong></p>
</div>

---

## 🌟 What is PortableVM?

**PortableVM** is a zero-dependency, ultra-lightweight launcher and virtualization environment that lives entirely on an external USB drive or SSD. 

Instead of carrying a laptop, just carry your portable SSD. Plug it into **any** host computer (Windows, Linux, or macOS), double-click the launcher, and instantly boot into your own persistent, personalized operating system running at near-native speeds.

- **Zero Installation on Host**: No need to install hypervisors or dependencies on the host machine. 
- **Hardware-Aware Engine**: Automatically inspects the host computer's CPU and RAM to safely allocate optimal resources to your VM without starving the host OS.
- **Cross-Platform Compatibility**: Uses native PowerShell (Windows) or Bash (Linux/macOS) wrappers.
- **Hardware Acceleration**: Automatically leverages WHPX (Windows), KVM (Linux), or HVF (macOS) for blistering fast near-native performance.

---

## 📥 Installation & Setup

We have packaged the entire PortableVM setup into a single, dead-simple installer file.

### Step 1: Download the Installer
Go to the **Releases** page of this repository and download the latest **`PortableVM_Setup.bat`**.

### Step 2: Run the Installer (Windows)
1. Plug in your external USB Drive or SSD.
2. Double-click the downloaded **`PortableVM_Setup.bat`** file.
3. The interactive GUI wizard will appear. 
4. The wizard will automatically detect your plugged-in USB drive, ensure it has enough free space, and prompt you to choose an installation folder.
5. It will securely download QEMU (the underlying virtualization engine) and extract all necessary PortableVM files directly to your USB drive.

> **Note on Upgrading:** If you already have a version of PortableVM installed, simply run the new `.bat` file and point it to your existing directory. The installer will safely upgrade the internal scripts while preserving your VMs and configurations!

---

## 💻 Accessing & Using Your PortableVM

Once installed, navigate to the `PortableVM` folder on your USB drive.

### 1. Launch the GUI Dashboard
To manage your VMs, create new ones, or interactively adjust RAM and CPU limits based on the current host machine:
- **Windows**: Double-click **`launch_gui.bat`**
- **Linux / macOS**: Execute **`./launch_gui.sh`**

### 2. Creating a Virtual Machine
Inside the GUI Launcher, click **"+ New VM"**. You can:
- Mount an `.iso` file (like Ubuntu, Debian, or Windows) to install a fresh OS.
- Define your virtual disk size (e.g., 64GB).
- The launcher will automatically spin up the QEMU instance and guide you through your OS installation.

### 3. Quick Launching
If you don't need the GUI and just want to boot your default VM immediately from the terminal:
- **Windows**: Double-click `launch.bat`
- **Linux / macOS**: Run `./launch.sh`

---

## ⚡ Virtualization Acceleration

PortableVM does not assume acceleration is available — it measures it, and tells
you in the launch summary which accelerator it picked and why.

- **Windows**: enable **Windows Hypervisor Platform** in Windows Features and
  reboot. The launcher confirms WHPX by briefly starting QEMU with it, because
  the accelerator being compiled in is not the same as it being usable.
- **Linux**: your user needs read *and* write access to `/dev/kvm` — usually
  `sudo usermod -aG kvm $USER`, then log out and back in.
- **macOS**: Hypervisor.framework is used automatically.

**Hardware acceleration requires the guest architecture to match the host.**
An x86_64 guest on an Apple Silicon or ARM64 Windows machine can only run under
TCG software emulation, which is dramatically slower. `config.json` ships with
`"arch": "x86_64"`; set it to `"host"` to make new VMs match whatever machine
they are created on.

---

## ⚙️ Configuration

`config.json` at the root of the drive holds the defaults for every VM, and both
the PowerShell and the Bash launcher read the same file.

| Key | Meaning |
| --- | --- |
| `vm_defaults.memory_percent` | Share of total host RAM to allocate. |
| `vm_defaults.host_reserve_mb` | RAM held back for the host OS. |
| `vm_defaults.arch` | Guest architecture: `x86_64`, `aarch64`, or `host`. |
| `vm_defaults.display` | Preferred display backend; falls back automatically if this QEMU lacks it. |
| `vm_defaults.disk_cache` | `auto` picks `writeback` for qcow2 and `writethrough` for raw. |
| `vm_defaults.audio` | `auto`, `off`, or an explicit QEMU audiodev name. |
| `guest_arch.<arch>` | Machine type, CPU model, GPU device and firmware filenames per architecture. |
| `host_accel` / `host_audio` | Per-host-OS accelerator and audio backend. |

Each VM can override any of these in its own `vms/<name>/vm.conf`:

```ini
name=ubuntu
arch=aarch64
memory_mb=8192
cores=4
display=gtk
ssh_port=2222
uefi=true
```

`arch` is written into `vm.conf` when a VM is created, because a disk image is
architecture-specific — changing the global default later must not silently
repoint an existing VM at a different guest platform.

---

## 🔒 Safety Behaviour

- **Single instance per VM.** A `.pvm-lock` directory is created next to the disk
  image while a VM runs. Two QEMU processes writing one qcow2 image corrupt it,
  usually with no error until the guest filesystem stops mounting. A lock left
  behind by a crashed launcher is detected and reclaimed automatically.
- **Persistent UEFI variables.** Each VM gets its own writable `uefi_vars.fd`
  alongside the shared read-only firmware, so boot entries survive — without it
  a freshly installed OS drops to the EFI shell on its second start.
- **Deletion asks you to type the VM name.** There is no undo, and the disk image
  is usually the only copy of the guest.

---
*PortableVM is currently at v0.2.*
