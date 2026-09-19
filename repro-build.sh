#!/usr/bin/env bash
# ============================================================
# repro-build.sh — 按"上游 Dockerfile.alpine 逐字一致"的配方本地复现二进制
# 用法: ./repro-build.sh [x86_64|aarch64] [上游版本]
# 前提: 本机有 docker
#
# 说明: Rust 构建不保证跨机构逐位一致（路径/时间戳可能嵌入），
#       权威值以 Release SHA256SUMS + config.env 钉死为准（见 VERIFICATION.md）。
# ============================================================
set -euo pipefail

ARCH="${1:-x86_64}"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# 版本来源：config.env（与 CI/fetch 同一配置源）
. "$SCRIPT_DIR/config.env"
VW_VERSION="${2:-$VAULTWARDEN_VERSION}"

case "$ARCH" in
  x86_64|aarch64) ;;
  *) echo "用法: $0 [x86_64|aarch64]" >&2; exit 1 ;;
esac

RUST_VER="1.98.1"
IMAGE="ghcr.io/blackdex/rust-musl:${ARCH}-musl-stable-${RUST_VER}"

echo "==> 复现构建 vaultwarden ${VW_VERSION}（${ARCH}，上游 Dockerfile.alpine 同配方）"
docker run --rm \
  -e VW_VERSION="$VW_VERSION" \
  -e PQ_LIB_DIR=/usr/local/musl/pq17/lib \
  "$IMAGE" bash -euxc '
    cd /tmp
    curl -fsSL --retry 5 \
      "https://github.com/dani-garcia/vaultwarden/archive/refs/tags/${VW_VERSION}.tar.gz" \
      -o src.tar.gz
    tar -xzf src.tar.gz
    cd "vaultwarden-${VW_VERSION}"
    cargo build \
      --features sqlite,mysql,postgresql,enable_mimalloc \
      --profile release \
      --target "${CARGO_BUILD_TARGET}"
    file "target/${CARGO_BUILD_TARGET}/release/vaultwarden"
    sha256sum "target/${CARGO_BUILD_TARGET}/release/vaultwarden"
  '

echo "==> 对比: 上面输出的 sha256 应与 Release SHA256SUMS / config.env 钉死值一致"
