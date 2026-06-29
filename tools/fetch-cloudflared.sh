#!/usr/bin/env bash
#
# Fetch the bundled cloudflared binary from an upstream Cloudflare release,
# verifying it against a pinned SHA-256 before it lands in the tree.
#
# Replaces the 37 MB binary that used to be committed to git (issue #16):
# the binary is now downloaded + checksum-verified at build time, so the
# repo stays small and the supply chain is auditable (the checksums below
# pin the exact, Developer-ID-signed Cloudflare release).
#
# Wired into the QuipMac build as a pre-build script (see QuipMac/project.yml).
# Safe to run by hand too: `tools/fetch-cloudflared.sh`.
set -euo pipefail

VERSION="2026.3.0"

# SHA-256 of the official cloudflared-darwin-<arch>.tgz release assets, verified
# against https://github.com/cloudflare/cloudflared/releases/tag/${VERSION}.
# Bump VERSION and both hashes together when updating cloudflared.
SHA256_ARM64="2aae4f69b0fc1c671b8353b4f594cbd902cd1e360c8eed2b8cad4602cb1546fb"
SHA256_AMD64="0f30140c4a5e213d22f951ef4c964cac5fb6a5f061ba6eba5ea932999f7c0394"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST_DIR="${REPO_ROOT}/QuipMac/Resources"
DEST="${DEST_DIR}/cloudflared"

case "$(uname -m)" in
  arm64)  ARCH="arm64"; SHA256="${SHA256_ARM64}" ;;
  x86_64) ARCH="amd64"; SHA256="${SHA256_AMD64}" ;;
  *) echo "fetch-cloudflared: unsupported arch $(uname -m)" >&2; exit 1 ;;
esac

# Idempotent: skip if the pinned version is already in place.
if [ -x "${DEST}" ] && "${DEST}" --version 2>/dev/null | grep -q "version ${VERSION} "; then
  echo "cloudflared ${VERSION} (${ARCH}) already present — skipping fetch"
  exit 0
fi

URL="https://github.com/cloudflare/cloudflared/releases/download/${VERSION}/cloudflared-darwin-${ARCH}.tgz"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

echo "Fetching cloudflared ${VERSION} (${ARCH}) ..."
curl -fL --retry 3 "${URL}" -o "${tmp}/cf.tgz"

echo "${SHA256}  ${tmp}/cf.tgz" | shasum -a 256 -c -

tar xzf "${tmp}/cf.tgz" -C "${tmp}"
mkdir -p "${DEST_DIR}"
mv -f "${tmp}/cloudflared" "${DEST}"
chmod +x "${DEST}"

echo "Installed verified cloudflared ${VERSION} (${ARCH}) -> ${DEST}"
