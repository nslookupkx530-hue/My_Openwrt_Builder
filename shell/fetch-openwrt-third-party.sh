#!/usr/bin/env bash
# =============================================================================
# openwrt 源第三方预编译 apk 拉取（仅 SOURCE_TYPE=openwrt 执行）
#
#   来源仓库 : nslookupkx530-hue/apk     分支 My（回退 master）
#   仓库路径 : run/<arch>/luci-third-party-openwrt/
#   清单文件 : configs/third-party-openwrt.config   （格式：包名=子目录）
#   输出位置 : <SRC_DIR>/files/usr/share/third-party/*.apk
#   记录文件 : tmp/openwrt-third-party.txt / .meta  （供 Release 正文与 BUILDINFO）
#
#   这批包不写进 .config，workflow 里 "Finalize Configuration" 的 MISS 检查
#   覆盖不到它们 —— 本脚本的 exit 1 就是唯一的守卫，任何缺失/校验失败都必须硬失败。
# =============================================================================
set -euo pipefail

SRC_DIR="${SRC_DIR:-src}"
PKG_LIST="${PKG_LIST:-configs/third-party-openwrt.config}"
APK_REPO="${APK_REPO:-nslookupkx530-hue/apk}"
BRANCHES="${BRANCHES:-My master}"
TARGET_ARCH="${TARGET_ARCH:-x86_64}"
REPO_ROOT="run/${TARGET_ARCH}"
DEFAULT_SUBDIR="luci-third-party-openwrt"
OUT_DIR="${SRC_DIR}/files/usr/share/third-party"
MANIFEST="tmp/openwrt-third-party.txt"
META="tmp/openwrt-third-party.meta"
APK_SRC_URL="${APK_SRC_URL:-https://mirror.nju.edu.cn/immortalwrt/releases/25.12.2/packages/${TARGET_ARCH}/luci/}"

log() { echo ">>> [openwrt-3rd] $*"; }
die() { echo "::error::$*" >&2; exit 1; }

# ---------- 0. 前置检查 ----------
[ "${SOURCE_TYPE:-immortalwrt}" = "openwrt" ] || { log "非 openwrt 源，跳过"; exit 0; }
[ -f "$PKG_LIST" ] || die "清单文件不存在: $PKG_LIST"
[ -d "$SRC_DIR" ]  || die "源码目录不存在: $SRC_DIR"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---------- 1. 克隆 apk 仓库（My 优先，失败回退） ----------
USED_BRANCH=""
for b in $BRANCHES; do
    log "克隆 ${APK_REPO} @ ${b} ..."
    if git clone --depth 1 --branch "$b" --single-branch \
            "https://github.com/${APK_REPO}.git" "$WORK/apk" 2>/dev/null; then
        USED_BRANCH="$b"; break
    fi
    rm -rf "$WORK/apk"
done
[ -n "$USED_BRANCH" ] || die "apk 仓库克隆失败（尝试分支: ${BRANCHES}）"
USED_COMMIT="$(git -C "$WORK/apk" rev-parse --short HEAD)"
log "apk 仓库: 分支=${USED_BRANCH} commit=${USED_COMMIT}"

# ---------- 2. 读清单（容忍 CRLF / 行尾空格 / 空行 / # 注释） ----------
mapfile -t PKGS < <(grep -vE '^[[:space:]]*(#|$)' "$PKG_LIST" \
                    | tr -d '\r' | sed -e 's/[[:space:]]*$//' -e 's/^[[:space:]]*//')
[ "${#PKGS[@]}" -gt 0 ] || die "清单里没有任何包: $PKG_LIST"
log "清单包数: ${#PKGS[@]}"

# 取子目录（没写 = 用默认）
subdir_of() { local l="$1" s="${1#*=}"; [ "$s" = "$l" ] && s="$DEFAULT_SUBDIR"; [ -n "$s" ] && echo "$s" || echo "$DEFAULT_SUBDIR"; }

# ---------- 3. 每个子目录先跑一次 SHA256SUMS 强校验 ----------
declare -A VERIFIED=()
for line in "${PKGS[@]}"; do
    sub="$(subdir_of "$line")"
    [ "${VERIFIED[$sub]:-0}" = "1" ] && continue
    d="$WORK/apk/${REPO_ROOT}/${sub}"
    [ -d "$d" ]           || die "仓库里没有目录: ${REPO_ROOT}/${sub}"
    [ -f "$d/SHA256SUMS" ] || die "缺少 ${REPO_ROOT}/${sub}/SHA256SUMS"
    ( cd "$d" && sha256sum -c --strict SHA256SUMS ) \
        || die "sha256 校验失败: ${REPO_ROOT}/${sub}"
    log "sha256 校验通过: ${REPO_ROOT}/${sub}"
    VERIFIED[$sub]=1
done

# ---------- 4. 逐包精确匹配 + 防呆 + 收集 ----------
mkdir -p "$OUT_DIR" "$(dirname "$MANIFEST")"
: > "$MANIFEST"

for line in "${PKGS[@]}"; do
    pkg="${line%%=*}"
    sub="$(subdir_of "$line")"
    d="$WORK/apk/${REPO_ROOT}/${sub}"

    # 精确匹配：完整包名 + 开头锚定；同时容忍 - 与 _ 两种分隔
    mapfile -t cands < <(find "$d" -maxdepth 1 -type f \
        \( -name "${pkg}-*.apk" -o -name "${pkg}_*.apk" \) | sort -V)

    [ "${#cands[@]}" -gt 0 ] || die "找不到包: ${pkg}（目录 ${REPO_ROOT}/${sub}）"
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

# ---------- 5. 写元信息（给 Release 正文 / BUILDINFO 用） ----------
printf 'apk_repo=%s\napk_branch=%s\napk_commit=%s\napk_source=%s\npkg_count=%s\n' \
    "$APK_REPO" "$USED_BRANCH" "$USED_COMMIT" "$APK_SRC_URL" "${#PKGS[@]}" > "$META"

log "完成：${#PKGS[@]} 个包已放入 ${OUT_DIR}"
log "清单: ${MANIFEST}   元信息: ${META}"
