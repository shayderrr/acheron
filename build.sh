#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_TYPE="Release"
BUILD_DIR="build"
JOBS="$(nproc 2>/dev/null || echo 4)"
QT_VERSION="6.10.2"

CURL_IMPERSONATE_VERSION="v2.0.0"
FFMPEG_RELEASE_TAG="autobuild-2026-07-31-14-10"
FFMPEG_LINUX_BUILD="ffmpeg-n8.1.2-34-g9b6c8969e0-linux64-lgpl-shared-8.1"
FFMPEG_LINUX_SHA256="c882a80f06617149198a98a07a0880a7e881953ae9f9cb931f5be09a4f93caae"

if [ "$#" -gt 0 ]; then
    echo "Usage: ./build.sh" >&2
    exit 1
fi

case "$(uname -s)" in
    Linux) ;;
    *) echo "build.sh supports Linux only; use build.bat on Windows." >&2; exit 1 ;;
esac

case "$BUILD_DIR" in
    /*) ;;
    *) BUILD_DIR="$ROOT/$BUILD_DIR" ;;
esac

MISSING=()
NEED_QT=0
NEED_CURL_IMP=0
NEED_FFMPEG=0
NEED_SUBMODULES=0

have() { command -v "$1" >/dev/null 2>&1; }

ver_ge() {
    [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n 1)" = "$2" ]
}

CURL_IMP_DIR="$ROOT/curl-impersonate"
CURL_LIB="$CURL_IMP_DIR/libcurl-impersonate-local.a"
FFMPEG_DIR="$ROOT/ffmpeg"
QT_ROOT_DIR="${QT_ROOT_DIR:-}"

for tool in git cmake pkg-config curl tar python3; do
    have "$tool" || MISSING+=("$tool")
done

if ! have ninja && ! have make; then
    MISSING+=("ninja")
fi

if ! have cc && ! have gcc && ! have g++ && ! have clang && ! have clang++; then
    MISSING+=("C++ compiler")
fi

if have cmake; then
    CMAKE_VER="$(cmake --version | head -n 1 | grep -oE '[0-9]+(\.[0-9]+)+' | head -n 1)"
    ver_ge "$CMAKE_VER" "3.16" || MISSING+=("cmake>=3.16")
fi

QT_OK=0

try_qmake() {
    local qv prefix
    qv="$("$1" -query QT_VERSION 2>/dev/null || true)"
    [ -n "$qv" ] || return 1
    ver_ge "$qv" "6.7.0" || return 1
    prefix="$("$1" -query QT_INSTALL_PREFIX 2>/dev/null || true)"
    [ -n "$prefix" ] || return 1
    QT_ROOT_DIR="$prefix"
    QT_OK=1
}

if [ -n "$QT_ROOT_DIR" ] && [ -x "$QT_ROOT_DIR/bin/qmake" ]; then
    try_qmake "$QT_ROOT_DIR/bin/qmake" || QT_OK=0
fi

if [ "$QT_OK" -eq 0 ]; then
    for q in qmake6 qmake; do
        have "$q" && try_qmake "$q" && break
    done
fi

if [ "$QT_OK" -eq 0 ]; then
    for d in "$ROOT/Qt" "$HOME/Qt" /opt/Qt /usr/local; do
        [ -d "$d" ] || continue
        while IFS= read -r qm; do
            try_qmake "$qm" && break 2
        done < <(find "$d" -maxdepth 4 -path '*/bin/qmake' 2>/dev/null | sort || true)
    done
fi

if [ "$QT_OK" -eq 0 ]; then
    MISSING+=("Qt 6.7+")
    NEED_QT=1
fi

if have pkg-config; then
    pkg-config --exists libcurl 2>/dev/null || MISSING+=("libcurl dev files")
    pkg-config --exists zlib 2>/dev/null || MISSING+=("zlib dev files")
    pkg-config --exists libsecret-1 2>/dev/null || MISSING+=("libsecret dev files")
fi

if [ -f "$CURL_IMP_DIR/include/curl/curl.h" ] \
    && ls "$CURL_IMP_DIR"/libcurl-impersonate*.a >/dev/null 2>&1; then
    :
else
    MISSING+=("curl-impersonate")
    NEED_CURL_IMP=1
fi

if [ "$NEED_CURL_IMP" -eq 1 ] && { ! have objcopy || ! have nm; }; then
    MISSING+=("binutils")
fi

ffmpeg_ok() {
    if have pkg-config \
        && pkg-config --exists libavcodec libavformat 'libavutil >= 57.28.100' \
            libswscale libswresample 2>/dev/null; then
        return 0
    fi
    [ -f "$FFMPEG_DIR/include/libavcodec/avcodec.h" ]
}

ffmpeg_ok || { MISSING+=("ffmpeg"); NEED_FFMPEG=1; }

if ! have git || git -C "$ROOT" submodule status 2>/dev/null | grep -q '^-'; then
    MISSING+=("git submodules")
    NEED_SUBMODULES=1
fi

if [ "${#MISSING[@]}" -gt 0 ]; then
    joined="$(printf '%s, ' "${MISSING[@]}")"
    joined="${joined%, }"
    if [ "${#MISSING[@]}" -eq 1 ]; then
        echo "$joined is not currently installed on your system."
    else
        echo "$joined are not currently installed on your system."
    fi

    if [ ! -t 0 ]; then
        echo "Not a terminal, aborting." >&2
        exit 1
    fi
    read -r -p "Do you want to continue? [Y/n] " ANSWER
    case "$ANSWER" in
        ""|[Yy]|[Yy][Ee][Ss]) ;;
        *) exit 1 ;;
    esac
else
    echo "All dependencies present."
fi

install_missing() {
    local SUDO PM
    if [ "$(id -u)" -ne 0 ]; then
        have sudo || { echo "sudo is required to install packages." >&2; exit 1; }
        SUDO="sudo"
    else
        SUDO=""
    fi

    if have apt-get; then
        PM="apt"
    elif have dnf; then
        PM="dnf"
    elif have pacman; then
        PM="pacman"
    elif have zypper; then
        PM="zypper"
    else
        echo "No supported package manager found (apt, dnf, pacman, zypper)." >&2
        exit 1
    fi

    case "$PM" in
        apt)
            PKGS=(git cmake ninja-build pkg-config build-essential curl tar xz-utils zip unzip autoconf automake libtool python3 python3-pip binutils libcurl4-openssl-dev libsecret-1-dev zlib1g-dev libavcodec-dev libavformat-dev libavutil-dev libswscale-dev libswresample-dev)
            export DEBIAN_FRONTEND=noninteractive
            $SUDO apt-get update
            $SUDO apt-get install -y "${PKGS[@]}"
            ;;
        dnf)
            PKGS=(git cmake ninja-build pkgconf-pkg-config gcc gcc-c++ make curl tar xz zip unzip autoconf automake libtool python3 python3-pip binutils libcurl-devel libsecret-devel zlib-devel)
            $SUDO dnf install -y "${PKGS[@]}"
            ;;
        pacman)
            PKGS=(base-devel cmake ninja pkgconf curl tar xz zip unzip autoconf automake libtool python python-pip binutils curl libsecret zlib)
            $SUDO pacman -Sy --needed --noconfirm "${PKGS[@]}"
            ;;
        zypper)
            PKGS=(git cmake ninja pkgconf gcc gcc-c++ make curl tar xz zip unzip autoconf automake libtool python3 python3-pip binutils libcurl-devel libsecret-devel zlib-devel)
            $SUDO zypper install -y "${PKGS[@]}"
            ;;
    esac

    if [ "$NEED_QT" -eq 1 ]; then
        python3 -m pip install --quiet --user aqtinstall 2>/dev/null \
            || python3 -m pip install --quiet --user --break-system-packages aqtinstall
        export PATH="$HOME/.local/bin:$PATH"
        (cd /tmp && python3 -m aqt install-qt linux desktop "$QT_VERSION" gcc_64 \
            -m qtimageformats -O "$ROOT/Qt")
        QT_ROOT_DIR="$ROOT/Qt/$QT_VERSION/gcc_64"
        [ -x "$QT_ROOT_DIR/bin/qmake" ] || { echo "Qt install failed." >&2; exit 1; }
    fi

    if [ "$NEED_CURL_IMP" -eq 1 ]; then
        case "$(uname -m)" in
            x86_64) CI_ARCH="x86_64-linux-gnu" ;;
            aarch64|arm64) CI_ARCH="aarch64-linux-gnu" ;;
            *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
        esac
        CI_TARBALL="/tmp/libcurl-impersonate.tar.gz"
        curl -fSL -o "$CI_TARBALL" \
            "https://github.com/lexiforest/curl-impersonate/releases/download/${CURL_IMPERSONATE_VERSION}/libcurl-impersonate-${CURL_IMPERSONATE_VERSION}.${CI_ARCH}.tar.gz"
        rm -rf "$CURL_IMP_DIR"
        mkdir -p "$CURL_IMP_DIR"
        tar -xzf "$CI_TARBALL" -C "$CURL_IMP_DIR"
        rm -f "$CI_TARBALL"
        KEEP_FLAGS="$(nm --defined-only -g "$CURL_IMP_DIR/libcurl-impersonate.a" \
            | awk '{print $NF}' | grep '^curl_' | sort -u \
            | sed 's/^/--keep-global-symbol=/' | tr '\n' ' ' || true)"
        objcopy $KEEP_FLAGS \
            "$CURL_IMP_DIR/libcurl-impersonate.a" "$CURL_LIB"
    fi

    if [ "$NEED_FFMPEG" -eq 1 ] && ! ffmpeg_ok; then
        FF_TARBALL="/tmp/ffmpeg-acheron.tar.xz"
        curl -fSL -o "$FF_TARBALL" \
            "https://github.com/BtbN/FFmpeg-Builds/releases/download/${FFMPEG_RELEASE_TAG}/${FFMPEG_LINUX_BUILD}.tar.xz"
        echo "${FFMPEG_LINUX_SHA256}  ${FF_TARBALL}" | sha256sum -c -
        rm -rf "$FFMPEG_DIR"
        mkdir -p "$FFMPEG_DIR"
        tar -xf "$FF_TARBALL" -C "$FFMPEG_DIR" --strip-components=1
        rm -f "$FF_TARBALL"
    fi

    if [ "$NEED_SUBMODULES" -eq 1 ]; then
        git -C "$ROOT" submodule update --init --recursive
    fi

    if [ ! -x "$ROOT/vendor/vcpkg/vcpkg" ]; then
        "$ROOT/vendor/vcpkg/bootstrap-vcpkg.sh"
    fi
}

if [ "${#MISSING[@]}" -gt 0 ]; then
    install_missing
fi

case "$(uname -m)" in
    x86_64) TRIPLET="x64-linux" ;;
    aarch64|arm64) TRIPLET="arm64-linux" ;;
    *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

PREFIX="$QT_ROOT_DIR"
if [ -f "$FFMPEG_DIR/include/libavcodec/avcodec.h" ]; then
    PREFIX="$PREFIX;$FFMPEG_DIR"
fi

CMAKE_ARGS=(
    -S "$ROOT" -B "$BUILD_DIR"
    "-DCMAKE_BUILD_TYPE=$BUILD_TYPE"
    "-DVCPKG_TARGET_TRIPLET=$TRIPLET"
    "-DCMAKE_PREFIX_PATH=$PREFIX"
    "-DCURL_INCLUDE_DIR=$CURL_IMP_DIR/include"
    "-DCURL_LIBRARY=$CURL_LIB"
    -DBUILD_TESTS=ON
)

if [ -f "$BUILD_DIR/CMakeCache.txt" ]; then
    CACHED_SRC="$(grep '^CMAKE_HOME_DIRECTORY:INTERNAL=' "$BUILD_DIR/CMakeCache.txt" | cut -d= -f2- || true)"
    CACHED_BIN="$(grep '^CMAKE_CACHEFILE_DIR:INTERNAL=' "$BUILD_DIR/CMakeCache.txt" | cut -d= -f2- || true)"
    if [ "$CACHED_SRC" != "$ROOT" ] || [ "$CACHED_BIN" != "$BUILD_DIR" ]; then
        rm -rf "$BUILD_DIR"
    fi
fi

cmake "${CMAKE_ARGS[@]}"
cmake --build "$BUILD_DIR" --parallel "$JOBS"

if [ -d "$FFMPEG_DIR/lib" ]; then
    export LD_LIBRARY_PATH="$FFMPEG_DIR/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi
ctest --test-dir "$BUILD_DIR" --output-on-failure

echo "Build complete: $BUILD_DIR/acheron"
