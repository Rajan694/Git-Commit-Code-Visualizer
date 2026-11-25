#!/usr/bin/env bash
# Builds the extension and packages it as releases/<name>-<version>.vsix.
# The version comes from package.json; this script never changes it.
#
# Usage: ./scripts/package.sh [--pre-release] [--install]
#   --pre-release  Mark the package as a pre-release (VS Code Marketplace / Open VSX).
#   --install      Run "npm ci" first, even if node_modules already exists.
set -euo pipefail

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }
die() { echo "error: $*" >&2; exit 1; }

PRE_RELEASE=0
FORCE_INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --pre-release) PRE_RELEASE=1 ;;
    --install) FORCE_INSTALL=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $arg" ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

command -v node >/dev/null 2>&1 || die "node is not installed (https://nodejs.org)"
command -v npm >/dev/null 2>&1 || die "npm is not installed"

if [ "$FORCE_INSTALL" = 1 ] || [ ! -d node_modules ]; then
  echo "==> Installing dependencies (npm ci)"
  npm ci --no-audit --no-fund
fi

NAME="$(node -p "require('./package.json').name")"
VERSION="$(node -p "require('./package.json').version")"
OUT_DIR="releases"
VSIX="$OUT_DIR/$NAME-$VERSION.vsix"
mkdir -p "$OUT_DIR"
rm -f "$VSIX"

vsce_args=(package --out "$VSIX")
[ "$PRE_RELEASE" = 1 ] && vsce_args+=(--pre-release)

# "vsce package" runs the vscode:prepublish script: type-check, lint, production bundle.
echo "==> Packaging $NAME $VERSION$([ "$PRE_RELEASE" = 1 ] && echo ' (pre-release)')"
npx --no -- vsce "${vsce_args[@]}"

echo "==> Created $VSIX"
