#!/usr/bin/env bash
# 从 apk 仓库拉 DSF 设备要用的第三方 apk → OUT_DIR（供首启离线安装）
# 环境变量:
#   APK_REPO=owner/repo   APK_BRANCH=My   APK_ARCH=arm64-a53
#   APK_GROUPS="passwall2 aurora"    # run/<arch>/<group>/ 下的 .apk 全部拉取
#   OUT_DIR=<绝对路径>                # 目标目录
#   GH_TOKEN（可选，提高 API 配额）
set -euo pipefail
: "${APK_REPO:?APK_REPO 未设置}"
: "${APK_BRANCH:?APK_BRANCH 未设置}"
: "${OUT_DIR:?OUT_DIR 未设置}"
APK_ARCH="${APK_ARCH:-arm64-a53}"
APK_GROUPS="${APK_GROUPS:-passwall2 aurora}"

api() { curl -sSL --max-time 60 ${GH_TOKEN:+-H "Authorization: Bearer ${GH_TOKEN}"} \
          -H 'Accept: application/vnd.github+json' "$1" 2>/dev/null || true; }

echo ">>> 列出 ${APK_REPO}@${APK_BRANCH} 文件树"
TREE="$(api "https://api.github.com/repos/${APK_REPO}/git/trees/${APK_BRANCH}?recursive=1" \
        | grep -oE '"path"[[:space:]]*:[[:space:]]*"[^"]+"' \
        | sed -E 's/.*"([^"]+)"[[:space:]]*$/\1/' || true)"
[ -n "${TREE}" ] || { echo "ERROR: 取不到文件树（分支名/权限？）"; exit 1; }
printf '%s\n' "${TREE}" > /tmp/apk-tree.txt

mkdir -p "${OUT_DIR}"
COUNT=0
for g in ${APK_GROUPS}; do
  FILES="$(grep -E "^run/${APK_ARCH}/${g}/.*\.apk$" /tmp/apk-tree.txt | sort || true)"
  [ -n "${FILES}" ] || { echo "::warning::run/${APK_ARCH}/${g}/ 下没有 apk"; continue; }
  for f in ${FILES}; do
    out="${OUT_DIR}/$(basename "${f}")"
    echo ">>> 下载 ${f}"
    curl -fsSL --retry 3 --max-time 300 \
      "https://raw.githubusercontent.com/${APK_REPO}/${APK_BRANCH}/${f}" -o "${out}" \
      || { echo "!! 下载失败: ${f}"; exit 1; }
    ls -l "${out}"
    COUNT=$((COUNT+1))
  done
done
[ "${COUNT}" -gt 0 ] || { echo "ERROR: 一个 apk 都没拉到"; exit 1; }

cd "${OUT_DIR}"
sha256sum ./*.apk > SHA256SUMS
echo ">>> 共拉取 ${COUNT} 个 apk → ${OUT_DIR}"
cat SHA256SUMS
