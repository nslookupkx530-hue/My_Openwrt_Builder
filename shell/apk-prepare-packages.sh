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
APK_MATCH_STRICT="${APK_MATCH_STRICT:-0}"

# ---------- apk 仓库分支优先级（My 优先，master 次选）----------
BRANCHES="${BRANCHES:-My master}"                    # 从左到右依次尝试，可再加 main
CLONE_DIR="${CLONE_DIR:-/tmp/wukongdaily-apk}"       # ★ 必须与你脚本里 clone 用的目录一致
BRANCH_USED=""

clone_repo() {
    rm -rf "${CLONE_DIR}"
    for br in ${BRANCHES}; do
        echo ">>> 尝试 clone 分支: ${br}"
        if git clone --depth 1 --single-branch -b "${br}" "${REPO}" "${CLONE_DIR}" 2>/dev/null; then
            BRANCH_USED="${br}"
            echo ">>> 使用分支: ${br}  commit=$(git -C "${CLONE_DIR}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
            return 0
        fi
        rm -rf "${CLONE_DIR}"
    done
    echo "ERROR: 分支依次尝试均失败（${BRANCHES}）" >&2
    return 1
}

echo "=========================================="
echo " Prepare third-party APK packages"
echo " SOURCE_DIR=${SOURCE_DIR}"
echo " CUSTOM_PACKAGES=${CUSTOM_PACKAGES:-<none>}"
echo "=========================================="

if [ -z "$(printf '%s' "${CUSTOM_PACKAGES}" | tr -d '[:space:]')" ]; then
    echo "No third-party APK packages specified. Skipping..."
    exit 0
fi

# 清理并创建目录
rm -rf "${OUTPUT_DIR}"
mkdir -p "${OUTPUT_DIR}"

# --- 克隆仓库（My 优先，master 次选）---
APK_REPO_DIR="/tmp/wukongdaily-apk"
BRANCH_USED=""
for round in 1 2 3; do
    for br in ${BRANCHES}; do
        rm -rf "${APK_REPO_DIR}"
        echo ">>> 尝试 clone 分支: ${br} （第 ${round}/3 轮）"
        if git clone --depth=1 --single-branch -b "${br}" "${REPO}" "${APK_REPO_DIR}"; then
            BRANCH_USED="${br}"
            break 2
        fi
    done
    echo "    候选分支 ${BRANCHES} 本轮都没成功，${round}/3 轮后重试"
    sleep 5
done
[ -n "${BRANCH_USED}" ] || { echo "ERROR: 克隆 ${REPO} 失败（候选分支：${BRANCHES}）"; exit 1; }
[ -d "${APK_REPO_DIR}/.git" ] || { echo "ERROR: 克隆结果异常：${APK_REPO_DIR}"; exit 1; }
echo ">>> apk 仓库: 分支=${BRANCH_USED} commit=$(git -C "${APK_REPO_DIR}" rev-parse --short HEAD 2>/dev/null || echo unknown)"

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

cand_name() {   # 从目录/.run/.apk 名字里提取纯包名
    local n
    n="$(basename "$1")"
    n="${n%.run}"; n="${n%.apk}"
    n="$(printf '%s' "$n" | sed -E 's/^[0-9]+-//')"
    n="$(printf '%s' "$n" | sed -E 's/_(x86_64|x86|i386|aarch64[_-][A-Za-z0-9_.-]*|aarch64|arm[_-][A-Za-z0-9_.-]*|arm|mips[a-z0-9_.-]*|riscv64).*$//')"
    n="$(printf '%s' "$n" | sed -E 's/[_-]v?[0-9][0-9A-Za-z._-]*$//')"
    printf '%s' "$n"
}

score_name() {   # $1=候选纯名 $2=包名 → 分数（0=不匹配）
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

prefilter() {
    find "$1" -maxdepth "${3:-3}" \( -type d -o -type f \( -name '*.run' -o -name '*.apk' \) \) -print 2>/dev/null \
        | awk -v kw="$2" '{ n=$0; sub(/.*\//,"",n); if (index(tolower(n), kw) > 0) print }'
}

resolve_candidates() {   # $1=根 $2=深度 $3=包名 $4=核心词 → 打印 "分数<TAB>路径"
    local root="$1" depth="$2" pkg="$3" kw="$4" item sc
    while IFS= read -r item; do
        [ -n "${item}" ] || continue
        sc="$(score_name "$(cand_name "${item}")" "${pkg}")"
        if [ "${sc}" -gt 0 ]; then printf '%s\t%s\n' "${sc}" "${item}"; fi
    done < <(prefilter "${root}" "${kw}" "${depth}")
    return 0
}

dedupe_paths() {   # 丢掉"被其它候选包含"的路径（如目录里的各个 apk）
    local item other skip
    local -a ALL=()
    while IFS= read -r item; do
        if [ -n "${item}" ]; then ALL+=("${item}"); fi
    done
    for item in "${ALL[@]}"; do
        skip=0
        for other in "${ALL[@]}"; do
            [ "${other}" = "${item}" ] && continue
            case "${item}" in "${other}"/*) skip=1; break ;; esac
        done
        if [ "${skip}" = "0" ]; then printf '%s\n' "${item}"; fi
    done
}

apk_count() { find "${OUTPUT_DIR}" -maxdepth 1 -type f -name '*.apk' | wc -l; }

unpack_run() {   # $1=*.run → 解包到临时目录并打印该目录路径
    local runfile="$1" work
    work="/tmp/apk-unpack-$(basename "${runfile}" .run)"
    rm -rf "${work}"; mkdir -p "${work}"
    if sh "${runfile}" --noexec --target "${work}" >/dev/null 2>&1; then
        echo "${work}"
        return 0
    fi
    echo "      WARNING: .run 解包失败 ${runfile}" >&2
    return 1
}

copy_apks() {   # 拷到至少一个 apk 返回 0（同名已存在也算成功，直接覆盖）
    local dir="$1" kw="$2" f base kept=0 skipped=0
    for f in "${dir}"/*.apk; do
        [ -f "$f" ] || continue
        base="$(basename "$f")"
        if [ "${APK_MATCH_STRICT}" = "1" ]; then
            case "$(normalize "${base}")" in
                *"${kw}"*) : ;;
                *) skipped=$((skipped + 1)); continue ;;
            esac
        fi
        cp -f "$f" "${OUTPUT_DIR}/"
        kept=$((kept + 1))
    done
    if [ "${kept}" -gt 0 ]; then
        echo "      拷贝 ${kept} 个 apk ← $(basename "${dir}")"
        [ "${skipped}" -eq 0 ] || echo "      提示：同目录另有 ${skipped} 个 apk 未拷；若为依赖请设 APK_MATCH_STRICT=0"
        return 0
    fi
    return 1
}

collect_from_path() {   # 成功收集到 apk 返回 0
    local path="$1" kw="$2" work runfile

    case "${path}" in
        *.run)
            work="$(unpack_run "${path}")" || return 1
            copy_apks "${work}" "${kw}" && return 0 || return 1
            ;;
        *.apk)
            cp -f "${path}" "${OUTPUT_DIR}/" && {
                echo "      直接拷贝 apk ← $(basename "${path}")"; return 0; }
            return 1
            ;;
    esac

    if [ -d "${path}" ]; then
        runfile="$(find "${path}" -maxdepth 1 -type f -name '*.run' -print -quit 2>/dev/null || true)"
        if [ -n "${runfile}" ]; then
            work="$(unpack_run "${runfile}" || true)"
            [ -n "${work}" ] && { copy_apks "${work}" "${kw}" || true; }
        fi
        copy_apks "${path}" "${kw}" && return 0 || return 1
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
    if [ -n "${KEY}" ]; then echo "  使用覆盖关键词: ${KEY}（MATCH_OVERRIDE）"; else KEY="${PACKAGE}"; fi
    KW="$(normalize "${KEY}")"
    echo "  核心词: ${KW}"

    CAND="$(resolve_candidates "${RUN_PATH_DIR}" 3 "${KEY}" "${KW}")"
    SCOPE="run/${ARCH}"
    if [ -z "${CAND}" ]; then
        echo "  run/${ARCH}/ 内无匹配 → 全仓库深搜"
        CAND="$(resolve_candidates "${APK_REPO_DIR}" 4 "${KEY}" "${KW}")"
        SCOPE="repo"
    fi

    if [ -z "${CAND}" ]; then
        echo "  FAIL: 在 ${SCOPE} 中找不到与 '${KW}' 匹配的 .run / 目录 / .apk"
        MISSING="${MISSING} ${PACKAGE}"
        continue
    fi

    BEST="$(printf '%s\n' "${CAND}" | sort -k1,1nr -k2,2 | awk -F'\t' 'NR==1{print $1}')"
    TOP="$(printf '%s\n' "${CAND}" | awk -F'\t' -v s="${BEST}" '$1==s {print $2}' | dedupe_paths)"
    echo "  命中（分数 ${BEST}，共 $(printf '%s\n' "${TOP}" | grep -c . || true) 个）："
    printf '%s\n' "${TOP}" | sed 's/^/      /'

    # ★ 用函数返回状态判断成功，不看 packages/ 的文件数
    #   （多个包命中同一目录时，第二次是重复拷贝同名文件，数量不会增加，但那也是成功）
    HIT=0
    while IFS= read -r item; do
        [ -n "${item}" ] || continue
        if collect_from_path "${item}" "${KW}"; then
            HIT=$((HIT + 1))
        else
            echo "      （该来源没有可用 apk: ${item}）"
        fi
    done <<< "${TOP}"

    if [ "${HIT}" -eq 0 ]; then
        echo "  FAIL: 命中的来源里没有可用 .apk"
        MISSING="${MISSING} ${PACKAGE}"
    else
        echo "  OK: ${PACKAGE}"
    fi
done

# --- 汇总 ---
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
    echo "       若该包本来就在官方 feed 里（bash、kmod-* 等），请从 CUSTOM_PACKAGES 去掉；"
    echo "       若是仓库命名特殊，用 MATCH_OVERRIDE=\"包名=关键词\" 指定，或先看："
    echo "       find ${RUN_PATH_DIR} -maxdepth 1 | sort"
    [ "${ALLOW_MISSING}" = "1" ] && echo "（ALLOW_MISSING=1，按警告处理）" || exit 1
fi
exit 0
