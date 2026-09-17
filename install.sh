#!/usr/bin/env bash
#
# Clarity installer — downloads the right binary for your platform.
# Usage: curl -fsSL https://raw.githubusercontent.com/monkdim/Kyanos/main/install.sh | bash
#

set -euo pipefail

REPO="monkdim/Kyanos"
INSTALL_DIR="${CLARITY_INSTALL_DIR:-/usr/local/bin}"

# ── Detect platform ──────────────────────────────────────

OS="$(uname -s)"
ARCH="$(uname -m)"

case "$OS" in
  Darwin) PLATFORM="darwin" ;;
  Linux)  PLATFORM="linux"  ;;
  *)
    echo "Error: unsupported OS: $OS"
    echo "Clarity supports macOS and Linux."
    exit 1
    ;;
esac

case "$ARCH" in
  arm64|aarch64) ARCH_NAME="arm64" ;;
  x86_64|amd64)  ARCH_NAME="x64"   ;;
  *)
    echo "Error: unsupported architecture: $ARCH"
    echo "Clarity supports x64 and arm64."
    exit 1
    ;;
esac

TARGET="clarity-${PLATFORM}-${ARCH_NAME}"

# ── Get latest version ───────────────────────────────────

echo ""
echo "   +===================================+"
echo "   |         C L A R I T Y             |"
echo "   |   Simple code. Real power.        |"
echo "   +===================================+"
echo ""

echo "  Platform: ${PLATFORM} ${ARCH_NAME}"

# Fetch latest release tag
VERSION=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
  | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"//;s/".*//')

if [ -z "$VERSION" ]; then
  echo "  Error: could not determine latest version."
  exit 1
fi

echo "  Version:  ${VERSION}"

# ── Download ─────────────────────────────────────────────

URL="https://github.com/${REPO}/releases/download/${VERSION}/${TARGET}.tar.gz"
echo "  Downloading ${TARGET}.tar.gz..."

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

curl -fsSL "$URL" -o "${TMP_DIR}/${TARGET}.tar.gz"
tar xzf "${TMP_DIR}/${TARGET}.tar.gz" -C "$TMP_DIR"

# ── Install ──────────────────────────────────────────────

if [ -w "$INSTALL_DIR" ]; then
  cp "${TMP_DIR}/clarity" "${INSTALL_DIR}/clarity"
else
  echo "  Need sudo to install to ${INSTALL_DIR}..."
  sudo cp "${TMP_DIR}/clarity" "${INSTALL_DIR}/clarity"
fi

chmod +x "${INSTALL_DIR}/clarity"

echo ""
echo "  Clarity ${VERSION} installed to ${INSTALL_DIR}/clarity"
echo ""
echo "  Get started:"
echo "    clarity shell     Interactive terminal"
echo "    clarity repl      Basic REPL"
echo "    clarity help      All commands"
echo ""

# ── Check PATH ───────────────────────────────────────────

case ":$PATH:" in
  *":${INSTALL_DIR}:"*) ;;
  *)
    echo "  Add to your shell profile:"
    echo "    export PATH=\"${INSTALL_DIR}:\$PATH\""
    echo ""
    ;;
esac
