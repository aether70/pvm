# Security Policy

## Supported Versions

We currently support the latest `beta` releases of PortableVM for security updates. Because this project is in active development, we recommend always updating to the latest version to ensure you have the most recent security patches and bug fixes.

| Version | Supported          |
| ------- | ------------------ |
| v0.1.x  | :white_check_mark: |
| < v0.1  | :x:                |

## Reporting a Vulnerability

Security is a top priority for PortableVM, especially given its nature as a virtualization tool.

If you discover a security vulnerability within PortableVM, please DO NOT open a public issue. Instead, please report it via GitHub's private vulnerability reporting feature on this repository, or email the maintainers directly if provided.

### What to include in your report:
- A description of the vulnerability.
- Steps to reproduce the vulnerability.
- Potential impact on users.
- Any suggested mitigations or fixes.

### Response Time
We will strive to acknowledge your report within 48 hours, and we will keep you updated on the progress of the patch and release schedule.

## QEMU Security
PortableVM relies on QEMU for virtualization. Security issues found directly within the QEMU engine should be reported to the upstream QEMU project according to their security policy at: https://www.qemu.org/contribute/security-process/
