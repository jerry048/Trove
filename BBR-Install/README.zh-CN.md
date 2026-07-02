# BBRInstall
# BBRInstall

[English](README.md)

这是一个适用于 Debian/Ubuntu 的 BBR 系列 TCP 拥塞控制算法安装脚本。

- **`bbrv3`** 会安装预编译的 Linux 内核镜像和对应的头文件软件包，然后把当前系统的拥塞控制算法配置为 `bbr`。
- **`bbrx`、`bbrw`、`bbr_brutal`、`bbrw_brutal`** 会下载所选模块的源代码，使用 DKMS 为当前正在运行的内核编译并安装模块，立即加载模块，配置开机自动加载，并启用所选算法。

> **警告**
>
> 此脚本会修改内核级网络行为，并且必须以 `root` 身份运行。用于生产环境之前，请先阅读脚本内容，并确认配置的上游下载源可信。

---

## 支持的系统

| 平台 | 支持版本 |
|---|---|
| Debian | 11、12、13 |
| Ubuntu | 20.04, 22.04, 24.04, 26.04 |

运行环境：

- 推荐在物理机或完整虚拟机中运行。
- 容器默认会被拦截，因为容器共享宿主机内核。
- WSL 默认会被拦截，因为这种内核/DKMS 安装并不适合 WSL。
- `--force-runtime` 可用于测试或特殊环境；生产环境中不要使用，除非你清楚当前的内核和运行环境边界。

架构和内核说明：

- 基于 DKMS 的算法要求当前运行的内核版本位于配置范围内，默认是 **5.10 到 7.1.x**。
- 基于 DKMS 的算法会先尝试使用与当前运行内核匹配的头文件。如果找不到或无法安装，脚本会回退到发行版通用内核镜像和头文件；在无头/非交互模式下，这个回退会自动执行。
- `bbrv3` 使用预编译内核软件包。当前软件包目录支持上述 Debian/Ubuntu 版本的 amd64/x86_64，也支持 Debian 13 的 arm64/aarch64。

---

## 系统要求

最低实用要求：

- root 权限。
- 受支持的 Debian 或 Ubuntu 主机。
- `bash`、`apt-get`、`dpkg`、`uname`、`awk`、`sed`、`grep`、`sha256sum`。
- 能访问配置的 `RAW_BASE` 下载源。
- 使用 DKMS 算法时，需要 `dkms`、`build-essential`、`kmod`，以及与当前内核匹配的 `linux-headers-$(uname -r)`。脚本会尝试安装缺少的构建依赖和当前运行内核的精确匹配头文件；如果精确匹配的头文件不可用，会改为安装发行版通用内核镜像和头文件，并提示你重启后重新运行安装脚本。

建议运行前先执行：

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl
```

---

## 快速开始

```bash
bash <(wget -qO- https://raw.githubusercontent.com/jerry048/Trove/refs/heads/main/BBR-Install/BBRInstall.sh) --lang zh-CN --algo bbrx
```

在非交互模式中，请始终通过 `--algo` 或 `BBR_ALGO` 指定算法。

---

## 无头模式下的头文件回退

对于基于 DKMS 的算法，安装器会先检查 `/lib/modules/$(uname -r)/build`，然后尝试安装 `linux-headers-$(uname -r)`。如果当前运行内核的精确头文件仍然不可用，就会回退到发行版通用内核软件包：

| 平台 | 通用软件包 |
|---|---|
| Debian amd64/x86_64 | `linux-image-amd64` 和 `linux-headers-amd64` |
| Debian arm64/aarch64 | `linux-image-arm64` 和 `linux-headers-arm64` |
| Ubuntu | `linux-image-generic` 和 `linux-headers-generic` |

在终端会话中，这个提示默认选择 **是**。在无头/非交互模式下，安装器会直接执行，不再等待确认。安装通用内核镜像和头文件后，请重启进入新内核，再重新运行同一条安装命令。

---

## 语言

脚本默认使用英文输出。需要简体中文输出时，使用 `--lang zh-CN`，或设置 `BBR_LANG=zh-CN`：

```bash
sudo bash /tmp/BBRInstall.sh --lang zh-CN --algo bbrw
```

支持的语言值：

| 值 | 说明 |
|---|---|
| `en` | 英文，默认 |
| `zh-CN` | 简体中文 |

---

## 选项

```text
用法: BBRInstall.sh [选项]

选项:
  --algo ALGO           安装以下算法之一: bbrv3 bbrx bbrw bbr_brutal bbrw_brutal
  --raw-base URL        覆盖下载源 URL；也可使用 RAW_BASE=...
  --lang LANG           输出语言：en（默认）、zh-CN；也可使用 BBR_LANG=...
  --force-runtime       在容器/WSL 等不支持的环境中继续运行
  -h, --help            显示此帮助
```

### `--algo ALGO`

以非交互方式选择要安装的拥塞控制算法。

```bash
sudo bash /tmp/BBRInstall.sh --algo bbrx
```

支持的算法值：

| 算法 | 安装方式 | 实际配置的拥塞控制名称 | 是否需要重启 |
|---|---|---|---|
| `bbrv3` | 预编译内核 `.deb` 包 | `bbr` | 需要，必须重启进入新内核。 |
| `bbrx` | DKMS 内核模块 | `bbrx` | 通常不需要；模块会立即加载。 |
| `bbrw` | DKMS 内核模块 | `bbrw` | 通常不需要；模块会立即加载。 |
| `bbr_brutal` | DKMS 内核模块 | `bbr_brutal` | 通常不需要；模块会立即加载。 |
| `bbrw_brutal` | DKMS 内核模块 | `bbrw_brutal` | 通常不需要；模块会立即加载。 |

### `--raw-base URL`

覆盖用于下载内核软件包、DKMS 源代码、`Makefile`、`dkms.conf` 和校验文件的源地址。

为了更好地控制供应链风险，建议使用你信任的 fork，或锁定到特定 commit 的 raw URL，而不是长期跟随会变化的分支：

```bash
sudo bash /tmp/BBRInstall.sh \
  --algo bbrv3 \
  --raw-base 'https://raw.githubusercontent.com/<owner>/<repo>/<commit>/BBR-Install/BBR'
```

### `--lang LANG`

设置脚本输出语言。默认是英文。

```bash
sudo bash /tmp/BBRInstall.sh --lang zh-CN --algo bbrw
```

### `--force-runtime`

绕过容器/WSL 运行环境拦截。

此选项主要用于受控测试。在容器内安装内核软件包或 DKMS 模块通常不会影响宿主机内核，结果可能看起来成功但实际没有生效。

---

## 环境变量

大多数命令行选项也可以通过环境变量设置。

| 变量 | 用途 |
|---|---|
| `BBR_LANG` | 等同于 `--lang`。支持 `en`、`zh-CN`。默认值：`en`。 |
| `BBR_ALGO` | 等同于 `--algo`。 |
| `RAW_BASE` | 等同于 `--raw-base`。 |
| `BBR_SYSCTL_DROPIN` | 覆盖脚本管理的 sysctl drop-in 路径。默认：`/etc/sysctl.d/90-bbr-congestion-control.conf`。 |
| `BBR_SYSCTL_LEGACY_FILE` | 覆盖用于扫描冲突设置的旧版 sysctl 文件。默认：`/etc/sysctl.conf`。 |
| `BBR_MODULES_LOAD_DROPIN` | 覆盖脚本管理的模块自动加载文件。默认：`/etc/modules-load.d/90-bbr-congestion-control.conf`。 |
| `BBR_FORCE_UNSUPPORTED_RUNTIME=1` | 等同于 `--force-runtime`。 |
| `BBR_WORK_DIR` | 使用指定工作目录，而不是自动创建临时目录。 |
| `BBR_CLEAN_WORK_DIR=0` | 退出后保留工作目录，方便调试。 |
| `BBR_KERNEL_MIN_VERSION` | 高级/测试用途：覆盖 DKMS 内核最低版本。默认：`5.10`。 |
| `BBR_KERNEL_MAX_VERSION` | 高级/测试用途：覆盖 DKMS 内核最高版本。默认：`7.1.999`。 |
| `NO_COLOR=1` | 关闭彩色输出。 |

通过 `sudo` 使用环境变量时，请注意很多 sudo 配置默认不会保留环境变量。可以使用下面的写法：

```bash
sudo BBR_ALGO=bbrw BBR_LANG=zh-CN ./BBRInstall.sh
```

或：

```bash
sudo -E ./BBRInstall.sh
```

只有在你明确信任继承的环境变量时，才使用 `sudo -E`。

---

## 安装器会修改什么

- 对所有算法，脚本默认会写入 `/etc/sysctl.d/90-bbr-congestion-control.conf` 这个由它管理的 sysctl drop-in。
- 写入自己的 drop-in 之前，脚本会备份并注释掉 `/etc/sysctl.conf` 以及其他本地 sysctl drop-in 中冲突的 `net.ipv4.tcp_congestion_control` 项。
- 对 DKMS 算法，脚本默认会写入 `/etc/modules-load.d/90-bbr-congestion-control.conf`，确保模块在应用 sysctl 设置前自动加载。
- 如果当前内核头文件无法用于 DKMS 算法，脚本会安装发行版通用内核镜像和头文件。非交互/无头模式会自动执行这个回退；交互模式下直接按 Enter 会接受默认安装操作。安装后脚本会退出，因为必须先重启进入新内核，DKMS 才能继续编译模块。
- 对 `bbrv3`，脚本会删除它管理的模块自动加载文件，因为该算法由安装的新内核提供，而不是 DKMS 模块。

---

## 验证

查看当前启用的拥塞控制算法：

```bash
sysctl net.ipv4.tcp_congestion_control
```

查看当前内核可用的算法：

```bash
sysctl net.ipv4.tcp_available_congestion_control
```

如果安装的是 `bbrv3`，请先重启，然后检查正在运行的内核和拥塞控制设置：

```bash
uname -r
sysctl net.ipv4.tcp_congestion_control
```

如果安装的是 DKMS 算法，检查 DKMS 状态和模块状态：

```bash
dkms status | grep -E 'bbrx|bbrw|bbr_brutal|bbrw_brutal'
lsmod | grep '^tcp_'
sysctl net.ipv4.tcp_congestion_control
```

检查脚本管理的配置文件：

```bash
cat /etc/sysctl.d/90-bbr-congestion-control.conf
cat /etc/modules-load.d/90-bbr-congestion-control.conf 2>/dev/null || true
```

---

## 回滚和卸载

回滚方式取决于之前使用的安装方式。

### 恢复为发行版默认拥塞控制算法

大多数 Debian/Ubuntu 系统都支持 `cubic`。先确认它可用：

```bash
sysctl net.ipv4.tcp_available_congestion_control
```

然后切换当前会话：

```bash
sudo sysctl -w net.ipv4.tcp_congestion_control=cubic
```

删除或编辑脚本管理的 drop-in：

```bash
sudo rm -f /etc/sysctl.d/90-bbr-congestion-control.conf
```

也可以创建自己的替代 drop-in：

```bash
printf 'net.ipv4.tcp_congestion_control = cubic\n' | \
  sudo tee /etc/sysctl.d/90-tcp-congestion-control.conf
```

### 移除基于 DKMS 的算法

用 `dkms status` 显示的值替换 `<algo>` 和 `<version>`：

```bash
dkms status | grep -E 'bbrx|bbrw|bbr_brutal|bbrw_brutal'

sudo dkms remove -m <algo> -v <version> --all
sudo rm -f /etc/modules-load.d/90-bbr-congestion-control.conf
sudo rm -f /etc/sysctl.d/90-bbr-congestion-control.conf
sudo depmod -a
```

切换到其他算法后，再卸载模块：

```bash
sudo sysctl -w net.ipv4.tcp_congestion_control=cubic
sudo modprobe -r tcp_<algo>
```

以 `bbrw` 为例：

```bash
sudo sysctl -w net.ipv4.tcp_congestion_control=cubic
sudo modprobe -r tcp_bbrw
```

### 移除 bbrv3 内核软件包

不要清除当前正在运行的内核。请先启动到一个确认可用的发行版内核。

列出可能相关的已安装软件包：

```bash
dpkg -l 'linux-image*' 'linux-headers*' | grep -i bbr || true
uname -r
```

启动到其他内核后，再根据 `dpkg -l` 显示的软件包名清除 bbrv3 镜像和头文件软件包：

```bash
sudo apt-get purge 'linux-image-<bbrv3-kernel-package>' 'linux-headers-<bbrv3-kernel-package>'
sudo update-grub
sudo rm -f /etc/sysctl.d/90-bbr-congestion-control.conf
sudo reboot
```

上游软件包名可能会变化，请先确认 `dpkg -l` 的输出，再执行清除操作。

---

## 故障排查

### `Error: non-interactive mode requires --algo or BBR_ALGO.`

脚本运行时没有 TTY。请明确指定算法：

```bash
sudo bash /tmp/BBRInstall.sh --algo bbrw
```

### 无法安装 `linux-headers-$(uname -r)`

当前运行的内核可能没有对应的头文件软件包。脚本会先尝试安装精确匹配的 `linux-headers-$(uname -r)`；如果该软件包不存在或安装后仍不可用，就会回退到发行版通用内核镜像和头文件。

可用的检查命令：

```bash
uname -r
ls -ld /lib/modules/$(uname -r)/build
apt-cache policy linux-headers-$(uname -r)
```

如果找不到精确匹配的头文件，脚本会回退到发行版通用内核镜像和头文件。在无头/非交互模式下会直接自动安装；在交互模式下，提示的默认选择也是安装（`Y`）。安装后请重启进入新内核，再重新运行安装脚本。

### DKMS 构建失败

查看 DKMS 构建日志：

```bash
sudo find /var/lib/dkms -name make.log -print
sudo less /var/lib/dkms/<algo>/<version>/build/make.log
```

常见原因包括缺少头文件、内核版本不受支持、编译器不匹配，或上游源代码与当前内核不兼容。

### `modprobe` 失败

查看内核日志：

```bash
dmesg | tail -n 100
journalctl -k -n 100 --no-pager
```

如果启用了 Secure Boot，请确认是否阻止了未签名模块加载。

### `sysctl` 无法切换到所选算法

可能是拥塞控制模块尚未加载，或者当前内核不提供该算法。

检查可用算法：

```bash
sysctl net.ipv4.tcp_available_congestion_control
lsmod | grep '^tcp_'
```

对 DKMS 算法，可以尝试手动加载模块：

```bash
sudo modprobe tcp_bbrw
```

请把 `tcp_bbrw` 替换成所选算法对应的模块名。

### `bbrv3` 安装后重启仍未生效

确认机器是否已经启动到新内核：

```bash
uname -r
```

然后检查引导项，并在需要时重新生成 GRUB 配置：

```bash
sudo update-grub
```

部分云厂商或 VPS 面板会固定或覆盖启动内核。如果新内核没有出现在启动项里，请检查服务商的启动设置。
