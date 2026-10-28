#!/usr/bin/env bash
# Fetches third-party deps into vendor/. Run once before building, and again after an OKET_REV bump.
set -euo pipefail

VENDOR="$(cd "$(dirname "$0")" && pwd)/vendor"
ODIN_ROOT="$(odin root)"
CC=${CC:-cc}
CXX=${CXX:-c++}

# Odin's stb bindings look for their archives inside the Odin tree, which may be root-owned.
odin_install() {
    local src="$1" dst="$2" dir
    dir="$(dirname "$dst")"
    if [ -w "$dir" ] || { [ ! -e "$dir" ] && [ -w "$(dirname "$dir")" ]; }; then
        mkdir -p "$dir"
        cp "$src" "$dst"
    else
        echo "  $dst is not writable; using sudo to install it"
        sudo mkdir -p "$dir"
        sudo cp "$src" "$dst"
    fi
}

echo "==> oket (gfx, font, cl, input, theme; built with -collection:oket=vendor/oket/src)"
OKET_REV="a8d0e8f678b8c2e64e0e2d6ebda4c53bd5f9e0be"
OKET_SRC="$VENDOR/oket"
if [ ! -d "$OKET_SRC/.git" ]; then
    rm -rf "$OKET_SRC"
    git clone -q "https://github.com/ItsNotPaths/oket.git" "$OKET_SRC"
fi
if [ "$(git -C "$OKET_SRC" rev-parse HEAD)" != "$OKET_REV" ]; then
    git -C "$OKET_SRC" fetch -q origin
    git -C "$OKET_SRC" checkout -q --detach "$OKET_REV"
fi
echo "  at $(git -C "$OKET_SRC" log --oneline -1)"

echo ""
echo "==> sdl3 (window, input, clipboard; static lib)"
SDL_VERSION="3.4.16"
SDL_SRC="$VENDOR/sdl3-src"
SDL_A="$VENDOR/sdl3/libSDL3.a"
if [ -f "$SDL_A" ]; then
    echo "  already present: libSDL3.a"
else
    if [ ! -d "$SDL_SRC" ] || [ -z "$(ls -A "$SDL_SRC" 2>/dev/null)" ]; then
        echo "  downloading sdl3 $SDL_VERSION source..."
        mkdir -p "$SDL_SRC"
        curl -fsSL "https://github.com/libsdl-org/SDL/releases/download/release-${SDL_VERSION}/SDL3-${SDL_VERSION}.tar.gz" \
            | tar xz --strip-components=1 -C "$SDL_SRC" \
            || { rm -rf "$SDL_SRC"; exit 1; }
    fi
    echo "  building static libSDL3.a..."
    rm -rf "$SDL_SRC/build"
    cmake -S "$SDL_SRC" -B "$SDL_SRC/build" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DSDL_SHARED=OFF -DSDL_STATIC=ON \
        -DSDL_AUDIO=OFF -DSDL_GPU=OFF -DSDL_RENDER=OFF -DSDL_CAMERA=OFF \
        -DSDL_JOYSTICK=OFF -DSDL_HAPTIC=OFF -DSDL_HIDAPI=OFF -DSDL_SENSOR=OFF \
        -DSDL_POWER=OFF -DSDL_DIALOG=OFF -DSDL_TRAY=OFF -DSDL_VULKAN=OFF \
        -DSDL_X11_XTEST=OFF -DSDL_TEST_LIBRARY=OFF \
        -DSDL_KMSDRM=OFF -DSDL_OFFSCREEN=OFF -DSDL_DUMMYVIDEO=OFF \
        -DCMAKE_C_FLAGS="-DSDL_LEAN_AND_MEAN=1 -ffunction-sections -fdata-sections" >/dev/null
    cmake --build "$SDL_SRC/build" --parallel >/dev/null
    mkdir -p "$(dirname "$SDL_A")"
    cp "$SDL_SRC/build/libSDL3.a" "$SDL_A"
    echo "  done."
fi

echo ""
echo "==> stb (font rasterizing, picture decoding; static libs)"
STB_SRC="${ODIN_ROOT%/}/vendor/stb/src"
STB_ODIN_LIB="${ODIN_ROOT%/}/vendor/stb/lib"
STB_OUT="$VENDOR/stb"
for name in stb_truetype stb_rect_pack stb_image; do
    if [ -f "$STB_ODIN_LIB/$name.a" ]; then
        echo "  already present: $name.a"
        continue
    fi
    echo "  building $name.a..."
    mkdir -p "$STB_OUT"
    (
        cd "$STB_OUT"
        $CC -c -Os -fPIC "$STB_SRC/$name.c" -o "$name.o"
        ar rcs "$name.a" "$name.o"
        rm -f "$name.o"
    )
    odin_install "$STB_OUT/$name.a" "$STB_ODIN_LIB/$name.a"
done

echo ""
echo "==> harfbuzz (oket's gfx links it from vendor/oket/vendor/harfbuzz; static lib)"
HB_VERSION="14.4.0"
HB_SRC="$OKET_SRC/vendor/harfbuzz"
HB_A="$HB_SRC/libharfbuzz.a"
if [ -f "$HB_A" ]; then
    echo "  already present: libharfbuzz.a"
else
    if [ ! -f "$HB_SRC/src/harfbuzz.cc" ]; then
        echo "  downloading harfbuzz $HB_VERSION source..."
        rm -rf "$HB_SRC"
        mkdir -p "$HB_SRC"
        curl -fsSL "https://github.com/harfbuzz/harfbuzz/releases/download/${HB_VERSION}/harfbuzz-${HB_VERSION}.tar.xz" \
            | tar xJ -C "$HB_SRC" --strip-components=1
    fi
    echo "  building static libharfbuzz.a..."
    (
        cd "$HB_SRC"
        $CXX -c -O2 -fPIC -fno-exceptions -fno-rtti \
            -DHB_NO_MT -DHB_LEAN -DHB_NO_AAT \
            -Isrc src/harfbuzz.cc -o harfbuzz.o
        ar rcs libharfbuzz.a harfbuzz.o
        rm -f harfbuzz.o
    )
    echo "  done."
fi
