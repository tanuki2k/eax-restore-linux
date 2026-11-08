# Security Policy

## Supported Versions

Only the [latest release](../../releases/latest) is supported. The `dev` pre-release is unstable and unsupported. Please update to the latest release before reporting an issue.

## Reporting a Vulnerability

This script downloads and executes third-party binaries (DSOAL/OpenAL builds, the MS VC++ Redistributable) and writes to Wine/Proton prefixes and the Windows registry within them. If you find a security issue — e.g. a way the script could be tricked into running untrusted code, writing outside the intended prefix/game folder, or a checksum verification bypass — please [open an issue](../../issues/new) describing it.

This is a hobby project without a dedicated security response process, but reports will be reviewed and addressed as soon as possible.
