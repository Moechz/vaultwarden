#!/bin/bash
# ============================================================
# publish_release.sh — 把本地构建的 store deb 补传到既有 Release，
# 并把「TOS App Center packages」段落更新进 Release 说明。
#
# 用法: ./scripts/publish_release.sh
#   （改自 docs/TASK_STATE 的发布流程；tag = v<VERSION_FULL> 由 config.env 推导）
# 前置: source 模式 `./build.sh all` 已产出 out/ 下的双架构 store deb + .sha256
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# shellcheck disable=SC1091
. ./config.env

TAG="v${VAULTWARDEN_VERSION}-${PKG_RELEASE}"
REPO="${REPO_URL#https://github.com/}"
OUT="out"

# PAT：优先环境变量，其次本地知识库（绝不入库/不打印）
TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
if [ -z "$TOKEN" ]; then
  TOKEN=$(grep -oE 'ghp_[A-Za-z0-9]+' "$HOME/Documents/projects/GITHUB-TOKEN.md" 2>/dev/null | head -1 || true)
fi
[ -n "$TOKEN" ] || { echo "错误: 未找到 GitHub PAT（GITHUB_TOKEN 或本地知识库）" >&2; exit 1; }

API="https://api.github.com/repos/${REPO}"
AUTH=(-H "Authorization: Bearer ${TOKEN}" -H "Accept: application/vnd.github+json")

echo "==> Release ${REPO} ${TAG}"

# 1. 取 release id
RID=$(curl -fsS "${AUTH[@]}" "${API}/releases/tags/${TAG}" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
echo "    release id = ${RID}"

# 2. 上传双架构 deb + .sha256（已存在则先删再传，满足「发布后不得原地覆盖」的
#    前提是 tag 已递增——本脚本只服务当前 tag）
for plat in x86_64 aarch64; do
  for f in "${OUT}/vaultwarden_${plat}.deb" "${OUT}/vaultwarden_${plat}.deb.sha256"; do
    [ -s "$f" ] || { echo "错误: 缺 $f（先跑 ./build.sh all）" >&2; exit 1; }
    name=$(basename "$f")
    # 同名资产若已存在，先删除（幂等重跑）
    old_id=$(curl -fsS "${AUTH[@]}" "${API}/releases/${RID}/assets" \
      | python3 -c "import sys,json;d=json.load(sys.stdin);print(next((a['id'] for a in d if a['name']=='${name}'),''))")
    if [ -n "$old_id" ]; then
      echo "    删除同名旧资产 ${name} (id=${old_id})"
      curl -fsS -X DELETE "${AUTH[@]}" "${API}/releases/assets/${old_id}" >/dev/null
    fi
    echo "    上传 ${name}"
    curl -fsS -X POST \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/octet-stream" \
      --data-binary @"$f" \
      "https://uploads.github.com/repos/${REPO}/releases/${RID}/assets?name=${name}" \
      >/dev/null
  done
done

# 3. 更新 Release 说明（CI 生成的正文 + deb 段落）
BODY=$(cat <<EOF
## Vaultwarden for TOS — build artifacts

CI-built static (musl) binaries of upstream Vaultwarden **${VAULTWARDEN_VERSION}**,
plus the official web vault **${WEB_VAULT_VERSION}** from bw_web_builds.

- Upstream source: https://github.com/dani-garcia/vaultwarden (tag ${VAULTWARDEN_VERSION})
- Build recipe: mirrors upstream docker/Dockerfile.alpine for ${VAULTWARDEN_VERSION}
- Web vault: https://github.com/dani-garcia/bw_web_builds (tag v${WEB_VAULT_VERSION}), redistributed unmodified
- Integrity: SHA256SUMS covers every CI asset and the unpacked binaries
- How to verify / reproduce: see VERIFICATION.md in this repository

## TOS App Center packages

Install-ready debs for the TerraMaster TOS 7 App Center (also installable via
\`apt install ./vaultwarden_<arch>.deb\`):

| Asset | Arch | sha256 |
|---|---|---|
| \`vaultwarden_x86_64.deb\` | x86_64 | \`$(awk '{print $1}' "${OUT}/vaultwarden_x86_64.deb.sha256")\` |
| \`vaultwarden_aarch64.deb\` | aarch64 | \`$(awk '{print $1}' "${OUT}/vaultwarden_aarch64.deb.sha256")\` |

- Served through the TOS gateway route \`/vaultwarden/\` (loopback-only service,
  prefix-preserving reverse proxy, WebSocket support).
- Privacy policy at \`/vaultwarden/privacy-policy.html\`; build provenance in
  \`/usr/local/vaultwarden/PROVENANCE.md\`.
- Admin token: \`grep ADMIN_TOKEN /usr/local/vaultwarden/vaultwarden.env\`.
- Upstream author: Daniel García; TOS packaging: Moechz.
EOF
)

python3 - "$RID" "$BODY" "$TOKEN" "$REPO" <<'PYEOF'
import json, sys, urllib.request
rid, body, token, repo = sys.argv[1:5]
req = urllib.request.Request(
    f"https://api.github.com/repos/{repo}/releases/{rid}",
    data=json.dumps({"body": body}).encode(),
    method="PATCH",
    headers={"Authorization": f"Bearer {token}",
             "Accept": "application/vnd.github+json",
             "Content-Type": "application/json"})
with urllib.request.urlopen(req, timeout=30) as r:
    rel = json.load(r)
print(f"    release body 已更新（tag={rel['tag_name']}, draft={rel['draft']}）")
PYEOF

echo "==> 完成。资产清单："
curl -fsS "${AUTH[@]}" "${API}/releases/${RID}/assets" \
  | python3 -c "import sys,json;[print('   ',a['name'],round(a['size']/1e6,1),'MB') for a in json.load(sys.stdin)]"
