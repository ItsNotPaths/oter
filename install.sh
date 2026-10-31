#!/usr/bin/env sh
#
# oter installer.
#
#   curl -fsSL https://github.com/ItsNotPaths/oter/releases/latest/download/install.sh | sh
#
# Downloads the release tarball, runs `oter --install` out of it, deletes it. The binary does
# the install (src/oter/install.odin), the same code `:oter install` runs.
#
# Flags:
#   --version <tag>  install that release instead of the latest
#   --keep           leave the unpacked folder behind, and say where it is

set -eu

REPO="ItsNotPaths/oter"
BIN_NAME="oter"
BIN_DIR="${HOME}/.local/bin"
REL_TAG="latest"
KEEP=0

usage() {
    cat <<'EOF'
usage: install.sh [--version <tag>] [--keep]

Downloads the oter release, unpacks it, and runs `oter --install` out of it.

  --version <tag>  install that release instead of the latest
  --keep           leave the unpacked folder behind, and say where it is
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --version) REL_TAG="${2:?--version needs a value}"; shift 2 ;;
        --keep)    KEEP=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown flag: $1" >&2; usage >&2; exit 1 ;;
    esac
done

say()  { printf '%s\n' "$*"; }
step() { printf '==> %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# Parsed, not sourced: sourcing would clobber our own variables.
os_release_field() {
    [ -r /etc/os-release ] || return 0
    sed -n "s/^$1=//p" /etc/os-release | head -n 1 | tr -d '"'"'"
}

OS_ID="$(os_release_field ID)"
OS_LIKE="$(os_release_field ID_LIKE)"
[ -n "$OS_ID" ] || OS_ID="unknown"

os_family() {
    case " ${OS_ID} ${OS_LIKE} " in
        *" arch "*|*" archlinux "*|*" omarchy "*) echo arch ;;
        *" debian "*|*" ubuntu "*)                echo debian ;;
        *" fedora "*|*" rhel "*|*" centos "*)     echo fedora ;;
        *" suse "*|*" opensuse "*)                echo suse ;;
        *" alpine "*)                             echo alpine ;;
        *)                                        echo unknown ;;
    esac
}

# Only names the command; installs nothing.
pkg_hint() {
    case "$(os_family)" in
        arch)   echo "sudo pacman -S $1" ;;
        debian) echo "sudo apt install $1" ;;
        fedora) echo "sudo dnf install $1" ;;
        suse)   echo "sudo zypper install $1" ;;
        alpine) echo "sudo apk add $1" ;;
        *)      echo "install $1 with your package manager" ;;
    esac
}

ARCH="$(uname -m)"
[ "$(uname -s)" = "Linux" ] || die "oter is Linux only (this is $(uname -s))."
[ "$ARCH" = "x86_64" ] || die "no ${ARCH} build is published — build from source: https://github.com/${REPO}"

if command -v curl >/dev/null 2>&1; then
    fetch() { curl -fsSL "$1" -o "$2"; }
elif command -v wget >/dev/null 2>&1; then
    fetch() { wget -qO "$2" "$1"; }
else
    die "neither curl nor wget is installed. $(pkg_hint curl)"
fi

command -v tar >/dev/null 2>&1 || die "tar is not installed. $(pkg_hint tar)"

ASSET="${BIN_NAME}-${ARCH}-linux.tar.gz"
if [ "$REL_TAG" = "latest" ]; then
    URL="https://github.com/${REPO}/releases/latest/download/${ASSET}"
else
    URL="https://github.com/${REPO}/releases/download/${REL_TAG}/${ASSET}"
fi

say "oter  ·  ${OS_ID} ($(os_family)), ${ARCH}"
step "Downloading ${ASSET} (${REL_TAG})"

WORK="$(mktemp -d)"
[ "$KEEP" -eq 1 ] || trap 'rm -rf "$WORK"' EXIT INT TERM

fetch "$URL" "$WORK/$ASSET" || die "download failed: $URL"
[ -s "$WORK/$ASSET" ] || die "downloaded an empty file from $URL"

step "Unpacking"
mkdir -p "$WORK/oter"
tar -xzf "$WORK/$ASSET" -C "$WORK/oter" || die "the archive did not unpack"
[ -x "$WORK/oter/$BIN_NAME" ] || die "no $BIN_NAME in the archive"

step "Installing"
"$WORK/oter/$BIN_NAME" --install || die "the install failed"

say ""
step "Done"

case ":${PATH}:" in
    *":${BIN_DIR}:"*) say "    Run it:  ${BIN_NAME}" ;;
    *)
        say "    ${BIN_DIR} is not on your PATH. Add it:"
        say "        export PATH=\"${BIN_DIR}:\$PATH\""
        say "    Until then, run it as:  ${BIN_DIR}/${BIN_NAME}"
        ;;
esac

if [ "$KEEP" -eq 1 ]; then
    say ""
    say "    The unpacked release is still at ${WORK}/oter"
fi

say ""
say "    :oter status  says where everything went."
say "    :oter uninstall  takes it all back out."
