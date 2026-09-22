#!/bin/bash

# ==============================================================================
# 脚本名称: inject_plugins.sh
# 描述: 
#   根据 configs/plugins.cfg 动态修改 .config 文件，开启/关闭用户态插件。
#   优化点：采用幂等性处理逻辑，确保配置项的唯一性和确定性，助力哈希对齐。
# ==============================================================================

set -euxo pipefail

CONFIG_FILE=".config"
# 开关文件在 configs/ 根目录（不是 configs/<SOURCE_TYPE>/ 下）
PLUGIN_CFG="../configs/plugins.cfg"
STRICT_SYMBOL_CHECK="${STRICT_SYMBOL_CHECK:-0}"

[ -f "$CONFIG_FILE" ] || { echo "ERROR: 找不到 .config，请先运行 prepare_base_config.sh"; exit 1; }
[ -f "$PLUGIN_CFG" ]  || { echo "ERROR: 找不到 ${PLUGIN_CFG}"; exit 1; }   # 硬失败，不再静默跳过

# 开关 → 选项 映射表
plugins=(
    "ENABLE_ARGON|CONFIG_PACKAGE_luci-theme-argon"
    "ENABLE_DISKMAN|CONFIG_PACKAGE_luci-app-diskman"
    "ENABLE_IRQBALANCE|CONFIG_PACKAGE_irqbalance"
    "ENABLE_FILEBROWSER_GO|CONFIG_PACKAGE_luci-app-filebrowser-go"
    "ENABLE_SQM|CONFIG_PACKAGE_sqm-scripts"
    "ENABLE_TTYD|CONFIG_PACKAGE_luci-app-ttyd"
    "ENABLE_AUTOREBOOT|CONFIG_PACKAGE_luci-app-autoreboot"
    "ENABLE_DOCKER|CONFIG_PACKAGE_docker"
)

get_switch() {   # 取最后一次定义，忽略注释与空格
    sed -e 's/#.*//' -e 's/[[:space:]]//g' "$PLUGIN_CFG" \
        | grep -E "^$1=" | sed -n '$p' | cut -d= -f2
}

symbol_exists() {
    local sym="${1#CONFIG_}"
    ls tmp/.config-*.in >/dev/null 2>&1 || return 0
    grep -qE "^[[:space:]]*config ${sym}$" tmp/.config-*.in 2>/dev/null
}

set_opt() {   # $1=选项名 $2=y|n
    sed -i "/^$1=/d; /^# $1 is not set$/d" "$CONFIG_FILE"
    case "$2" in
        y) echo "$1=y" >> "$CONFIG_FILE" ;;
        n) echo "# $1 is not set" >> "$CONFIG_FILE" ;;
    esac
}

mkdir -p tmp
: > tmp/injected-plugins.txt

TOTAL=0; ENABLED=0; UNKNOWN=""
for entry in "${plugins[@]}"; do
    IFS="|" read -r var_name config_opt <<< "$entry"
    enable_val="$(get_switch "$var_name" || true)"
    TOTAL=$((TOTAL + 1))

    if [ -z "$enable_val" ]; then
        echo "WARNING: ${PLUGIN_CFG} 中没有 ${var_name}，按禁用处理"
    elif [ "$enable_val" != "0" ] && [ "$enable_val" != "1" ]; then
        echo "ERROR: ${var_name}=${enable_val} 非法（只允许 0 或 1）"; exit 1
    fi

    if [ "$enable_val" = "1" ]; then
        if ! symbol_exists "$config_opt"; then
            echo "WARNING: ${config_opt} 在当前源码中不存在，注入无效（请核对选项名）"
            UNKNOWN="$UNKNOWN ${config_opt}"
            [ "$STRICT_SYMBOL_CHECK" = "1" ] && exit 1
        fi
        set_opt "$config_opt" y
        echo "$config_opt" >> tmp/injected-plugins.txt
        ENABLED=$((ENABLED + 1))
    else
        set_opt "$config_opt" n
    fi
done

# 反向校验：cfg 里有、映射表里没有的开关
# ⚠ 这里必须用 [:blank:]（只删空格/Tab）；用 [:space:] 会把换行也删掉，导致所有名字被拼成一个
MAPPED_NAMES="$(printf '%s\n' "${plugins[@]}" | cut -d'|' -f1)"
for v in $(sed -e 's/#.*//' "$PLUGIN_CFG" \
           | grep -oE '^[[:space:]]*ENABLE_[A-Z0-9_]+' | tr -d '[:blank:]'); do
    echo "$MAPPED_NAMES" | grep -qx "$v" || \
        echo "WARNING: ${v} 在 ${PLUGIN_CFG} 中定义，但脚本映射表里没有，将被忽略"
done

echo "Plugin injection done: ${ENABLED}/${TOTAL} enabled"
[ -z "$UNKNOWN" ] || echo "WARNING: 以下选项在源码中不存在:${UNKNOWN}"
