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

# --- 1. 参数处理 ---
SOURCE_TYPE="${1:-immortalwrt}"    # 默认 immortalwrt
TARGET_DEVICE="${2:-x86}"      # 默认 x86 (对应 x86_64)

# --- 2. 自动获取版本号 ---
# 如果用户没有通过环境变量 VERSION 传参，则自动抓取
if [ -z "$VERSION" ]; then
    echo "--- Detecting latest stable version ---"
    if [ "$SOURCE_TYPE" = "openwrt" ]; then
        # 从 immortalwrt release 页面抓取
        VERSION=$(curl -s https://downloads.immortalwrt.org/releases/ | grep -oE '2[0-9]\.[0-9]{2}\.[0-9]{1,2}' | sort -nr | head -n1)
    else
        # 从 openwrt release 页面抓取最新的版本号 (例如 23.05.2)
        VERSION=$(curl -s https://downloads.openwrt.org/releases/ | grep -oE '2[0-9]\.[0-9]{2}\.[0-9]{1,2}' | sort -nr | head -n1)
    fi
    
    if [ -z "$VERSION" ]; then
        echo "Error: Could not detect version automatically."
        exit 1
    fi
    echo "Detected Version: $VERSION"
fi

# --- 3. 配置基础 URL ---
if [ "$SOURCE_TYPE" = "immortalwrt" ]; then
    BASE_URL="https://downloads.immortalwrt.org/releases"
else
    BASE_URL="https://downloads.openwrt.org/releases"
fi

# --- 4. 设备与 Target 路径映射 ---
# 注意：为了保证内核哈希一致，这里映射到官方的通用 target。
# 对于 GL.iNet 等设备，使用对应的 SoC 基础配置即可。
case "$TARGET_DEVICE" in
    "x86"|"x86_64")
        DEVICE_PATH="targets/x86/64/generic"
        ;;
    "AXT-1800")
        # 高通 IPQ60xx 平台
        DEVICE_PATH="targets/quennvi/ipq6000"
        ;;
    "GL-MT3600BE"|"Cudy-TR3000-256MB"|"Tenda-BE12PRO")
        # 均属于 MediaTek Filogic 系列 (mt7987/mt7988/mt7981)
        DEVICE_PATH="targets/mediatek/filogic"
        ;;
    *)
        echo "Error: Unknown device $TARGET_DEVICE"
        exit 1
        ;;
esac

# --- 5. 构造最终下载地址 ---
# 最终路径格式: https://xxx.org/releases/[VERSION]/[DEVICE_PATH]/config.buildinfo
FINAL_URL="${BASE_URL}/${VERSION}/${DEVICE_PATH}/config.buildinfo"

echo "--- Fetching config from: ${FINAL_URL} ---"

# --- 6. 下载并转换 ---
# 下载到临时文件，防止直接覆盖导致失败
if curl -L -s "${FINAL_URL}" -o "tmp_config.buildinfo"; then
    mv "tmp_config.buildinfo" ".config"
    echo "Successfully created .config from $SOURCE_TYPE $VERSION"
else
    echo "Error: Failed to download config.buildinfo."
    exit 1
fi

# --- 7. 补全配置 ---
echo "--- Running make defconfig ---"
# 使用官方的 buildinfo 作为基础，make defconfig 会根据当前源码环境补全所有必要选项
# 这一步非常重要，它能保证 .config 文件是“合规”的，包含所有基础库
make defconfig

echo "--- Configuration preparation complete ---"
