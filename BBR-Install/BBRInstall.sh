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

## Choose the congestion control algorithm
info "请选择要安装的拥塞控制算法:"
select algo in "bbrx" "bbrw" "attack"; do
	case $algo in
			bbrx|bbrw|attack)
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
seperator

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
	if [ $(systemd-detect-virt) != "none" ]; then
		virt_tech=$(systemd-detect-virt)
	else
		virt_tech="No Virtualization"
	fi
	
	return 0
}

## Check if the script is run on a supported OS
sysinfo_
if [ "$os" != "Ubuntu" ] && [ "$os" != "Debian" ]; then
	fail "错误: 本脚本仅支持Ubuntu/Debian系统."
	exit 1
fi
if [ "$os" == "Ubuntu" ]; then
	if [ "$ver" != "24.04" ] && [ "$ver" != "22.04" ]; then
		fail "错误: 本脚本仅支持Ubuntu 24.04/22.04系统."
		exit 1
	fi
fi
if [ "$os" == "Debian" ]; then
	if [ "$ver" != "12" ] && [ "$ver" != "11" ]; then
		fail "警告: 本脚本仅支持Debian 12/11系统."
		exit 1
	fi
fi

## Check if the script is run on a supported kernel version
trimmed_kernel_ver=$(echo $kernel | cut -d'-' -f1)
if [ "$trimmed_kernel_ver" != "5.10.0" ] && [ "$trimmed_kernel_ver" != "5.15.0" ] && [ "$trimmed_kernel_ver" != "6.1.0" ] && [ "$trimmed_kernel_ver" != "6.8.0" ]; then
	fail "错误: 本脚本仅支持内核版本 [5.10.0, 5.15.0, 6.1.0, 6.8.0]"
	exit 1
fi

## Check if the script is run on a supported virtualization technology
if [ "$virt_tech" != "No Virtualization" ] && [ "$virt_tech" != "kvm" ]; then
	fail "错误: 本脚本仅支持无虚拟化和KVM虚拟化环境."
	exit 1
fi

## Ensure there is header file
if [ ! -f /usr/src/linux-headers-$(uname -r)/.config ]; then
	if [[ -z $(apt-cache search linux-headers-$(uname -r)) ]]; then
		fail "错误: 未找到适用于当前内核版本的头文件. 正在安装新内核版本..."
		if [[ "$os" =~ "Debian" ]]; then
			if [ $(uname -m) == "x86_64" ]; then
				apt-get -y install linux-image-amd64 linux-headers-amd64 &> /dev/null
			elif [ $(uname -m) == "aarch64" ]; then
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

## Install dkms if not installed
if [ ! -x /usr/sbin/dkms ]; then
	apt-get -y install dkms
    if [ ! -x /usr/sbin/dkms ]; then
		fail "错误: 安装 dkms 失败"
		exit 1
	fi
fi

## Download the Modified BBR source code
mkdir -p $HOME/.bbr/src && cd $HOME/.bbr/src
if [ ! -d $HOME/.bbr/src ]; then
	fail "错误: 创建目录失败."
	exit 1
fi
wget -O $HOME/.bbr/src/tcp_$algo.c https://raw.githubusercontent.com/jerry048/Trove/refs/heads/main/BBR-Install/BBR/$trimmed_kernel_ver/tcp_$algo.c
if [ ! -f $HOME/.bbr/src/tcp_$algo.c ]; then
	fail "错误: 下载源代码失败."
	exit 1
fi

## This part of the script is modified from https://github.com/KozakaiAya/TCP_BBR
## Compile and install
info "正在编译并安装 $algo 拥塞控制模块..."
bbr_file=tcp_$algo
bbr_src=$bbr_file.c
bbr_obj=$bbr_file.o

# Detect if the module is already installed
if [ -f /lib/modules/$trimmed_kernel_ver/updates/net/ipv4/$bbr_file.ko ]; then
	info "正在卸载现有的 $algo 拥塞控制模块..."
	dkms remove -m $algo/$trimmed_kernel_ver --all
	if [ ! $? -eq 0 ]; then
		fail "错误: 卸载失败"
		exit 1
	fi
fi

## Compile the module
# Create Makefile
cat > ./Makefile << EOF
obj-m:=$bbr_obj

default:
	make -C /lib/modules/\$(shell uname -r)/build M=\$(PWD)/src modules

clean:
	-rm modules.order
	-rm Module.symvers
	-rm .[!.]* ..?*
	-rm $bbr_file.mod
	-rm $bbr_file.mod.c
	-rm *.o
	-rm *.cmd
EOF

    # Create dkms.conf
    cd ..
    cat > ./dkms.conf << EOF
MAKE="'make' -C src/"
CLEAN="make -C src/ clean"
BUILT_MODULE_NAME=$bbr_file
BUILT_MODULE_LOCATION=src/
DEST_MODULE_LOCATION=/updates/net/ipv4
PACKAGE_NAME=$algo
PACKAGE_VERSION=$trimmed_kernel_ver
REMAKE_INITRD=yes
EOF

# Start dkms install
cp -R . /usr/src/$algo-$trimmed_kernel_ver

dkms add -m $algo -v $trimmed_kernel_ver
if [ ! $? -eq 0 ]; then
    dkms remove -m $algo/$trimmed_kernel_ver --all
	fail "错误: DKMS 无法添加内核模块"
	exit 1
fi

dkms build -m $algo -v $trimmed_kernel_ver
if [ ! $? -eq 0 ]; then
    dkms remove -m $algo/$trimmed_kernel_ver --all
	fail "Error: 构建 DKMS 模块失败"
    exit 1
fi

dkms install -m $algo -v $trimmed_kernel_ver
if [ ! $? -eq 0 ]; then
    dkms remove -m $algo/$trimmed_kernel_ver --all
	fail "Error: DKMS 无法安装内核模块"
    exit 1
fi

# Auto-load kernel module at system startup
echo $bbr_file | sudo tee -a /etc/modules
sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control = $algo" >> /etc/sysctl.conf
sysctl -p > /dev/null

# Test loading module
modprobe $bbr_file
if [ ! $? -eq 0 ]; then
	dkms remove -m $algo/$trimmed_kernel_ver --all
	fail "Error: 加载模块失败"
    exit 1
fi

# Check if the module is loaded
if lsmod | grep -q $bbr_file; then
	seperator
	info "$algo 拥塞控制模块已成功安装! 无需重启即可生效."
else
	dkms remove -m $algo/$trimmed_kernel_ver --all
	fail "Error: 加载模块失败"
	exit 1
fi

# Clean up
rm -r $HOME/.bbr

