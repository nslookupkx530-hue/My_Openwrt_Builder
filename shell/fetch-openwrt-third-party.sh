#!/usr/bin/env bash
# =============================================================================
# openwrt 源第三方预编译 apk 拉取 —— 全架构通用
#
#   来源仓库 : nslookupkx530-hue/apk     分支 My（回退 master）
#   仓库布局 : <arch目录>/luci-third-party-openwrt/*.apk
#                x86_64/      ← CONFIG_TARGET_ARCH_PACKAGES=x86_64
#                arm64-a53/   ← aarch64_cortex-a53
#                arm64/       ← 其它 aarch64 / arm64（通用兜底）
#   清单文件 : configs/third-party-openwrt.config       （格式：包名=子目录）
#   输出位置 : $OUT_DIR     默认 <SRC_DIR>/files/usr/share/third-party
#   记录文件 : <SRC_DIR>/tmp/openwrt-third-party.txt / .meta
#
#   架构由本脚本自己从 .config 推导，不对任何单一架构做 gate。
#
#   这批包不写进 .config，workflow 里 "Finalize Configuration" 的 MISS 检查
#   覆盖不到它们 —— 本脚本的 exit 1 就是唯一的守卫，任何缺失/校验失败都必须硬失败。
# =============================================================================
set -euo pipefail

SRC_DIR="${SRC_DIR:-src}"
PKG_LIST="${PKG_LIST:-configs/third-party-openwrt.config}"
APK_REPO="${APK_REPO:-nslookupkx530-hue/apk}"
BRANCHES="${BRANCHES:-My master}"
DEFAULT_SUBDIR="luci-third-party-openwrt"
APK_REPO_PREFIX="${APK_REPO_PREFIX:-openwrt}"   # 仓库里"架构目录"之前的前缀层（实测仓库是 openwrt/<arch>/...）

OUT_DIR="${OUT_DIR:-${SRC_DIR}/files/usr/share/third-party}"
MANIFEST="${MANIFEST:-${SRC_DIR}/tmp/openwrt-third-party.txt}"
META="${META:-${SRC_DIR}/tmp/openwrt-third-party.meta}"

log() { echo ">>> [openwrt-3rd] $*"; }
die() { echo "::error::$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 架构映射：CONFIG_TARGET_ARCH_PACKAGES → apk 仓库里的目录名
#   exact_*   : 精确目录（优先）
#   generic_* : 通用兜底目录
# ---------------------------------------------------------------------------
exact_arch_dir() {
    case "$1" in
        x86_64|x86_64_*)                          echo "x86_64" ;;
        aarch64_cortex-a53|aarch64_cortex-a53_*)   echo "arm64-a53" ;;
        aarch64*|arm64*)                          echo "arm64" ;;
        *)                                        echo "" ;;
    esac
}
generic_arch_dir() {
    case "$1" in
        x86_64*|i386*|i486*|i686*)   echo "x86_64" ;;
        aarch64*|arm64*)             echo "arm64" ;;
        *)                           echo "" ;;
    esac
}

# ---------- 0. 前置检查 ----------
[ "${SOURCE_TYPE:-immortalwrt}" = "openwrt" ] || { log "非 openwrt 源，跳过"; exit 0; }
[ -f "$PKG_LIST" ] || die "清单文件不存在: $PKG_LIST"
[ -d "$SRC_DIR" ]  || die "源码目录不存在: $SRC_DIR"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---------- 1. 推导架构 ----------
ARCH_PACKAGES="${TARGET_ARCH:-}"
if [ -z "${ARCH_PACKAGES}" ] && [ -f "${SRC_DIR}/.config" ]; then
    ARCH_PACKAGES="$(sed -n 's/^CONFIG_TARGET_ARCH_PACKAGES="\?\([^"]*\)"\?$/\1/p' "${SRC_DIR}/.config" | head -n1)"
fi
[ -n "${ARCH_PACKAGES}" ] || die "无法推导 CONFIG_TARGET_ARCH_PACKAGES（.config 缺失或该符号未生成）；请显式设置 TARGET_ARCH"

if [ -n "${APK_ARCH_DIR:-}" ]; then
    ARCH_EXACT="${APK_ARCH_DIR}"
    ARCH_GENERIC="${APK_ARCH_DIR}"
else
    ARCH_EXACT="$(exact_arch_dir "${ARCH_PACKAGES}")"
    ARCH_GENERIC="$(generic_arch_dir "${ARCH_PACKAGES}")"
fi
[ -n "${ARCH_EXACT}" ] || die "未映射的架构: ARCH_PACKAGES=${ARCH_PACKAGES}；请在 exact_arch_dir() 里补一条映射"

# 供 sparse checkout 用（两个候选都取，clone 完再决定用哪个）
ARCH_CANDIDATES="${ARCH_EXACT}"
[ -n "${ARCH_GENERIC}" ] && [ "${ARCH_GENERIC}" != "${ARCH_EXACT}" ] && \
    ARCH_CANDIDATES="${ARCH_CANDIDATES} ${ARCH_GENERIC}"

# sparse checkout 的路径必须带上仓库前缀（openwrt/），否则永远命中不了，
# 每次都退化成完整 clone（仓库里现在有三套 apk + run/，白下不少东西）
SPARSE_DIRS=""
for d in ${ARCH_CANDIDATES}; do
    SPARSE_DIRS="${SPARSE_DIRS}${SPARSE_DIRS:+ }${APK_REPO_PREFIX:+${APK_REPO_PREFIX}/}${d}"
done

log "ARCH_PACKAGES=${ARCH_PACKAGES}  候选目录=${SPARSE_DIRS}"

# ---------- 2. 克隆 apk 仓库（My 优先，失败回退） ----------
try_clone() {
    local b="$1"
    rm -rf "$WORK/apk"

    # 快路径：sparse checkout 只取本架构目录（仓库里存了三套 apk，能省很多流量）
    if git clone --depth 1 --branch "$b" --single-branch \
            --filter=blob:none --sparse \
            "https://github.com/${APK_REPO}.git" "$WORK/apk" >/dev/null 2>&1; then
        # shellcheck disable=SC2086
        git -C "$WORK/apk" sparse-checkout set --no-cone ${SPARSE_DIRS} >/dev/null 2>&1 \
          || git -C "$WORK/apk" sparse-checkout set ${SPARSE_DIRS} >/dev/null 2>&1 \
          || true
        local d
        for d in ${ARCH_CANDIDATES}; do
            [ -d "$WORK/apk/${APK_REPO_PREFIX:+${APK_REPO_PREFIX}/}${d}" ] && return 0
        done
        echo ">>> [${b}] sparse 未命中 ${ARCH_CANDIDATES}，改用完整 clone"
    fi

    # 慢路径：完整浅克隆
    rm -rf "$WORK/apk"
    git clone --depth 1 --branch "$b" --single-branch \
        "https://github.com/${APK_REPO}.git" "$WORK/apk" >/dev/null 2>&1
}

USED_BRANCH=""
for b in $BRANCHES; do
    log "克隆 ${APK_REPO} @ ${b} ..."
    if try_clone "$b"; then USED_BRANCH="$b"; break; fi
    echo ">>> [${b}] 克隆失败"
done
[ -n "$USED_BRANCH" ] || die "apk 仓库克隆失败（尝试分支: ${BRANCHES}）"
USED_COMMIT="$(git -C "$WORK/apk" rev-parse --short HEAD)"
log "apk 仓库: 分支=${USED_BRANCH} commit=${USED_COMMIT}"

# ---------- 3. 定下最终架构目录（精确 → 通用兜底 → 硬失败） ----------
ARCH_BASE="${APK_REPO_PREFIX:+${APK_REPO_PREFIX}/}${ARCH_EXACT}"
if [ ! -d "$WORK/apk/${ARCH_BASE}" ] && [ -n "${ARCH_GENERIC}" ] && [ "${ARCH_GENERIC}" != "${ARCH_EXACT}" ]; then
    ARCH_GENERIC_PATH="${APK_REPO_PREFIX:+${APK_REPO_PREFIX}/}${ARCH_GENERIC}"
    if [ -d "$WORK/apk/${ARCH_GENERIC_PATH}" ]; then
        echo "::warning::${ARCH_EXACT} 目录不存在，回退到通用目录 ${ARCH_GENERIC}（纯 Lua/i18n 包跨 arm64 通用；含 Go 二进制请自行确认）"
        ARCH_BASE="${ARCH_GENERIC_PATH}"
    fi
fi
log "使用架构目录: ${ARCH_BASE}"

if [ ! -d "$WORK/apk/${ARCH_BASE}" ]; then
    echo ">>> 仓库根目录下的实际内容:"
    ls -1 "$WORK/apk" 2>/dev/null | sed 's/^/        /' || true
    die "apk 仓库里没有 ${ARCH_BASE}（ARCH_PACKAGES=${ARCH_PACKAGES}）"
fi

# ---------- 4. 读清单（容忍 CRLF / 行尾空格 / 空行 / # 注释） ----------
mapfile -t PKGS < <(grep -vE '^[[:space:]]*(#|$)' "$PKG_LIST" \
                    | tr -d '\r' | sed -e 's/[[:space:]]*$//' -e 's/^[[:space:]]*//')
[ "${#PKGS[@]}" -gt 0 ] || die "清单里没有任何包: $PKG_LIST"
log "清单包数: ${#PKGS[@]}"

subdir_of() { local l="$1" s="${1#*=}"; [ "$s" = "$l" ] && s="$DEFAULT_SUBDIR"; [ -n "$s" ] && echo "$s" || echo "$DEFAULT_SUBDIR"; }

# ---------- 5. 每个子目录先跑一次 SHA256SUMS 强校验 ----------
declare -A VERIFIED=()
for line in "${PKGS[@]}"; do
    sub="$(subdir_of "$line")"
    [ "${VERIFIED[$sub]:-0}" = "1" ] && continue
    d="$WORK/apk/${ARCH_BASE}/${sub}"
    [ -d "$d" ]            || die "仓库里没有目录: ${ARCH_BASE}/${sub}"
    [ -f "$d/SHA256SUMS" ] || die "缺少 ${ARCH_BASE}/${sub}/SHA256SUMS"
    ( cd "$d" && sha256sum -c --strict SHA256SUMS ) \
        || die "sha256 校验失败: ${ARCH_BASE}/${sub}"
    log "sha256 校验通过: ${ARCH_BASE}/${sub}"
    VERIFIED[$sub]=1
done

# ---------- 6. 逐包精确匹配 + 防呆 + 收集 ----------
mkdir -p "$OUT_DIR" "$(dirname "$MANIFEST")"
: > "$MANIFEST"

for line in "${PKGS[@]}"; do
    pkg="${line%%=*}"
    sub="$(subdir_of "$line")"
    d="$WORK/apk/${ARCH_BASE}/${sub}"

    # 精确匹配：完整包名 + 开头锚定；同时容忍 - 与 _ 两种分隔
    mapfile -t cands < <(find "$d" -maxdepth 1 -type f \
        \( -name "${pkg}-*.apk" -o -name "${pkg}_*.apk" \) | sort -V)

    [ "${#cands[@]}" -gt 0 ] || die "找不到包: ${pkg}（目录 ${ARCH_BASE}/${sub}）"
    if [ "${#cands[@]}" -gt 1 ]; then
        log "WARNING: ${pkg} 匹配到 ${#cands[@]} 个文件，取版本最新的那个:"
        printf '         %s\n' "${cands[@]##*/}"
    fi
    f="${cands[-1]}"
    [ -s "$f" ] || die "文件为空: $f"

    # 防呆：同一个包既在 .config 里编译、又走二进制旁路（会互相覆盖）
    if grep -qE "^CONFIG_PACKAGE_${pkg}=y$" "${SRC_DIR}/.config" 2>/dev/null; then
        die "${pkg} 既在 .config 中被编译、又作为第三方 apk 旁路 —— 二者只能取其一"
    fi

    install -m 0644 "$f" "${OUT_DIR}/$(basename "$f")"
    printf '%s\t%s\t%s\n' "$pkg" "$(basename "$f")" \
        "$(sha256sum "$f" | awk '{print $1}')" >> "$MANIFEST"
    log "已放入: ${pkg}  <-  $(basename "$f")"
done

# ---------- 7. 写元信息（给 Release 正文 / BUILDINFO 用） ----------
printf 'apk_repo=%s\napk_branch=%s\napk_commit=%s\napk_arch=%s\napk_arch_dir=%s\narch_packages=%s\npkg_count=%s\n' \
    "$APK_REPO" "$USED_BRANCH" "$USED_COMMIT" "${TARGET_ARCH:-$ARCH_PACKAGES}" "$ARCH_BASE" "$ARCH_PACKAGES" "${#PKGS[@]}" > "$META"

log "完成：${#PKGS[@]} 个包已放入 ${OUT_DIR}"
log "架构: ${ARCH_PACKAGES} → ${ARCH_BASE}"
log "清单: ${MANIFEST}   元信息: ${META}"
