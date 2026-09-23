#!/bin/bash

# ==============================================================================
# 脚本名称: inject_plugins.sh
# 描述: 
#   根据 configs/plugins.cfg 动态修改 .config 文件，开启/关闭用户态插件。
#   优化点：采用幂等性处理逻辑，确保配置项的唯一性和确定性，助力哈希对齐。
# ==============================================================================

set -euo pipefail

CONFIG_FILE="${CONFIG_FILE:-.config}"
PLUGIN_CFG="${PLUGIN_CFG:-../configs/plugins.cfg}"
OUT_FILE="${OUT_FILE:-tmp/injected-plugins.txt}"

echo ">>> inject_plugins.sh"

if [ ! -f "$PLUGIN_CFG" ]; then
    echo "ERROR: 找不到插件开关文件 ${PLUGIN_CFG}" >&2
    exit 1
fi
if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: 找不到 ${CONFIG_FILE}（本脚本必须在 src/ 下执行，且已生成基础配置）" >&2
    exit 1
fi

mkdir -p "$(dirname "$OUT_FILE")"
: > "$OUT_FILE"

# ------------------------------------------------------------ 映射表
# 格式：  "开关名|选项1 选项2 选项3"
# 注意：这里是 .config 里的真实符号（去掉 CONFIG_ 前缀）
PLUGIN_MAP=(
    "ENABLE_ARGON|luci-theme-argon luci-app-argon-config luci-i18n-argon-config-zh-cn"
    "ENABLE_DISKMAN|luci-app-diskman luci-i18n-diskman-zh-cn"
    "ENABLE_IRQBALANCE|irqbalance luci-app-irqbalance luci-i18n-irqbalance-zh-cn"
    "ENABLE_FILEBROWSER_GO|luci-app-filebrowser-go luci-i18n-filebrowser-go-zh-cn"
    "ENABLE_SQM|luci-app-sqm luci-i18n-sqm-zh-cn"
    "ENABLE_TTYD|luci-app-ttyd luci-i18n-ttyd-zh-cn"
    "ENABLE_AUTOREBOOT|luci-app-autoreboot luci-i18n-autoreboot-zh-cn"
    "ENABLE_IRQBALANCE|smartdns luci-app-smartdns luci-i18n-smartdns-zh-cn"
    "ENABLE_DOCKER|docker luci-app-dockerman luci-i18n-dockerman-zh-cn"
)

# 读开关（plugins.cfg 里形如 ENABLE_SQM=1）
# shellcheck disable=SC1090
. "$PLUGIN_CFG"

is_on() {
    local flag="$1" val=""
    eval "val=\${${flag}:-0}"
    case "$val" in
        1|y|Y|yes|YES|true|TRUE|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

# 幂等写入：先清掉 `SYM=y` 和 `# SYM is not set`，再追加唯一一行
set_opt_on() {
    local sym="CONFIG_PACKAGE_$1"
    sed -i -e "/^${sym}=/d" -e "/^# ${sym} is not set[[:space:]]*$/d" "$CONFIG_FILE"
    printf '%s=y\n' "$sym" >> "$CONFIG_FILE"
    printf '%s\n'   "$sym" >> "$OUT_FILE"
}

enabled_flags=0
for entry in "${PLUGIN_MAP[@]}"; do
    flag="${entry%%|*}"
    opts="${entry#*|}"
    if is_on "$flag"; then
        echo ">>> ${flag}=1  →  ${opts}"
        for o in $opts; do
            set_opt_on "$o"
        done
        enabled_flags=$((enabled_flags + 1))
    else
        echo ">>> ${flag}=0  →  跳过"
    fi
done

echo ">>> 已开启开关数: ${enabled_flags}"
echo ">>> 注入选项清单（${OUT_FILE}）:"
sed 's/^/      /' "$OUT_FILE"
[ "$enabled_flags" -gt 0 ] || echo ">>> 提示：没有任何插件开关被打开"
