#!/usr/bin/env bash
# BBR installer for Debian/Ubuntu.
#
# Debian 13 / trixie compatibility note:
# systemd-sysctl no longer reads /etc/sysctl.conf on Debian 13.  Local sysctl
# configuration is written to /etc/sysctl.d/*.conf instead.

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="${0##*/}"
DEFAULT_RAW_BASE="https://raw.githubusercontent.com/jerry048/Trove/refs/heads/main/BBR-Install/BBR"

# Environment overrides for advanced users / tests.
RAW_BASE="${RAW_BASE:-$DEFAULT_RAW_BASE}"
SYSCTL_DROPIN="${BBR_SYSCTL_DROPIN:-/etc/sysctl.d/90-bbr-congestion-control.conf}"
SYSCTL_LEGACY_FILE="${BBR_SYSCTL_LEGACY_FILE:-/etc/sysctl.conf}"
MODULES_LOAD_DROPIN="${BBR_MODULES_LOAD_DROPIN:-/etc/modules-load.d/90-bbr-congestion-control.conf}"
FORCE_UNSUPPORTED_RUNTIME="${BBR_FORCE_UNSUPPORTED_RUNTIME:-0}"
WORK_DIR="${BBR_WORK_DIR:-}"
CLEAN_WORK_DIR="${BBR_CLEAN_WORK_DIR:-auto}"
ALGO="${BBR_ALGO:-}"
KERNEL_MIN_VERSION="${BBR_KERNEL_MIN_VERSION:-5.10}"
KERNEL_MAX_VERSION="${BBR_KERNEL_MAX_VERSION:-7.1.999}"

SUPPORTED_ALGOS=("bbrv3" "bbrx" "bbrw" "bbr_brutal" "bbrw_brutal")
WORK_DIR_CREATED=""
WORK_DIR_IS_AUTO=0

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
	COLOR_INFO=$'\e[92m'
	COLOR_NOTE=$'\e[94m'
	COLOR_WARN=$'\e[93m'
	COLOR_FAIL=$'\e[91m'
	COLOR_RESET=$'\e[0m'
else
	COLOR_INFO=""
	COLOR_NOTE=""
	COLOR_WARN=""
	COLOR_FAIL=""
	COLOR_RESET=""
fi

info() { printf '%s%s%s\n' "$COLOR_INFO" "$*" "$COLOR_RESET"; }
note() { printf '%s%s%s\n' "$COLOR_NOTE" "$*" "$COLOR_RESET"; }
warn() { printf '%s%s%s\n' "$COLOR_WARN" "$*" "$COLOR_RESET" >&2; }
fail() { printf '%s%s%s\n' "$COLOR_FAIL" "$*" "$COLOR_RESET" >&2; }
die() { fail "$*"; exit 1; }

join_words() {
	local item output=""
	for item in "$@"; do
		output="${output:+$output }$item"
	done
	printf '%s' "$output"
}

separator() {
	local cols
	cols="$(tput cols 2>/dev/null || printf '80')"
	printf '\n%*s\n' "$cols" '' | tr ' ' '='
}

usage() {
	local algos
	algos="$(join_words "${SUPPORTED_ALGOS[@]}")"
	cat <<USAGE
Usage: $SCRIPT_NAME [options]

Options:
  --algo ALGO           Install one of: $algos
  --raw-base URL        Override source base URL. Can also use RAW_BASE=...
  --force-runtime       Continue in unsupported runtimes such as containers/WSL
  -h, --help            Show this help

Environment overrides:
  BBR_ALGO, RAW_BASE, BBR_SYSCTL_DROPIN, BBR_MODULES_LOAD_DROPIN,
  BBR_FORCE_UNSUPPORTED_RUNTIME=1,
  BBR_WORK_DIR, BBR_CLEAN_WORK_DIR=0
USAGE
}

cleanup() {
	if [[ -z "$WORK_DIR_CREATED" || ! -d "$WORK_DIR_CREATED" ]]; then
		return 0
	fi

	if [[ "$CLEAN_WORK_DIR" == "1" || ( "$CLEAN_WORK_DIR" == "auto" && "$WORK_DIR_IS_AUTO" == "1" ) ]]; then
		rm -rf -- "$WORK_DIR_CREATED"
	fi
}
trap cleanup EXIT

parse_args() {
	while (($#)); do
		case "$1" in
			--algo)
				shift
				[[ $# -gt 0 ]] || die "错误: --algo 需要参数."
				ALGO="$1"
				;;
			--algo=*)
				ALGO="${1#*=}"
				;;
			--raw-base)
				shift
				[[ $# -gt 0 ]] || die "错误: --raw-base 需要参数."
				RAW_BASE="${1%/}"
				;;
			--raw-base=*)
				RAW_BASE="${1#*=}"
				RAW_BASE="${RAW_BASE%/}"
				;;
			--force-runtime)
				FORCE_UNSUPPORTED_RUNTIME=1
				;;
			-h|--help)
				usage
				exit 0
				;;
			*)
				die "错误: 未知参数: $1"
				;;
		esac
		shift
	done
}

is_supported_algo() {
	local candidate="$1"
	local algo
	for algo in "${SUPPORTED_ALGOS[@]}"; do
		[[ "$candidate" == "$algo" ]] && return 0
	done
	return 1
}

choose_algo() {
	if [[ -n "$ALGO" ]]; then
		is_supported_algo "$ALGO" || die "错误: 不支持的拥塞控制算法: $ALGO"
		return 0
	fi

	[[ -t 0 ]] || die "错误: 非交互模式下请使用 --algo 或 BBR_ALGO 指定算法."

	info "请选择要安装的拥塞控制算法:"
	select selected_algo in "${SUPPORTED_ALGOS[@]}"; do
		if is_supported_algo "${selected_algo:-}"; then
			ALGO="$selected_algo"
			break
		fi
		fail "错误: 无效的选择."
	done
}

require_root() {
	[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "错误: 脚本需要 root 运行."
}

require_command() {
	command -v "$1" >/dev/null 2>&1 || die "错误: 缺少必需命令: $1"
}

apt_update() {
	export DEBIAN_FRONTEND=noninteractive
	info "正在更新 APT 软件包索引..."
	apt-get update >/dev/null
}

apt_install() {
	export DEBIAN_FRONTEND=noninteractive
	apt-get install -y --no-install-recommends "$@"
}

lowercase() {
	printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

parse_major_version() {
	local version="$1"
	if [[ "$version" =~ ^([0-9]+) ]]; then
		printf '%s' "${BASH_REMATCH[1]}"
	fi
}

OS_ID=""
OS_NAME=""
OS_VERSION_ID=""
OS_VERSION_MAJOR=""
OS_CODENAME=""
OS_ARCH=""
KERNEL=""
KERNEL_BASE=""
VIRT_KIND="unknown"
VIRT_TYPE="unknown"

collect_system_info() {
	local name="" id="" version_id="" version_codename="" ubuntu_codename=""

	if [[ -r /etc/os-release ]]; then
		# shellcheck disable=SC1091
		. /etc/os-release
		name="${NAME:-}"
		id="${ID:-}"
		version_id="${VERSION_ID:-}"
		version_codename="${VERSION_CODENAME:-}"
		ubuntu_codename="${UBUNTU_CODENAME:-}"
	elif command -v lsb_release >/dev/null 2>&1; then
		name="$(lsb_release -si 2>/dev/null || true)"
		id="$name"
		version_id="$(lsb_release -sr 2>/dev/null || true)"
		version_codename="$(lsb_release -sc 2>/dev/null || true)"
	elif [[ -r /etc/debian_version ]]; then
		name="Debian"
		id="debian"
		version_id="$(cat /etc/debian_version)"
	else
		die "错误: 无法识别系统发行版. 本脚本仅支持 Debian/Ubuntu."
	fi

	OS_ID="$(lowercase "$id")"
	OS_NAME="${name:-$OS_ID}"
	OS_VERSION_ID="$version_id"
	OS_VERSION_MAJOR="$(parse_major_version "$OS_VERSION_ID")"
	OS_CODENAME="${version_codename:-$ubuntu_codename}"
	OS_ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
	KERNEL="$(uname -r)"
	KERNEL_BASE="$(printf '%s' "$KERNEL" | sed -E 's/^([0-9]+(\.[0-9]+){1,2}).*/\1/')"

	if command -v systemd-detect-virt >/dev/null 2>&1; then
		if systemd-detect-virt --quiet --container; then
			VIRT_KIND="container"
			VIRT_TYPE="$(systemd-detect-virt --container 2>/dev/null || printf 'container')"
		elif systemd-detect-virt --quiet --vm; then
			VIRT_KIND="vm"
			VIRT_TYPE="$(systemd-detect-virt --vm 2>/dev/null || printf 'vm')"
		else
			VIRT_KIND="none"
			VIRT_TYPE="none"
		fi
	elif grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then
		VIRT_KIND="wsl"
		VIRT_TYPE="wsl"
	else
		VIRT_KIND="unknown"
		VIRT_TYPE="unknown"
	fi
}

check_supported_os() {
	case "$OS_ID" in
		debian)
			case "$OS_VERSION_MAJOR" in
				11|12|13) ;;
				*) die "错误: 本脚本仅支持 Debian 11/12/13. 当前版本: ${OS_VERSION_ID:-unknown}" ;;
			esac
			;;
		ubuntu)
			case "$OS_VERSION_ID" in
				22.04*|24.04*|26.04*) ;;
				*) die "错误: 本脚本仅支持 Ubuntu 22.04/24.04/26.04. 当前版本: ${OS_VERSION_ID:-unknown}" ;;
			esac
			;;
		*)
			die "错误: 本脚本仅支持 Debian/Ubuntu. 当前系统: ${OS_NAME:-unknown} (${OS_ID:-unknown})"
			;;
	esac
}

check_supported_runtime() {
	if [[ "$FORCE_UNSUPPORTED_RUNTIME" == "1" ]]; then
		warn "警告: 已使用 --force-runtime，跳过运行环境限制检查。"
		return 0
	fi

	case "$VIRT_KIND" in
		container)
			die "错误: 检测到容器环境 ($VIRT_TYPE)。安装内核/DKMS 模块需要宿主机或完整虚拟机。"
			;;
		wsl)
			die "错误: 检测到 WSL 环境。WSL 不适合安装此类内核/DKMS 模块。"
			;;
		unknown)
			warn "警告: 无法识别虚拟化环境，继续前请确认这是宿主机或完整虚拟机。"
			;;
		*) ;;
	esac
}

print_system_info() {
	separator
	info "系统信息:"
	note "  发行版: ${OS_NAME:-unknown} ${OS_VERSION_ID:-unknown} ${OS_CODENAME:+($OS_CODENAME)}"
	note "  架构:   ${OS_ARCH:-unknown}"
	note "  内核:   ${KERNEL:-unknown}"
	note "  环境:   ${VIRT_KIND:-unknown}/${VIRT_TYPE:-unknown}"
}

ensure_download_tools() {
	if command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; then
		return 0
	fi

	info "正在安装下载工具..."
	apt_install ca-certificates curl || apt_install ca-certificates wget

	command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || die "错误: 安装 curl/wget 失败."
}

fetch_optional() {
	local url="$1"
	local output="$2"

	rm -f -- "$output"
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL --retry 3 --connect-timeout 15 --output "$output" "$url" || return 1
	else
		wget -q --tries=3 --timeout=30 -O "$output" "$url" || return 1
	fi

	if [[ ! -s "$output" ]]; then
		rm -f -- "$output"
		return 1
	fi
}

fetch() {
	local url="$1"
	local output="$2"

	fetch_optional "$url" "$output" || die "错误: 下载失败或文件为空: $url"
}

create_work_dir() {
	if [[ -n "$WORK_DIR_CREATED" ]]; then
		return 0
	fi

	if [[ -n "$WORK_DIR" ]]; then
		mkdir -p -- "$WORK_DIR"
		WORK_DIR_CREATED="$WORK_DIR"
		WORK_DIR_IS_AUTO=0
	else
		WORK_DIR_CREATED="$(mktemp -d -t bbr-install.XXXXXX)"
		WORK_DIR_IS_AUTO=1
	fi
}

backup_file_once() {
	local file="$1"
	local stamp backup
	[[ -f "$file" ]] || return 0
	stamp="$(date +%Y%m%d%H%M%S)"
	backup="${file}.bbrinstall.${stamp}.bak"
	cp -a -- "$file" "$backup"
	note "已备份: $file -> $backup"
}

comment_conflicting_sysctl_key() {
	local file="$1"
	local key_regex='net[./]ipv4[./]tcp_congestion_control'

	[[ -f "$file" ]] || return 0
	[[ "$file" != "$SYSCTL_DROPIN" ]] || return 0

	if grep -Eq "^[[:space:]]*-?[[:space:]]*${key_regex}[[:space:]]*=" "$file"; then
		backup_file_once "$file"
		sed -i -E "s|^([[:space:]]*)(-?[[:space:]]*${key_regex}[[:space:]]*=.*)|\1# BBRInstall disabled conflicting setting: \2|" "$file"
		note "已注释本地冲突 sysctl 项: $file"
	fi
}

comment_local_conflicting_sysctls() {
	local sysctl_dir
	sysctl_dir="$(dirname -- "$SYSCTL_DROPIN")"

	comment_conflicting_sysctl_key "$SYSCTL_LEGACY_FILE"

	if [[ -d "$sysctl_dir" ]]; then
		local file
		for file in "$sysctl_dir"/*.conf; do
			[[ -e "$file" ]] || continue
			comment_conflicting_sysctl_key "$file"
		done
	fi
}

configure_sysctl_cc() {
	local cc_algo="$1"
	local sysctl_dir
	sysctl_dir="$(dirname -- "$SYSCTL_DROPIN")"

	[[ "$cc_algo" =~ ^[A-Za-z0-9_]+$ ]] || die "错误: 非法的拥塞控制算法名称: $cc_algo"

	mkdir -p -- "$sysctl_dir"
	comment_local_conflicting_sysctls

	cat > "$SYSCTL_DROPIN" <<EOF_SYSCTL
# Managed by BBRInstall.
# Debian 13/trixie: systemd-sysctl no longer reads /etc/sysctl.conf.
# Keep local kernel parameter overrides in /etc/sysctl.d/*.conf.
net.ipv4.tcp_congestion_control = $cc_algo
EOF_SYSCTL
	chmod 0644 "$SYSCTL_DROPIN"
	note "已写入 sysctl 配置: $SYSCTL_DROPIN"

	if sysctl -w "net.ipv4.tcp_congestion_control=$cc_algo" >/dev/null 2>&1; then
		note "当前会话已切换拥塞控制算法为: $cc_algo"
	else
		warn "警告: 已写入持久化配置，但当前内核暂时无法切换到 $cc_algo。重启或加载对应模块后会再次尝试生效。"
	fi
}

configure_module_autoload() {
	local module_name="$1"
	local modules_dir
	modules_dir="$(dirname -- "$MODULES_LOAD_DROPIN")"

	mkdir -p -- "$modules_dir"
	cat > "$MODULES_LOAD_DROPIN" <<EOF_MODULES
# Managed by BBRInstall.
# Load the DKMS congestion-control module before sysctl.d settings are applied.
$module_name
EOF_MODULES
	chmod 0644 "$MODULES_LOAD_DROPIN"
	note "已写入模块自动加载配置: $MODULES_LOAD_DROPIN"
}

remove_managed_module_autoload() {
	if [[ -f "$MODULES_LOAD_DROPIN" ]]; then
		rm -f -- "$MODULES_LOAD_DROPIN"
		note "已移除旧的模块自动加载配置: $MODULES_LOAD_DROPIN"
	fi
}

resolve_bbrv3_candidate_dirs() {
	# Current bbrv3 packages are grouped by architecture, for example:
	#   bbrv3/x86_64/debian13-amd64
	#   bbrv3/ARM64/debian13-arm64
	# Keep legacy top-level paths as fallbacks so older mirrors continue to work.
	case "$OS_ARCH" in
		amd64|x86_64)
			case "$OS_ID:$OS_VERSION_MAJOR" in
				debian:11) printf '%s\n' "x86_64/debian11-amd64" "debian11-amd64" ;;
				debian:12) printf '%s\n' "x86_64/debian12-amd64" "debian12-amd64" ;;
				debian:13) printf '%s\n' "x86_64/debian13-amd64" "debian13-amd64" ;;
				ubuntu:22) printf '%s\n' "x86_64/ubuntu2204-generic" "ubuntu2204-generic" ;;
				ubuntu:24) printf '%s\n' "x86_64/ubuntu2404-generic" "ubuntu2404-generic" ;;
				ubuntu:26) printf '%s\n' "x86_64/ubuntu2604-generic" "ubuntu2604-generic" ;;
				*) die "错误: 未找到适用于 ${OS_NAME:-$OS_ID} ${OS_VERSION_ID:-unknown} $OS_ARCH 的 bbrv3 软件包目录." ;;
			esac
			;;
		arm64|aarch64)
			case "$OS_ID:$OS_VERSION_MAJOR" in
				debian:13) printf '%s\n' "ARM64/debian13-arm64" "debian13-arm64" ;;
				*) die "错误: bbrv3 ARM64 预编译内核包当前仅支持 Debian 13. 当前系统: ${OS_NAME:-$OS_ID} ${OS_VERSION_ID:-unknown}, 架构: $OS_ARCH" ;;
			esac
			;;
		*)
			die "错误: bbrv3 预编译内核包当前仅支持 amd64/x86_64 与 arm64/aarch64. 当前架构: $OS_ARCH"
			;;
	esac
}

extract_checksum_filename() {
	awk '{print $2}' "$1" | sed -e 's#^\*##' -e 's#^\./##'
}

write_selected_sha256sums() {
	local checksum_file="$1"
	local output_file="$2"
	shift 2
	local wanted_csv="," wanted_file
	for wanted_file in "$@"; do
		wanted_csv+="${wanted_file},"
	done

	awk -v wanted="$wanted_csv" '
		{
			file=$2
			sub(/^\*/, "", file)
			sub(/^\.\//, "", file)
			if (index(wanted, "," file ",") > 0) {
				print $1 "  " file
			}
		}
	' "$checksum_file" > "$output_file"
}

install_bbrv3_deb() {
	local pkg_dir pkg_base selected_pkg_dir work headers_deb image_deb sha_selected
	local -a pkg_candidates=()

	ensure_download_tools
	create_work_dir
	work="$WORK_DIR_CREATED/bbrv3"
	mkdir -p -- "$work"
	cd "$work"

	mapfile -t pkg_candidates < <(resolve_bbrv3_candidate_dirs)
	[[ ${#pkg_candidates[@]} -gt 0 ]] || die "错误: 未找到适用于当前系统的 bbrv3 软件包目录候选."

	separator
	info "正在下载 bbrv3 内核 Debian 软件包..."
	for pkg_dir in "${pkg_candidates[@]}"; do
		pkg_base="$RAW_BASE/bbrv3/$pkg_dir"
		note "尝试 bbrv3 软件包目录: bbrv3/$pkg_dir"
		if fetch_optional "$pkg_base/SHA256SUMS" "SHA256SUMS"; then
			selected_pkg_dir="$pkg_dir"
			break
		fi
	done

	[[ -n "${selected_pkg_dir:-}" ]] || die "错误: 无法从任何候选目录下载 bbrv3 SHA256SUMS: $(join_words "${pkg_candidates[@]}")"
	pkg_base="$RAW_BASE/bbrv3/$selected_pkg_dir"
	note "已选择 bbrv3 软件包目录: bbrv3/$selected_pkg_dir"

	headers_deb="$(extract_checksum_filename SHA256SUMS | grep -E '^linux-headers-.*\.deb$' | head -n 1 || true)"
	image_deb="$(extract_checksum_filename SHA256SUMS | grep -E '^linux-image-.*\.deb$' | head -n 1 || true)"

	[[ -n "$headers_deb" && -n "$image_deb" ]] || die "错误: 无法从 SHA256SUMS 中识别 linux-headers/linux-image 软件包."

	fetch "$pkg_base/$headers_deb" "$headers_deb"
	fetch "$pkg_base/$image_deb" "$image_deb"

	sha_selected="SHA256SUMS.selected"
	write_selected_sha256sums "SHA256SUMS" "$sha_selected" "$headers_deb" "$image_deb"
	[[ -s "$sha_selected" ]] || die "错误: 无法生成待校验文件列表."

	sha256sum -c "$sha_selected" >/dev/null || die "错误: SHA256 校验失败."
	note "bbrv3 内核软件包下载并校验完成."

	separator
	info "正在安装 bbrv3 内核软件包..."
	apt-get install -y "./$image_deb" "./$headers_deb"

	if command -v update-grub >/dev/null 2>&1; then
		update-grub >/dev/null
	fi

	remove_managed_module_autoload
	# BBRv3 kernel packages expose the congestion control as bbr.
	configure_sysctl_cc "bbr"

	separator
	info "bbrv3 内核软件包已成功安装。请重启系统以进入 bbrv3 内核。"
	note "重启后可使用: uname -r && sysctl net.ipv4.tcp_congestion_control"
}

check_kernel_for_dkms() {
	[[ "$KERNEL_BASE" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || die "错误: 无法解析当前内核版本: $KERNEL"

	if ! dpkg --compare-versions "$KERNEL_BASE" ge "$KERNEL_MIN_VERSION" || \
	   ! dpkg --compare-versions "$KERNEL_BASE" le "$KERNEL_MAX_VERSION"; then
		die "错误: DKMS 模块仅支持内核版本 [$KERNEL_MIN_VERSION - 7.1.x]. 当前内核: $KERNEL"
	fi
}

ensure_build_prereqs() {
	local packages=()

	command -v dkms >/dev/null 2>&1 || packages+=(dkms)
	command -v make >/dev/null 2>&1 || packages+=(build-essential)
	command -v gcc >/dev/null 2>&1 || packages+=(build-essential)
	command -v modprobe >/dev/null 2>&1 || packages+=(kmod)
	command -v sha256sum >/dev/null 2>&1 || packages+=(coreutils)

	if ((${#packages[@]})); then
		info "正在安装构建依赖: $(join_words "${packages[@]}")"
		apt_install "${packages[@]}"
	fi
}

resolve_generic_kernel_packages() {
	case "$OS_ID" in
		debian)
			case "$OS_ARCH" in
				amd64|x86_64)
					printf '%s\n' "linux-image-amd64" "linux-headers-amd64"
					;;
				arm64|aarch64)
					printf '%s\n' "linux-image-arm64" "linux-headers-arm64"
					;;
				*)
					return 1
					;;
			esac
			;;
		ubuntu)
			printf '%s\n' "linux-image-generic" "linux-headers-generic"
			;;
		*)
			return 1
			;;
	esac
}

install_generic_kernel_and_exit() {
	local image_pkg headers_pkg answer generic_output
	local -a generic_packages=()

	if ! generic_output="$(resolve_generic_kernel_packages)"; then
		die "错误: 未找到适用于 ${OS_NAME:-$OS_ID} ${OS_ARCH:-unknown} 的通用内核/头文件包。请手动安装与当前内核匹配的 headers 包。"
	fi
	mapfile -t generic_packages <<< "$generic_output"

	image_pkg="${generic_packages[0]:-}"
	headers_pkg="${generic_packages[1]:-}"
	[[ -n "$image_pkg" && -n "$headers_pkg" ]] || die "错误: 无法解析通用内核/头文件包名。"

	separator
	warn "警告: 未找到或无法使用当前运行内核的头文件: linux-headers-${KERNEL}"
	note "可以改为安装发行版通用内核镜像和头文件:"
	note "  内核镜像: $image_pkg"
	note "  内核头文件: $headers_pkg"
	warn "安装后必须重启进入新内核，然后重新运行本脚本，DKMS 模块才能继续编译安装。"

	if [[ ! -t 0 ]]; then
		die "错误: 非交互模式无法确认安装通用内核。请手动运行: apt-get install -y $image_pkg $headers_pkg，然后重启并重新运行本脚本。"
	fi

	printf '%s' "是否现在安装通用内核镜像和头文件？[y/N]: "
	read -r answer
	case "$(lowercase "$answer")" in
		y|yes)
			info "正在安装通用内核镜像和头文件: $image_pkg $headers_pkg"
			apt_install "$image_pkg" "$headers_pkg" || die "错误: 安装通用内核/头文件失败: $image_pkg $headers_pkg"
			if command -v update-grub >/dev/null 2>&1; then
				update-grub >/dev/null || warn "警告: update-grub 执行失败，请确认引导配置。"
			fi
			separator
			info "通用内核镜像和头文件已安装。"
			note "请现在重启系统，然后重新运行本脚本。"
			note "重启后可使用: uname -r && ls -l /lib/modules/\$(uname -r)/build"
			note "重新运行示例: ./$SCRIPT_NAME --algo $ALGO"
			exit 0
			;;
		*)
			die "已取消安装通用内核。请安装与当前内核匹配的 headers 包，或安装 $image_pkg $headers_pkg 后重启并重新运行本脚本。"
			;;
	esac
}

ensure_kernel_headers() {
	local build_dir headers_dir
	build_dir="/lib/modules/${KERNEL}/build"
	headers_dir="/usr/src/linux-headers-${KERNEL}"

	if [[ ! -e "$build_dir" && -d "$headers_dir" ]]; then
		mkdir -p -- "/lib/modules/${KERNEL}"
		ln -s -- "$headers_dir" "$build_dir"
	fi

	if [[ -e "$build_dir/Makefile" ]]; then
		note "检测到当前内核头文件: $build_dir"
		return 0
	fi

	info "正在安装当前内核头文件: linux-headers-${KERNEL}"
	if apt_install "linux-headers-${KERNEL}"; then
		if [[ ! -e "$build_dir" && -d "$headers_dir" ]]; then
			mkdir -p -- "/lib/modules/${KERNEL}"
			ln -s -- "$headers_dir" "$build_dir"
		fi

		if [[ -e "$build_dir/Makefile" ]]; then
			note "当前内核头文件检查通过: $build_dir"
			return 0
		fi

		warn "警告: linux-headers-${KERNEL} 已安装/尝试安装，但 $build_dir 不可用于 DKMS。"
	else
		warn "警告: 未找到或无法安装当前运行内核的头文件包: linux-headers-${KERNEL}。"
	fi

	install_generic_kernel_and_exit
}

remove_existing_dkms_module() {
	local module="$1"
	local installed_ver_dir installed_ver

	[[ -d "/var/lib/dkms/$module" ]] || return 0

	info "检测到现有的 $module DKMS 模块，正在卸载旧版本..."
	for installed_ver_dir in "/var/lib/dkms/$module"/*; do
		[[ -d "$installed_ver_dir" ]] || continue
		installed_ver="$(basename -- "$installed_ver_dir")"
		dkms remove -m "$module" -v "$installed_ver" --all >/dev/null || die "错误: 卸载 $module/$installed_ver 失败."
	done
}

download_dkms_source() {
	local src_dir="$1"
	mkdir -p -- "$src_dir"

	fetch "$RAW_BASE/$ALGO/tcp_$ALGO.c" "$src_dir/tcp_$ALGO.c"
	fetch "$RAW_BASE/$ALGO/dkms.conf" "$src_dir/dkms.conf"
	fetch "$RAW_BASE/$ALGO/Makefile" "$src_dir/Makefile"
}

install_dkms_bbr() {
	local module_name module_version src_dir dkms_src_dir
	module_name="tcp_${ALGO}"
	module_version="$KERNEL_BASE"

	check_kernel_for_dkms
	ensure_build_prereqs
	ensure_kernel_headers
	ensure_download_tools
	note "系统支持检查通过."

	create_work_dir
	src_dir="$WORK_DIR_CREATED/src"

	separator
	info "正在下载 $ALGO 拥塞控制模块源代码..."
	download_dkms_source "$src_dir"
	note "源代码下载完成."

	separator
	info "正在编译并安装 $ALGO 拥塞控制模块..."
	remove_existing_dkms_module "$ALGO"

	dkms_src_dir="/usr/src/${ALGO}-${module_version}"
	rm -rf -- "$dkms_src_dir"
	mkdir -p -- "$dkms_src_dir"
	cp -a "$src_dir/." "$dkms_src_dir/"

	if ! dkms add -m "$ALGO" -v "$module_version" >/dev/null; then
		dkms remove -m "$ALGO" -v "$module_version" --all >/dev/null 2>&1 || true
		die "错误: DKMS 无法添加内核模块."
	fi

	if ! dkms build -m "$ALGO" -v "$module_version" >/dev/null; then
		dkms remove -m "$ALGO" -v "$module_version" --all >/dev/null 2>&1 || true
		die "错误: 构建 DKMS 模块失败."
	fi

	if ! dkms install -m "$ALGO" -v "$module_version" >/dev/null; then
		dkms remove -m "$ALGO" -v "$module_version" --all >/dev/null 2>&1 || true
		die "错误: DKMS 无法安装内核模块."
	fi

	depmod -a "$KERNEL" >/dev/null 2>&1 || true

	if ! modprobe "$module_name"; then
		dkms remove -m "$ALGO" -v "$module_version" --all >/dev/null 2>&1 || true
		die "错误: 加载模块失败: $module_name"
	fi

	separator
	if grep -q "^${module_name}[[:space:]]" /proc/modules; then
		info "$ALGO 拥塞控制模块已成功安装并加载。无需重启即可尝试生效。"
	else
		dkms remove -m "$ALGO" -v "$module_version" --all >/dev/null 2>&1 || true
		die "错误: 模块未出现在 /proc/modules: $module_name"
	fi

	configure_module_autoload "$module_name"
	configure_sysctl_cc "$ALGO"
}

main() {
	parse_args "$@"

	clear

	choose_algo
	require_root
	require_command apt-get
	require_command dpkg
	require_command uname
	require_command awk
	require_command sed
	require_command grep
	require_command sha256sum

	collect_system_info
	print_system_info

	separator
	info "正在检查系统支持状态..."
	check_supported_os
	check_supported_runtime
	apt_update

	if [[ "$ALGO" == "bbrv3" ]]; then
		note "系统支持检查通过."
		install_bbrv3_deb
	else
		install_dkms_bbr
	fi
}

main "$@"
