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
LANG_CODE="${BBR_LANG:-en}"
SHOW_HELP=0

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

normalize_lang() {
	case "${1:-en}" in
		en|en-US|en_US|en-us|en_us) printf '%s' "en" ;;
		zh|zh-CN|zh_CN|zh-cn|zh_cn|zh-Hans|zh_Hans|zh-hans|zh_hans|cn|simplified|simplified-chinese) printf '%s' "zh-CN" ;;
		*) return 1 ;;
	esac
}

set_language() {
	local requested="${1:-en}" normalized
	if ! normalized="$(normalize_lang "$requested")"; then
		die "Error: unsupported language: $requested (supported: en, zh-CN)"
	fi
	LANG_CODE="$normalized"
}

l10n() {
	local zh_cn="$1" en="$2"
	if [[ "$LANG_CODE" == "zh-CN" ]]; then
		printf '%s' "$zh_cn"
	else
		printf '%s' "$en"
	fi
}

set_language "$LANG_CODE"

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

	if [[ "$LANG_CODE" == "zh-CN" ]]; then
		cat <<USAGE
用法: $SCRIPT_NAME [选项]

选项:
  --algo ALGO           安装下列任一算法: $algos
  --raw-base URL        覆盖下载源基础 URL；也可使用 RAW_BASE=...
  --lang LANG           输出语言: en（默认）、zh-CN；也可使用 BBR_LANG=...
  --force-runtime       在容器/WSL 等不支持的环境中仍继续运行
  -h, --help            显示此说明

环境变量覆盖:
  BBR_LANG=en|zh-CN, BBR_ALGO, RAW_BASE,
  BBR_SYSCTL_DROPIN, BBR_SYSCTL_LEGACY_FILE,
  BBR_MODULES_LOAD_DROPIN, BBR_FORCE_UNSUPPORTED_RUNTIME=1,
  BBR_WORK_DIR, BBR_CLEAN_WORK_DIR=0,
  BBR_KERNEL_MIN_VERSION, BBR_KERNEL_MAX_VERSION, NO_COLOR=1
USAGE
	else
		cat <<USAGE
Usage: $SCRIPT_NAME [options]

Options:
  --algo ALGO           Install one of: $algos
  --raw-base URL        Override source base URL. Can also use RAW_BASE=...
  --lang LANG           Output language: en (default), zh-CN. Can also use BBR_LANG=...
  --force-runtime       Continue in unsupported runtimes such as containers/WSL
  -h, --help            Show this help

Environment overrides:
  BBR_LANG=en|zh-CN, BBR_ALGO, RAW_BASE,
  BBR_SYSCTL_DROPIN, BBR_SYSCTL_LEGACY_FILE,
  BBR_MODULES_LOAD_DROPIN, BBR_FORCE_UNSUPPORTED_RUNTIME=1,
  BBR_WORK_DIR, BBR_CLEAN_WORK_DIR=0,
  BBR_KERNEL_MIN_VERSION, BBR_KERNEL_MAX_VERSION, NO_COLOR=1
USAGE
	fi
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
				[[ $# -gt 0 ]] || die "$(l10n "错误：--algo 需要参数。" "Error: --algo requires a value.")"
				ALGO="$1"
				;;
			--algo=*)
				ALGO="${1#*=}"
				;;
			--raw-base)
				shift
				[[ $# -gt 0 ]] || die "$(l10n "错误：--raw-base 需要参数。" "Error: --raw-base requires a value.")"
				RAW_BASE="${1%/}"
				;;
			--raw-base=*)
				RAW_BASE="${1#*=}"
				RAW_BASE="${RAW_BASE%/}"
				;;
			--lang)
				shift
				[[ $# -gt 0 ]] || die "$(l10n "错误：--lang 需要参数。" "Error: --lang requires a value.")"
				set_language "$1"
				;;
			--lang=*)
				set_language "${1#*=}"
				;;
			--force-runtime)
				FORCE_UNSUPPORTED_RUNTIME=1
				;;
			-h|--help)
				SHOW_HELP=1
				;;
			*)
				die "$(l10n "错误：未知参数：$1" "Error: unknown argument: $1")"
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
		is_supported_algo "$ALGO" || die "$(l10n "错误：不支持的拥塞控制算法：$ALGO" "Error: unsupported congestion-control algorithm: $ALGO")"
		return 0
	fi

	[[ -t 0 ]] || die "$(l10n "错误：非交互模式请使用 --algo 或 BBR_ALGO 指定算法。" "Error: non-interactive mode requires --algo or BBR_ALGO.")"

	info "$(l10n "请选择要安装的拥塞控制算法：" "Select the congestion-control algorithm to install:")"
	local PS3
	PS3="$(l10n "请输入编号：" "Enter selection number: ")"
	select selected_algo in "${SUPPORTED_ALGOS[@]}"; do
		if is_supported_algo "${selected_algo:-}"; then
			ALGO="$selected_algo"
			break
		fi
		fail "$(l10n "错误：无效的选择。" "Error: invalid selection.")"
	done
}

require_root() {
	[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "$(l10n "错误：此脚本必须以 root 身份运行。" "Error: this script must be run as root.")"
}

require_command() {
	command -v "$1" >/dev/null 2>&1 || die "$(l10n "错误：缺少必要命令：$1" "Error: required command not found: $1")"
}

apt_update() {
	export DEBIAN_FRONTEND=noninteractive
	info "$(l10n "正在更新 APT 软件包索引..." "Updating APT package indexes...")"
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
		die "$(l10n "错误：无法识别系统发行版。本脚本仅支持 Debian/Ubuntu。" "Error: could not identify the OS distribution. This script supports Debian/Ubuntu only.")"
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
				*) die "$(l10n "错误：本脚本仅支持 Debian 11/12/13。当前版本：${OS_VERSION_ID:-unknown}" "Error: this script supports Debian 11/12/13 only. Current version: ${OS_VERSION_ID:-unknown}")" ;;
			esac
			;;
		ubuntu)
			case "$OS_VERSION_ID" in
				20.04*|22.04*|24.04*|26.04*) ;;
				*) die "$(l10n "错误：本脚本仅支持 Ubuntu 20.04/22.04/24.04/26.04。当前版本：${OS_VERSION_ID:-unknown}" "Error: this script supports Ubuntu 20.04/22.04/24.04/26.04 only. Current version: ${OS_VERSION_ID:-unknown}")" ;;
			esac
			;;
		*)
			die "$(l10n "错误：本脚本仅支持 Debian/Ubuntu。当前系统：${OS_NAME:-unknown} (${OS_ID:-unknown})" "Error: this script supports Debian/Ubuntu only. Current system: ${OS_NAME:-unknown} (${OS_ID:-unknown})")"
			;;
	esac
}

check_supported_runtime() {
	if [[ "$FORCE_UNSUPPORTED_RUNTIME" == "1" ]]; then
		warn "$(l10n "警告：已使用 --force-runtime，将跳过运行环境限制检查。" "Warning: --force-runtime was used; skipping runtime safety checks.")"
		return 0
	fi

	case "$VIRT_KIND" in
		container)
			die "$(l10n "错误：检测到容器环境 ($VIRT_TYPE)。安装内核/DKMS 模块需要宿主机或完整虚拟机。" "Error: container environment detected ($VIRT_TYPE). Installing kernel/DKMS modules requires the host or a full VM.")"
			;;
		wsl)
			die "$(l10n "错误：检测到 WSL 环境。WSL 不适合安装这类内核/DKMS 模块。" "Error: WSL environment detected. WSL is not suitable for this kind of kernel/DKMS module installation.")"
			;;
		unknown)
			warn "$(l10n "警告：无法识别虚拟化环境，继续前请确认这是宿主机或完整虚拟机。" "Warning: could not identify the virtualization environment; make sure this is the host or a full VM before continuing.")"
			;;
		*) ;;
	esac
}

print_system_info() {
	separator
	info "$(l10n "系统信息：" "System information:")"
	note "$(l10n "  发行版：${OS_NAME:-unknown} ${OS_VERSION_ID:-unknown} ${OS_CODENAME:+($OS_CODENAME)}" "  Distribution: ${OS_NAME:-unknown} ${OS_VERSION_ID:-unknown} ${OS_CODENAME:+($OS_CODENAME)}")"
	note "$(l10n "  架构：  ${OS_ARCH:-unknown}" "  Architecture: ${OS_ARCH:-unknown}")"
	note "$(l10n "  内核：  ${KERNEL:-unknown}" "  Kernel:       ${KERNEL:-unknown}")"
	note "$(l10n "  环境：  ${VIRT_KIND:-unknown}/${VIRT_TYPE:-unknown}" "  Runtime:      ${VIRT_KIND:-unknown}/${VIRT_TYPE:-unknown}")"
}

ensure_download_tools() {
	if command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; then
		return 0
	fi

	info "$(l10n "正在安装下载工具..." "Installing download tools...")"
	apt_install ca-certificates curl || apt_install ca-certificates wget

	command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || die "$(l10n "错误：安装 curl/wget 失败。" "Error: failed to install curl/wget.")"
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

	fetch_optional "$url" "$output" || die "$(l10n "错误：下载失败或文件为空：$url" "Error: download failed or file is empty: $url")"
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
	note "$(l10n "已备份：$file -> $backup" "Backed up: $file -> $backup")"
}

comment_conflicting_sysctl_key() {
	local file="$1"
	local key_regex='net[./]ipv4[./]tcp_congestion_control'

	[[ -f "$file" ]] || return 0
	[[ "$file" != "$SYSCTL_DROPIN" ]] || return 0

	if grep -Eq "^[[:space:]]*-?[[:space:]]*${key_regex}[[:space:]]*=" "$file"; then
		backup_file_once "$file"
		sed -i -E "s|^([[:space:]]*)(-?[[:space:]]*${key_regex}[[:space:]]*=.*)|\1# BBRInstall disabled conflicting setting: \2|" "$file"
		note "$(l10n "已注释本地冲突的 sysctl 设置：$file" "Commented out conflicting local sysctl setting: $file")"
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

	[[ "$cc_algo" =~ ^[A-Za-z0-9_]+$ ]] || die "$(l10n "错误：无效的拥塞控制算法名称：$cc_algo" "Error: invalid congestion-control algorithm name: $cc_algo")"

	mkdir -p -- "$sysctl_dir"
	comment_local_conflicting_sysctls

	cat > "$SYSCTL_DROPIN" <<EOF_SYSCTL
# Managed by BBRInstall.
# Debian 13/trixie: systemd-sysctl no longer reads /etc/sysctl.conf.
# Keep local kernel parameter overrides in /etc/sysctl.d/*.conf.
net.ipv4.tcp_congestion_control = $cc_algo
EOF_SYSCTL
	chmod 0644 "$SYSCTL_DROPIN"
	note "$(l10n "已写入 sysctl 设置：$SYSCTL_DROPIN" "Wrote sysctl configuration: $SYSCTL_DROPIN")"

	if sysctl -w "net.ipv4.tcp_congestion_control=$cc_algo" >/dev/null 2>&1; then
		note "$(l10n "当前会话已将拥塞控制算法切换为：$cc_algo" "Switched the current session to congestion-control algorithm: $cc_algo")"
	else
		warn "$(l10n "警告：已写入持久化设置，但当前内核暂时无法切换到 $cc_algo。重启或加载对应模块后会再次尝试生效。" "Warning: persistent configuration was written, but the current kernel could not switch to $cc_algo yet. It will be retried after reboot or after the matching module is loaded.")"
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
	note "$(l10n "已写入模块自动加载设置：$MODULES_LOAD_DROPIN" "Wrote module autoload configuration: $MODULES_LOAD_DROPIN")"
}

remove_managed_module_autoload() {
	if [[ -f "$MODULES_LOAD_DROPIN" ]]; then
		rm -f -- "$MODULES_LOAD_DROPIN"
		note "$(l10n "已移除旧的模块自动加载设置：$MODULES_LOAD_DROPIN" "Removed old module autoload configuration: $MODULES_LOAD_DROPIN")"
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
				*) die "$(l10n "错误：找不到适用于 ${OS_NAME:-$OS_ID} ${OS_VERSION_ID:-unknown} $OS_ARCH 的 bbrv3 软件包目录。" "Error: no bbrv3 package directory found for ${OS_NAME:-$OS_ID} ${OS_VERSION_ID:-unknown} $OS_ARCH.")" ;;
			esac
			;;
		arm64|aarch64)
			case "$OS_ID:$OS_VERSION_MAJOR" in
				debian:13) printf '%s\n' "ARM64/debian13-arm64" "debian13-arm64" ;;
				*) die "$(l10n "错误：bbrv3 ARM64 预编译内核软件包目前仅支持 Debian 13。当前系统：${OS_NAME:-$OS_ID} ${OS_VERSION_ID:-unknown}，架构：$OS_ARCH" "Error: bbrv3 ARM64 prebuilt kernel packages currently support Debian 13 only. Current system: ${OS_NAME:-$OS_ID} ${OS_VERSION_ID:-unknown}, architecture: $OS_ARCH")" ;;
			esac
			;;
		*)
			die "$(l10n "错误：bbrv3 预编译内核软件包目前仅支持 amd64/x86_64 和 arm64/aarch64。当前架构：$OS_ARCH" "Error: bbrv3 prebuilt kernel packages currently support amd64/x86_64 and arm64/aarch64 only. Current architecture: $OS_ARCH")"
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
	[[ ${#pkg_candidates[@]} -gt 0 ]] || die "$(l10n "错误：找不到适用于当前系统的 bbrv3 软件包目录候选项。" "Error: no bbrv3 package directory candidates were found for this system.")"

	separator
	info "$(l10n "正在下载 bbrv3 Debian 内核软件包..." "Downloading bbrv3 Debian kernel packages...")"
	for pkg_dir in "${pkg_candidates[@]}"; do
		pkg_base="$RAW_BASE/bbrv3/$pkg_dir"
		note "$(l10n "尝试 bbrv3 软件包目录：bbrv3/$pkg_dir" "Trying bbrv3 package directory: bbrv3/$pkg_dir")"
		if fetch_optional "$pkg_base/SHA256SUMS" "SHA256SUMS"; then
			selected_pkg_dir="$pkg_dir"
			break
		fi
	done

	[[ -n "${selected_pkg_dir:-}" ]] || die "$(l10n "错误：无法从任何候选目录下载 bbrv3 SHA256SUMS：$(join_words "${pkg_candidates[@]}")" "Error: could not download bbrv3 SHA256SUMS from any candidate directory: $(join_words "${pkg_candidates[@]}")")"
	pkg_base="$RAW_BASE/bbrv3/$selected_pkg_dir"
	note "$(l10n "已选择 bbrv3 软件包目录：bbrv3/$selected_pkg_dir" "Selected bbrv3 package directory: bbrv3/$selected_pkg_dir")"

	headers_deb="$(extract_checksum_filename SHA256SUMS | grep -E '^linux-headers-.*\.deb$' | head -n 1 || true)"
	image_deb="$(extract_checksum_filename SHA256SUMS | grep -E '^linux-image-.*\.deb$' | head -n 1 || true)"

	[[ -n "$headers_deb" && -n "$image_deb" ]] || die "$(l10n "错误：无法从 SHA256SUMS 识别 linux-headers/linux-image 软件包。" "Error: could not identify linux-headers/linux-image packages from SHA256SUMS.")"

	fetch "$pkg_base/$headers_deb" "$headers_deb"
	fetch "$pkg_base/$image_deb" "$image_deb"

	sha_selected="SHA256SUMS.selected"
	write_selected_sha256sums "SHA256SUMS" "$sha_selected" "$headers_deb" "$image_deb"
	[[ -s "$sha_selected" ]] || die "$(l10n "错误：无法生成待校验文件清单。" "Error: could not create the checksum file list.")"

	sha256sum -c "$sha_selected" >/dev/null || die "$(l10n "错误：SHA256 校验失败。" "Error: SHA256 verification failed.")"
	note "$(l10n "bbrv3 内核软件包已下载并完成校验。" "bbrv3 kernel packages downloaded and verified.")"

	separator
	info "$(l10n "正在安装 bbrv3 内核软件包..." "Installing bbrv3 kernel packages...")"
	apt-get install -y "./$image_deb" "./$headers_deb"

	if command -v update-grub >/dev/null 2>&1; then
		update-grub >/dev/null
	fi

	remove_managed_module_autoload
	# BBRv3 kernel packages expose the congestion control as bbr.
	configure_sysctl_cc "bbr"

	separator
	info "$(l10n "bbrv3 内核软件包已成功安装。请重启以进入 bbrv3 内核。" "bbrv3 kernel packages were installed successfully. Reboot to enter the bbrv3 kernel.")"
	note "$(l10n "重启后可使用：uname -r && sysctl net.ipv4.tcp_congestion_control" "After reboot, verify with: uname -r && sysctl net.ipv4.tcp_congestion_control")"
}

check_kernel_for_dkms() {
	[[ "$KERNEL_BASE" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || die "$(l10n "错误：无法解析当前内核版本：$KERNEL" "Error: could not parse the current kernel version: $KERNEL")"

	if ! dpkg --compare-versions "$KERNEL_BASE" ge "$KERNEL_MIN_VERSION" || \
	   ! dpkg --compare-versions "$KERNEL_BASE" le "$KERNEL_MAX_VERSION"; then
		die "$(l10n "错误：DKMS 模块仅支持内核版本 [$KERNEL_MIN_VERSION - 7.1.x]。当前内核：$KERNEL" "Error: DKMS modules support kernel versions [$KERNEL_MIN_VERSION - 7.1.x] only. Current kernel: $KERNEL")"
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
		info "$(l10n "正在安装构建依赖软件包：$(join_words "${packages[@]}")" "Installing build dependencies: $(join_words "${packages[@]}")")"
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
		die "$(l10n "错误：找不到适用于 ${OS_NAME:-$OS_ID} ${OS_ARCH:-unknown} 的通用内核/头文件软件包。请手动安装与当前内核匹配的 headers 软件包。" "Error: no generic kernel/header packages found for ${OS_NAME:-$OS_ID} ${OS_ARCH:-unknown}. Manually install headers matching the current kernel.")"
	fi
	mapfile -t generic_packages <<< "$generic_output"

	image_pkg="${generic_packages[0]:-}"
	headers_pkg="${generic_packages[1]:-}"
	[[ -n "$image_pkg" && -n "$headers_pkg" ]] || die "$(l10n "错误：无法解析通用内核/头文件软件包名称。" "Error: could not resolve generic kernel/header package names.")"

	separator
	warn "$(l10n "警告：找不到或无法使用当前运行中内核的头文件：linux-headers-${KERNEL}" "Warning: headers for the running kernel were not found or are not usable: linux-headers-${KERNEL}")"
	note "$(l10n "可改为安装发行版通用内核映像和头文件：" "You can install the distribution generic kernel image and headers instead:")"
	note "$(l10n "  内核映像：$image_pkg" "  Kernel image: $image_pkg")"
	note "$(l10n "  内核头文件：$headers_pkg" "  Kernel headers: $headers_pkg")"
	warn "$(l10n "安装后必须重启进入新内核，然后重新运行本脚本，DKMS 模块才能继续编译安装。" "After installation, reboot into the new kernel and rerun this script before the DKMS module can be built and installed.")"

	if [[ ! -t 0 ]]; then
		die "$(l10n "错误：非交互模式无法确认安装通用内核。请手动运行：apt-get install -y $image_pkg $headers_pkg，然后重启并重新运行本脚本。" "Error: non-interactive mode cannot confirm generic kernel installation. Run manually: apt-get install -y $image_pkg $headers_pkg, then reboot and rerun this script.")"
	fi

	printf '%s' "$(l10n "是否现在安装发行版通用内核映像和头文件？[y/N]: " "Install the generic distribution kernel image and headers now? [y/N]: ")"
	read -r answer
	case "$(lowercase "$answer")" in
		y|yes)
			info "$(l10n "正在安装通用内核映像和头文件：$image_pkg $headers_pkg" "Installing generic kernel image and headers: $image_pkg $headers_pkg")"
			apt_install "$image_pkg" "$headers_pkg" || die "$(l10n "错误：安装通用内核/头文件失败：$image_pkg $headers_pkg" "Error: failed to install generic kernel/headers: $image_pkg $headers_pkg")"
			if command -v update-grub >/dev/null 2>&1; then
				update-grub >/dev/null || warn "$(l10n "警告：update-grub 运行失败，请检查引导加载器配置。" "Warning: update-grub failed; check the bootloader configuration.")"
			fi
			separator
			info "$(l10n "通用内核映像和头文件已安装。" "Generic kernel image and headers were installed.")"
			note "$(l10n "请现在重启，然后重新运行本脚本。" "Reboot now, then rerun this script.")"
			note "$(l10n "重启后可使用：uname -r && ls -l /lib/modules/\$(uname -r)/build" "After reboot, verify with: uname -r && ls -l /lib/modules/\$(uname -r)/build")"
			note "$(l10n "重新运行示例：./$SCRIPT_NAME --algo $ALGO" "Rerun example: ./$SCRIPT_NAME --algo $ALGO")"
			exit 0
			;;
		*)
			die "$(l10n "已取消安装通用内核。请安装与当前内核匹配的 headers 软件包，或安装 $image_pkg $headers_pkg 后重启并重新运行本脚本。" "Generic kernel installation was cancelled. Install headers matching the current kernel, or install $image_pkg $headers_pkg, reboot, and rerun this script.")"
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
		note "$(l10n "检测到当前内核头文件：$build_dir" "Detected current kernel headers: $build_dir")"
		return 0
	fi

	info "$(l10n "正在安装当前内核头文件：linux-headers-${KERNEL}" "Installing current kernel headers: linux-headers-${KERNEL}")"
	if apt_install "linux-headers-${KERNEL}"; then
		if [[ ! -e "$build_dir" && -d "$headers_dir" ]]; then
			mkdir -p -- "/lib/modules/${KERNEL}"
			ln -s -- "$headers_dir" "$build_dir"
		fi

		if [[ -e "$build_dir/Makefile" ]]; then
			note "$(l10n "当前内核头文件检查通过：$build_dir" "Current kernel header check passed: $build_dir")"
			return 0
		fi

		warn "$(l10n "警告：linux-headers-${KERNEL} 已安装/已尝试安装，但 $build_dir 无法供 DKMS 使用。" "Warning: linux-headers-${KERNEL} was installed or attempted, but $build_dir is not usable for DKMS.")"
	else
		warn "$(l10n "警告：找不到或无法安装当前运行中内核的头文件软件包：linux-headers-${KERNEL}。" "Warning: could not find or install the running kernel headers package: linux-headers-${KERNEL}.")"
	fi

	install_generic_kernel_and_exit
}

remove_existing_dkms_module() {
	local module="$1"
	local installed_ver_dir installed_ver

	[[ -d "/var/lib/dkms/$module" ]] || return 0

	info "$(l10n "检测到现有的 $module DKMS 模块，正在移除旧版本..." "Found an existing $module DKMS module; removing old versions...")"
	for installed_ver_dir in "/var/lib/dkms/$module"/*; do
		[[ -d "$installed_ver_dir" ]] || continue
		installed_ver="$(basename -- "$installed_ver_dir")"
		dkms remove -m "$module" -v "$installed_ver" --all >/dev/null || die "$(l10n "错误：移除 $module/$installed_ver 失败。" "Error: failed to remove $module/$installed_ver.")"
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
	note "$(l10n "系统支持检查通过。" "System support check passed.")"

	create_work_dir
	src_dir="$WORK_DIR_CREATED/src"

	separator
	info "$(l10n "正在下载 $ALGO 拥塞控制模块源代码..." "Downloading $ALGO congestion-control module source...")"
	download_dkms_source "$src_dir"
	note "$(l10n "源代码下载完成。" "Source download completed.")"

	separator
	info "$(l10n "正在编译并安装 $ALGO 拥塞控制模块..." "Building and installing the $ALGO congestion-control module...")"
	remove_existing_dkms_module "$ALGO"

	dkms_src_dir="/usr/src/${ALGO}-${module_version}"
	rm -rf -- "$dkms_src_dir"
	mkdir -p -- "$dkms_src_dir"
	cp -a "$src_dir/." "$dkms_src_dir/"

	if ! dkms add -m "$ALGO" -v "$module_version" >/dev/null; then
		dkms remove -m "$ALGO" -v "$module_version" --all >/dev/null 2>&1 || true
		die "$(l10n "错误：DKMS 无法新增内核模块。" "Error: DKMS could not add the kernel module.")"
	fi

	if ! dkms build -m "$ALGO" -v "$module_version" >/dev/null; then
		dkms remove -m "$ALGO" -v "$module_version" --all >/dev/null 2>&1 || true
		die "$(l10n "错误：构建 DKMS 模块失败。" "Error: DKMS module build failed.")"
	fi

	if ! dkms install -m "$ALGO" -v "$module_version" >/dev/null; then
		dkms remove -m "$ALGO" -v "$module_version" --all >/dev/null 2>&1 || true
		die "$(l10n "错误：DKMS 无法安装内核模块。" "Error: DKMS could not install the kernel module.")"
	fi

	depmod -a "$KERNEL" >/dev/null 2>&1 || true

	if ! modprobe "$module_name"; then
		dkms remove -m "$ALGO" -v "$module_version" --all >/dev/null 2>&1 || true
		die "$(l10n "错误：加载模块失败：$module_name" "Error: failed to load module: $module_name")"
	fi

	separator
	if grep -q "^${module_name}[[:space:]]" /proc/modules; then
		info "$(l10n "$ALGO 拥塞控制模块已成功安装并加载。通常无需重启即可尝试生效。" "$ALGO congestion-control module was installed and loaded successfully. You can usually try it without rebooting.")"
	else
		dkms remove -m "$ALGO" -v "$module_version" --all >/dev/null 2>&1 || true
		die "$(l10n "错误：模块未出现在 /proc/modules：$module_name" "Error: module did not appear in /proc/modules: $module_name")"
	fi

	configure_module_autoload "$module_name"
	configure_sysctl_cc "$ALGO"
}

main() {
	parse_args "$@"

	if [[ "$SHOW_HELP" == "1" ]]; then
		usage
		exit 0
	fi

	if [[ -t 1 && -n "${TERM:-}" ]]; then
		clear
	fi

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
	info "$(l10n "正在检查系统支持状态..." "Checking system support...")"
	check_supported_os
	check_supported_runtime
	apt_update

	if [[ "$ALGO" == "bbrv3" ]]; then
		note "$(l10n "系统支持检查通过。" "System support check passed.")"
		install_bbrv3_deb
	else
		install_dkms_bbr
	fi
}

main "$@"
