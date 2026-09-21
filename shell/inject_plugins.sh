#!/bin/bash

# ==============================================================================
# 脚本名称: inject_plugins.sh
# 描述: 
#   根据 configs/plugins.cfg 动态修改 .config 文件，开启/关闭用户态插件。
#   优化点：采用幂等性处理逻辑，确保配置项的唯一性和确定性，助力哈希对齐。
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

echo "Starting deterministic plugin injection..."

# --- 定义注入规则 ---
# 格式: "变量名|CONFIG_选项"
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
        # --- 目标：确保配置项为 y ---
        if grep -q "^${config_opt}=y" "$CONFIG_FILE"; then
            echo "Status: ${config_opt} is already enabled."
        elif grep -q "^${config_opt}" "$CONFIG_FILE"; then
            # 如果存在但不是 y（可能是 n），则替换为 y
            sed -i "s/^${config_opt}=.*/${config_opt}=y/" "$CONFIG_FILE"
            echo "Action: Updating ${config_opt} to enabled (y)."
        else
            # 如果完全不存在，则追加到文件末尾
            echo "${config_opt}=y" >> "$CONFIG_FILE"
            echo "Action: Appending ${config_opt} as enabled (y)."
        fi
    else
        # --- 目标：确保配置项为 n 或不存在 ---
        if grep -q "^${config_opt}=y" "$CONFIG_FILE"; then
            # 如果是 y，则替换为 n
            sed -i "s/^${config_opt}=y/${config_opt}=n/" "$CONFIG_FILE"
            echo "Action: Updating ${config_opt} to disabled (n)."
        elif grep -q "^${config_opt}" "$CONFIG_FILE"; then
            # 如果已经是 n，则不做处理
            echo "Status: ${config_opt} is already disabled."
        fi
    fi
done

echo "Plugin injection completed successfully."
