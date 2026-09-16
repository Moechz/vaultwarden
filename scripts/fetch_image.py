#!/usr/bin/env python3
"""fetch_image.py — 从 Docker Registry 拉取 Vaultwarden 官方镜像内容（免 docker 依赖）

上游自 1.37.x 起不再在 GitHub Release 附二进制，官方二进制只随 Docker 镜像分发：
  vaultwarden/server:<tag>          → Debian trixie glibc 动态链接（GLIBC_2.39，TOS7 不可用）
  vaultwarden/server:<tag>-alpine   → static-pie musl 全静态二进制 + 配套 web-vault ← 本脚本取这个

流程（全部走 Docker Registry HTTP API v2，匿名 token）：
  1. auth.docker.io 取匿名 pull token
  2. 拉 <tag> 的 OCI index，选 linux/<arch> manifest（记录 digest 实现内容固定）
  3. 下载各层 blob，边下边按 digest 做 sha256 校验（digest 即官方哈希，无需另找 checksums）
  4. 从中提取 /vaultwarden 二进制与 /web-vault 层（层 tar 原样保存，stage 阶段再展开）
  5. 写 image-lock.json（tag/arch/digests），同参数重跑时命中缓存直接复用

用法:
  python3 scripts/fetch_image.py --tag 1.37.3-alpine --arch amd64 --destdir build/downloads
"""
import argparse
import hashlib
import io
import json
import ssl
import sys
import tarfile
import urllib.error
import urllib.request

REGISTRY = "https://registry-1.docker.io"
AUTH = "https://auth.docker.io/token"
ACCEPT = ", ".join([
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.docker.distribution.manifest.v2+json",
])

ARCH_MAP = {"amd64": "x86-64", "arm64": "ARM aarch64"}


def log(msg):
    print(f"    {msg}")


def http_json(url, token=None):
    req = urllib.request.Request(url)
    if token:
        req.add_header("Authorization", "Bearer " + token)
    req.add_header("Accept", ACCEPT)
    with urllib.request.urlopen(req, timeout=120,
                                context=ssl.create_default_context()) as r:
        return json.loads(r.read())


def fetch_blob(repo, digest, token, dest, expect_min=0, attempts=3):
    """下载 blob 到 dest，流式校验 sha256 必须等于 digest（官方内容哈希）；带重试"""
    import os
    import time
    url = f"{REGISTRY}/v2/{repo}/blobs/{digest}"
    want = digest.split(":", 1)[1]
    last_err = None
    for attempt in range(1, attempts + 1):
        try:
            req = urllib.request.Request(url, headers={"Authorization": "Bearer " + token})
            h = hashlib.sha256()
            total = 0
            with urllib.request.urlopen(req, timeout=600,
                                        context=ssl.create_default_context()) as r, open(dest + ".part", "wb") as f:
                while True:
                    chunk = r.read(1 << 20)
                    if not chunk:
                        break
                    f.write(chunk)
                    h.update(chunk)
                    total += len(chunk)
            if h.hexdigest() != want:
                raise RuntimeError(f"sha256 不匹配: want={want} got={h.hexdigest()}")
            if expect_min and total < expect_min:
                raise RuntimeError(f"层体积异常偏小: {total}B < {expect_min}B")
            os.replace(dest + ".part", dest)
            return total
        except Exception as e:  # noqa: BLE001
            last_err = e
            try:
                os.remove(dest + ".part")
            except OSError:
                pass
            if attempt < attempts:
                log(f"下载失败（第 {attempt} 次）：{e}，10 秒后重试")
                time.sleep(10)
    raise SystemExit(f"blob 下载失败: {digest}（{last_err}）")


def top_levels(tf):
    tops = set()
    for n in tf.getnames():
        n = n.lstrip("./")
        if n:
            tops.add(n.split("/")[0])
    return tops


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default="vaultwarden/server")
    ap.add_argument("--tag", required=True, help="如 1.37.3-alpine")
    ap.add_argument("--arch", required=True, choices=["amd64", "arm64"])
    ap.add_argument("--destdir", required=True)
    args = ap.parse_args()

    import os
    os.makedirs(args.destdir, exist_ok=True)
    lock_path = os.path.join(args.destdir, "image-lock.json")
    bin_path = os.path.join(args.destdir, "vaultwarden")
    wv_path = os.path.join(args.destdir, "web-vault-layer.tgz")

    want = {"repo": args.repo, "tag": args.tag, "arch": args.arch}
    if os.path.exists(lock_path) and os.path.exists(bin_path) and os.path.exists(wv_path):
        try:
            if json.load(open(lock_path))["request"] == want:
                log(f"已缓存: {args.repo}:{args.tag} ({args.arch})（image-lock.json 匹配）")
                return 0
        except Exception:
            pass

    print(f"==> 拉取 {args.repo}:{args.tag} ({args.arch})")
    token = http_json(
        f"{AUTH}?service=registry.docker.io&scope=repository:{args.repo}:pull")["token"]

    index = http_json(f"{REGISTRY}/v2/{args.repo}/manifests/{args.tag}", token)
    if "manifests" not in index:
        raise SystemExit("不是 multi-arch index")
    m = [x for x in index["manifests"]
         if x.get("platform", {}).get("architecture") == args.arch
         and x.get("platform", {}).get("os") == "linux"]
    if not m:
        raise SystemExit(f"镜像无 linux/{args.arch} 变体")
    m = m[0]
    log(f"manifest digest: {m['digest']}")
    manifest = http_json(f"{REGISTRY}/v2/{args.repo}/manifests/{m['digest']}", token)

    bin_layer = wv_layer = None
    for layer in manifest["layers"]:
        tmp = os.path.join(args.destdir, f".layer-{layer['digest'].split(':')[1][:12]}.tmp")
        try:
            size = fetch_blob(args.repo, layer["digest"], token, tmp)
            try:
                tf = tarfile.open(tmp, "r:gz")
                tops = top_levels(tf)
            except tarfile.ReadError:
                continue  # 配置/脚本层，非目标内容
            if tops == {"web-vault"}:
                wv_layer = layer
                os.replace(tmp, wv_path)
                log(f"web-vault 层: {layer['digest'][:24]}… ({size/1e6:.1f}MB 压缩)")
            elif tops == {"vaultwarden"}:
                bin_layer = layer
                member = tf.getmember("vaultwarden")
                with open(bin_path, "wb") as f:
                    f.write(tf.extractfile(member).read())
                os.chmod(bin_path, 0o755)
                log(f"二进制层: {layer['digest'][:24]}… ({member.size/1e6:.1f}MB 解压后)")
        finally:
            if os.path.exists(tmp):
                try:
                    os.remove(tmp)
                except OSError:
                    pass
    if not (bin_layer and wv_layer):
        raise SystemExit("镜像层中未找到 /vaultwarden 与 /web-vault（上游布局变化？）")

    # 二进制与 web-vault 版本自检（与请求 tag 一致性提示用）
    tf = tarfile.open(wv_path, mode="r:gz")
    try:
        vj = json.load(tf.extractfile("web-vault/version.json"))
        log(f"web vault 版本: {vj.get('version')}")
        webvault_version = vj.get("version")
    except Exception:
        webvault_version = None

    lock = {
        "request": want,
        "manifest_digest": m["digest"],
        "binary_layer": bin_layer["digest"],
        "webvault_layer": wv_layer["digest"],
        "webvault_version": webvault_version,
    }
    json.dump(lock, open(lock_path, "w"), indent=2)
    print(f"==> 完成（内容哈希已按镜像 digest 固定，重跑可复现）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
