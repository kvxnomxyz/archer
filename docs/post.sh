#!/bin/sh
# Archer launcher: downloads the newest release of post-live-iso.sh and runs it.
#   curl -fsSL https://kvxnomxyz.github.io/archer/post.sh | bash
#   wget -qO- https://kvxnomxyz.github.io/archer/post.sh | bash
# Pin a version: ARCHER_VERSION=v0.1.0
set -eu

REPO="${ARCHER_REPO:-kvxnomxyz/archer}"
ASSET="post-live-iso.sh"
VERSION="${ARCHER_VERSION:-latest}"
if [ "$VERSION" = latest ]; then
  URL="https://github.com/$REPO/releases/latest/download/$ASSET"
else
  URL="https://github.com/$REPO/releases/download/$VERSION/$ASSET"
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$URL" -o "$tmp"
elif command -v wget >/dev/null 2>&1; then
  wget -qO "$tmp" "$URL"
else
  echo "archer: need curl or wget" >&2; exit 1
fi
[ -s "$tmp" ] || { echo "archer: download failed ($URL)" >&2; exit 1; }

# Give the installer the terminal back (we may have been piped into sh)
if [ -r /dev/tty ] && : </dev/tty 2>/dev/null; then
  bash "$tmp" "$@" </dev/tty
else
  bash "$tmp" "$@"
fi
