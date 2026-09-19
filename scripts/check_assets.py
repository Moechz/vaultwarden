#!/usr/bin/env python3
"""check_assets.py — 上架前的资产静态自检（Makefile check 调用，无需网络）

按 TOS 7 应用中心规范 + 商店审核驳回实录门禁校验：
  1. assets/config.ini.in 是合法 JSON（渲染 @@VERSION@@ 等占位符后），
     path 必须为 /<appid>/ 路由格式（C21：直连 URL 必被驳回）
  2. assets/vaultwarden.lang 含全部 23 个语言节、无 beta 字样（V11）、
     各语 auth 与 config.env PUBLISHER 一致（坑 49：上游署名）
  3. assets/ 下所有文本资产无 CRLF / BOM
  4. 隐私政策资产齐备（C3：双语、数据路径说明）
  5. nginx 路由为保留前缀反代回环 + WS 头 + 隐私政策精确路由（坑 38/45）
  6. systemd unit 回环监听（坑 38：0.0.0.0 裸奔一票否决）
  7. 图标 SVG 完整性（坑 47：XML 可解析 / viewBox / 主 path / 显式 fill）
"""
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
fail = 0

REQUIRED_LANGS = [
    # 真机实测必需 14 语
    "zh-cn", "zh-hk", "en-us", "fr-fr", "de-de", "it-it", "es-es",
    "hu-hu", "ja-jp", "ko-kr", "pl-pl", "ru-ru", "tr-tr", "pt-pt",
    # 官方英文文档口径 9 语（超集覆盖）
    "ar-sa", "cs-cz", "he-il", "id-id", "nb-no", "nl-nl", "sv-se",
    "th-th", "vi-vn",
]


def err(msg):
    global fail
    print(msg)
    fail = 1


# config.env 读取（publisher 一致性）
def env_value(key):
    for line in (ROOT / "config.env").read_text(encoding="utf-8").splitlines():
        m = re.match(rf'^{key}=(.*)$', line)
        if m and not line.startswith("#"):
            return m.group(1).strip().strip('"')
    return None


APP_ID = env_value("APP_ID") or "vaultwarden"

# ---------- 1. config.ini.in ----------
raw = (ROOT / "assets/config.ini.in").read_text(encoding="utf-8")
rendered = (raw.replace("@@VERSION@@", "0.0.0")
              .replace("@@PUBLISHER@@", "x")
              .replace("@@PLATFORM@@", "x86_64")
              .replace("@@REPO_URL@@", "https://github.com/x/y"))
try:
    cfg = json.loads(rendered)
    print("config.ini.in: JSON 合法 ✓")
except Exception as e:  # noqa: BLE001
    err(f"config.ini.in: JSON 非法 ✗ ({e})")
    cfg = {}
if cfg:
    path = cfg.get("path", "")
    if not re.fullmatch(r"/[a-z0-9_-]+/", path):
        err(f"config.ini.in: path 必须为 /<appid>/ 路由（当前 {path!r}，C21） ✗")
    elif path != f"/{APP_ID}/":
        err(f"config.ini.in: path 应为 /{APP_ID}/ ✗")
    else:
        print("config.ini.in: path 路由格式 ✓")
    if not re.fullmatch(r"https://\S+", cfg.get("official", "")):
        err("config.ini.in: official 必须为 https URL（30a 机器验链） ✗")
    if cfg.get("beta") is not False:
        err("config.ini.in: beta 必须为 false（V11） ✗")

# ---------- 2. lang ----------
lang_path = ROOT / "assets/vaultwarden.lang"
data = lang_path.read_bytes()
if data.startswith(b"\xef\xbb\xbf"):
    err("lang: 含 BOM ✗")
text = data.decode("utf-8")
found = re.findall(r"^\[([a-z]{2}-[a-z]{2})\]$", text, re.M)
missing = [t for t in REQUIRED_LANGS if t not in found]
if missing:
    err(f"lang: 缺少语言节 ✗ {missing}")
else:
    print(f"lang: {len(REQUIRED_LANGS)} 语言齐全 ✓（共 {len(found)} 节）")
for key in ("name", "auth", "version", "descript", "release_note", "important"):
    if text.count(f"{key} ") < len(REQUIRED_LANGS):
        err(f"lang: 字段 {key} 未在所有语言节中出现 ✗")
if re.search(r'(^|[^a-zA-Z])beta([^a-zA-Z]|$)', text, re.I):
    err("lang: 文案含 beta 字样（V11 文案门禁） ✗")
else:
    print("lang: 无 beta 字样 ✓")
author = env_value("AUTHOR")
if author:
    n_auth = text.count(f'auth         = "{author}"')
    if n_auth == len(REQUIRED_LANGS):
        print(f"lang: 各语 auth 均为上游作者 {author!r} ✓")
    else:
        err(f"lang: auth 与 config.env AUTHOR 不一致（{n_auth}/{len(REQUIRED_LANGS)}） ✗")
# 直开端口表述残留（D-001 已废止）
if re.search(r':8222|0\.0\.0\.0', text):
    err("lang: 残留直开端口/0.0.0.0 表述（应统一为 /%s/ 路由） ✗" % APP_ID)

# ---------- 3. CRLF / BOM 扫描 ----------
text_fail = False
for p in sorted((ROOT / "assets").rglob("*")):
    if not p.is_file() or p.suffix not in {".ini", ".in", ".lang", ".conf",
                                           ".service", ".env", ".sh", ".html",
                                           ".js", ".css", ".svg"}:
        continue
    b = p.read_bytes()
    rel = p.relative_to(ROOT)
    if b.startswith(b"\xef\xbb\xbf"):
        err(f"{rel}: 含 BOM ✗")
        text_fail = True
    if b"\r\n" in b or b"\r" in b:
        err(f"{rel}: 含 CR ✗")
        text_fail = True
if not text_fail:
    print("行尾/BOM: 全部合规 ✓")

# ---------- 4. 隐私政策资产（C3） ----------
pp = ROOT / "assets/privacy/privacy-policy.html"
if not pp.is_file():
    err("assets/privacy/privacy-policy.html: 缺失（C3 必备资产） ✗")
else:
    html = pp.read_text(encoding="utf-8")
    if "Privacy Policy" not in html or "隐私政策" not in html:
        err("privacy-policy.html: 非双语 ✗")
    if "/var/lib/vaultwarden" not in html:
        err("privacy-policy.html: 未说明数据存放路径 ✗")
    else:
        print("privacy-policy.html: 双语 + 数据路径说明 ✓")

# ---------- 5. nginx 路由 ----------
nginx = (ROOT / f"assets/nginx/{APP_ID}.conf").read_text(encoding="utf-8")
port = env_value("APP_PORT") or "8222"
if f"proxy_pass http://127.0.0.1:{port}/{APP_ID}/" in nginx:
    print(f"nginx: 保留前缀反代回环 :{port} ✓")
else:
    err(f"nginx: 必须保留前缀反代到 127.0.0.1:{port}/{APP_ID}/ ✗")
if "proxy_set_header Upgrade" in nginx and "proxy_set_header Connection" in nginx:
    print("nginx: WebSocket 头齐备 ✓")
else:
    err("nginx: 缺 WebSocket 升级头 ✗")
if f"location = /{APP_ID}/privacy-policy.html" in nginx and "privacy/privacy-policy.html" in nginx:
    print("nginx: 隐私政策精确路由 ✓")
else:
    err("nginx: 缺隐私政策精确路由（C3） ✗")
if re.search(r"return 302 http", nginx):
    err("nginx: 残留直开端口 302 跳转（D-001 已废止） ✗")

# ---------- 6. systemd unit 回环监听 ----------
unit = (ROOT / f"assets/init.d/{APP_ID}.service").read_text(encoding="utf-8")
if re.search(r"^Environment=ROCKET_ADDRESS=127\.0\.0\.1$", unit, re.M):
    print("unit: 回环监听 ✓")
else:
    err("unit: 必须 Environment=ROCKET_ADDRESS=127.0.0.1（坑 38） ✗")
if re.search(r"^Environment=DOMAIN=\S*/" + APP_ID + r"$", unit, re.M):
    print("unit: DOMAIN 路径前缀与 nginx 路由联动 ✓")
else:
    err(f"unit: 缺 DOMAIN=/…/{APP_ID}（保留前缀模式必需） ✗")
if re.search(r"^ExecStart=.*\$", unit, re.M):
    err("unit: ExecStart 含变量展开（坑 1） ✗")

# ---------- 7. 图标 SVG 完整性（坑 47） ----------
svg_path = ROOT / f"assets/images/icons/{APP_ID}.svg"
try:
    root = ET.parse(svg_path).getroot()
except Exception as e:  # noqa: BLE001
    err(f"icon: SVG 解析失败 ✗ ({e})")
else:
    vb = root.get("viewBox", "")
    paths = [el for el in root.iter() if el.tag.endswith("path")]
    fills = {el.get("fill") for el in root.iter() if el.get("fill")}
    if len(vb.split()) == 4 and re.fullmatch(r"[0-9.\s-]+", vb):
        print(f"icon: viewBox={vb} ✓")
    else:
        err(f"icon: viewBox 缺失/畸形 ✗ ({vb!r})")
    if any(len(el.get("d", "")) > 50 for el in paths):
        print(f"icon: 主 path 有效 ✓（{len(paths)} 条）")
    else:
        err("icon: 缺少有效主 path ✗")
    if fills - {None, "none"}:
        print(f"icon: 显式 fill ✓ {sorted(fills)}")
    else:
        err("icon: 缺少显式 fill ✗")

sys.exit(fail)
