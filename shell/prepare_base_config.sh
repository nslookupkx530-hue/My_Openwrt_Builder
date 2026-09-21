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
MAPPING_FILE="../configs/device_mapping.conf"

if [ ! -f "$MAPPING_FILE" ]; then
    echo "Error: Mapping file $MAPPING_FILE not found!"
    exit 1
fi

# 改进的提取逻辑：
# 1. 使用 tr 删除可能存在的 Windows 换行符 (\r)
# 2. 使用 sed 去除每行开头的空格
# 3. 使用 grep 匹配包含设备名的行
# 4. 使用 cut 获取等号后的内容并去除多余空格
DEVICE_PATH=$(tr -d '\r' < "$MAPPING_FILE" | sed 's/^[[:space:]]*//' | grep "^${TARGET_DEVICE}=" | head -n1 | cut -d'=' -f2 | tr -d '[:space:]')
if [ -z "$DEVICE_PATH" ]; then
    echo "Error: Unknown device '$TARGET_DEVICE'. Please ensure it is correctly defined in $MAPPING_FILE."
    echo "Current MAPPING_FILE content:"
    cat "$MAPPING_FILE" # 在报错时打印出文件内容，方便排查问题
    exit 1
fi
echo "Mapped Device Path: ${DEVICE_PATH}"

# --- 4. 构造最终 URL ---
# 官方通常的路径结构是: BASE_URL/targets/xxx/xxx/xxx/config.buildinfo
# 对于 x86，路径是 targets/x86/64/generic
# 对于其他，路径是 targets/mediatek/filogic 等
# 路径结构：BASE_URL/VERSION/DEVICE_PATH/config.buildinfo
FINAL_URL="${BASE_URL}/${VERSION}/${DEVICE_PATH}/config.buildinfo"

echo "Constructed FINAL_URL: ${FINAL_URL}"

# 使用 -L 跟随重定向，-s 静默模式，-o 输出到临时文件
if curl -L -s "${FINAL_URL}" -o "tmp_config.buildinfo"; then
    echo "Download successful."
    # 覆盖当前的 .config
    mv "tmp_config.buildinfo" ".config"
    echo "Created .config from official source."
else
    echo "Error: Failed to download config.buildinfo from ${FINAL_URL}"
    # 打印出 URL 以便排查是否路径错误
    exit 1
fi

# --- 5. 执行 make defconfig ---
    # --- 执行 make defconfig ---
    # 这一步非常关键：
    # 1. 使用 FORCE=1 是为了跳过 GitHub Actions 环境中可能存在的 host 架构不匹配检查
    # 2. 它会根据我们下载的 .buildinfo 自动补全所有基础依赖、架构相关的内核配置和工具链
    echo "Running make defconfig with FORCE=1 to complement the configuration..."
    make defconfig FORCE=1
    
    if [ $? -eq 0 ]; then
        echo "make defconfig completed successfully."
    else
        echo "Error: make defconfig failed."
        exit 1
    fi

    echo "=============================================================="
    echo ">>> FINAL .config CONTENT (Source: ${SOURCE_TYPE}, Device: ${TARGET_DEVICE})"
    echo "=============================================================="
    cat .config
    echo "=============================================================="
