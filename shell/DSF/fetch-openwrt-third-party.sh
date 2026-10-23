#!/usr/bin/env bash
# =============================================================================
# DSF 线第三方预编译 apk 拉取（第三方源码树，不是 openwrt 官方源）
#
#   用途：官方 feed 里没有、但 A 线一直有的那些 app（diskman / aurora /
#         autoreboot / ramfree / filebrowser-go / tcping …），
#         以【预编译 apk】形式补齐：不进 .config、不参与编译。
#
#   来源仓库 : nslookupkx530-hue/apk        分支 My（回退 master）
#   仓库布局 : openwrt/<arch目录>/luci-third-party-openwrt/*.apk
#                x86_64/      ← ARCH_PACKAGES=x86_64
#                arm64-a53/   ← aarch64_cortex-a53（MT5000 / AX6600 都是这个）
#                arm64/       ← 其它 aarch64 兜底
#   清单文件 : configs/third-party-openwrt.config       （与 A 线【共享】；格式：包名[=子目录]）
#   生效设备 : TP_APK_DEVICES（默认 GL-MT5000）
#              JDC-AX6600 用老源 libwrt，这些包树里自带 → 绝不能走二进制旁路
#              （否则 .config 里也有、apk 里也有，脚本的防呆会直接报错）
#   输出位置 : ${SRC_DIR}/files/usr/share/third-party
#              → 固件内 /usr/share/third-party → 首启由
#                /etc/third-party/install_third_party_apk.sh 安装
#   记录文件 : ${SRC_DIR}/tmp/openwrt-third-party.txt / .meta
#
#   ⚠ 这批包不写进 .config，Finalize 的 MISS 检查覆盖不到 →
#     本脚本的 exit 1 就是唯一守卫，任何缺失/校验失败都必须硬失败。
#   ⚠ "防呆"会检查同名包是否也在 .config 里 =y —— 那样会双份覆盖。
#     从种子里删掉的包，请只在这里交付。
# =============================================================================
set -euo pipefail

SRC_DIR="${SRC_DIR:-src}"
PKG_LIST="${PKG_LIST:-configs/third-party-openwrt.config}"
APK_REPO="${APK_REPO:-nslookupkx530-hue/apk}"
BRANCHES="${BRANCHES:-My master}"
DEFAULT_SUBDIR="luci-third-party-openwrt"
APK_REPO_PREFIX="${APK_REPO_PREFIX:-openwrt}"

OUT_DIR="${OUT_DIR:-${SRC_DIR}/files/usr/share/third-party}"
MANIFEST="${MANIFEST:-${SRC_DIR}/tmp/openwrt-third-party.txt}"
META="${META:-${SRC_DIR}/tmp/openwrt-third-party.meta}"

log() { echo ">>> [dsf-3rd] $*"; }
die() { echo "::error::$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 架构映射：CONFIG_TARGET_ARCH_PACKAGES → apk 仓库里的目录名
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
[ "${SKIP_TP_APK:-0}" = "1" ] && { log "SKIP_TP_APK=1，跳过"; exit 0; }
[ -f "$PKG_LIST" ] || die "清单文件不存在: $PKG_LIST"
[ -d "$SRC_DIR" ]  || die "源码目录不存在: $SRC_DIR"
[ -f "${SRC_DIR}/.config" ] || die "${SRC_DIR}/.config 不存在（种子还没展开？本步要放在 defconfig 之后）"

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

ARCH_CANDIDATES="${ARCH_EXACT}"
[ -n "${ARCH_GENERIC}" ] && [ "${ARCH_GENERIC}" != "${ARCH_EXACT}" ] && ARCH_CANDIDATES="${ARCH_CANDIDATES} ${ARCH_GENERIC}"

SPARSE_DIRS=""
for d in ${ARCH_CANDIDATES}; do
    SPARSE_DIRS="${SPARSE_DIRS}${SPARSE_DIRS:+ }${APK_REPO_PREFIX:+${APK_REPO_PREFIX}/}${d}"
done

log "DEVICE=${TARGET_DEVICE:-?}  ARCH_PACKAGES=${ARCH_PACKAGES}  候选目录=${SPARSE_DIRS}"

# ---------- 2. 克隆 apk 仓库（My 优先，失败回退） ----------
try_clone() {
    local b="$1"
    rm -rf "$WORK/apk"

    if git clone --depth 1 --branch "$b" --single-branch --filter=blob:none --sparse \
            "https://github.com/${APK_REPO}.git" "$WORK/apk" >/dev/null 2>&1; then
        git -C "$WORK/apk" sparse-checkout set --no-cone ${SPARSE_DIRS} >/dev/null 2>&1 \
          || git -C "$WORK/apk" sparse-checkout set ${SPARSE_DIRS} >/dev/null 2>&1 \
          || true
        local d
        for d in ${ARCH_CANDIDATES}; do
            [ -d "$WORK/apk/${APK_REPO_PREFIX:+${APK_REPO_PREFIX}/}${d}" ] && return 0
        done
        echo ">>> [${b}] sparse 未命中 ${ARCH_CANDIDATES}，改用完整 clone"
    fi

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
        echo "::warning::${ARCH_EXACT} 目录不存在，回退到通用目录 ${ARCH_GENERIC}（纯 Lua/i18n 包跨 arm64 通用；含 Go/C 二进制请自行确认）"
        ARCH_BASE="${ARCH_GENERIC_PATH}"
    fi
fi
log "使用架构目录: ${ARCH_BASE}"

if [ ! -d "$WORK/apk/${ARCH_BASE}" ]; then
    echo ">>> 仓库根目录下的实际内容:"
    ls -1 "$WORK/apk" 2>/dev/null | sed 's/^/        /' || true
    die "apk 仓库里没有 ${ARCH_BASE}（ARCH_PACKAGES=${ARCH_PACKAGES}）"
fi

# ---------- 4. 读清单 ----------
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
    ( cd "$d" && sha256sum -c --strict SHA256SUMS ) || die "sha256 校验失败: ${ARCH_BASE}/${sub}"
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

    mapfile -t cands < <(find "$d" -maxdepth 1 -type f \
        \( -name "${pkg}-*.apk" -o -name "${pkg}_*.apk" \) | sort -V)

    [ "${#cands[@]}" -gt 0 ] || die "找不到包: ${pkg}（目录 ${ARCH_BASE}/${sub}）"
    if [ "${#cands[@]}" -gt 1 ]; then
        log "WARNING: ${pkg} 匹配到 ${#cands[@]} 个文件，取版本最新的那个:"
        printf '         %s\n' "${cands[@]##*/}"
    fi
    f="${cands[-1]}"
    [ -s "$f" ] || die "文件为空: $f"

    # 防呆：同一个包既在 .config 里编译、又走 apk 旁路 → 会互相覆盖
    if grep -qE "^CONFIG_PACKAGE_${pkg}=y$" "${SRC_DIR}/.config" 2>/dev/null; then
        die "${pkg} 既在 .config 中被编译、又作为第三方 apk 旁路 —— 请从种子里删掉，只走这一条通路"
    fi

    install -m 0644 "$f" "${OUT_DIR}/$(basename "$f")"
    printf '%s\t%s\t%s\n' "$pkg" "$(basename "$f")" "$(sha256sum "$f" | awk '{print $1}')" >> "$MANIFEST"
    log "已放入: ${pkg}  <-  $(basename "$f")"
done

# ---------- 7. 写元信息 ----------
printf 'apk_repo=%s\napk_branch=%s\napk_commit=%s\napk_arch=%s\napk_arch_dir=%s\narch_packages=%s\npkg_count=%s\ndevice=%s\n' \
    "$APK_REPO" "$USED_BRANCH" "$USED_COMMIT" "${TARGET_ARCH:-$ARCH_PACKAGES}" "$ARCH_BASE" "$ARCH_PACKAGES" "${#PKGS[@]}" "${TARGET_DEVICE:-}" > "$META"

log "完成：${#PKGS[@]} 个包已放入 ${OUT_DIR}"
log "架构: ${ARCH_PACKAGES} → ${ARCH_BASE}"
log "清单: ${MANIFEST}   元信息: ${META}"
log "输出目录内容："
ls -lh "$OUT_DIR" | sed 's/^/        /'
