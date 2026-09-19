#!/usr/bin/env python3
# ============================================================
# fetch_release.py — 从本仓库 GitHub Release 拉取 CI 自建产物
# （V6 合规链：上游源码 tag → GitHub Actions 构建 → Release 资产）
#
# 资产布局（由 .github/workflows/release.yml 产出）:
#   vaultwarden-<plat>.tar.gz     内含单文件 vaultwarden（static musl）
#   web-vault-<ver>.tar.gz        bw_web_builds 官方发布原样再分发
#   SHA256SUMS                    上述资产 + 二进制本体的校验清单
#
# 双重校验:
#   1. Release 内 SHA256SUMS（产物完整性）
#   2. config.env 钉死值 VW_SHA256_* / WEB_VAULT_SHA256（来源固定性）
# ============================================================
import argparse
import fcntl
import hashlib
import json
import os
import sys
import tarfile
import time
import urllib.request

API = "https://api.github.com"


def log(msg):
    print(f"\033[1;32m==>\033[0m {msg}")


def die(msg):
    print(f"\033[1;31m错误:\033[0m {msg}", file=sys.stderr)
    sys.exit(1)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def http_get(url, dest=None, token=None, timeout=60):
    """GET（可下大文件）；返回 bytes 或写 dest。带 3 次退避重试。"""
    last = None
    for attempt in range(5):
        try:
            req = urllib.request.Request(url, headers={
                "User-Agent": "vaultwarden-tos-fetch",
                "Accept": "application/octet-stream",
            })
            if token:
                req.add_header("Authorization", f"Bearer {token}")
            with urllib.request.urlopen(req, timeout=timeout) as r:
                if dest is None:
                    return r.read()
                with open(dest + ".part", "wb") as f:
                    while True:
                        chunk = r.read(1 << 20)
                        if not chunk:
                            break
                        f.write(chunk)
                os.replace(dest + ".part", dest)
                return None
        except Exception as e:  # noqa: BLE001
            last = e
            wait = 2 ** attempt
            log(f"  网络重试（{e}），{wait}s 后重试")
            time.sleep(wait)
    die(f"下载失败: {url}（{last}）")


def release_assets(repo, tag, token=None):
    url = f"{API}/repos/{repo}/releases/tags/{tag}"
    req = urllib.request.Request(url, headers={
        "User-Agent": "vaultwarden-tos-fetch",
        "Accept": "application/vnd.github+json",
    })
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(req, timeout=30) as r:
        rel = json.load(r)
    return {a["name"]: a for a in rel.get("assets", [])}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True, help="如 Moechz/vaultwarden")
    ap.add_argument("--tag", required=True, help="如 v1.37.3-1")
    ap.add_argument("--arch", required=True, choices=["x86_64", "aarch64"])
    ap.add_argument("--webvault-version", required=True)
    ap.add_argument("--pin-binary", required=True, help="config.env 钉死的二进制 sha256")
    ap.add_argument("--pin-webvault", required=True, help="config.env 钉死的 web vault sha256")
    ap.add_argument("--destdir", required=True)
    args = ap.parse_args()

    os.makedirs(args.destdir, exist_ok=True)
    lock_path = os.path.join(args.destdir, ".fetch.lock")
    with open(lock_path, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)

    token = os.environ.get("GITHUB_TOKEN")

    names = {
        "bin": f"vaultwarden-{args.arch}.tar.gz",
        "wv": f"web-vault-{args.webvault-version}.tar.gz",
        "sums": "SHA256SUMS",
    }
    log(f"查询 Release {args.repo} {args.tag}")
    assets = release_assets(args.repo, args.tag, token)
    missing = [n for n in names.values() if n not in assets]
    if missing:
        die(f"Release 缺少资产: {missing}（现有: {list(assets)}；先跑 CI 并发布 Release）")

    dl = args.destdir
    for key, name in names.items():
        dest = os.path.join(dl, name)
        if os.path.exists(dest) and os.path.getsize(dest) > 0:
            log(f"  已缓存: {name}")
        else:
            log(f"  下载: {name}（{assets[name]['size'] / 1e6:.1f} MB）")
            http_get(assets[name]["url"], dest, token=token)

    # ---- 校验 1：Release 内 SHA256SUMS ----
    log("校验 Release SHA256SUMS")
    sums = {}
    for line in open(os.path.join(dl, names["sums"]), encoding="utf-8"):
        h, _, fname = line.strip().partition("  ")
        if h:
            sums[fname.strip()] = h
    for key in ("bin", "wv"):
        name = names[key]
        if name not in sums:
            die(f"SHA256SUMS 未覆盖 {name}")
        got = sha256_file(os.path.join(dl, name))
        if got != sums[name]:
            die(f"{name} sha256 与 SHA256SUMS 不符: {got} != {sums[name]}")

    # ---- 解包二进制 & 校验 2：config.env 钉死值 ----
    log("解包二进制 tar.gz")
    bin_path = os.path.join(dl, "vaultwarden")
    with tarfile.open(os.path.join(dl, names["bin"]), "r:gz") as tf:
        members = [m for m in tf.getmembers() if m.isfile()]
        cand = [m for m in members if m.name in ("vaultwarden", "./vaultwarden")
                or m.name.endswith("/vaultwarden")]
        if not cand:
            die(f"tar.gz 内未找到 vaultwarden 二进制: {[m.name for m in members]}")
        m = cand[0]
        with open(bin_path + ".out", "wb") as f:
            f.write(tf.extractfile(m).read())
    os.chmod(bin_path + ".out", 0o755)
    got_bin = sha256_file(bin_path + ".out")
    bin_pin_from_sums = sums.get("vaultwarden-" + args.arch + ".sha256")
    # SHA256SUMS 中二进制本体条目（无扩展名形式）
    for fname, h in sums.items():
        if fname in ("vaultwarden", f"vaultwarden-{args.arch}"):
            bin_pin_from_sums = h
    if bin_pin_from_sums and got_bin != bin_pin_from_sums:
        die(f"二进制 sha256 与 Release 清单不符: {got_bin} != {bin_pin_from_sums}")
    if got_bin != args.pin_binary:
        die(f"二进制 sha256 与 config.env 钉死值不符:\n  实际 {got_bin}\n  钉死 {args.pin_binary}\n"
            "（若刚出 CI，请把实际值回填 config.env 的 VW_SHA256_*）")
    os.replace(bin_path + ".out", bin_path)

    # ---- web vault tarball 钉死 + 版本核对 ----
    wv_got = sha256_file(os.path.join(dl, names["wv"]))
    if wv_got != args.pin_webvault:
        die(f"web vault sha256 与 config.env 钉死值不符:\n  实际 {wv_got}\n  钉死 {args.pin_webvault}")
    with tarfile.open(os.path.join(dl, names["wv"]), "r:gz") as tf:
        try:
            import io
            vj = json.load(tf.extractfile("web-vault/version.json"))
            if vj.get("version") != args.webvault_version:
                die(f"web vault 版本不符: {vj.get('version')} != {args.webvault_version}")
        except KeyError:
            die("web vault tar.gz 缺少 web-vault/version.json（资产不是 bw_web_builds 官方布局）")
    # 统一改名成 stage 期望的 web-vault-layer.tgz
    wv_layer = os.path.join(dl, "web-vault-layer.tgz")
    if os.path.abspath(os.path.join(dl, names["wv"])) != os.path.abspath(wv_layer):
        import shutil
        shutil.copyfile(os.path.join(dl, names["wv"]), wv_layer)

    log(f"完成: vaultwarden ({got_bin[:16]}…) + web-vault-{args.webvault_version}.tar.gz")


if __name__ == "__main__":
    main()
