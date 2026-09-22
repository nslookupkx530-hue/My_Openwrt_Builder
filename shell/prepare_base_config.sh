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

echo ">>> source=${SOURCE_TYPE} device=${TARGET_DEVICE} version=${VERSION:-<latest>} list_profiles=${LIST_PROFILES}"

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
# ⚠ profile 只去首尾空格，中间空格要保留（显示名形式需要）
PROFILE="$(printf '%s' "$PROFILE" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

[ -n "$DEVICE_PATH" ] || { echo "ERROR: ${TARGET_DEVICE} 的 target 路径为空"; exit 1; }
echo ">>> target path=${DEVICE_PATH} profile=${PROFILE:-<未指定>}"

BOARD="$(printf '%s' "$DEVICE_PATH" | cut -d/ -f2)"
SUBTARGET="$(printf '%s' "$DEVICE_PATH" | cut -d/ -f3)"
[ -n "$BOARD" ] && [ -n "$SUBTARGET" ] || {
    echo "ERROR: 无法从 '${DEVICE_PATH}' 解析 board/subtarget"; exit 1; }

# --- 3. 下载 config.buildinfo ---
download_buildinfo() {
    curl -fL --retry 3 --retry-delay 3 --connect-timeout 20 -o tmp_config.buildinfo "$1" 2>/dev/null
}

CHANNEL=""
if [ -z "$VERSION" ]; then
    CHANNEL="snapshot"
    FINAL_URL="${SITE}/snapshots/${DEVICE_PATH}/config.buildinfo"
    echo ">>> 模式: 最新(snapshot) → ${FINAL_URL}"
    if ! download_buildinfo "${FINAL_URL}"; then
        echo "WARNING: snapshot buildinfo 下载失败，回退到最新 release（可能与源码分支不一致）"
        VERSION="$(curl -fsSL --retry 3 --connect-timeout 20 "${SITE}/releases/" \
            | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | sort -Vu | sed -n '$p' || true)"
        [ -n "$VERSION" ] || { echo "ERROR: 无法识别 release 版本"; exit 1; }
        CHANNEL="release-fallback"
        FINAL_URL="${SITE}/releases/${VERSION}/${DEVICE_PATH}/config.buildinfo"
        echo ">>> 回退 → ${FINAL_URL}"
        download_buildinfo "${FINAL_URL}" || { echo "ERROR: 下载失败: ${FINAL_URL}"; exit 1; }
    fi
else
    CHANNEL="release"
    FINAL_URL="${SITE}/releases/${VERSION}/${DEVICE_PATH}/config.buildinfo"
    echo ">>> 模式: release ${VERSION} → ${FINAL_URL}"
    download_buildinfo "${FINAL_URL}" || { echo "ERROR: 下载失败: ${FINAL_URL}"; exit 1; }
fi

grep -q '^CONFIG_TARGET_' tmp_config.buildinfo || {
    echo "ERROR: 下载内容不是 config.buildinfo，前 5 行："; sed -n '1,5p' tmp_config.buildinfo; exit 1; }

mv -f tmp_config.buildinfo .config
echo ">>> 已用 buildinfo 覆盖 .config（channel=${CHANNEL}）"

# --- 3.5列出配置文件 ---
if [ "$LIST_PROFILES" = "1" ]; then
    make defconfig
    echo "=============================================================="
    echo ">>> 候选 profile（symbol 形式，复制其一填进 configs/device_mapping.conf 第二段）"
    grep -oE '^CONFIG_TARGET_[A-Za-z0-9_]+_DEVICE_[A-Za-z0-9_.-]+=y' .config \
        | sed 's/^CONFIG_TARGET_[A-Za-z0-9_]*_DEVICE_//; s/=y$//' | sort -u || true
    echo ">>> 候选 profile（string 形式，若本源码使用）"
    grep -E '^CONFIG_TARGET_PROFILE=' .config || echo "  (无)"
    echo "=============================================================="
    exit 0
fi

# --- 4. 重建配置文件 ---
PROFILE_STYLE=""
if [ -n "$PROFILE" ]; then
    case "$PROFILE" in
        *" "*)
            PROFILE_STYLE="string"
            echo ">>> 按显示名写入 profile: \"${PROFILE}\""
            sed -i '/^CONFIG_TARGET_PROFILE=/d' .config
            printf 'CONFIG_TARGET_PROFILE="%s"\n' "$PROFILE" >> .config
            ;;
        *)
            PROFILE_STYLE="symbol"
            PSYM="CONFIG_TARGET_${BOARD}_${SUBTARGET}_DEVICE_${PROFILE}"
            echo ">>> 按符号写入 profile: ${PSYM}"
            sed -i "/^CONFIG_TARGET_${BOARD}_${SUBTARGET}_DEVICE_[A-Za-z0-9_.-]*=y$/d" .config
            sed -i "/^# CONFIG_TARGET_${BOARD}_${SUBTARGET}_DEVICE_[A-Za-z0-9_.-]* is not set$/d" .config
            for s in CONFIG_TARGET_ALL_PROFILES CONFIG_TARGET_MULTI_PROFILE; do
                grep -q "^${s}=" .config && sed -i "s/^${s}=.*/${s}=n/" .config || true
            done
            echo "${PSYM}=y" >> .config
            ;;
    esac
fi

# --- 5. 执行 make defconfig ---
    # 这一步非常关键：
    # 1. 使用 FORCE=1 是为了跳过 GitHub Actions 环境中可能存在的 host 架构不匹配检查
    # 2. 它会根据我们下载的 .buildinfo 自动补全所有基础依赖、架构相关的内核配置和工具链
echo ">>> make defconfig"
make defconfig

# --- 6. 执行校验 ---    
grep -q "^CONFIG_TARGET_${BOARD}_${SUBTARGET}=y" .config || {
    echo "ERROR: 目标 ${BOARD}/${SUBTARGET} 不在当前源码中 →"
    echo "       源码分支与 buildinfo(${CHANNEL}${VERSION:+/${VERSION}}) 不匹配，请检查 feeds 或改用 source_ref 配套"
    exit 1; }

if [ -n "$PROFILE" ]; then
    PROFILE_OK=0
    if [ "$PROFILE_STYLE" = "string" ]; then
        grep -Fq "CONFIG_TARGET_PROFILE=\"${PROFILE}\"" .config && PROFILE_OK=1 || true
    else
        grep -qE "^${PSYM}=y$" .config && PROFILE_OK=1 || true
    fi
    if [ "$PROFILE_OK" != "1" ]; then
        echo "ERROR: profile '${PROFILE}' 未被 defconfig 保留 → 本源码不认这个值"
        echo ">>> 本源码可用的 profile（复制其一填进 configs/device_mapping.conf 第二段）："
        grep -oE '^CONFIG_TARGET_[A-Za-z0-9_]+_DEVICE_[A-Za-z0-9_.-]+=y' .config \
            | sed 's/^CONFIG_TARGET_[A-Za-z0-9_]*_DEVICE_//; s/=y$//' | sort -u | sed -n '1,40p' || true
        grep -E '^CONFIG_TARGET_PROFILE=' .config || true
        exit 1
    fi
    echo ">>> profile 校验通过: ${PROFILE}"
fi

echo "=============================================================="
echo ">>> .config 摘要 (source=${SOURCE_TYPE} device=${TARGET_DEVICE} channel=${CHANNEL} version=${VERSION:-latest})"
grep -E "^CONFIG_TARGET_${BOARD}_${SUBTARGET}(_DEVICE_[A-Za-z0-9_.-]+)?=y$" .config || true
grep -E '^CONFIG_TARGET_PROFILE=' .config || true
echo ">>> 已启用 device 选项数: $(grep -cE "^CONFIG_TARGET_${BOARD}_${SUBTARGET}_DEVICE_[A-Za-z0-9_.-]+=y$" .config || true)"
echo ">>> 已启用包数量: $(grep -c '^CONFIG_PACKAGE_.*=y' .config || true)"
echo "=============================================================="
