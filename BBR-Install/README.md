# BBRInstall

A Debian/Ubuntu installer for BBR-family TCP congestion-control algorithms.


- **`bbrv3`**: installs a prebuilt Linux kernel image and matching headers package, then configures the kernel congestion-control setting to `bbr`.
- **`bbrx`, `bbrw`, `bbr_brutal`, `bbrw_brutal`**: downloads the selected module source, builds it with DKMS for the currently running kernel, loads the module, enables autoload at boot, and configures the selected algorithm.

> **Warning**
>
> This script changes kernel-level networking behavior and must run as `root`. Review the script and the upstream source location before running it on a production host.

---
## Supported systems

| Platform | Supported versions
|---|---|
| Debian | 11, 12, 13
| Ubuntu | 22.04, 24.04, 26.04

Runtime support:

- Bare-metal hosts and full virtual machines are expected to work.
- Containers are blocked by default because they share the host kernel.
- WSL is blocked by default because this type of kernel/DKMS installation is not appropriate there.
- `--force-runtime` exists for testing or unusual environments, but it should not be used on production systems unless you understand the kernel/runtime boundary.

Architecture and kernel limitations:
- DKMS-based algorithms require a running kernel version in the configured range, defaulting to **5.10 through 7.1.x**.
- DKMS-based algorithms require matching kernel headers for the currently running kernel.

---

## Requirements

Minimum practical requirements:

- Root privileges.
- Debian or Ubuntu host matching the supported version list.
- `bash`, `apt-get`, `dpkg`, `uname`, `awk`, `sed`, `grep`, and `sha256sum`.
- Internet access to the configured `RAW_BASE` source.
- For DKMS algorithms: `dkms`, `build-essential`, `kmod`, and matching `linux-headers-$(uname -r)`. The script will attempt to install missing build dependencies.


Recommended before running:

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl
```

---

## Quick start

```bash
bash <(wget -qO- https://raw.githubusercontent.com/jerry048/Trove/refs/heads/main/BBR-Install/BBRInstall.sh)
```

```text
Options:
  --algo ALGO           Install one of: bbrv3 bbrx bbrw bbr_brutal bbrw_brutal
  --raw-base URL        Override source base URL. Can also use RAW_BASE=...
  --upgrade-system      Run apt-get upgrade after apt-get update. Default: off
  --force-runtime       Continue in unsupported runtimes such as containers/WSL
  --no-clear            Do not clear the terminal
  -h, --help            Show this help
```

Supported algorithm values:

| Algorithm | Install method | Congestion-control name configured | Reboot required? |
|---|---|---|---|
| `bbrv3` | Prebuilt kernel `.deb` packages | `bbr` | Yes, to boot into the new kernel. |
| `bbrx` | DKMS kernel module | `bbrx` | Usually no; module is loaded immediately. |
| `bbrw` | DKMS kernel module | `bbrw` | Usually no; module is loaded immediately. |
| `bbr_brutal` | DKMS kernel module | `bbr_brutal` | Usually no; module is loaded immediately. |
| `bbrw_brutal` | DKMS kernel module | `bbrw_brutal` | Usually no; module is loaded immediately. |

---

## Options

### `--algo ALGO`

Selects the congestion-control algorithm non-interactively.

Example:

```bash
bash <(wget -qO- https://raw.githubusercontent.com/jerry048/Trove/refs/heads/main/BBR-Install/BBRInstall.sh) --algo bbrx
```

### `--raw-base URL`

Overrides the source URL used to download kernel packages, DKMS source files, `Makefile`, `dkms.conf`, and checksum files.

For stronger supply-chain control, prefer a trusted fork or a commit-pinned raw URL rather than a moving branch:

```bash
bash <(wget -qO- https://raw.githubusercontent.com/jerry048/Trove/refs/heads/main/BBR-Install/BBRInstall.sh) \
  --algo bbrv3 \
  --raw-base 'https://raw.githubusercontent.com/<owner>/<repo>/<commit>/BBR-Install/BBR'
```

### `--force-runtime`

Bypasses container/WSL runtime blocking.

Use only for controlled testing. Installing kernel packages or DKMS modules inside containers generally does not affect the host kernel and can produce misleading results.

---

## Environment variables

Most CLI options can also be controlled with environment variables.

| Variable | Purpose |
|---|---|
| `BBR_ALGO` | Same as `--algo`. |
| `RAW_BASE` | Same as `--raw-base`. |
| `BBR_SYSCTL_DROPIN` | Override the managed sysctl drop-in path. Default: `/etc/sysctl.d/90-bbr-congestion-control.conf`. |
| `BBR_SYSCTL_LEGACY_FILE` | Override the legacy sysctl file scanned for conflicting settings. Default: `/etc/sysctl.conf`. |
| `BBR_MODULES_LOAD_DROPIN` | Override the managed module autoload file. Default: `/etc/modules-load.d/90-bbr-congestion-control.conf`. |
| `BBR_FORCE_UNSUPPORTED_RUNTIME=1` | Same as `--force-runtime`. |
| `BBR_WORK_DIR` | Use a specific work directory instead of an auto-created temporary directory. |
| `BBR_CLEAN_WORK_DIR=0` | Preserve the work directory after exit for debugging. |
| `BBR_KERNEL_MIN_VERSION` | Advanced/test override for the minimum DKMS kernel version. |
| `BBR_KERNEL_MAX_VERSION` | Advanced/test override for the maximum DKMS kernel version. |

When using environment variables with `sudo`, remember that many sudo configurations do not preserve environment variables by default. Use one of these patterns:

```bash
sudo BBR_ALGO=bbrw ./.sh
```

or:

```bash
sudo -E ./.sh
```

Use `sudo -E` only when you intentionally trust the inherited environment.

---

## Verification

Check the active congestion-control algorithm:

```bash
sysctl net.ipv4.tcp_congestion_control
```

Check the algorithms available to the current kernel:

```bash
sysctl net.ipv4.tcp_available_congestion_control
```

For `bbrv3`, reboot first, then check the running kernel and congestion-control setting:

```bash
uname -r
sysctl net.ipv4.tcp_congestion_control
```

For DKMS algorithms, check DKMS and module state:

```bash
dkms status | grep -E 'bbrx|bbrw|bbr_brutal|bbrw_brutal'
lsmod | grep '^tcp_'
sysctl net.ipv4.tcp_congestion_control
```

Check the managed configuration files:

```bash
cat /etc/sysctl.d/90-bbr-congestion-control.conf
cat /etc/modules-load.d/90-bbr-congestion-control.conf 2>/dev/null || true
```

---

## Rollback and uninstall

Rollback depends on which installation method was used.

### Reset congestion control to the distro default

Most Debian/Ubuntu systems support `cubic`. Confirm availability first:

```bash
sysctl net.ipv4.tcp_available_congestion_control
```

Then switch the current session:

```bash
sudo sysctl -w net.ipv4.tcp_congestion_control=cubic
```

Remove or edit the managed drop-in:

```bash
sudo rm -f /etc/sysctl.d/90-bbr-congestion-control.conf
```

Optionally create your own replacement drop-in:

```bash
printf 'net.ipv4.tcp_congestion_control = cubic\n' | \
  sudo tee /etc/sysctl.d/90-tcp-congestion-control.conf
```

### Remove a DKMS-based algorithm

Replace `<algo>` and `<version>` with the values shown by `dkms status`:

```bash
dkms status | grep -E 'bbrx|bbrw|bbr_brutal|bbrw_brutal'

sudo dkms remove -m <algo> -v <version> --all
sudo rm -f /etc/modules-load.d/90-bbr-congestion-control.conf
sudo rm -f /etc/sysctl.d/90-bbr-congestion-control.conf
sudo depmod -a
```

Unload the module after switching away from it:

```bash
sudo sysctl -w net.ipv4.tcp_congestion_control=cubic
sudo modprobe -r tcp_<algo>
```

Example for `bbrw`:

```bash
sudo sysctl -w net.ipv4.tcp_congestion_control=cubic
sudo modprobe -r tcp_bbrw
```

### Remove a bbrv3 kernel package

Do **not** purge the kernel currently in use. Boot into a known-good distro kernel first.

List installed candidate packages:

```bash
dpkg -l 'linux-image*' 'linux-headers*' | grep -i bbr || true
uname -r
```

After booting into a different kernel, purge the bbrv3 image and headers package names shown by `dpkg -l`:

```bash
sudo apt-get purge 'linux-image-<bbrv3-kernel-package>' 'linux-headers-<bbrv3-kernel-package>'
sudo update-grub
sudo rm -f /etc/sysctl.d/90-bbr-congestion-control.conf
sudo reboot
```

Package names vary based on the upstream package set, so inspect `dpkg -l` before purging.

---

## Troubleshooting

### `error: non-interactive mode requires --algo or BBR_ALGO`

The script was run without a TTY. Specify the algorithm explicitly:

```bash
bash <(wget -qO- https://raw.githubusercontent.com/jerry048/Trove/refs/heads/main/BBR-Install/BBRInstall.sh) --algo bbrw
```

### `linux-headers-$(uname -r)` cannot be installed

The running kernel may not have matching headers available from your APT repositories. Install the exact matching headers package, or boot into a kernel that has matching headers available.

Useful checks:

```bash
uname -r
ls -ld /lib/modules/$(uname -r)/build
apt-cache policy linux-headers-$(uname -r)
```

### DKMS build fails

Review the DKMS build log:

```bash
sudo find /var/lib/dkms -name make.log -print
sudo less /var/lib/dkms/<algo>/<version>/build/make.log
```

Common causes include missing headers, an unsupported kernel version, compiler mismatch, or upstream source incompatibility with the running kernel.

### `modprobe` fails

Check kernel logs:

```bash
dmesg | tail -n 100
journalctl -k -n 100 --no-pager
```

If Secure Boot is enabled, confirm whether unsigned module loading is blocked.

### `sysctl` cannot switch to the selected algorithm

The congestion-control module may not be loaded, or the running kernel may not provide that algorithm.

Check availability:

```bash
sysctl net.ipv4.tcp_available_congestion_control
lsmod | grep '^tcp_'
```

For DKMS algorithms, try loading the module manually:

```bash
sudo modprobe tcp_bbrw
```

Replace `tcp_bbrw` with the module name for the selected algorithm.

### bbrv3 installed but not active after reboot

Confirm that the machine booted into the new kernel:

```bash
uname -r
```

Then inspect bootloader entries and regenerate GRUB if needed:

```bash
sudo update-grub
```

Cloud providers and VPS panels sometimes pin or override boot kernels. Check provider-specific boot settings if the new kernel does not appear.

