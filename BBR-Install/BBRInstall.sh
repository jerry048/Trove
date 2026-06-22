#!/bin/bash
clear

## Text colors and styles
info() {
	echo -e "\e[92m$1\e[0m"
}
info_2() {
	echo -e "\e[94m$1\e[0m"
}
fail() {
	echo -e "\e[91m$1\e[0m" 1>&2
}
seperator() {
	echo -e "\n"
	echo $(printf '%*s' "$(tput cols)" | tr ' ' '=')
}

RAW_BASE="https://raw.githubusercontent.com/jerry048/Trove/refs/heads/main/BBR-Install/BBR"

## Choose the congestion control algorithm
info "请选择要安装的拥塞控制算法:"
select algo in "BBRv3" "BBRx" "BBRw" "BBR_brutal"  "BBRw_brutal"; do
	case $algo in
		bbrv3|bbrx|bbrw|bbr_brutal|bbrw_brutal)
			break
			;;
		*)
			fail "错误: 无效的选择."
			;;
	esac
done

## Ensure the script is run as root
if [ "$(id -u)" != "0" ]; then
	echo "脚本需要root运行." 1>&2
	exit 1
fi

## System Update
seperator
info "正在更新系统..."
apt-get update -y &> /dev/null
apt-get upgrade -y &> /dev/null
info_2 "系统更新完成."

## System Info
sysinfo_(){
	#Linux Distro Version
	if [ -f /etc/os-release ]; then
		. /etc/os-release
		os=$NAME
		ver=$VERSION_ID
	elif type lsb_release >/dev/null 2>&1; then
		os=$(lsb_release -si)
		ver=$(lsb_release -sr)
	elif [ -f /etc/lsb-release ]; then
		. /etc/lsb-release
		os=$DISTRIB_ID
		ver=$DISTRIB_RELEASE
	elif [ -f /etc/debian_version ]; then
		os=Debian
		ver=$(cat /etc/debian_version)
	elif [ -f /etc/redhat-release ]; then
		os=Redhat
	else
		os=$(uname -s)
		ver=$(uname -r)
	fi

	#Kernel Version
	kernel=$(uname -r)

	#Virtualization Technology
	if [ "$(systemd-detect-virt)" != "none" ]; then
		virt_tech=$(systemd-detect-virt)
	else
		virt_tech="No Virtualization"
	fi
	
	return 0
}

check_supported_os(){
	if [[ ! "$os" =~ "Ubuntu" ]] && [[ ! "$os" =~ "Debian" ]]; then
		fail "错误: 本脚本仅支持Ubuntu/Debian系统."
		exit 1
	fi

	if [[ "$os" =~ "Ubuntu" ]]; then
		case "$ver" in
			22*|24*|26*) ;;
			*)
				fail "错误: 本脚本仅支持Ubuntu 22.04/24.04/26.04系统."
				exit 1
				;;
		esac
	fi

	if [[ "$os" =~ "Debian" ]]; then
		case "$ver" in
			11*|12*|13*) ;;
			*)
				fail "错误: 本脚本仅支持Debian 11/12/13系统."
				exit 1
				;;
		esac
	fi
}

check_supported_virt(){
	if [ "$virt_tech" != "No Virtualization" ] && [ "$virt_tech" != "kvm" ]; then
		fail "错误: 本脚本仅支持无虚拟化和KVM虚拟化环境."
		exit 1
	fi
}

ensure_download_tools(){
	if ! command -v wget >/dev/null 2>&1; then
		apt-get -y install wget &> /dev/null
		if ! command -v wget >/dev/null 2>&1; then
			fail "错误: 安装 wget 失败"
			exit 1
		fi
	fi
}

configure_sysctl_cc(){
	local cc_algo="$1"
	sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
	echo "net.ipv4.tcp_congestion_control = $cc_algo" >> /etc/sysctl.conf
	if ! sysctl -p > /dev/null 2>&1; then
		info_2 "已写入 sysctl 配置，重启后会再次生效."
	fi
}

get_bbrv3_package_dir(){
	if [ "$(uname -m)" != "x86_64" ] && [ "$(uname -m)" != "amd64" ]; then
		fail "错误: bbrv3 预编译内核包当前仅支持 amd64/x86_64."
		exit 1
	fi

	if [[ "$os" =~ "Debian" ]]; then
		case "$ver" in
			11*) bbrv3_pkg_dir="debian11-amd64" ;;
			12*) bbrv3_pkg_dir="debian12-amd64" ;;
			13*) bbrv3_pkg_dir="debian13-amd64" ;;
			*)
				fail "错误: 未找到适用于 Debian $ver 的 bbrv3 软件包目录."
				exit 1
				;;
		esac
	elif [[ "$os" =~ "Ubuntu" ]]; then
		case "$ver" in
			22*) bbrv3_pkg_dir="ubuntu2204-generic" ;;
			24*) bbrv3_pkg_dir="ubuntu2404-generic" ;;
			26*) bbrv3_pkg_dir="ubuntu2604-generic" ;;
			*)
				fail "错误: 未找到适用于 Ubuntu $ver 的 bbrv3 软件包目录."
				exit 1
				;;
		esac
	fi
}

install_bbrv3_deb(){
	get_bbrv3_package_dir
	ensure_download_tools

	seperator
	info "正在下载 bbrv3 内核 Debian 软件包..."
	mkdir -p "$HOME/.bbr/bbrv3" && cd "$HOME/.bbr/bbrv3" || {
		fail "错误: 创建目录失败."
		exit 1
	}

	local pkg_base="$RAW_BASE/bbrv3/$bbrv3_pkg_dir"
	wget -O SHA256SUMS "$pkg_base/SHA256SUMS" &> /dev/null
	if [ ! -f SHA256SUMS ]; then
		fail "错误: 下载 SHA256SUMS 失败."
		exit 1
	fi

	local headers_deb
	local image_deb
	headers_deb=$(awk '{print $2}' SHA256SUMS | sed -e 's#^\*##' -e 's#^\./##' | grep '^linux-headers-.*\.deb$' | head -n 1)
	image_deb=$(awk '{print $2}' SHA256SUMS | sed -e 's#^\*##' -e 's#^\./##' | grep '^linux-image-.*\.deb$' | head -n 1)

	if [ -z "$headers_deb" ] || [ -z "$image_deb" ]; then
		fail "错误: 无法从 SHA256SUMS 中识别 linux-headers/linux-image 软件包."
		exit 1
	fi

	wget -O "$headers_deb" "$pkg_base/$headers_deb" &> /dev/null
	if [ ! -f "$headers_deb" ]; then
		fail "错误: 下载 $headers_deb 失败."
		exit 1
	fi

	wget -O "$image_deb" "$pkg_base/$image_deb" &> /dev/null
	if [ ! -f "$image_deb" ]; then
		fail "错误: 下载 $image_deb 失败."
		exit 1
	fi

	sha256sum -c SHA256SUMS &> /dev/null
	if [ $? -ne 0 ]; then
		fail "错误: SHA256 校验失败."
		exit 1
	fi
	info_2 "bbrv3 内核软件包下载并校验完成."

	seperator
	info "正在安装 bbrv3 内核软件包..."
	apt-get -y install "./$image_deb" "./$headers_deb" &> /dev/null
	if [ $? -ne 0 ]; then
		fail "错误: 安装 bbrv3 内核软件包失败."
		exit 1
	fi

	if command -v update-grub >/dev/null 2>&1; then
		update-grub &> /dev/null
	fi

	# BBRv3 kernel packages expose the congestion control as bbr.
	configure_sysctl_cc "bbr"

	# Clean up
	rm -rf "$HOME/.bbr"

	seperator
	info "bbrv3 内核软件包已成功安装. 请重启系统以进入 bbrv3 内核."
	info_2 "重启后可使用 uname -r 和 sysctl net.ipv4.tcp_congestion_control 检查状态."
	exit 0
}

check_kernel_for_dkms(){
	## Check if the script is run on a supported kernel version
	trimmed_kernel_ver=$(echo "$kernel" | cut -d'-' -f1)
	if ! dpkg --compare-versions "$trimmed_kernel_ver" ge "5.10" || \
	   ! dpkg --compare-versions "$trimmed_kernel_ver" le "7.1"; then
		fail "错误: 本脚本仅支持内核版本 [5.10 - 7.1]"
		exit 1
	fi
}

ensure_kernel_headers(){
	## Ensure there is header file
	if [ ! -f /usr/src/linux-headers-$(uname -r)/.config ]; then
		if [[ -z $(apt-cache search linux-headers-$(uname -r)) ]]; then
			fail "错误: 未找到适用于当前内核版本的头文件. 正在安装新内核版本..."
			if [[ "$os" =~ "Debian" ]]; then
				if [ "$(uname -m)" == "x86_64" ]; then
					apt-get -y install linux-image-amd64 linux-headers-amd64 &> /dev/null
				elif [ "$(uname -m)" == "aarch64" ]; then
					apt-get -y install linux-image-arm64 linux-headers-arm64 &> /dev/null
				fi
				if [ $? -ne 0 ]; then
					fail "错误: 安装失败"
					exit 1
				else
					info "成功安装了一个带有头文件的新内核. 请重新启动并再次运行脚本"
					exit 0
				fi
			elif [[ "$os" =~ "Ubuntu" ]]; then
				apt-get -y install linux-image-generic linux-headers-generic &> /dev/null
				if [ $? -ne 0 ]; then
					fail "错误: 安装失败"
					exit 1
				else
					info "成功安装了一个带有头文件的新内核. 请重新启动并再次运行脚本"
					exit 0
				fi
			fi
		else
			apt-get -y install linux-headers-$(uname -r)
			if [ ! -f /usr/src/linux-headers-$(uname -r)/.config ]; then
				fail "错误: linux-headers-$(uname -r) 安装失败"
				exit 1
			fi
		fi
	fi
}

ensure_dkms(){
	## Install dkms if not installed
	if [ ! -x /usr/sbin/dkms ]; then
		apt-get -y install dkms
		if [ ! -x /usr/sbin/dkms ]; then
			fail "错误: 安装 dkms 失败"
			exit 1
		fi
	fi
}

install_dkms_bbr(){
	check_kernel_for_dkms
	ensure_kernel_headers
	ensure_dkms
	ensure_download_tools
	info_2 "系统支持检查通过."

	## Download the Modified BBR source code
	seperator
	info "正在下载 $algo 拥塞控制模块源代码..."
	mkdir -p "$HOME/.bbr/src" && cd "$HOME/.bbr/src" || {
		fail "错误: 创建目录失败."
		exit 1
	}

	wget -O "$HOME/.bbr/src/tcp_$algo.c" "$RAW_BASE/$algo/tcp_$algo.c" &> /dev/null
	if [ ! -f "$HOME/.bbr/src/tcp_$algo.c" ]; then
		fail "错误: 下载源代码失败."
		exit 1
	fi
	wget -O "$HOME/.bbr/src/dkms.conf" "$RAW_BASE/$algo/dkms.conf" &> /dev/null
	if [ ! -f "$HOME/.bbr/src/dkms.conf" ]; then
		fail "错误: 下载配置失败."
		exit 1
	fi
	wget -O "$HOME/.bbr/src/Makefile" "$RAW_BASE/$algo/Makefile" &> /dev/null
	if [ ! -f "$HOME/.bbr/src/Makefile" ]; then
		fail "错误: 下载Makefile失败."
		exit 1
	fi
	info_2 "源代码下载完成."

	## This part of the script is modified from https://github.com/KozakaiAya/TCP_BBR
	## Compile and install
	seperator
	info "正在编译并安装 $algo 拥塞控制模块..."
	bbr_file=tcp_${algo}
	bbr_src="${bbr_file}.c"

	# Detect if the module is already installed
	if [ -d "/var/lib/dkms/$algo" ]; then
		info "检测到现有的 $algo 拥塞控制模块."
		info_2 "正在卸载并重装 $algo 拥塞控制模块..."
		for installed_ver_dir in "/var/lib/dkms/$algo"/*; do
			[ -d "$installed_ver_dir" ] || continue
			installed_ver=$(basename "$installed_ver_dir")
			dkms remove -m "$algo" -v "$installed_ver" --all &> /dev/null
			if [ ! $? -eq 0 ]; then
				fail "错误: 卸载失败"
				exit 1
			fi
		done
	fi

	## Compile the module
	# Start dkms install
	rm -rf "/usr/src/$algo-$trimmed_kernel_ver"
	cp -R . "/usr/src/$algo-$trimmed_kernel_ver"

	dkms add -m "$algo" -v "$trimmed_kernel_ver" &> /dev/null
	if [ ! $? -eq 0 ]; then
		dkms remove -m "$algo" -v "$trimmed_kernel_ver" --all &> /dev/null
		fail "错误: DKMS 无法添加内核模块"
		exit 1
	fi

	dkms build -m "$algo" -v "$trimmed_kernel_ver" &> /dev/null
	if [ ! $? -eq 0 ]; then
		dkms remove -m "$algo" -v "$trimmed_kernel_ver" --all &> /dev/null
		fail "Error: 构建 DKMS 模块失败"
		exit 1
	fi

	dkms install -m "$algo" -v "$trimmed_kernel_ver" &> /dev/null
	if [ ! $? -eq 0 ]; then
		dkms remove -m "$algo" -v "$trimmed_kernel_ver" --all &> /dev/null
		fail "Error: DKMS 无法安装内核模块"
		exit 1
	fi

	# Test loading module
	modprobe "$bbr_file"
	if [ ! $? -eq 0 ]; then
		dkms remove -m "$algo" -v "$trimmed_kernel_ver" --all &> /dev/null
		fail "Error: 加载模块失败"
		exit 1
	fi

	# Check if the module is loaded
	seperator
	if lsmod | grep -q "$bbr_file"; then
		info "$algo 拥塞控制模块已成功安装! 无需重启即可生效."
	else
		dkms remove -m "$algo" -v "$trimmed_kernel_ver" --all &> /dev/null
		fail "Error: 加载模块失败"
		exit 1
	fi

	# Auto-load kernel module at system startup
	if ! grep -qxF "$bbr_file" /etc/modules; then
		echo "$bbr_file" >> /etc/modules
	fi
	configure_sysctl_cc "$algo"

	# Clean up
	rm -rf "$HOME/.bbr"
}

## Check if the script is run on a supported OS
sysinfo_
seperator
info "正在检查系统..."
check_supported_os
check_supported_virt

if [ "$algo" = "bbrv3" ]; then
	info_2 "系统支持检查通过."
	install_bbrv3_deb
else
	install_dkms_bbr
fi
