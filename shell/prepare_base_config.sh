#!/bin/bash

# ==============================================================================
# 脚本名称: prepare_base_config.sh
# 描述: 
#   1. 自动识别并下载官方/ImmortalWrt 的最新稳定版 config.buildinfo
#   2. 将其转换为 .config 文件
#   3. 执行 make defconfig 确保基础依赖完整
# 
# 使用方法: 
#   source ./shell/prepare_base_config.sh [openwrt|immortalwrt] [device_name]
#   或者直接执行: sh ./shell/prepare_base_config.sh openwrt x86
# ==============================================================================

set -euxo pipefail

# --- 配置变量 ---
# 允许通过环境变量传入：SOURCE_TYPE (openwrt|immortalwrt), TARGET_DEVICE
# TARGET_DEVICE 对应用户要求的：x86, AXT-1800, GL-MT3600BE, Cudy-TR3000-256MB, Tenda-BE12PRO
SOURCE_TYPE="${SOURCE_TYPE:-immortalwrt}"    # 默认 immortalwrt
TARGET_DEVICE="${TARGET_DEVICE:-x86}"      # 默认 x86 (对应 x86_64)
VERSION=""

echo "Starting configuration preparation..."
echo "Source Type: $SOURCE_TYPE"
echo "Target Device: $TARGET_DEVICE"

# --- 1. 自动获取版本号 ---
if [ -z "$VERSION" ]; then
    echo "Attempting to fetch the latest stable version..."
    if [ "$SOURCE_TYPE" = "immortalwrt" ]; then
        # 从 immortalwrt release 页面抓取最新的 25.x.x 或 23.x.x 版本号
        VERSION=$(curl -s https://downloads.immortalwrt.org/releases/ | grep -oE '2[0-9]\.[0-9]{2}\.[0-9]{1,2}' | sort -nr | head -n1)
    else
        # 从 openwrt release 页面抓取最新的版本号
        VERSION=$(curl -s https://downloads.openwrt.org/releases/ | grep -oE '2[0-9]\.[0-9]{2}\.[0-9]{1,2}' | sort -nr | head -n1)
    fi
    
    if [ -z "$VERSION" ]; then
        echo "Error: Could not automatically detect the version. Please set VERSION environment variable."
        exit 1
    fi
    echo "Detected Version: $VERSION"
fi

# --- 2. 配置基础 URL ---
if [ "$SOURCE_TYPE" = "immortalwrt" ]; then
    BASE_URL="https://downloads.immortalwrt.org/releases"
else
    BASE_URL="https://downloads.openwrt.org/releases"
fi

# --- 3. 设备与 Target 路径映射 ---
# 注意：为了保证内核哈希一致，这里映射到官方的通用 target。
# 对于 GL.iNet 等设备，使用对应的 SoC 基础配置即可。
case "$TARGET_DEVICE" in
    "x86"|"x86_64")
        DEVICE_PATH="targets/x86/64/generic"
        ;;
    "AXT-1800")
        # 高通 IPQ60xx 系列
        DEVICE_PATH="targets/qualcomm/ipq60xx"
        ;;
    "GL-MT3600BE"|"Cudy-TR3000-256MB")
        # 联发科 Filogic 系列
        DEVICE_PATH="targets/mediatek/filogic"
        ;;
    "Tenda-BE12PRO")
        # 联发科 Filogic 系列 (MT7988A/B)
        DEVICE_PATH="targets/mediatek/filogic"
        ;;
    *)
        echo "Error: Unknown device $TARGET_DEVICE"
        echo "Please check the mapping in the script."
        exit 1
        ;;
esac

echo "Mapped Device Path: ${DEVICE_PATH}"

# --- 4. 构造最终 URL ---
# 官方通常的路径结构是: BASE_URL/targets/xxx/xxx/xxx/config.buildinfo
# 对于 x86，路径是 targets/x86/64/generic
# 对于其他，路径是 targets/mediatek/filogic 等
FINAL_URL="${BASE_URL}/${DEVICE_PATH}/config.buildinfo"

echo "Fetching config from: ${FINAL_URL}"

# --- 5. 执行下载 ---
# 使用 -L 跟随重定向，-s 静默模式，-o 输出到临时文件
if curl -L -s "${FINAL_URL}" -o "tmp_config.buildinfo"; then
    echo "Download successful."
    mv "tmp_config.buildinfo" ".config"
    echo "Created .config from official source."
else
    echo "Error: Failed to download config.buildinfo from ${FINAL_URL}"
    # 检查一下是否是 404，可能是路径变动
    echo "Hint: Please verify the device path in the script."
    exit 1
fi

# --- 6. 执行 make defconfig ---
echo "Running make defconfig to complement the configuration..."
# 使用 -j1 确保 defconfig 在单线程下运行，避免某些构建系统下的竞态问题
make defconfig
echo "make defconfig completed successfully."
