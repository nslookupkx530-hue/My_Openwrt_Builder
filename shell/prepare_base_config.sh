#!/bin/bash

# ==============================================================================
# 脚本名称: prepare_base_config.sh
# 描述: 
#   1. 自动识别并下载官方/ImmortalWrt 的最新稳定版 config.buildinfo
#   2. 用 configs/device_mapping.conf 解析 target 路径与 profile
#   3. 执行 make defconfig 确保基础依赖完整
# 
# 使用方法: 
#   bash ../shell/prepare_base_config.sh [source_type] [device]
#   bash ../shell/prepare_base_config.sh --list-profiles <device>   # 列出候选 profile
#
# 环境变量：SOURCE_TYPE / TARGET_DEVICE / VERSION（留空=自动抓最新 release）
# ==============================================================================

set -euxo pipefail

LIST_PROFILES=0
if [ "${1:-}" = "--list-profiles" ]; then LIST_PROFILES=1; shift; fi

# 允许通过环境变量传入：SOURCE_TYPE (openwrt|immortalwrt), TARGET_DEVICE
SOURCE_TYPE="${1:-${SOURCE_TYPE:-immortalwrt}}"    # 默认 immortalwrt
TARGET_DEVICE="${2:-${TARGET_DEVICE:-x86}}"      # 默认 x86 (对应 x86/64)
VERSION="${VERSION:-}"      #对应版本号

echo ">>> source=${SOURCE_TYPE} device=${TARGET_DEVICE} version=${VERSION:-<auto:latest stable>} list_profiles=${LIST_PROFILES}"

# --- 环境自检 ---
[ -f ./Makefile ] && [ -d ./scripts ] || {
    echo "ERROR: 当前目录不是 buildroot（$(pwd)），请 cd 到 src/ 后执行"; exit 1; }
[ -d ./feeds ] || echo "WARNING: ./feeds 不存在，feeds 可能尚未安装"

case "$SOURCE_TYPE" in
    immortalwrt) SITE="https://downloads.immortalwrt.org" ;;
    openwrt)     SITE="https://downloads.openwrt.org" ;;
    *) echo "ERROR: 不支持的 SOURCE_TYPE: ${SOURCE_TYPE}"; exit 1 ;;
esac

# --- 1. 设备映射 (核心：确保内核哈希一致) ---
MAPPING_FILE="../configs/device_mapping.conf"

[ -f "$MAPPING_FILE" ] || {
    echo "ERROR: 找不到映射文件 ${MAPPING_FILE}（当前目录：$(pwd)）"; exit 1; }

# 改进的提取逻辑：
# 1. 使用 tr 删除可能存在的 Windows 换行符 (\r)
# 2. 使用 sed 去除每行开头的空格
# 3. 使用 grep 匹配包含设备名的行
# 4. 使用 cut 获取等号后的内容并去除多余空格
DEVICE_LINE="$(sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$MAPPING_FILE" \
    | grep -E "^${TARGET_DEVICE}=" | sed -n '$p' || true)"

if [ -z "$DEVICE_LINE" ]; then
    echo "ERROR: 设备 '${TARGET_DEVICE}' 未在 ${MAPPING_FILE} 中定义。可用设备："
    sed -e 's/#.*//' "$MAPPING_FILE" | sed '/^[[:space:]]*$/d' | cut -d= -f1
    exit 1
fi

case "$DEVICE_LINE" in
    *"|"*) DEVICE_PATH="${DEVICE_LINE#*=}"; DEVICE_PATH="${DEVICE_PATH%%|*}"; PROFILE="${DEVICE_LINE#*|}" ;;
    *)     DEVICE_PATH="${DEVICE_LINE#*=}"; PROFILE="" ;;
esac

DEVICE_PATH="$(printf '%s' "$DEVICE_PATH" | tr -d '[:space:]')"
# profile 只去首尾空格，中间空格必须保留（显示名形式需要）
PROFILE="$(printf '%s' "$PROFILE" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

[ -n "$DEVICE_PATH" ] || { echo "ERROR: ${TARGET_DEVICE} 的 target 路径为空"; exit 1; }
echo ">>> target path=${DEVICE_PATH} profile=${PROFILE:-<未指定，会编出该 target 全套镜像>}"

BOARD="$(printf '%s' "$DEVICE_PATH" | cut -d/ -f2)"
SUBTARGET="$(printf '%s' "$DEVICE_PATH" | cut -d/ -f3)"
[ -n "$BOARD" ] && [ -n "$SUBTARGET" ] || {
    echo "ERROR: 无法从 '${DEVICE_PATH}' 解析 board/subtarget"; exit 1; }

# --- 3. 下载 config.buildinfo ---
download_buildinfo() {
    curl -fL --retry 3 --retry-delay 3 --connect-timeout 20 -o tmp_config.buildinfo "$1" 2>/dev/null
}

CHANNEL=""
if [ "$VERSION" = "snapshot" ]; then
    CHANNEL="snapshot"
    VERSION=""
    FINAL_URL="${SITE}/snapshots/${DEVICE_PATH}/config.buildinfo"
    echo ">>> 模式: 开发快照(snapshot) → ${FINAL_URL}"
elif [ -n "$VERSION" ]; then
    CHANNEL="release"
    FINAL_URL="${SITE}/releases/${VERSION}/${DEVICE_PATH}/config.buildinfo"
    echo ">>> 模式: 指定稳定版 ${VERSION} → ${FINAL_URL}"
else
    CHANNEL="stable"
    echo ">>> 模式: 最新稳定版（自动识别）"
    VERSION="$(curl -fsSL --retry 3 --connect-timeout 20 "${SITE}/releases/" \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | sort -Vu | sed -n '$p' || true)"
    [ -n "$VERSION" ] || { echo "ERROR: 无法识别最新稳定版本，请显式传入 VERSION"; exit 1; }
    FINAL_URL="${SITE}/releases/${VERSION}/${DEVICE_PATH}/config.buildinfo"
    echo ">>> 最新稳定版: ${VERSION}"
    echo ">>> 基线地址: ${FINAL_URL}"
fi

if ! download_buildinfo "${FINAL_URL}"; then
    echo "WARNING: ${CHANNEL} 的 buildinfo 下载失败（${FINAL_URL}）"
    echo "WARNING: 回退到 snapshot；若源码不是默认分支，可能符号错配"
    CHANNEL="snapshot-fallback"
    FINAL_URL="${SITE}/snapshots/${DEVICE_PATH}/config.buildinfo"
    echo ">>> 回退地址: ${FINAL_URL}"
    download_buildinfo "${FINAL_URL}" || { echo "ERROR: 下载失败: ${FINAL_URL}"; exit 1; }
fi

grep -q '^CONFIG_TARGET_' tmp_config.buildinfo || {
    echo "ERROR: 下载内容不是 config.buildinfo，前 5 行："
    sed -n '1,5p' tmp_config.buildinfo
    exit 1
}

mv -f tmp_config.buildinfo .config
echo ">>> 已用 buildinfo 覆盖 .config（channel=${CHANNEL} version=${VERSION:-snapshot}）"

# --- 4. 执行 make defconfig ---
echo ">>> make defconfig（第 1 次：生成元数据 + 规范化）"
make defconfig

# ================================================================
#  device 选项解析（不用 awk；按元数据里实际存在的选项来）
# ================================================================
dev_symbols() {
    if [ ! -f tmp/.config-target.in ]; then
        return 0
    fi
    grep -oE 'TARGET_(DEVICE_)?[A-Za-z0-9_]+_DEVICE_[A-Za-z0-9_.-]+' tmp/.config-target.in | sort -u
}

profile_key() {
    printf '%s' "$1" | sed -E 's/^TARGET_DEVICE_//; s/^TARGET_//; s/^[A-Za-z0-9_]+_DEVICE_//'
}

profile_prompt() {
    grep -A1 -E "^[[:space:]]*config[[:space:]]+$1\$" tmp/.config-target.in 2>/dev/null \
        | sed -n '2p' \
        | sed -e 's/^[[:space:]]*bool[[:space:]]*//' -e 's/^"//' -e 's/"[[:space:]]*$//'
}

show_profiles() {
    local sym key prompt
    dev_symbols | while read -r sym; do
        key="$(profile_key "$sym")"
        prompt="$(profile_prompt "$sym")"
        printf '  key=%-45s %s\n' "$key" "$prompt"
    done
}

resolve_profile() {
    local cand hit
    for cand in "TARGET_DEVICE_${1}_${2}_DEVICE_${3}" "TARGET_${1}_${2}_DEVICE_${3}"; do
        if dev_symbols | grep -qx "$cand"; then
            printf 'CONFIG_%s\n' "$cand"
            return 0
        fi
    done
    hit="$(grep -i -B1 -F -- "$3" tmp/.config-target.in 2>/dev/null \
        | grep -oE 'TARGET_(DEVICE_)?[A-Za-z0-9_]+_DEVICE_[A-Za-z0-9_.-]+' | sed -n '1p')"
    if [ -n "$hit" ]; then
        printf 'CONFIG_%s\n' "$hit"
        return 0
    fi
    return 1
}

# --- 4.5列出配置文件 ---
if [ "$LIST_PROFILES" = "1" ]; then
    echo "=============================================================="
    echo ">>> 本 target (${BOARD}/${SUBTARGET}) 可选的 device 选项"
    echo ">>> 把 key 或显示名填进 configs/device_mapping.conf 第二段，两种写法都支持"
    show_profiles
    echo "=============================================================="
    exit 0
fi

# --- 5. 重建配置文件 ---
PROFILE_SYMBOL=""
if [ -n "$PROFILE" ]; then
    echo ">>> 解析 profile: ${PROFILE}"
    PROFILE_SYMBOL="$(resolve_profile "$BOARD" "$SUBTARGET" "$PROFILE" || true)"
    if [ -z "$PROFILE_SYMBOL" ]; then
        echo "ERROR: 当前源码里找不到与 '${PROFILE}' 匹配的 device 选项"
        echo ">>> 可选项（把 key 或显示名填进 configs/device_mapping.conf 第二段）："
        show_profiles
        exit 1
    fi
    echo ">>> 命中选项: ${PROFILE_SYMBOL}"

    sed -i "/^CONFIG_TARGET_DEVICE_${BOARD}_${SUBTARGET}_DEVICE_[A-Za-z0-9_.-]*=/d" .config
    sed -i "/^CONFIG_TARGET_${BOARD}_${SUBTARGET}_DEVICE_[A-Za-z0-9_.-]*=/d" .config
    for s in CONFIG_TARGET_ALL_PROFILES CONFIG_TARGET_MULTI_PROFILE; do
        if grep -q "^${s}=" .config; then
            sed -i "s/^${s}=.*/${s}=n/" .config
        fi
    done
    echo "${PROFILE_SYMBOL}=y" >> .config
fi

# --- 6. 再次执行 make defconfig ---
    # 这一步非常关键：
    # 1. 使用 FORCE=1 是为了跳过 GitHub Actions 环境中可能存在的 host 架构不匹配检查
echo ">>> make defconfig（第 2 次：应用 profile + 补依赖）"
make defconfig

# --- 7. 执行校验 ---    
grep -q "^CONFIG_TARGET_${BOARD}_${SUBTARGET}=y" .config || {
    echo "ERROR: 目标 ${BOARD}/${SUBTARGET} 不在当前源码中"
    echo "       源码分支与基线 ${CHANNEL}${VERSION:+/$VERSION} 不配套，请检查 Clone 步骤日志里的 ref"
    exit 1
}

if [ -n "$PROFILE" ]; then
    if ! grep -q "^${PROFILE_SYMBOL}=y" .config; then
        echo "ERROR: ${PROFILE_SYMBOL} 未被 defconfig 保留"
        echo ">>> 可选项："
        show_profiles
        exit 1
    fi
    echo ">>> profile 校验通过: ${PROFILE_SYMBOL}"
fi

DEV_ON="$(grep -cE "^CONFIG_TARGET_DEVICE_${BOARD}_${SUBTARGET}_DEVICE_[A-Za-z0-9_.-]*=y$" .config || true)"
echo "=============================================================="
echo ">>> .config 摘要 (source=${SOURCE_TYPE} device=${TARGET_DEVICE} channel=${CHANNEL} version=${VERSION:-snapshot})"
grep -E "^CONFIG_TARGET_${BOARD}_${SUBTARGET}(_DEVICE_[A-Za-z0-9_.-]+)?=y$" .config || true
echo ">>> 已启用 device 选项数: ${DEV_ON:-0}   (期望 1；大于 1 说明没收窄干净)"
echo ">>> 已启用包数量: $(grep -c '^CONFIG_PACKAGE_.*=y' .config || true)"
echo "=============================================================="
