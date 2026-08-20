#!/bin/sh
# Resolve one FreeBSD package and unpack it into a rootfs, without FreeBSD.
#
# A .pkg is a zstd-compressed tar and pkg.freebsd.org publishes a plain index,
# so both steps are ordinary tar work. That is what lets the image be built on a
# stock Linux runner: no FreeBSD binary ever has to execute, which is also why
# the Containerfile has no RUN instruction.
#
#   ./fetch-pkg.sh <abi> <package> <rootfs-dir>
#   ./fetch-pkg.sh FreeBSD:15:amd64 oauth2-proxy build/amd64
#
# Only for packages with no dependencies: it fetches exactly what you name and
# does not resolve a graph. oauth2-proxy is a static Go binary with none, which
# is what keeps this honest — and it aborts if that ever stops being true rather
# than quietly shipping a broken image.
set -eu

ABI="${1:?usage: fetch-pkg.sh <abi> <package> <rootfs-dir>}"
PKGNAME="${2:?usage: fetch-pkg.sh <abi> <package> <rootfs-dir>}"
ROOTFS="${3:?usage: fetch-pkg.sh <abi> <package> <rootfs-dir>}"
BRANCH="${PKG_BRANCH:-latest}"
BASE="https://pkg.freebsd.org/${ABI}/${BRANCH}"
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

echo "==> index ${BASE}/packagesite.pkg"
curl -fsSL "${BASE}/packagesite.pkg" -o "$work/packagesite.pkg"
tar xf "$work/packagesite.pkg" -C "$work" packagesite.yaml

# The index is one JSON object per line, despite the .yaml name.
python3 "$HERE/pkgindex.py" find "$work/packagesite.yaml" "$PKGNAME" > "$work/found"

VERSION=$(sed -n 1p "$work/found")
REPOPATH=$(sed -n 2p "$work/found")
WANTSUM=$(sed -n 3p "$work/found")
echo "==> ${PKGNAME} ${VERSION} (${ABI})"

curl -fsSL "${BASE}/${REPOPATH}" -o "$work/pkg.pkg"
python3 "$HERE/pkgindex.py" verify "$work/pkg.pkg" "$WANTSUM"

mkdir -p "$ROOTFS"
# Everything except pkg's own metadata, which means nothing outside pkg.
tar xf "$work/pkg.pkg" -C "$ROOTFS" --exclude '+*'
printf '%s' "$VERSION" > "${ROOTFS}.version"
echo "==> unpacked into ${ROOTFS}"
