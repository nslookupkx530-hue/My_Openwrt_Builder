#!/bin/bash
# ==============================================================================
# trim_config.sh —— 关掉本项目用不到 / 已知编不过的选项
#
# 为什么需要：
#   官方 config.buildinfo 里带了一批开发调试工具（perf、kselftests-* 等），
#   它们对路由器固件没有任何用处，而且经常因内核 config / 工具链差异编译失败：
#       ERROR: package/devel/kselftests-bpf failed to build.
#   这里统一关掉，避免每次构建都死在同一个地方。
#
# 执行位置：buildroot 目录（.config 所在），在 prepare_base_config.sh 之后、
#           workflow 最后一次 make defconfig 之前执行。
# 记录：tmp/trimmed-options.txt（供 workflow 校验它们确实还是关闭状态）
#
# 注意：只关"用不到 + 易失败"的；base-files / busybox / libc 这类基础包不要动。
# ==============================================================================
set -euo pipefail

CONFIG_FILE="${CONFIG_FILE:-.config}"
OUT_FILE="${OUT_FILE:-tmp/trimmed-options.txt}"

# ------------------------------------------------------------------
# 关闭列表
#   CONFIG_PACKAGE_kselftests-bpf  ← 内核 BPF 自测集，依赖内核 BTF/调试信息，用不到
#   CONFIG_PACKAGE_kselftests-net  ← 同族（源码里没有会自动跳过）
#   CONFIG_PACKAGE_perf            ← 需要时再放开
#   CONFIG_PACKAGE_bpftool
# ------------------------------------------------------------------
TRIM_OPTS=(
    "CONFIG_PACKAGE_kselftests-bpf"
    "CONFIG_PACKAGE_kselftests-net"
"

# ------------------------------------------------------------------
# 必须打开的选项
#   CONFIG_PACKAGE_ip-full  ← 第三方包 quickstart（网络向导后端）要求 ip-full
#     官方基线装的是 ip-tiny，两者 CONFLICTS，不换掉就永远装不上 quickstart
# ------------------------------------------------------------------
FORCE_ON_OPTS=(
    "CONFIG_PACKAGE_ip-full"
)

# ------------------------------------------------------------------
# 必须关闭的选项（与上面互斥）
#   CONFIG_PACKAGE_ip-tiny
# ------------------------------------------------------------------
FORCE_OFF_OPTS=(
    "CONFIG_PACKAGE_ip-tiny"
)

if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: 找不到 ${CONFIG_FILE}（本脚本必须在 src/ 下执行）" >&2
    exit 1
fi

mkdir -p "$(dirname "$OUT_FILE")"
: > "$OUT_FILE"

set_off() {
    local sym="$1"
    sed -i -e "/^${sym}=/d" -e "/^# ${sym} is not set[[:space:]]*$/d" "$CONFIG_FILE"
    printf '# %s is not set\n' "$sym" >> "$CONFIG_FILE"
    printf '# %s is not set\n' "$sym" >> "$OUT_FILE"
}

set_on() {
    local sym="$1"
    sed -i -e "/^${sym}=/d" -e "/^# ${sym} is not set[[:space:]]*$/d" "$CONFIG_FILE"
    printf '%s=y\n' "$sym" >> "$CONFIG_FILE"
    printf '%s=y\n' "$sym" >> "$OUT_FILE"
}

echo ">>> trim_config.sh"
for s in "${TRIM_OPTS[@]}";      do echo ">>> 关闭 ${s}"; set_off "$s"; done
for s in "${FORCE_OFF_OPTS[@]}"; do echo ">>> 关闭 ${s}"; set_off "$s"; done
for s in "${FORCE_ON_OPTS[@]}";  do echo ">>> 开启 ${s}"; set_on  "$s"; done

echo ">>> 本次改动:"
sed 's/^/      /' "$OUT_FILE"
