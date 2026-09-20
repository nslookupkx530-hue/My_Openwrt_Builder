#!/bin/bash

# ==============================================================================
# 脚本名称: inject_plugins.sh
# 描述: 根据 configs/plugins.cfg 动态修改 .config 文件，开启/关闭用户态插件。
#       确保在开启插件时不改变内核哈希（仅修改 CONFIG_PACKAGE_xxx）。
# ==============================================================================

set -euxo pipefail

CONFIG_FILE=".config"
PLUGIN_CFG="../configs/plugins.cfg"

# --- 校验环境 ---
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: .config file not found! Please run prepare_base_config.sh first."
    exit 1
fi

if [ ! -f "$PLUGIN_CFG" ]; then
    echo "Warning: $PLUGIN_CFG not found, skipping plugin injection."
    exit 0
fi

echo "Starting plugin injection..."

# --- 定义注入规则 ---
# 格式: "变量名|CONFIG_选项"
# 注意：这里只包含用户态应用，不包含 kmod-xxx 或核心驱动
plugins=(
    "ENABLE_ARGON|CONFIG_PACKAGE_luci-app-argon"
    "ENABLE_DISKMAN|CONFIG_PACKAGE_luci-app-diskman"
    "ENABLE_IRQBALANCE|CONFIG_irqbalance"
    "ENABLE_FILEBROWSER_GO|CONFIG_PACKAGE_luci-app-filebrowser-go"
    "ENABLE_SQM|CONFIG_PACKAGE_sqm"
    "ENABLE_TTYD|CONFIG_PACKAGE_luci-app-ttyd"
    "ENABLE_AUTOREBOOT|CONFIG_PACKAGE_luci-app-autoreboot"
    "ENABLE_DOCKER|CONFIG_PACKAGE_docker"
)

# --- 执行注入 ---
for entry in "${plugins[@]}"; do
    # 解析变量名和对应的配置项
    IFS="|" read -r var_name config_opt <<< "$entry"
    
    # 从 plugins.cfg 获取开关状态 (例如 ENABLE_ARGON=1)
    enable_val=$(grep "^${var_name}" "$PLUGIN_CFG" | cut -d'=' -f2 | tr -d ' ')
    
    if [ "$enable_val" = "1" ]; then
        # 如果配置不存在，直接追加，则改为 y
        if ! grep -q "^${config_opt}=y" "$CONFIG_FILE"; then
            echo "Injecting: ${config_opt}=y"
            echo "${config_opt}=y" >> "$CONFIG_FILE"
        fi
    else
        # 如果配置存在且为 y，则改为 n
        if grep -q "^${config_opt}=y" "$CONFIG_FILE"; then
            echo "Disabling: ${config_opt}=n"
            sed -i "s/^${config_opt}=y/${config_opt}=n/" "$CONFIG_FILE"
        fi
    fi
done

echo "Plugin injection completed."
