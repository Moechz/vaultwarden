#!/usr/bin/env bash
# ============================================================
# build.sh - 在 macOS / Linux 上把 Vaultwarden 打包成 TOS 7 应用中心
# 规范的 deb 包（WebUI 应用，经 TOS nginx 网关路由访问）
#
# 规范依据: https://help.terra-master.com/developer/development-docs/
#   - Deb Development Specification（目录结构/config.ini/systemd/生命周期）
#   - Package Specification（版本号三处一致、资产命名）
#
# 访问架构（docs/DESIGN_DECISIONS.md D-010，2026-09 商店审核合规版）:
#   - config.ini 的 path 为路由 /vaultwarden/（C21：禁直连 URL，
#     TOS web 入口端口逐机漂移，直开端口的 path 写法必被驳回）
#   - 服务仅监听 127.0.0.1:<port>（安全审核：0.0.0.0 裸奔一票否决）
#   - nginx 网关为唯一入口：/vaultwarden/ 保留前缀反代
#     （vaultwarden 经 DOMAIN 的路径部分原生把全部路由挂在前缀下，
#     上游官方支持的部署方式；WebSocket 升级头已带）
#   - 附带隐私政策精确路由 /vaultwarden/privacy-policy.html（C3 必备）
#
# 二进制来源（D-011，V6 审核关键）:
#   source（默认，上架必用）: 本仓库 GitHub Actions 从上游源码 tag
#     自建的静态 musl 二进制 + bw_web_builds 官方 web vault，
#     产物来自公开 Release，sha256 与 config.env 钉死值双重校验
#   compat（仅本地调试）: 上游官方 alpine 镜像提取（预编译 ELF 无
#     源码可溯，V6 一票否决；产物不得提交商店）
#
# 产物（out/）:
#   vaultwarden_<版本>_<arch>.deb       完整版本名 deb（本地安装/测试用）
#   vaultwarden_{x86_64,aarch64}.deb    Release 资产名 deb（上架上传用）
#   vaultwarden_<platform>.deb.sha256   上架要求的校验文件
#
# 阶段: fetch → stage → verify → deb
# ============================================================
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=config.env
. "$SCRIPT_DIR/config.env"

# 本地调试逃生门：VW_COMPAT=1 ./build.sh ... 强制 compat 模式
# （镜像提取，产物禁止上架；见 docs/DESIGN_DECISIONS.md D-011）
if [ "${VW_COMPAT:-0}" = "1" ]; then
  BINARY_SOURCE=compat
fi

BUILD_DIR="$SCRIPT_DIR/build"
DL_DIR="$BUILD_DIR/downloads"
STAGE_DIR="$BUILD_DIR/pkgroot"
OUT_DIR="$SCRIPT_DIR/out"
ASSETS_DIR="$SCRIPT_DIR/assets"

# 完整版本 = 上游版本-打包迭代号（如 1.37.3-1）
VERSION_FULL="${VAULTWARDEN_VERSION}-${PKG_RELEASE}"

# ---------------- 目标平台（TOS / NAS 侧） ----------------
case "$TARGET_ARCH" in
  amd64)
    TOS_PLATFORM="x86_64"
    ELF_ARCH="x86-64"
    ;;
  arm64)
    TOS_PLATFORM="aarch64"
    ELF_ARCH="ARM aarch64"
    ;;
  *)
    echo "错误: 未知 TARGET_ARCH=$TARGET_ARCH（支持 amd64 / arm64）" >&2
    exit 1
    ;;
esac

DEB_FILE="$OUT_DIR/${APP_ID}_${VERSION_FULL}_${TARGET_ARCH}.deb"
STORE_DEB="$OUT_DIR/${APP_ID}_${TOS_PLATFORM}.deb"       # Release 资产命名（无版本）

MAINTAINER_FULL="$MAINTAINER_NAME <$MAINTAINER_EMAIL>"

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m警告:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m错误:\033[0m %s\n' "$*" >&2; exit 1; }

sha256_of() { # sha256_of <file> -> 64 位哈希（macOS/Linux 兼容）
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

normalize_text() { # 规范要求：文本文件 LF 行尾 + UTF-8 无 BOM（构建时统一清洗）
  python3 - "$@" <<'PYEOF'
import sys
for p in sys.argv[1:]:
    with open(p, 'rb') as f:
        data = f.read()
    if data.startswith(b'\xef\xbb\xbf'):
        data = data[3:]
    data = data.replace(b'\r\n', b'\n').replace(b'\r', b'\n')
    with open(p, 'wb') as f:
        f.write(data)
PYEOF
}

# ============================================================
# 阶段: fetch
# ============================================================
stage_fetch() {
  mkdir -p "$DL_DIR"

  # 1. 二进制 + web vault（按 BINARY_SOURCE 分流）
  case "$BINARY_SOURCE" in
    source)
      # V6 合规来源：本仓库 Release 的 CI 自建静态二进制
      # （上游源码 tag → blackdex/rust-musl 容器 → cargo --locked 构建）
      case "$TARGET_ARCH" in
        amd64) local PIN="$VW_SHA256_AMD64" ;;
        arm64) local PIN="$VW_SHA256_ARM64" ;;
      esac
      [ -n "$PIN" ] || die "config.env 未钉死 VW_SHA256_$TARGET_ARCH（source 模式必需；CI 出产物后回填）"
      [ -n "$WEB_VAULT_SHA256" ] || die "config.env 未钉死 WEB_VAULT_SHA256（source 模式必需）"
      log "拉取自建产物 Release v$VERSION_FULL（$REPO_URL）"
      python3 "$SCRIPT_DIR/scripts/fetch_release.py" \
        --repo "${REPO_URL#https://github.com/}" --tag "v$VERSION_FULL" \
        --arch "$TOS_PLATFORM" --webvault-version "$WEB_VAULT_VERSION" \
        --pin-binary "$PIN" --pin-webvault "$WEB_VAULT_SHA256" \
        --destdir "$DL_DIR"
      ;;
    compat)
      # 本地调试：上游官方 alpine 镜像提取（V6 不合规，禁止上架）
      warn "compat 模式产物禁止提交商店（预编译 ELF，V6 一票否决）"
      local IMAGE_TAG="${VAULTWARDEN_VERSION}${IMAGE_TAG_VARIANT}"
      log "拉取 $IMAGE_REPO:$IMAGE_TAG ($TARGET_ARCH)"
      python3 "$SCRIPT_DIR/scripts/fetch_image.py" \
        --repo "$IMAGE_REPO" --tag "$IMAGE_TAG" --arch "$TARGET_ARCH" \
        --destdir "$DL_DIR"
      ;;
    *)
      die "未知 BINARY_SOURCE=$BINARY_SOURCE（支持 source / compat）"
      ;;
  esac

  # 2. 上游 LICENSE（AGPL-3.0，进 /usr/share/doc/vaultwarden/copyright）
  if [ ! -s "$DL_DIR/LICENSE" ]; then
    log "下载 LICENSE"
    curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors \
      "https://raw.githubusercontent.com/dani-garcia/vaultwarden/${VAULTWARDEN_VERSION}/LICENSE.txt" \
      -o "$DL_DIR/LICENSE" || \
      curl -fsSL --retry 5 --retry-delay 3 \
      "https://raw.githubusercontent.com/dani-garcia/vaultwarden/${VAULTWARDEN_VERSION}/LICENSE" \
      -o "$DL_DIR/LICENSE"
  fi

  # 3. web vault 版本记录（changelog/文档用；与二进制同源配套）
  python3 - "$DL_DIR/web-vault-layer.tgz" "$DL_DIR/web-vault-version.txt" <<'PYEOF'
import sys, json, tarfile
tf = tarfile.open(sys.argv[1], "r:gz")
v = json.load(tf.extractfile("web-vault/version.json"))["version"]
open(sys.argv[2], "w").write(v + "\n")
PYEOF
  log "web vault 版本: $(cat "$DL_DIR/web-vault-version.txt")"
  if [ "$BINARY_SOURCE" = source ]; then
    [ "$(cat "$DL_DIR/web-vault-version.txt")" = "$WEB_VAULT_VERSION" ] \
      || die "web vault 版本 ($WEB_VAULT_VERSION) 与 Release 资产不符"
  fi
}

# ============================================================
# 阶段: stage —— 组装 deb 文件系统树（官方规范布局）
# ============================================================
stage_stage() {
  [ -s "$DL_DIR/vaultwarden" ] && [ -s "$DL_DIR/web-vault-layer.tgz" ] \
    || die "缺少下载产物，请先运行: ./build.sh fetch"
  local WEBVAULT_VERSION
  WEBVAULT_VERSION=$(cat "$DL_DIR/web-vault-version.txt")

  local APP="$STAGE_DIR/usr/local/$APP_ID"
  log "组装文件系统树: $STAGE_DIR（/usr/local/$APP_ID 规范布局）"
  rm -rf "$STAGE_DIR"
  mkdir -p "$APP/bin"
  mkdir -p "$APP/images/icons"
  mkdir -p "$APP/nginx"
  mkdir -p "$APP/init.d"
  mkdir -p "$APP/privacy"
  mkdir -p "$STAGE_DIR/usr/share/doc/$APP_ID"

  # 二进制（source 模式为 CI 自建静态 musl；规范要求放 bin/）
  log "  + bin/vaultwarden（上游 $VAULTWARDEN_VERSION，$BINARY_SOURCE 来源）"
  install -m 0755 "$DL_DIR/vaultwarden" "$APP/bin/vaultwarden"

  # web vault 静态文件（bw_web_builds 官方发布，与二进制同 Release 配套）
  log "  + web-vault/（web vault $WEBVAULT_VERSION）"
  python3 - "$DL_DIR/web-vault-layer.tgz" "$APP/web-vault" <<'PYEOF'
import os, stat, sys, tarfile
src, dest = sys.argv[1], sys.argv[2]
os.makedirs(dest, exist_ok=True)
tf = tarfile.open(src, "r:gz")
count = 0
for m in tf:
    name = m.name.lstrip("./")
    if not name.startswith("web-vault/"):
        continue
    rel = name[len("web-vault/"):]
    if not rel or rel.endswith(("/._", "/.DS_Store")) or "/._" in rel or rel.startswith("._"):
        continue
    out = os.path.join(dest, rel)
    if m.isdir():
        os.makedirs(out, exist_ok=True)
        os.chmod(out, 0o755)
    elif m.issym():
        os.makedirs(os.path.dirname(out), exist_ok=True)
        try:
            os.symlink(m.linkname, out)
        except FileExistsError:
            pass
    elif m.isfile():
        os.makedirs(os.path.dirname(out), exist_ok=True)
        with open(out, "wb") as f:
            f.write(tf.extractfile(m).read())
        os.chmod(out, 0o644)
        count += 1
    else:
        pass  # 罕见类型（fifo/dev）不适用
print(f"    提取 {count} 个文件")
PYEOF

  # config.ini（严格 JSON；@@...@@ 占位符渲染）
  # 路由模式（C21）：path 必须是 /<appid>/ 路由，不得出现 ${ip}/协议/端口
  log "  + config.ini（path=/vaultwarden/ 路由）"
  sed -e "s|@@VERSION@@|$VERSION_FULL|g" \
      -e "s|@@PUBLISHER@@|$PUBLISHER|g" \
      -e "s|@@PLATFORM@@|$TOS_PLATFORM|g" \
      "$ASSETS_DIR/config.ini.in" > "$APP/config.ini"

  # 多语言文件（文件名必须等于 app id；23 语超集覆盖两个官方口径）
  log "  + $APP_ID.lang（23 语言超集）"
  sed -e "s|@@VERSION@@|$VERSION_FULL|g" \
      -e "s|@@UPSTREAM@@|$VAULTWARDEN_VERSION|g" \
      -e "s|@@WEBVAULT@@|$WEBVAULT_VERSION|g" \
      "$ASSETS_DIR/$APP_ID.lang" > "$APP/$APP_ID.lang"

  # 图标（官方 icon，viewBox 0 0 256 256，透明背景；文件名必须等于 app id）
  log "  + images/icons/$APP_ID.svg"
  cp "$ASSETS_DIR/images/icons/$APP_ID.svg" "$APP/images/icons/$APP_ID.svg"

  # nginx 路由：app 目录内 nginx/ 满足 TOS 规范；
  # 内容为 /vaultwarden/ 保留前缀反代（回环）+ 隐私政策精确路由；
  # 同时以 dpkg 实体文件放 /etc/nginx/conf.d（双落盘模式，postinst 校验自愈）
  log "  + nginx/ + /etc/nginx/conf.d/（保留前缀反代 → 127.0.0.1:$APP_PORT）"
  mkdir -p "$STAGE_DIR/etc/nginx/conf.d"
  cp "$ASSETS_DIR/nginx/$APP_ID.conf" "$APP/nginx/$APP_ID.conf"
  cp "$APP/nginx/$APP_ID.conf" "$STAGE_DIR/etc/nginx/conf.d/$APP_ID.conf"

  # systemd 服务：init.d/ 满足 TOS 规范；同时以 dpkg 实体文件放
  # /etc/systemd/system（双落盘模式，systemd 直接加载，不依赖 postinst 拷贝）
  log "  + init.d/ + /etc/systemd/system/（回环监听）"
  mkdir -p "$STAGE_DIR/etc/systemd/system"
  cp "$ASSETS_DIR/init.d/$APP_ID.service" "$APP/init.d/$APP_ID.service"
  cp "$ASSETS_DIR/init.d/$APP_ID.service" "$STAGE_DIR/etc/systemd/system/$APP_ID.service"

  # webui.bz2（WebUI 类应用必填；解压须含可打开的 .html）
  # 入口页：跳转到 /vaultwarden/ 路由 + 隐私政策链接
  # 坑 46：python tarfile 重打（uid/gid=0、mtime=0、GNU 格式），
  #        bsdtar 在 macOS 上的 uid 501 污染会触发嵌套归档校验失败
  log "  + webui.bz2（入口页 → /vaultwarden/，python tarfile 规范重打）"
  local WEBUI_DIR="$BUILD_DIR/webui"
  rm -rf "$WEBUI_DIR"
  mkdir -p "$WEBUI_DIR"
  sed -e "s|@@VERSION@@|$VERSION_FULL|g" \
      "$ASSETS_DIR/webui/index.html" > "$WEBUI_DIR/index.html"
  normalize_text "$WEBUI_DIR/index.html"
  find "$WEBUI_DIR" -name '._*' -delete 2>/dev/null || true
  python3 - "$WEBUI_DIR" "$APP/webui.bz2" <<'PYEOF'
import os, tarfile, sys
src_dir, out = sys.argv[1], sys.argv[2]
with tarfile.open(out, "w:bz2", format=tarfile.GNU_FORMAT) as tf:
    for root, dirs, files in os.walk(src_dir):
        dirs.sort(); files.sort()
        for name in files:
            if name.startswith("._") or name == ".DS_Store":
                continue
            full = os.path.join(root, name)
            arc = os.path.relpath(full, src_dir)
            ti = tf.gettarinfo(full, arcname=arc)
            ti.uid = 0; ti.gid = 0; ti.uname = "root"; ti.gname = "root"
            ti.mtime = 0
            ti.mode = 0o644
            with open(full, "rb") as f:
                tf.addfile(ti, f)
PYEOF

  # 隐私政策（C3 必备资产；nginx 精确路由 + 包内落盘 + 文档指引三处可达）
  log "  + privacy/privacy-policy.html（/vaultwarden/privacy-policy.html）"
  cp "$ASSETS_DIR/privacy/privacy-policy.html" "$APP/privacy/privacy-policy.html"

  # 配置模板（以 .example 随包分发，postinst 首装复制为正式 env；升级不覆盖）
  log "  + $APP_ID.env.example 配置模板"
  cp "$ASSETS_DIR/$APP_ID.env" "$APP/$APP_ID.env.example"

  # 文档（copyright = 上游 AGPL-3.0 + web vault 版权说明）
  {
    head -2 "$DL_DIR/LICENSE"
    echo ""
    echo "Vaultwarden is licensed under the GNU Affero General Public License v3.0."
    echo "Full text follows."
    echo ""
    echo "This package additionally bundles the Bitwarden-compatible web vault"
    echo "(version $WEBVAULT_VERSION, from the official bw_web_builds release,"
    echo "(c) Bitwarden Inc., https://github.com/bitwarden/clients — AGPL-3.0,"
    echo "patches by Daniel García, https://github.com/dani-garcia/bw_web_builds)."
    echo ""
    tail -n +3 "$DL_DIR/LICENSE"
  } > "$STAGE_DIR/usr/share/doc/$APP_ID/copyright"
  {
    echo "$APP_ID ($VERSION_FULL) TOS7; urgency=medium"
    echo ""
    echo "  * Vaultwarden 上游 $VAULTWARDEN_VERSION（本仓库 CI 从官方源码"
    echo "    tag 自建的静态 musl 二进制，溯源见 PROVENANCE.md）"
    echo "  * 随包 web vault $WEBVAULT_VERSION（bw_web_builds 官方发布）"
    echo "  * 经 TOS 网关路由 /vaultwarden/ 访问（保留前缀反代 + WebSocket）"
    echo "  * 服务仅监听回环 127.0.0.1，隐私政策见 /vaultwarden/privacy-policy.html"
    echo "  * 管理后台 /vaultwarden/admin，安装时自动生成 ADMIN_TOKEN"
    echo ""
    echo " -- $MAINTAINER_FULL  $(date -R 2>/dev/null || date '+%a, %d %b %Y %H:%M:%S %z')"
  } > "$STAGE_DIR/usr/share/doc/$APP_ID/changelog.Debian"

  # 构建溯源（V6/坑 43：源码-产物对应关系随包可查；注意放应用目录——
  # TOS dpkg path-exclude 会剥离 /usr/share/doc 下非 copyright/changelog 文件）
  {
    echo "Vaultwarden for TOS — build provenance"
    echo "====================================="
    echo "Package version : $VERSION_FULL ($TOS_PLATFORM)"
    echo "Upstream source : https://github.com/dani-garcia/vaultwarden"
    echo "Upstream tag    : $VAULTWARDEN_VERSION"
    echo "Web vault       : bw_web_builds v$WEBVAULT_VERSION (official release)"
    echo "Binary origin   : GitHub Actions build from the upstream source tag"
    echo "                  $REPO_URL (CI workflow: .github/workflows/release.yml)"
    echo "Toolchain       : blackdex/rust-musl <arch>-musl-stable-1.98.1"
    echo "                  cargo build --features sqlite,mysql,postgresql,enable_mimalloc"
    echo "                  --profile release --target <arch>-unknown-linux-musl"
    if [ "$BINARY_SOURCE" = source ]; then
      echo "Binary sha256   : $( [ "$TARGET_ARCH" = amd64 ] && echo "$VW_SHA256_AMD64" || echo "$VW_SHA256_ARM64" )"
      echo "Web vault sha256: $WEB_VAULT_SHA256"
      echo "Release         : $REPO_URL/releases/tag/v$VERSION_FULL"
    else
      echo "Binary sha256   : (compat mode: extracted from official alpine image)"
      echo "!! This binary was NOT built by the public CI (compat/local mode)."
      echo "!! Do not submit this build to the TOS App Center."
    fi
    echo "Reproducible build: see $REPO_URL (VERIFICATION.md, repro-build.sh)"
  } > "$APP/PROVENANCE.md"

  # 规范清洗：LF 行尾 + 去 BOM（.ini/.lang/.conf/.service/env/.sh/.html；
  # web-vault 为上游二进制资产，不动）
  log "  清洗行尾（LF）与 BOM"
  normalize_text \
    "$APP/config.ini" "$APP/$APP_ID.lang" \
    "$APP/nginx/$APP_ID.conf" \
    "$STAGE_DIR/etc/nginx/conf.d/$APP_ID.conf" \
    "$APP/init.d/"*.service \
    "$STAGE_DIR/etc/systemd/system/"*.service \
    "$APP/"*.example \
    "$APP/privacy/privacy-policy.html" \
    "$APP/PROVENANCE.md" \
    "$STAGE_DIR/usr/share/doc/$APP_ID/copyright" \
    "$STAGE_DIR/usr/share/doc/$APP_ID/changelog.Debian"

  # 清理 macOS 扩展属性，避免污染 tar（AppleDouble / quarantine）
  if command -v xattr >/dev/null 2>&1; then
    xattr -rc "$STAGE_DIR" >/dev/null 2>&1 || true
  fi
  find "$STAGE_DIR" -name '._*' -delete 2>/dev/null || true
  find "$STAGE_DIR" -name '.DS_Store' -delete 2>/dev/null || true

  log "组装完成（$APP/bin/vaultwarden + $APP/web-vault/ 共 $(du -sh "$APP" | cut -f1)）"
}

# ============================================================
# 阶段: verify —— 目标架构与规范关键项校验（商店审核门禁）
# ============================================================
stage_verify() {
  local APP="$STAGE_DIR/usr/local/$APP_ID"
  [ -d "$APP" ] || die "尚未组装，请先运行: ./build.sh stage"
  local fail=0

  log "校验规范关键路径..."
  local p
  for p in "$APP/config.ini" "$APP/$APP_ID.lang" \
           "$APP/images/icons/$APP_ID.svg" \
           "$APP/nginx/$APP_ID.conf" \
           "$APP/init.d/$APP_ID.service" \
           "$STAGE_DIR/etc/systemd/system/$APP_ID.service" \
           "$STAGE_DIR/etc/nginx/conf.d/$APP_ID.conf" \
           "$APP/bin/vaultwarden" \
           "$APP/web-vault/index.html" \
           "$APP/web-vault/version.json" \
           "$APP/webui.bz2" \
           "$APP/privacy/privacy-policy.html" \
           "$APP/$APP_ID.env.example" \
           "$APP/PROVENANCE.md" \
           "$STAGE_DIR/usr/share/doc/$APP_ID/copyright"; do
    [ -e "$p" ] || { warn "缺失: ${p#$STAGE_DIR/}"; fail=1; }
  done

  log "校验 config.ini（JSON 合法性 / 路由 path / 版本一致性）..."
  python3 - "$APP/config.ini" "$VERSION_FULL" "$TOS_PLATFORM" "$APP_ID" "$APP_USER" <<'PYEOF' || fail=1
import json, re, sys
cfg_path, want_ver, want_plat, app_id, app_user = sys.argv[1:6]
cfg = json.load(open(cfg_path))
errs = []
if cfg.get("id") != app_id: errs.append(f"id != {app_id}")
if cfg.get("version") != want_ver: errs.append(f"version != {want_ver}")
if cfg.get("system_id") != app_id: errs.append("system_id 不一致")
if cfg.get("package") != app_id: errs.append("package 不一致")
if cfg.get("platform") != want_plat: errs.append(f"platform != {want_plat}")
if cfg.get("open_path") is not True: errs.append("open_path 必须为 true")
if "type" in cfg: errs.append("不得包含 type 字段（与 open_path 互斥）")
# C21：path 必须是 /<appid>/ 形式路由；直连 URL（${ip}/协议/端口）必被驳回
path = cfg.get("path", "")
if not re.fullmatch(r"/[a-z0-9_-]+/", path):
    errs.append(f"path 必须为 /<appid>/ 路由格式（当前: {path!r}）")
if path != f"/{app_id}/":
    errs.append(f"path 应为 /{app_id}/")
if "${ip}" in path or "://" in path or ":" in path:
    errs.append("path 不得含 ${ip} / 协议 / 端口（C21 直连写法）")
if not re.fullmatch(r"https://\S+", cfg.get("official", "")):
    errs.append("official 必须为可达的 https URL（30a 机器验链）")
if cfg.get("user") != app_user: errs.append(f"user 应为 {app_user}")
if cfg.get("recommend") is not False: errs.append("recommend 提交时必须为 false")
if cfg.get("beta") is not False: errs.append("beta 必须为 false（V11 双重门禁）")
for e in errs:
    print(f"    校验失败: {e}", file=sys.stderr)
sys.exit(1 if errs else 0)
PYEOF

  log "校验 .lang（23 语超集 + 版本一致 + 禁 beta 字样）..."
  local lang_missing
  lang_missing=$(python3 - "$APP/$APP_ID.lang" <<'PYEOF'
import sys
required = ["zh-cn","zh-hk","en-us","fr-fr","de-de","it-it","es-es",
            "hu-hu","ja-jp","ko-kr","pl-pl","ru-ru","tr-tr","pt-pt",
            "ar-sa","cs-cz","he-il","id-id","nb-no","nl-nl","sv-se",
            "th-th","vi-vn"]
text = open(sys.argv[1], encoding="utf-8").read()
missing = [t for t in required if f"[{t}]" not in text]
print(",".join(missing))
PYEOF
)
  [ -z "$lang_missing" ] || { warn "lang 缺少语言节: $lang_missing"; fail=1; }
  # V11：beta 双重门禁之文案门（config 已查，此处查 lang 文本）
  if grep -qiE '(^|[^a-z])beta([^a-z]|$)' "$APP/$APP_ID.lang"; then
    warn "lang 文案含 beta 字样（V11 门禁：未过 beta 审核不得出现）"
    fail=1
  fi
  if grep -q "@@VERSION@@\|@@UPSTREAM@@\|@@WEBVAULT@@" "$APP/$APP_ID.lang"; then
    warn "lang 存在未渲染的占位符"; fail=1
  fi

  log "校验 systemd 服务（回环监听 / 禁 Restart / 禁 ExecStart 变量展开）..."
  local svc
  for svc in "$APP/init.d/"*.service \
             "$STAGE_DIR/etc/systemd/system/"*.service; do
    grep -q '^\[Unit\]' "$svc" || { warn "非 systemd unit: $svc"; fail=1; }
    grep -Eq '^Restart' "$svc" && { warn "规范禁止配置 Restart: $svc"; fail=1; }
    grep -Eq '^ExecStart=.*\$' "$svc" && { warn "ExecStart 禁用变量展开（曾致全环境 502）: $svc"; fail=1; }
    grep -q '^StartLimitBurst=' "$svc" || { warn "缺少 StartLimitBurst: $svc"; fail=1; }
    grep -q '^StartLimitIntervalSec=' "$svc" || { warn "缺少 StartLimitIntervalSec: $svc"; fail=1; }
    grep -q "^User=$APP_USER" "$svc" || { warn "必须 User=$APP_USER: $svc"; fail=1; }
    # 安全审核：服务必须回环监听（0.0.0.0 无平台鉴权 = 一票否决）
    grep -q '^Environment=ROCKET_ADDRESS=127\.0\.0\.1$' "$svc" \
      || { warn "unit 必须内置 Environment=ROCKET_ADDRESS=127.0.0.1（回环）: $svc"; fail=1; }
    grep -q "^Environment=DOMAIN=.*/$APP_ID\$" "$svc" \
      || { warn "unit 必须内置 DOMAIN（路径部分 /$APP_ID 与 nginx 路由联动）: $svc"; fail=1; }
  done
  grep -q "^Environment=ROCKET_PORT=$APP_PORT\$" "$APP/init.d/$APP_ID.service" \
    || { warn "unit 必须内置 Environment=ROCKET_PORT=$APP_PORT"; fail=1; }
  grep -q '^Environment=DATA_FOLDER=/var/lib/vaultwarden' "$APP/init.d/$APP_ID.service" \
    || { warn "unit 必须内置 Environment=DATA_FOLDER"; fail=1; }

  log "校验 nginx 路由（保留前缀反代回环 + WS 头 + 隐私政策精确路由）..."
  grep -q "proxy_pass http://127\.0\.0\.1:$APP_PORT/$APP_ID/" "$APP/nginx/$APP_ID.conf" \
    || { warn "nginx 必须保留前缀反代到 127.0.0.1:$APP_PORT/$APP_ID/"; fail=1; }
  grep -q 'proxy_set_header Upgrade' "$APP/nginx/$APP_ID.conf" \
    || { warn "nginx 缺 WebSocket Upgrade 头"; fail=1; }
  grep -q 'proxy_set_header Connection' "$APP/nginx/$APP_ID.conf" \
    || { warn "nginx 缺 WebSocket Connection 头"; fail=1; }
  grep -qE 'location = /'"$APP_ID"'/privacy-policy\.html' "$APP/nginx/$APP_ID.conf" \
    || { warn "nginx 缺隐私政策精确路由（C3）"; fail=1; }
  grep -q "alias .*privacy/privacy-policy\.html" "$APP/nginx/$APP_ID.conf" \
    || { warn "nginx 隐私政策路由必须 alias 到包内落盘文件"; fail=1; }
  grep -qE 'return 302 http' "$APP/nginx/$APP_ID.conf" \
    && { warn "nginx 不得再含直开端口 302 跳转（D-001 已废止）"; fail=1; }

  log "校验隐私政策资产（C3：双语 + 内嵌样式 + 三处可达）..."
  grep -qi '<h1>.*Privacy Policy' "$APP/privacy/privacy-policy.html" \
    || { warn "privacy-policy.html 缺英文标题"; fail=1; }
  grep -q '隐私政策' "$APP/privacy/privacy-policy.html" \
    || { warn "privacy-policy.html 缺中文版（双语要求）"; fail=1; }
  grep -q '/var/lib/vaultwarden' "$APP/privacy/privacy-policy.html" \
    || { warn "privacy-policy.html 应说明数据存放路径"; fail=1; }
  grep -q 'privacy-policy.html' "$APP/webui/index.html" 2>/dev/null \
    || true  # 入口页链接为可发现性加分项，不设硬门

  log "校验 webui.bz2（坑 46：归档元数据 uid/gid=0、mtime=0、无 macOS 污染）..."
  python3 - "$APP/webui.bz2" <<'PYEOF' || fail=1
import sys, tarfile
bad = []
with tarfile.open(sys.argv[1], "r:bz2") as tf:
    names = tf.getnames()
    if not any(n.endswith(".html") for n in names):
        bad.append("缺少 html 入口")
    for m in tf.getmembers():
        if m.name.startswith("._") or "/._" in m.name or m.name == ".DS_Store":
            bad.append(f"AppleDouble 条目: {m.name}")
        if m.uid != 0 or m.gid != 0:
            bad.append(f"uid/gid 非 0: {m.name} uid={m.uid} gid={m.gid}")
        if m.mtime != 0:
            bad.append(f"mtime 非 0: {m.name} mtime={m.mtime}")
if bad:
    for b in bad:
        print(f"    {b}", file=sys.stderr)
    sys.exit(1)
print(f"    {len(names)} 个成员全部合规")
PYEOF

  log "校验图标（坑 47：XML 完整性 / viewBox / 主 path 存在）..."
  python3 - "$APP/images/icons/$APP_ID.svg" <<'PYEOF' || fail=1
import re, sys, xml.etree.ElementTree as ET
path = sys.argv[1]
try:
    root = ET.parse(path).getroot()
except ET.ParseError as e:
    print(f"    SVG 解析失败: {e}", file=sys.stderr); sys.exit(1)
errs = []
if root.tag.endswith("svg") is False:
    errs.append("根元素不是 svg")
vb = root.get("viewBox", "")
if not re.fullmatch(r"[0-9.\s-]+", vb) or len(vb.split()) != 4:
    errs.append(f"viewBox 缺失/畸形: {vb!r}")
paths = [el for el in root.iter() if el.tag.endswith("path")]
if not paths or not any(len(el.get("d", "")) > 50 for el in paths):
    errs.append("缺少有效的主 path")
fills = {el.get("fill") for el in root.iter() if el.get("fill")}
if not fills - {None, "none"}:
    errs.append("缺少显式 fill 颜色")
for e in errs:
    print(f"    {e}", file=sys.stderr)
sys.exit(1 if errs else 0)
PYEOF

  log "校验 ELF（架构 $ELF_ARCH / 静态链接 / 无 UPX 摘除段表 / sha256 钉死）..."
  local bin_out
  bin_out=$(file "$APP/bin/vaultwarden")
  if echo "$bin_out" | grep -q "ELF.*$ELF_ARCH"; then
    log "  ok: 架构匹配"
  else
    warn "错误架构: bin/vaultwarden -> $bin_out"
    fail=1
  fi
  # 坑 28：glibc 动态二进制混入 = TOS 装机必挂（GLIBC_2.39 > TOS 2.35）
  if echo "$bin_out" | grep -q "dynamically linked"; then
    warn "二进制是动态链接（glibc 版本混入？TOS 不可用）: $bin_out"
    fail=1
  else
    log "  ok: 静态链接"
  fi
  # 坑 31：UPX 摘除段表的二进制过不了 V6（file 输出会标注 "no section header"）
  if echo "$bin_out" | grep -q "no section header"; then
    warn "二进制段表缺失（UPX 加壳特征，V6 驳回）"
    fail=1
  fi
  if [ "$BINARY_SOURCE" = source ]; then
    local want_pin bin_sha
    case "$TARGET_ARCH" in amd64) want_pin="$VW_SHA256_AMD64" ;; arm64) want_pin="$VW_SHA256_ARM64" ;; esac
    bin_sha=$(sha256_of "$APP/bin/vaultwarden")
    if [ "$bin_sha" = "$want_pin" ]; then
      log "  ok: sha256 与 config.env 钉死值一致（CI 产物链完整）"
    else
      warn "二进制 sha256 与钉死值不符: $bin_sha != $want_pin"
      fail=1
    fi
  else
    warn "compat 模式：跳过 sha256 钉死校验（产物禁止上架）"
  fi

  log "检查 macOS Mach-O / AppleDouble 混入（应为 0）..."
  local n_macho n_appledouble
  n_macho=$(find "$APP" -type f -exec file {} + 2>/dev/null | grep -c "Mach-O" || true)
  [ "$n_macho" -eq 0 ] || { warn "发现 $n_macho 个 Mach-O 文件！"; fail=1; }
  n_appledouble=$(find "$APP" -name '._*' -o -name '.DS_Store' | wc -l | tr -d ' ')
  [ "$n_appledouble" -eq 0 ] || { warn "发现 $n_appledouble 个 AppleDouble/.DS_Store 条目"; fail=1; }

  log "S8 自检：包内维护脚本零在线安装/零网络操作（回环健康检查除外）..."
  local bad
  bad=$(grep -RnE 'pip install|apt(-get)? install|curl .*(install|https?://)|wget |urllib|urlopen' \
        "$ASSETS_DIR/preinst" "$ASSETS_DIR/postinst" "$ASSETS_DIR/prerm" "$ASSETS_DIR/postrm" 2>/dev/null \
        | grep -vE '127\.0\.0\.1|localhost|unix-socket' || true)
  if [ -n "$bad" ]; then
    warn "维护脚本中出现疑似网络操作（商店 S8 红线）:"
    echo "$bad" >&2
    fail=1
  fi

  if [ "$fail" -eq 0 ]; then
    log "校验通过 ✅"
  else
    die "校验失败，请检查上方警告"
  fi
}

# ============================================================
# 阶段: deb —— 生成 .deb + 上架资产
# ============================================================
stage_deb() {
  [ -d "$STAGE_DIR/usr/local/$APP_ID" ] || die "尚未组装，请先运行: ./build.sh stage"
  mkdir -p "$OUT_DIR"
  # shellcheck source=makedeb.sh
  "$SCRIPT_DIR/makedeb.sh" "$STAGE_DIR" "$ASSETS_DIR" "$DEB_FILE" \
    "$VERSION_FULL" "$TARGET_ARCH" "$MAINTAINER_FULL"

  # Release 资产命名（版本由 Release tag 表达）+ 上架要求的 sha256
  cp "$DEB_FILE" "$STORE_DEB"
  sha256_of "$STORE_DEB" | awk '{print $1"  "$2}' > "$STORE_DEB.sha256"
  log "完成: $DEB_FILE"
  log "上架资产: $STORE_DEB (+ .sha256；Release tag 须为 v$VERSION_FULL)"
}

stage_info() {
  cat <<EOF
Vaultwarden 版本: $VAULTWARDEN_VERSION (完整版本 $VERSION_FULL)
web vault 版本  : $(cat "$DL_DIR/web-vault-version.txt" 2>/dev/null || echo 未 fetch)
二进制来源     : $BINARY_SOURCE（source=CI 自建 / compat=镜像提取仅本地）
目标架构       : $TARGET_ARCH (TOS:$TOS_PLATFORM)
TOS app id     : $APP_ID（入口路由 /$APP_ID/，回环 :$APP_PORT）
产物           : $DEB_FILE
上架资产       : $STORE_DEB + .sha256（Release tag: v$VERSION_FULL）
EOF
}

stage_clean() {
  rm -rf "$STAGE_DIR" "$BUILD_DIR/webui"
  log "已清理 stage（保留下载缓存）"
}

stage_distclean() {
  rm -rf "$BUILD_DIR" "$OUT_DIR"
  log "已清理全部构建产物与下载缓存"
}

# ============================================================
# 入口
# ============================================================
STAGE=${1:-all}
case "$STAGE" in
  fetch)      stage_fetch ;;
  stage)      stage_stage ;;
  deb)        stage_deb ;;
  all)        stage_fetch; stage_stage; stage_verify; stage_deb ;;
  clean)      stage_clean ;;
  distclean)  stage_distclean ;;
  verify)     stage_verify ;;
  info)       stage_info ;;
  *)          die "未知阶段: $STAGE（可用: fetch stage deb verify clean distclean info）" ;;
esac
