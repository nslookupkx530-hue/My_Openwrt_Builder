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

# --- 3. 设备与 Target 路径映射 (核心：确保内核哈希一致) ---
# 根据你提供的处理器规格进行精确映射
case "$TARGET_DEVICE" in
    "x86"|"x86_64")
        DEVICE_PATH="targets/x86/64"
        ;;
    "AXT-1800")
        # 高通 IPQ6000/6018 系列
        DEVICE_PATH="targets/qualcommax/ipq60xx"
        ;;
    "GL-MT3600BE")
        # 联发科 Filogic 系列 (MT7987A)
        DEVICE_PATH="targets/mediatek/filogic"
        ;;
    "Cudy-TR3000-256MB")
        # 联发科 Filogic 系列 (MT7981B)
        DEVICE_PATH="targets/mediatek/filogic"
        ;;
    "Tenda-BE12PRO")
        # 联发科 Filogic 系列 (MT7988A)
        DEVICE_PATH="targets/mediatek/filogic"
        ;;
    *)
        echo "Error: Unknown device $TARGET_DEVICE"
        exit 1
        ;;
esac

echo "Mapped Device Path: $DEVICE_PATH"

# --- 4. 构造最终 URL ---
# 官方通常的路径结构是: BASE_URL/targets/xxx/xxx/xxx/config.buildinfo
# 对于 x86，路径是 targets/x86/64/generic
# 对于其他，路径是 targets/mediatek/filogic 等
FINAL_URL="${BASE_URL}/${DEVICE_PATH}/config.buildinfo"

echo "Fetching config from: ${FINAL_URL}"

# 使用 -L 跟随重定向，-s 静默模式，-o 输出到临时文件
if curl -L -s "${FINAL_URL}" -o "tmp_config.buildinfo"; then
    echo "Download successful."
    # 覆盖当前的 .config
    mv "tmp_config.buildinfo" ".config"
    echo "Created .config from official source."
else
    echo "Error: Failed to download config.buildinfo from ${FINAL_URL}"
    # 检查一下是否是 404，可能是路径变动
    echo "Hint: Please verify the device path in the script."
    exit 1
fi

# --- 5. 执行 make defconfig ---
# 使用 FORCE=1 是为了在 GitHub Actions 环境下绕过某些环境依赖检查（如特定的 host 库缺失）
# 这一步会根据官方 buildinfo 自动补全所有基础依赖
echo "Running make defconfig with FORCE=1..."
make defconfig FORCE=1

echo "Configuration preparation completed successfully."
