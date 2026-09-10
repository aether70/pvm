# Contributing to PortableVM

First off, thank you for considering contributing to PortableVM! It's people like you that make this project great.

## Where do I go from here?

If you've noticed a bug or have a feature request, make sure to check our [Issues](../../issues) page to see if someone else has already created a ticket. If not, go ahead and [make one](../../issues/new)!

## How to Contribute

### 1. Fork & Clone
1. Fork the repository on GitHub.
2. Clone your fork locally:
   ```bash
   git clone https://github.com/YOUR-USERNAME/pvm.git
   ```

### 2. Branching
Create a new branch for your feature or bug fix:
```bash
git checkout -b feature/my-new-feature
```
or
```bash
git checkout -b fix/issue-123
```

### 3. Making Changes
When making changes to the scripts:
- **PowerShell**: Ensure compatibility with PowerShell 5.1 (the default in Windows 10/11).
- **Bash**: Ensure scripts are POSIX compliant and work on both Linux (GNU) and macOS (BSD) utilities.
- Do not hardcode paths; always use relative paths from the script directory.

### 4. Testing Your Changes
Before submitting a pull request, test your changes:
1. Run `setup.bat` (Windows) or `./setup.sh` (Unix) and verify the installation process completes.
2. Launch a VM and verify hardware allocation works as intended without crashing the host.

### 5. Submitting a Pull Request
1. Commit your changes with a descriptive commit message.
2. Push your branch to your fork:
   ```bash
   git push origin feature/my-new-feature
   ```
3. Open a Pull Request against the `main` branch of this repository.
4. Describe your changes in detail in the PR description.

## Development Setup
No specialized build tools are required since PortableVM is entirely script-based. You only need:
- Windows: PowerShell 5.1+
- Unix: Bash 4.0+
- Optional: QEMU binaries if you are modifying the virtualization parameters.

Thank you for contributing!
