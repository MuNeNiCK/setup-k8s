#!/bin/sh

# Build the single-file release bundle and its sha256 checksum.
#
# Usage: scripts/build.sh [output_path] [version]
#   output_path  default: dist/setup-k8s.sh
#   version      default: $SETUP_K8S_VERSION, then `git describe`, then "dev"

set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/dist/setup-k8s.sh}"
VERSION="${2:-${SETUP_K8S_VERSION:-}}"
if [ -z "$VERSION" ]; then
    VERSION="$(git -C "$ROOT" describe --tags --always --dirty 2>/dev/null || echo dev)"
fi
case "$VERSION" in
    *"'"*) echo "Error: version must not contain a single quote" >&2; exit 1 ;;
esac

# shellcheck source=lib/bootstrap.sh
. "$ROOT/lib/bootstrap.sh"
# shellcheck source=lib/bundle.sh
. "$ROOT/lib/bundle.sh"

mkdir -p "$(dirname "$OUT")"
_generate_bundle_core "$OUT" "$ROOT" "$VERSION"

if ! sh -n "$OUT"; then
    echo "Error: generated bundle has syntax errors: $OUT" >&2
    exit 1
fi

(cd "$(dirname "$OUT")" && sha256sum "$(basename "$OUT")" > "$(basename "$OUT").sha256")
echo "Built $OUT (version $VERSION)"
