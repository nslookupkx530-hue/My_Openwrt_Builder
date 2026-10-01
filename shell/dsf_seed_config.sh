#!/usr/bin/env bash
# 用法: dsf_seed_config.sh <种子配置相对路径> <profile key>
# 作用: 种子 .config → make defconfig → 收窄到单设备 → zh-cn 兜底 → 断言
set -euo pipefail

SEED="$1"; PROFILE="$2"
SRC_DIR="${WORKSPACE:?}/src"
SEED_PATH="${WORKSPACE}/${SEED}"
[ -f "${SEED_PATH}" ] || { echo "ERROR: 找不到种子配置 ${SEED_PATH}"; exit 1; }
cd "${SRC_DIR}"

set_on()  { local s="$1"; grep -q "^${s}=" .config && sed -i "s|^${s}=.*|${s}=y|" .config     || echo "${s}=y" >> .config; }
set_off() { local s="$1"; grep -q "^${s}=" .config && sed -i "s|^${s}=.*|# ${s} is not set|" .config || echo "# ${s} is not set" >> .config; }

SEED_ZHCN="$(grep -c '^CONFIG_PACKAGE_luci-i18n-.*-zh-cn=y' "${SEED_PATH}" || true)"
echo ">>> 种子里的 zh-cn 包: ${SEED_ZHCN} 个"

cp -f "${SEED_PATH}" .config
echo ">>> 第 1 次 defconfig（展开种子）"
make defconfig

BOARD="$(sed -n 's/^CONFIG_TARGET_BOARD="\?\([^"]*\)"\?$/\1/p' .config | head -n1)"
SUB="$(sed -n 's/^CONFIG_TARGET_SUBTARGET="\?\([^"]*\)"\?$/\1/p' .config | head -n1)"
[ -n "${BOARD}" ] && [ -n "${SUB}" ] || { echo "ERROR: 无法从 .config 推导 target（board/subtarget）"; exit 1; }
SYM="CONFIG_TARGET_${BOARD}_${SUB}_DEVICE_${PROFILE}"
echo ">>> target=${BOARD}/${SUB}  profile 符号=${SYM}"
grep -q "^CONFIG_TARGET_PROFILE=\"DEVICE_${PROFILE}\"" .config \
  && echo ">>> CONFIG_TARGET_PROFILE 正常" \
  || echo "::warning::CONFIG_TARGET_PROFILE 与 ${PROFILE} 不一致（继续，后面看 DEV_ON）"

# ---------- 收窄：只留 1 台设备 ----------
BEFORE="$(grep -cE '^CONFIG_(TARGET_DEVICE_|TARGET_).*_DEVICE_[A-Za-z0-9_.-]+=y$' .config || true)"
echo ">>> 收窄前已启用 device 选项数: ${BEFORE}"
[ -s tmp/.config-target.in ] || { echo "ERROR: tmp/.config-target.in 不存在"; exit 1; }

N=0
while read -r s; do
  [ -n "${s}" ] || continue
  [ "${s}" = "${SYM#CONFIG_}" ] && continue
  case "${s}" in *TARGET_DEVICE_PACKAGES_*) continue ;; esac
  set_off "${s}"; N=$((N+1))
done < <(sed -n -E 's/^[[:space:]]*config[[:space:]]+(TARGET_[A-Za-z0-9_.-]*_DEVICE_[A-Za-z0-9_.-]+)$/\1/p' tmp/.config-target.in | sort -u)
echo ">>> 已显式关闭 ${N} 个其它 device 符号"
set_on "${SYM#CONFIG_}"
set_off CONFIG_TARGET_ALL_PROFILES

echo ">>> 第 2 次 defconfig（固化收窄）"
make defconfig

DEV_ON="$(grep -cE '^CONFIG_(TARGET_DEVICE_|TARGET_).*_DEVICE_[A-Za-z0-9_.-]+=y$' .config || true)"
echo ">>> 收窄后已启用 device 选项数: ${DEV_ON}   (期望 1)"
grep -E '^CONFIG_(TARGET_DEVICE_|TARGET_).*_DEVICE_[A-Za-z0-9_.-]+=y$' .config | sed 's/^/    /' || true
[ "${DEV_ON}" = "1" ] || { echo "ERROR: 收窄失败（${DEV_ON} 台）—— 会编全 target 镜像"; exit 1; }

# ---------- zh-cn 兜底（openwrt 底子的源会丢中文包）----------
if [ "${SEED_ZHCN}" -gt 0 ]; then
  NOW_ZHCN="$(grep -c '^CONFIG_PACKAGE_luci-i18n-.*-zh-cn=y' .config || true)"
  if [ "${NOW_ZHCN}" -eq 0 ]; then
    echo "::warning::种子里 ${SEED_ZHCN} 个 zh-cn 包被 defconfig 丢光了 → 补 CONFIG_LUCI_LANG_zh_Hans=y 后重来"
    set_on CONFIG_LUCI_LANG_zh_Hans
    make defconfig
    grep -q '^CONFIG_LUCI_LANG_zh_Hans=y' .config || { echo "ERROR: LUCI_LANG_zh_Hans 未生效（该树可能没有此符号，需手工处理中文包）"; exit 1; }
    NOW_ZHCN="$(grep -c '^CONFIG_PACKAGE_luci-i18n-.*-zh-cn=y' .config || true)"
    echo ">>> 补后 zh-cn 包: ${NOW_ZHCN} 个"
  else
    echo ">>> zh-cn 包保留 ${NOW_ZHCN} 个（无需兜底）"
  fi
fi

echo ">>> ARCH_PACKAGES = $(sed -n 's/^CONFIG_TARGET_ARCH_PACKAGES="\?\([^"]*\)"\?$/\1/p' .config | head -n1)"
echo ">>> 已选包数     = $(grep -cE '^CONFIG_PACKAGE_.*=y$' .config || true)"
echo ">>> 种子配置处理完成"
