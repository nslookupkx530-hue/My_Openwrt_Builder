#!/bin/bash

# ==============================================================================
# 脚本名称: inject_plugins.sh
# 描述: 
#   根据 configs/plugins.cfg 动态修改 .config 文件，开启/关闭用户态插件。
#   优化点：采用幂等性处理逻辑，确保配置项的唯一性和确定性，助力哈希对齐。
#    A) 按需打开 LuCI 语言开关 CONFIG_LUCI_LANG_zh_Hans
#       —— 否则 luci-i18n-*-zh-cn 会因依赖不满足被 make defconfig 丢掉
#          （immortalwrt 那边默认开了中文所以一直没问题；openwrt 上游只有 en）
#    B) 注入前检查"本源码树是否真的有这个包"
#       —— openwrt 上游的 luci/packages 比 immortalwrt 少一批包
#          （argon / diskman / filebrowser-go / autoreboot / ramfree 等），
#          不存在就直接跳过，避免变成 MISS 并让构建失败
# ==============================================================================

set -euo pipefail

CONFIG_FILE="${CONFIG_FILE:-.config}"
PLUGIN_CFG="${PLUGIN_CFG:-../configs/plugins.cfg}"
OUT_FILE="${OUT_FILE:-tmp/injected-plugins.txt}"
PKG_IN="${PKG_IN:-tmp/.config-package.in}"

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
PLUGIN_MAP=(
    "ENABLE_ARGON|luci-theme-argon luci-app-argon-config luci-i18n-argon-config-zh-cn"
    "ENABLE_DISKMAN|luci-app-diskman luci-i18n-diskman-zh-cn"
    "ENABLE_IRQBALANCE|irqbalance luci-app-irqbalance luci-i18n-irqbalance-zh-cn"
    "ENABLE_FILEBROWSER_GO|luci-app-filebrowser-go luci-i18n-filebrowser-go-zh-cn"
    "ENABLE_SQM|luci-app-sqm luci-i18n-sqm-zh-cn"
    "ENABLE_TTYD|luci-app-ttyd luci-i18n-ttyd-zh-cn"
    "ENABLE_AUTOREBOOT|luci-app-autoreboot luci-i18n-autoreboot-zh-cn"
    "ENABLE_SMARTDNS|smartdns luci-app-smartdns luci-i18n-smartdns-zh-cn"
    "ENABLE_RAMFREE|luci-app-ramfree luci-i18n-ramfree-zh-cn"
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

# ------------------------------------------------------------ 包存在性检查
# 只有"本源码树真的存在这个包"才注入。
# ⚠️ tmp/.config-package.in 里的条目带前导制表符（\tconfig PACKAGE_xxx），
#    正则必须允许前导空白，否则全部匹配不到 → 会把所有包都误判成不存在！
pkg_symbol_exists() {               # $1 = 不带 CONFIG_PACKAGE_ 前缀的包名
    [ -f "$PKG_IN" ] || return 0    # 拿不到清单时不拦（保守放行）
    local esc
    esc="$(printf '%s' "$1" | sed 's/[.[\*^$]/\\&/g')"
    grep -qE "^[[:space:]]*config[[:space:]]+PACKAGE_${esc}([[:space:]]|\$)" "$PKG_IN"
}

# ------------------------------------------------------------ 幂等写入
# 先清掉 `SYM=y` 和 `# SYM is not set`，再追加唯一一行
set_opt_on() {
    local sym="CONFIG_PACKAGE_$1"
    sed -i -e "/^${sym}=/d" -e "/^# ${sym} is not set[[:space:]]*$/d" "$CONFIG_FILE"
    printf '%s=y\n' "$sym" >> "$CONFIG_FILE"
    printf '%s\n'   "$sym" >> "$OUT_FILE"
}

# ------------------------------------------------------------ 语言开关
# LuCI 的 i18n 包依赖 CONFIG_LUCI_LANG_<lang>（见 feeds/luci/luci.mk 的 LUCI_LANGUAGES）。
# 按"注入清单里出现的语言后缀"按需打开；符号不存在则跳过，不报错。
enable_luci_lang() {                 # $1 = 语言代号，如 zh_Hans / zh_Hant
    local sym="CONFIG_LUCI_LANG_$1"
    if grep -qE "^${sym}=" "$CONFIG_FILE" || grep -qE "^# ${sym} is not set" "$CONFIG_FILE"; then
        sed -i -e "/^${sym}=/d" -e "/^# ${sym} is not set\$/d" "$CONFIG_FILE"
        printf '%s=y\n' "${sym}" >> "$CONFIG_FILE"
        echo ">>> 已启用 ${sym}（中文 i18n 包的前置条件）"
    else
        echo ">>> 跳过 ${sym}（本源码树没有这个语言开关）"
    fi
}

# ------------------------------------------------------------ 主循环
SKIPPED_PKGS=""
enabled_flags=0

for entry in "${PLUGIN_MAP[@]}"; do
    flag="${entry%%|*}"
    opts="${entry#*|}"
    if is_on "$flag"; then
        echo ">>> ${flag}=1  →  ${opts}"
        for o in $opts; do
            if ! pkg_symbol_exists "$o"; then
                echo ">>> 跳过 $o（本源码树没有这个包）"
                SKIPPED_PKGS="${SKIPPED_PKGS} $o"
                continue
            fi
            set_opt_on "$o"
        done
        enabled_flags=$((enabled_flags + 1))
    else
        echo ">>> ${flag}=0  →  跳过"
    fi
done

# ------------------------------------------------------------ 按需开语言开关
if grep -q -- '-zh-cn' "$OUT_FILE" 2>/dev/null; then enable_luci_lang zh_Hans; fi
if grep -q -- '-zh-tw' "$OUT_FILE" 2>/dev/null; then enable_luci_lang zh_Hant; fi

# ------------------------------------------------------------ 汇总
echo ">>> 已开启开关数: ${enabled_flags}"
echo ">>> 本源码树不存在的包（已跳过，未计入注入清单）:${SKIPPED_PKGS:-<无>}"
echo ">>> 注入选项清单（${OUT_FILE}）:"
sed 's/^/      /' "$OUT_FILE"
[ "$enabled_flags" -gt 0 ] || echo ">>> 提示：没有任何插件开关被打开"
