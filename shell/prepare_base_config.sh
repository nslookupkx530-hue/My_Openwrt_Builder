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
    *"|"*) DEVICE_PATH="${DEVICE_LINE#*=}"; DEVICE_PATH="${DEVICE_PATH%%|*}"
           PROFILE="${DEVICE_LINE#*|}"; PROFILE="${PROFILE%%|*}" ;;
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
    # 排除 TARGET_DEVICE_PACKAGES_* 这类"附加包列表"符号（它们是 string 选项，不是设备）
    grep -oE 'TARGET_(DEVICE_)?[A-Za-z0-9_]+_DEVICE_[A-Za-z0-9_.-]+' tmp/.config-target.in \
      | grep -vE '^TARGET_DEVICE_PACKAGES_' \
      | sort -u
}

profile_key() {
    printf '%s' "$1" | sed -E 's/^TARGET_DEVICE_//; s/^TARGET_//; s/^[A-Za-z0-9_]+_DEVICE_//'
}

profile_prompt() {
    grep -A2 -E "^[[:space:]]*config[[:space:]]+$1\$" tmp/.config-target.in 2>/dev/null \
        | grep -m1 -E '^[[:space:]]*bool[[:space:]]*"' \
        | sed -e 's/^[[:space:]]*bool[[:space:]]*//' -e 's/^"//' -e 's/"[[:space:]]*$//'
}

show_profiles() {
    local sym key prompt syms
    syms="$(dev_symbols | grep -E "^(TARGET_DEVICE_|TARGET_)${BOARD}_${SUBTARGET}_DEVICE_" || true)"
    if [ -z "${syms}" ]; then
        echo "  （没有解析出 ${BOARD}/${SUBTARGET} 的设备符号，请检查 tmp/.config-target.in）"
        return 0
    fi
    while read -r sym; do
        [ -n "${sym}" ] || continue
        key="$(profile_key "$sym")"
        prompt="$(profile_prompt "$sym")"
        printf '  key=%-45s %s\n' "$key" "$prompt"
    done <<< "${syms}"
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

# --- 5. 重建配置文件（收窄到单设备）---
PROFILE_SYMBOL=""
if [ -n "$PROFILE" ]; then
    echo ">>> 解析 profile: ${PROFILE}"
    PROFILE_SYMBOL="$(resolve_profile "$BOARD" "$SUBTARGET" "$PROFILE" || true)"
    if [ -z "$PROFILE_SYMBOL" ]; then
        echo "ERROR: 当前源码里找不到与 '${PROFILE}' 匹配的 device 选项"
        show_profiles
        exit 1
    fi
    echo ">>> 命中选项: ${PROFILE_SYMBOL}"

    # 该 board/subtarget 下所有 device 符号（两种命名前缀都取）
    ALL_SYMS="$(dev_symbols | grep -E "^(TARGET_DEVICE_|TARGET_)${BOARD}_${SUBTARGET}_DEVICE_" | sort -u)"
    [ -n "$ALL_SYMS" ] || {
        echo "ERROR: 在 tmp/.config-target.in 里找不到 ${BOARD}_${SUBTARGET} 的 device 符号"; exit 1; }

    # 5.1 删掉这些符号的旧行（=y 与 is not set 都删）
    while read -r s; do
        [ -n "$s" ] || continue
        sed -i -e "/^CONFIG_${s}=/d" -e "/^# CONFIG_${s} is not set$/d" .config
    done <<< "${ALL_SYMS}"

    # 5.2 关掉"全 profile / 多 profile"（必须无条件显式写，
    #     config.buildinfo 里可能压根没有这两行，原来"有才改"的写法会静默跳过）
    for s in CONFIG_TARGET_ALL_PROFILES CONFIG_TARGET_MULTI_PROFILE; do
        sed -i -e "/^${s}=/d" -e "/^# ${s} is not set$/d" .config
        printf '# %s is not set\n' "${s}" >> .config
    done

    # 5.3 目标设备 =y，其余显式 "is not set"
    #     关键：这些符号在 Kconfig 里是 default y，只删 =y 行的话 defconfig 会把它们全开回来
    n_total=0; n_on=0
    while read -r s; do
        [ -n "$s" ] || continue
        n_total=$((n_total+1))
        if [ "CONFIG_${s}" = "${PROFILE_SYMBOL}" ]; then
            printf 'CONFIG_%s=y\n' "${s}" >> .config
            n_on=$((n_on+1))
        else
            printf '# CONFIG_%s is not set\n' "${s}" >> .config
        fi
    done <<< "${ALL_SYMS}"
    echo ">>> 本 target 共 ${n_total} 个 device 符号：1 台 =y / $((n_total-1)) 台 is not set"
    [ "${n_on}" = "1" ] || {
        echo "ERROR: ${PROFILE_SYMBOL} 不在本 target 的 device 列表里（解析结果异常）"
        show_profiles; exit 1; }
fi

# --- 6. 再次执行 make defconfig ---
echo ">>> make defconfig（第 2 次：应用 profile + 补依赖）"
make defconfig

# --- 7. 执行校验 ---
grep -q "^CONFIG_TARGET_${BOARD}_${SUBTARGET}=y" .config || {
    echo "ERROR: 目标 ${BOARD}/${SUBTARGET} 不在当前源码中"
    echo "       源码分支与基线 ${CHANNEL}${VERSION:+/$VERSION} 不配套，请检查 Clone 步骤日志里的 ref"
    exit 1
}

# 收窄后重新数一次：两种前缀都数，不满足 1 就硬失败
DEV_ON="$(grep -E "^CONFIG_(TARGET_DEVICE_|TARGET_)${BOARD}_${SUBTARGET}_DEVICE_[A-Za-z0-9_.-]+=y$" .config | wc -l)"
echo ">>> 收窄后已启用 device 选项数: ${DEV_ON}   (期望 1)"
grep -E "^CONFIG_(TARGET_DEVICE_|TARGET_)${BOARD}_${SUBTARGET}_DEVICE_[A-Za-z0-9_.-]+=y$" .config \
  | sed 's/^/    /' || true

if [ -n "$PROFILE" ]; then
    grep -q "^${PROFILE_SYMBOL}=y" .config || {
        echo "ERROR: ${PROFILE_SYMBOL} 未被 defconfig 保留（可能被别的选项顶掉）"
        show_profiles; exit 1; }
    [ "${DEV_ON}" = "1" ] || {
        echo "ERROR: 收窄失败，仍有 ${DEV_ON} 台设备被选中 —— 会编全 target 镜像并超时"
        echo ">>> 把上面列出的符号也补进 is not set 列表，或检查 ALL_PROFILES 开关"
        exit 1; }
    echo ">>> profile 收窄校验通过：本 target 只编这 1 台"
else
    echo "::warning::未指定 profile → ${BOARD}/${SUBTARGET} 下 ${DEV_ON} 台设备的镜像都会被编（filogic 上必超时）"
fi

echo "=============================================================="
echo ">>> .config 摘要 (source=${SOURCE_TYPE} device=${TARGET_DEVICE} channel=${CHANNEL} version=${VERSION:-snapshot})"
grep -E "^CONFIG_TARGET_${BOARD}_${SUBTARGET}(_DEVICE_[A-Za-z0-9_.-]+)?=y$" .config || true
echo ">>> 已启用 device 选项数: ${DEV_ON:-0}   (期望 1；大于 1 说明没收窄干净)"
echo ">>> 已启用包数量: $(grep -c '^CONFIG_PACKAGE_.*=y' .config || true)"
echo "=============================================================="
