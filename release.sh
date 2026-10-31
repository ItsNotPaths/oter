#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_NAME="oter"

usage() {
    cat <<EOF2
usage: $(basename "$0") [--local [--tarball]] [--public --version vX.Y.Z [--notes "text"]]

  --local               release build into build/ (gitignored), stripped
  --tarball             with --local: pack it into dist/ as the asset a release ships
  --public              trigger the release.yml workflow via gh CLI
  --version <tag>       the tag; required with --public
  --notes <text>        optional release notes
EOF2
}

DO_LOCAL=0
DO_PUBLIC=0
DO_TARBALL=0
VERSION=""
NOTES=""

while [ $# -gt 0 ]; do
    case "$1" in
        --local)   DO_LOCAL=1; shift ;;
        --tarball) DO_TARBALL=1; shift ;;
        --public)  DO_PUBLIC=1; shift ;;
        --version) VERSION="${2:?--version needs a value}"; shift 2 ;;
        --notes)   NOTES="${2:?--notes needs a value}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown flag: $1" >&2; usage; exit 1 ;;
    esac
done

if [ $DO_LOCAL -eq 0 ] && [ $DO_PUBLIC -eq 0 ]; then
    usage
    exit 1
fi

if [ $DO_LOCAL -eq 1 ]; then
    echo "==> Local build: $BIN_NAME -> $PROJECT_DIR/build"
    "$PROJECT_DIR/build.sh" release
    strip --strip-all "$PROJECT_DIR/build/$BIN_NAME" # release.yml ships this, so local matches
    echo "==> Local done"
fi

# One archive holding the bare binary; the desktop entry and icon are #load-ed into it.
if [ $DO_TARBALL -eq 1 ]; then
    if [ $DO_LOCAL -eq 0 ]; then
        echo "error: --tarball needs --local" >&2
        exit 1
    fi
    DIST_DIR="$PROJECT_DIR/dist"
    TARBALL="$DIST_DIR/${BIN_NAME}-$(uname -m)-linux.tar.gz"
    echo "==> Tarball: $TARBALL"
    mkdir -p "$DIST_DIR"
    rm -f "$DIST_DIR"/*.tar.gz
    tar -czf "$TARBALL" -C "$PROJECT_DIR/build" "$BIN_NAME"
    cp "$PROJECT_DIR/install.sh" "$DIST_DIR/install.sh"
    echo "==> Tarball done: $(du -h "$TARBALL" | cut -f1)"
fi

if [ $DO_PUBLIC -eq 1 ]; then
    if [ -z "$VERSION" ]; then
        echo "error: --public requires --version <tag>" >&2
        exit 1
    fi
    if ! command -v gh >/dev/null 2>&1; then
        echo "error: gh CLI not found; install it and run 'gh auth login'" >&2
        exit 1
    fi
    REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || true)
    if [ -z "$REPO" ]; then
        echo "error: not in a github repo (or gh not authenticated)" >&2
        exit 1
    fi
    WORKFLOW="release.yml"
    echo "==> Triggering $WORKFLOW on $REPO ($VERSION)"
    OLD_ID=$(gh run list --workflow="$WORKFLOW" --limit 1 --json databaseId -q '.[0].databaseId' 2>/dev/null || echo "")
    gh workflow run "$WORKFLOW" \
        --field version="$VERSION" \
        --field notes="$NOTES"
    echo "==> Waiting for run to register..."
    NEW_ID=""
    for _ in $(seq 1 30); do
        sleep 2
        CUR_ID=$(gh run list --workflow="$WORKFLOW" --limit 1 --json databaseId -q '.[0].databaseId' 2>/dev/null || echo "")
        if [ -n "$CUR_ID" ] && [ "$CUR_ID" != "$OLD_ID" ]; then
            NEW_ID="$CUR_ID"
            break
        fi
    done
    if [ -z "$NEW_ID" ]; then
        echo "error: failed to detect new workflow run" >&2
        exit 1
    fi
    echo "==> Watching run $NEW_ID"
    gh run watch "$NEW_ID" --exit-status
fi
