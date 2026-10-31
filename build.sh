#!/usr/bin/env bash
# ./build.sh          debug build into build/oter
# ./build.sh release  optimised build into build/oter
# ./build.sh test     run tests/
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$DIR/build"
FLAGS=(-collection:oket="$DIR/vendor/oket/src" -extra-linker-flags:"-L$DIR/vendor/sdl3")

cargo build -q --release --manifest-path "$DIR/hz/Cargo.toml" # libhz.a: hatchzip's listing

case "${1:-debug}" in
    debug)   odin build "$DIR/src/oter" -out:"$DIR/build/oter" -debug "${FLAGS[@]}" ;;
    release) odin build "$DIR/src/oter" -out:"$DIR/build/oter" -o:speed -collection:oket="$DIR/vendor/oket/src" -extra-linker-flags:"-L$DIR/vendor/sdl3 -Wl,--gc-sections" ;;
    test)    odin test "$DIR/tests" -collection:oter="$DIR/src" "${FLAGS[@]}" ;;
    *)       echo "usage: $0 [debug|release|test]" >&2; exit 2 ;;
esac
