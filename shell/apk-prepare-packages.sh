#!/bin/bash

# ============================================================
# ImmortalWrt 25.12.x 第三方 APK 插件配置
# ============================================================
#
# 支持架构: x86, arm64, arm64-a53, arm (通用)
#
# 工作方式:
# 1. 优先寻找 .run 脚本进行动态解包
# 2. 若无脚本，寻找包含核心关键词的静态文件夹并提取 APK
# 3. 核心关键词提取逻辑：自动去除 -i18n- 和 -zh-cn 等后缀
#
# ============================================================

set -euxo pipefail

SOURCE_DIR="${SOURCE_DIR:-$(pwd)}"
CUSTOM_PACKAGES="${CUSTOM_PACKAGES:-}"
OUTPUT_DIR="${SOURCE_DIR}/packages"
REPO="${REPO:-https://github.com/nslookupkx530-hue/apk.git}"
MATCH_OVERRIDE="${MATCH_OVERRIDE:-}"
ALLOW_MISSING="${ALLOW_MISSING:-0}"

echo "=========================================="
echo " Prepare third-party APK packages"
echo " SOURCE_DIR=${SOURCE_DIR}"
echo "=========================================="

if [ -z "$(printf '%s' "${CUSTOM_PACKAGES}" | tr -d '[:space:]')" ]; then
    echo "No third-party APK packages specified. Skipping..."
    exit 0
fi

# 清理并创建目录
rm -rf "${OUTPUT_DIR}"
mkdir -p "${OUTPUT_DIR}"

# --- 克隆仓库 ---
APK_REPO_DIR="/tmp/wukongdaily-apk"
rm -rf "${APK_REPO_DIR}"
for i in 1 2 3; do
    git clone --depth=1 "${REPO}" "${APK_REPO_DIR}" && break \
        || { echo "clone 失败，重试 ${i}/3"; rm -rf "${APK_REPO_DIR}"; sleep 5; }
done
[ -d "${APK_REPO_DIR}/.git" ] || { echo "ERROR: 克隆 ${REPO} 失败"; exit 1; }

# --- 架构检测 ---
echo "Detecting Architecture..."
ARCH_PACKAGES="$(grep -m1 '^CONFIG_TARGET_ARCH_PACKAGES=' "${SOURCE_DIR}/.config" | cut -d'"' -f2 || true)"
echo "CONFIG_TARGET_ARCH_PACKAGES=${ARCH_PACKAGES:-<empty>}"

case "${ARCH_PACKAGES}" in
    x86_64)             ARCH="x86" ;;
    aarch64_cortex-a53) ARCH="arm64-a53" ;;
    aarch64_*)          ARCH="arm64" ;;
    arm_*)              ARCH="arm" ;;
    *) echo "ERROR: 不支持/无法识别架构 '${ARCH_PACKAGES}'（支持 x86 / arm64 / arm64-a53 / arm）"
       echo "       请确认 .config 里有 CONFIG_TARGET_ARCH_PACKAGES"; exit 1 ;;
esac
echo "Final Architecture: ${ARCH}"

RUN_PATH_DIR="${APK_REPO_DIR}/run/${ARCH}"
[ -d "${RUN_PATH_DIR}" ] || {
    echo "ERROR: 仓库中不存在 ${RUN_PATH_DIR}，可用目录："; ls "${APK_REPO_DIR}/run" || true; exit 1; }

# --- 模糊匹配核心 ---
normalize() {
    printf '%s' "$1" \
        | sed -E 's/^luci-(app|i18n|theme|proto|lib)-//; s/-(zh-cn|zh-tw|zh-hans|zh-hant|en|ru|ja)$//' \
        | tr 'A-Z' 'a-z' \
        | sed 's/[-_ ]//g'
}

score_name() {   # $1=候选名（已去扩展名） $2=包名 → 打印分数，0 表示不匹配
    local base pkg
    base="$(normalize "$1")"
    pkg="$(normalize "$2")"
    if [ -z "${base}" ] || [ -z "${pkg}" ]; then echo 0; return 0; fi
    if [ "${base}" = "${pkg}" ]; then echo 100; return 0; fi
    case "${base}" in
        *"${pkg}"*) if [ "${#pkg}" -ge 3 ]; then echo 80; return 0; fi ;;
    esac
    case "${pkg}" in
        *"${base}"*) if [ "${#base}" -ge 3 ]; then echo 60; return 0; fi ;;
    esac
    echo 0
}

resolve_candidates() {   # $1=搜索根 $2=包名/关键词 → 打印 "分数<TAB>路径"
    local root="$1" pkg="$2" item base sc
    while IFS= read -r item; do
        base="$(basename "${item}")"
        base="${base%.run}"
        sc="$(score_name "${base}" "${pkg}")"
        if [ "${sc}" -gt 0 ]; then printf '%s\t%s\n' "${sc}" "${item}"; fi
    done < <(find "${root}" -maxdepth 3 \( -type d -o -type f -name '*.run' \) -print 2>/dev/null | sort)
    return 0
}

apk_count() { find "${OUTPUT_DIR}" -maxdepth 1 -type f -name '*.apk' | wc -l; }

unpack_run() {   # $1 = *.run 文件；成功解包并拷贝 apk 返回 0
    local runfile="$1" work
    work="/tmp/apk-unpack-$(basename "${runfile}" .run)"
    rm -rf "${work}"; mkdir -p "${work}"
    if sh "${runfile}" --noexec --target "${work}" >/dev/null 2>&1; then
        find "${work}" -name '*.apk' -exec cp -f {} "${OUTPUT_DIR}/" \;
        echo "      [run] 解包 $(basename "${runfile}")"
        return 0
    fi
    echo "      WARNING: 解包失败 ${runfile}"
    return 1
}

collect_from_path() {   # $1 = 目录 或 *.run 文件
    local path="$1" runfile
    if [ -f "${path}" ]; then
        unpack_run "${path}" && return 0 || return 1
    fi
    if [ -d "${path}" ]; then
        runfile="$(find "${path}" -maxdepth 1 -type f -name '*.run' -print -quit 2>/dev/null || true)"
        if [ -n "${runfile}" ]; then unpack_run "${runfile}" || true; fi
        find "${path}" -name '*.apk' -exec cp -f {} "${OUTPUT_DIR}/" \;
        echo "      [dir] 收集 $(basename "${path}") 下的 *.apk"
        return 0
    fi
    return 1
}

# --- 逐个包处理（全部走模糊匹配） ---
MISSING=""
for PACKAGE in ${CUSTOM_PACKAGES}; do
    echo
    echo "---------- ${PACKAGE} ----------"

    KEY="$(printf '%s\n' "${MATCH_OVERRIDE}" | tr ' ' '\n' \
        | grep -E "^${PACKAGE}=" | sed -n '$p' | cut -d= -f2 || true)"
    if [ -n "${KEY}" ]; then
        echo "  使用覆盖关键词: ${KEY}（来自 MATCH_OVERRIDE）"
    else
        KEY="${PACKAGE}"
    fi
    echo "  归一化核心词: $(normalize "${KEY}")"

    CAND="$(resolve_candidates "${RUN_PATH_DIR}" "${KEY}")"
    SCOPE="run/${ARCH}"
    if [ -z "${CAND}" ]; then
        echo "  run/${ARCH} 内无匹配 → 全仓库深搜"
        CAND="$(resolve_candidates "${APK_REPO_DIR}" "${KEY}")"
        SCOPE="repo"
    fi

    if [ -z "${CAND}" ]; then
        echo "  FAIL: 在 ${SCOPE} 中找不到与 '${KEY}' 匹配的目录或 .run"
        MISSING="${MISSING} ${PACKAGE}"
        continue
    fi

    BEST="$(printf '%s\n' "${CAND}" | sort -k1,1nr -k2,2 | awk -F'\t' 'NR==1{print $1}')"
    TOP="$(printf '%s\n' "${CAND}" | awk -F'\t' -v s="${BEST}" '$1==s {print $2}')"
    echo "  匹配到最高分 ${BEST}，候选 $(printf '%s\n' "${TOP}" | grep -c . || true) 个："
    printf '%s\n' "${TOP}" | sed 's/^/      /'

    HIT=0
    while IFS= read -r item; do
        [ -n "${item}" ] || continue
        BEFORE="$(apk_count)"
        collect_from_path "${item}" || true
        AFTER="$(apk_count)"
        if [ "${AFTER}" -gt "${BEFORE}" ]; then
            HIT=$((HIT + 1))
        else
            echo "      （该来源没有产生新 apk: ${item}）"
        fi
    done <<< "${TOP}"

    if [ "${HIT}" -eq 0 ]; then
        echo "  FAIL: 候选里没有可用的 .apk"
        MISSING="${MISSING} ${PACKAGE}"
    else
        echo "  OK: ${PACKAGE}（命中 ${HIT} 个来源）"
    fi
done

# --- 架构体检 + 汇总 ---
EXPECT=""; case "${ARCH}" in
    x86) EXPECT="x86_64";; arm64-a53) EXPECT="aarch64_cortex-a53";; arm64) EXPECT="aarch64_*";; arm) EXPECT="arm_*";;
esac
for f in "${OUTPUT_DIR}"/*.apk; do
    [ -f "$f" ] || continue
    A="$(tar -xzOf "$f" .PKGINFO 2>/dev/null | sed -n 's/^arch = //p' || true)"
    A="${A%%$'\n'*}"
    [ -z "${A}" ] && continue
    case "$A" in
        ${EXPECT}) : ;;
        *) echo "WARNING: $(basename "$f") 架构为 ${A}，期望 ${EXPECT}" ;;
    esac
done

APK_TOTAL="$(apk_count)"
echo "=========================================="
echo "APK 输出目录: ${OUTPUT_DIR}（${APK_TOTAL} 个 apk）"
find "${OUTPUT_DIR}" -maxdepth 1 -type f -name '*.apk' -exec ls -lh {} \; || true
echo "=========================================="

if [ "${APK_TOTAL}" -eq 0 ]; then
    echo "ERROR: 一个 apk 都没准备好"; exit 1
fi
if [ -n "${MISSING}" ]; then
    echo "ERROR: 以下请求的包没有准备好:${MISSING}"
    echo "       若该包本来就在官方 feed 里（bash、kmod-* 等），请从 CUSTOM_PACKAGES 里去掉；"
    echo "       若是仓库目录名特殊，用 MATCH_OVERRIDE=\"包名=关键词\" 指定（见文件头注释）"
    [ "${ALLOW_MISSING}" = "1" ] && echo "（ALLOW_MISSING=1，按警告处理）" || exit 1
fi
exit 0
