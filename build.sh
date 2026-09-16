#!/usr/bin/env bash
# ============================================================
# build.sh - 在 macOS / Linux 上把 Vaultwarden 打包成 TOS 7 应用中心
# 规范的 deb 包（WebUI External Open / 新标签页直开端口模式）
#
# 规范依据: https://help.terra-master.com/developer/development-docs/
#   - Deb Development Specification（目录结构/config.ini/systemd/生命周期）
#   - Package Specification（版本号三处一致、资产命名）
#
# 模式说明（hermes 同款"直开端口"方案，docs/DESIGN_DECISIONS.md D-001）:
#   Vaultwarden 的 API 全部固定挂载在根路径（/api /identity /notifications
#   /icons /alive …），web vault 也有根相对请求，不支持子路径部署；
#   TOS 8181 的根命名空间又是平台自身的，不能占用。
#   因此不走"回环 + /vaultwarden/ 反代"，而是：
#     - 服务监听 0.0.0.0:8222，桌面图标新标签页打开 http://${ip}:8222
#     - 各端客户端（浏览器插件/桌面/移动 App）直连同一地址
#     - 附带 /vaultwarden/ → :8222 的 nginx 302 兜底路由（满足 External
#       Open 应用必须带 nginx/ 配置的规范，同时容错手输地址的用户）
#
# 二进制来源（D-002）:
#   GitHub Release 自 1.37.x 起不再附二进制；官方 Docker 镜像默认 tag 的
#   二进制是 glibc 动态链接（GLIBC_2.39 > TOS7 的 2.35，不可用）；
#   <tag>-alpine 镜像内为 static-pie musl 全静态二进制，随包还带配套
#   web-vault。fetch 阶段经 Docker Registry API 拉取，层 digest 即官方
#   sha256，天然完成校验与内容固定。
#
# 产物（out/）:
#   vaultwarden_<版本>_<arch>.deb       完整版本名 deb（本地安装/测试用）
#   vaultwarden_<platform>.deb          Release 资产名 deb（上架上传用）
#   vaultwarden_<platform>.deb.sha256   上架要求的校验文件
#
# 阶段: fetch → stage → verify → deb
# ============================================================
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=config.env
. "$SCRIPT_DIR/config.env"

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

IMAGE_TAG="${VAULTWARDEN_VERSION}${IMAGE_TAG_VARIANT}"
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

  # 1. 官方 alpine 镜像中的静态二进制 + 配套 web-vault（Registry API 直拉）
  log "拉取 $IMAGE_REPO:$IMAGE_TAG ($TARGET_ARCH)"
  python3 "$SCRIPT_DIR/scripts/fetch_image.py" \
    --repo "$IMAGE_REPO" --tag "$IMAGE_TAG" --arch "$TARGET_ARCH" \
    --destdir "$DL_DIR"

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

  # 3. web vault 版本记录（changelog/文档用；与二进制同镜像层，天然配套）
  python3 - "$DL_DIR/web-vault-layer.tgz" "$DL_DIR/web-vault-version.txt" <<'PYEOF'
import sys, json, tarfile
tf = tarfile.open(sys.argv[1], "r:gz")
v = json.load(tf.extractfile("web-vault/version.json"))["version"]
open(sys.argv[2], "w").write(v + "\n")
PYEOF
  log "web vault 版本: $(cat "$DL_DIR/web-vault-version.txt")"
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
  mkdir -p "$STAGE_DIR/usr/share/doc/$APP_ID"

  # 二进制（官方 alpine 镜像内的 static-pie musl 静态二进制；规范要求放 bin/）
  log "  + bin/vaultwarden（上游 $VAULTWARDEN_VERSION，静态）"
  install -m 0755 "$DL_DIR/vaultwarden" "$APP/bin/vaultwarden"

  # web vault 静态文件（与二进制同镜像层，版本天然配套）
  # 注意：层 tar 为 macOS 端 Python tarfile 处理（无 AppleDouble 污染路径），
  # 但仍显式剔除 ._* / .DS_Store 并规整权限
  log "  + web-vault/（上游 web vault $WEBVAULT_VERSION）"
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
  # 直开端口模式：path 为完整 URL（hermes 先例），TOS 以 ${ip} 渲染 NAS 地址
  log "  + config.ini（External Open: open_path=true, path=http://\${ip}:$APP_PORT）"
  sed -e "s|@@VERSION@@|$VERSION_FULL|g" \
      -e "s|@@PUBLISHER@@|$PUBLISHER|g" \
      -e "s|@@PLATFORM@@|$TOS_PLATFORM|g" \
      -e "s|@@APP_PORT@@|$APP_PORT|g" \
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

  # nginx 路由：app 目录内 nginx/ 满足 TOS 规范（External Open 应用必带）；
  # 内容为 /vaultwarden/ → :$APP_PORT 的 302 兜底跳转（见文件头注释）；
  # 同时以 dpkg 实体文件放 /etc/nginx/conf.d（双落盘模式，postinst 校验自愈）
  log "  + nginx/ + /etc/nginx/conf.d/（302 兜底跳转到 :$APP_PORT）"
  mkdir -p "$STAGE_DIR/etc/nginx/conf.d"
  sed -e "s|@@APP_PORT@@|$APP_PORT|g" \
      "$ASSETS_DIR/nginx/$APP_ID.conf" > "$APP/nginx/$APP_ID.conf"
  cp "$APP/nginx/$APP_ID.conf" "$STAGE_DIR/etc/nginx/conf.d/$APP_ID.conf"

  # systemd 服务：init.d/ 满足 TOS 规范；同时以 dpkg 实体文件放
  # /etc/systemd/system（双落盘模式，systemd 直接加载，不依赖 postinst 拷贝）
  log "  + init.d/ + /etc/systemd/system/"
  mkdir -p "$STAGE_DIR/etc/systemd/system"
  cp "$ASSETS_DIR/init.d/$APP_ID.service" "$APP/init.d/$APP_ID.service"
  cp "$ASSETS_DIR/init.d/$APP_ID.service" "$STAGE_DIR/etc/systemd/system/$APP_ID.service"

  # webui.bz2（WebUI 类应用必填；解压须含可打开的 .html。
  # 直开端口模式下为规范要求的跳转占位页：按当前访问主机的 hostname
  # 拼出 http://<主机>:8222/ 再跳转）
  log "  + webui.bz2（占位跳转页 → :$APP_PORT）"
  local WEBUI_DIR="$BUILD_DIR/webui"
  rm -rf "$WEBUI_DIR"
  mkdir -p "$WEBUI_DIR"
  sed -e "s|@@VERSION@@|$VERSION_FULL|g" \
      -e "s|@@APP_PORT@@|$APP_PORT|g" \
      "$ASSETS_DIR/webui/index.html" > "$WEBUI_DIR/index.html"
  export COPYFILE_DISABLE=1
  find "$WEBUI_DIR" -name '._*' -delete 2>/dev/null || true
  ( cd "$WEBUI_DIR" && COPYFILE_DISABLE=1 tar -cjf "$APP/webui.bz2" index.html )

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
    echo "(version $WEBVAULT_VERSION, extracted from the official"
    echo "vaultwarden/server alpine image, (c) Bitwarden Inc.,"
    echo "https://github.com/bitwarden/clients — AGPL-3.0)."
    echo ""
    tail -n +3 "$DL_DIR/LICENSE"
  } > "$STAGE_DIR/usr/share/doc/$APP_ID/copyright"
  {
    echo "$APP_ID ($VERSION_FULL) TOS7; urgency=medium"
    echo ""
    echo "  * 基于 Vaultwarden 上游 $VAULTWARDEN_VERSION 打包（官方 alpine 镜像"
    echo "    static-pie musl 二进制，零运行时依赖，层 digest 校验）"
    echo "  * 随包 web vault $WEBVAULT_VERSION（与二进制同源配套）"
    echo "  * WebUI External Open：新标签页直开 http://<NAS-IP>:$APP_PORT/"
    echo "    （Vaultwarden API 固定根路径挂载，不支持子路径反代）"
    echo "  * 管理后台 /admin，安装时自动生成 ADMIN_TOKEN"
    echo ""
    echo " -- $MAINTAINER_FULL  $(date -R 2>/dev/null || date '+%a, %d %b %Y %H:%M:%S %z')"
  } > "$STAGE_DIR/usr/share/doc/$APP_ID/changelog.Debian"

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
# 阶段: verify —— 目标架构与规范关键项校验
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
           "$APP/$APP_ID.env.example" \
           "$STAGE_DIR/usr/share/doc/$APP_ID/copyright"; do
    [ -e "$p" ] || { warn "缺失: ${p#$STAGE_DIR/}"; fail=1; }
  done

  log "校验 config.ini（JSON 合法性 / 互斥字段 / 版本一致性）..."
  python3 - "$APP/config.ini" "$VERSION_FULL" "$TOS_PLATFORM" "$APP_ID" "$APP_USER" "$APP_PORT" <<'PYEOF' || fail=1
import json, sys
cfg_path, want_ver, want_plat, app_id, app_user, app_port = sys.argv[1:7]
cfg = json.load(open(cfg_path))
errs = []
if cfg.get("id") != app_id: errs.append(f"id != {app_id}")
if cfg.get("version") != want_ver: errs.append(f"version != {want_ver}")
if cfg.get("system_id") != app_id: errs.append("system_id 不一致")
if cfg.get("package") != app_id: errs.append("package 不一致")
if cfg.get("platform") != want_plat: errs.append(f"platform != {want_plat}")
# WebUI External Open: open_path=true 且不得出现 type；
# 直开端口模式：path 为 http://${ip}:<port>（hermes 先例）
if cfg.get("open_path") is not True: errs.append("open_path 必须为 true")
if "type" in cfg: errs.append("不得包含 type 字段（与 open_path 互斥）")
if cfg.get("path") != f"http://${{ip}}:{app_port}": errs.append(f"path 必须为 http://${{ip}}:{app_port}")
if cfg.get("user") != app_user: errs.append(f"user 应为 {app_user}")
if cfg.get("recommend") is not False: errs.append("recommend 提交时必须为 false")
for e in errs:
    print(f"    校验失败: {e}", file=sys.stderr)
sys.exit(1 if errs else 0)
PYEOF

  log "校验 .lang（23 语超集，覆盖两个官方口径）..."
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

  log "校验 systemd 服务（禁 Restart/必配 StartLimit/禁 ExecStart 变量展开）..."
  local svc
  for svc in "$APP/init.d/"*.service \
             "$STAGE_DIR/etc/systemd/system/"*.service; do
    grep -q '^\[Unit\]' "$svc" || { warn "非 systemd unit: $svc"; fail=1; }
    grep -Eq '^Restart' "$svc" && { warn "规范禁止配置 Restart: $svc"; fail=1; }
    grep -Eq '^ExecStart=.*\$' "$svc" && { warn "ExecStart 禁用变量展开（曾致全环境 502）: $svc"; fail=1; }
    grep -q '^StartLimitBurst=' "$svc" || { warn "缺少 StartLimitBurst: $svc"; fail=1; }
    grep -q '^StartLimitIntervalSec=' "$svc" || { warn "缺少 StartLimitIntervalSec: $svc"; fail=1; }
    grep -q "^User=$APP_USER" "$svc" || { warn "必须 User=$APP_USER: $svc"; fail=1; }
  done

  log "校验监听默认值写死在 unit（0.0.0.0:$APP_PORT，env 可覆盖）..."
  grep -q '^Environment=ROCKET_ADDRESS=0\.0\.0\.0' "$APP/init.d/$APP_ID.service" \
    || { warn "unit 必须内置 Environment=ROCKET_ADDRESS=0.0.0.0"; fail=1; }
  grep -q "^Environment=ROCKET_PORT=$APP_PORT\$" "$APP/init.d/$APP_ID.service" \
    || { warn "unit 必须内置 Environment=ROCKET_PORT=$APP_PORT"; fail=1; }
  grep -q '^Environment=DATA_FOLDER=/var/lib/vaultwarden' "$APP/init.d/$APP_ID.service" \
    || { warn "unit 必须内置 Environment=DATA_FOLDER"; fail=1; }

  log "校验 nginx 兜底跳转（302 → :$APP_PORT，不反代）..."
  grep -q "return 302 http://\$host:$APP_PORT" "$APP/nginx/$APP_ID.conf" \
    || { warn "nginx conf 必须为 302 跳转到 :$APP_PORT"; fail=1; }

  log "校验 webui.bz2（解压含 .html）..."
  tar tjf "$APP/webui.bz2" | grep -q '\.html$' || { warn "webui.bz2 缺少 html"; fail=1; }
  if tar tjf "$APP/webui.bz2" | grep -qE '(^|/)\._'; then
    warn "webui.bz2 含 AppleDouble ._ 垃圾条目（macOS 污染）"
    fail=1
  fi

  log "校验 ELF 架构（目标: $ELF_ARCH；必须为静态链接）..."
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
    warn "二进制是动态链接（官方默认镜像的 glibc 版本混入？TOS 不可用）: $bin_out"
    fail=1
  else
    log "  ok: 静态链接"
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
目标架构       : $TARGET_ARCH (TOS:$TOS_PLATFORM)
TOS app id     : $APP_ID（新标签页直开 http://<IP>:$APP_PORT）
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
