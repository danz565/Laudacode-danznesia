#!/bin/sh
# Laudacode installer — Termux, Linux and macOS.
#
# Install:
#   curl -fsSL https://raw.githubusercontent.com/danz565/Laudacode-danznesia/main/install.sh | sh
#
# Behavior:
#   1. Try latest GitHub Release binary
#   2. If no Release/binary exists, build from source
#   3. FORCE_BUILD=1 skips Release and builds from main
#
# Environment:
#   REPO
#   LAUDACODE_VERSION
#   PREFIX
#   TMPDIR
#   FORCE_BUILD=1

set -eu

# ---------------------------------------------------------------------
# PLATFORM
# ---------------------------------------------------------------------

if [ -n "${TERMUX_VERSION:-}" ]; then
    PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
    TMPDIR="${TMPDIR:-$PREFIX/tmp}"
else
    PREFIX="${PREFIX:-/usr/local}"
    TMPDIR="${TMPDIR:-/tmp}"
fi

REPO="${REPO:-danz565/Laudacode-danznesia}"
BUILD_DIR="$TMPDIR/laudacode-build"

# ---------------------------------------------------------------------
# DEPENDENCIES
# ---------------------------------------------------------------------

for tool in curl tar; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "✗ $tool not found." >&2

        if [ -n "${TERMUX_VERSION:-}" ]; then
            echo "  Termux: pkg install $tool" >&2
        else
            echo "  Please install $tool first." >&2
        fi

        exit 1
    }
done

# ---------------------------------------------------------------------
# SUDO
# ---------------------------------------------------------------------

SUDO=""

if [ ! -w "$PREFIX" ] && [ "$(id -u)" != "0" ]; then
    if command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
    fi
fi

# ---------------------------------------------------------------------
# INSTALL BINARY
# ---------------------------------------------------------------------

install_binary() {
    if [ -n "$SUDO" ]; then
        $SUDO mkdir -p "${PREFIX%/}/bin"
        $SUDO install -m 755 "$1" "${PREFIX%/}/bin/laudacode"
    else
        mkdir -p "${PREFIX%/}/bin"
        install -m 755 "$1" "${PREFIX%/}/bin/laudacode"
    fi
}

# ---------------------------------------------------------------------
# DETECT PLATFORM
# ---------------------------------------------------------------------

detect_targets() {
    arch="$(uname -m)"

    if [ -n "${TERMUX_VERSION:-}" ]; then

        case "$arch" in
            aarch64)
                echo "aarch64-linux-android"
                ;;

            armv7l|armv8l|armv7)
                echo "armv7-linux-androideabi"
                ;;

            x86_64)
                echo "x86_64-linux-android"
                ;;

            i686|i386)
                echo "i686-linux-android"
                ;;

            *)
                return 1
                ;;
        esac

        return 0
    fi

    [ "$(uname -s)" = "Linux" ] || return 1

    case "$arch" in
        x86_64)
            echo "x86_64-unknown-linux-musl"
            echo "x86_64-unknown-linux-gnu"
            ;;

        aarch64)
            echo "aarch64-unknown-linux-musl"
            echo "aarch64-unknown-linux-gnu"
            ;;

        *)
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------------
# RESOLVE RELEASE
# ---------------------------------------------------------------------

VERSION=""

if [ -n "${LAUDACODE_VERSION:-}" ]; then

    VERSION="$LAUDACODE_VERSION"

elif [ "${FORCE_BUILD:-0}" = "1" ]; then

    echo "==> FORCE_BUILD=1"
    echo "==> skipping GitHub Release"

else

    echo "==> resolving latest release"

    if RELEASE_JSON="$(curl -fsSL \
        --connect-timeout 15 \
        "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null)"; then

        VERSION="$(printf '%s\n' "$RELEASE_JSON" \
            | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' \
            | head -n 1)"

    fi

    if [ -n "$VERSION" ]; then
        echo "==> latest release: $VERSION"
    else
        echo "==> no GitHub Release found"
        echo "==> falling back to source build from main"
    fi
fi

# ---------------------------------------------------------------------
# PREBUILT BINARY
# ---------------------------------------------------------------------

try_prebuilt() {

    [ -n "$VERSION" ] || return 1

    [ "${FORCE_BUILD:-0}" = "1" ] && return 1

    TARGETS="$(detect_targets)" || return 1

    BASE="https://github.com/${REPO}/releases/download/${VERSION}"

    for TARGET in $TARGETS; do

        ASSET="laudacode-${VERSION}-${TARGET}.tar.gz"

        echo "==> trying prebuilt binary:"
        echo "    $ASSET"

        rm -rf "$BUILD_DIR"
        mkdir -p "$BUILD_DIR"

        if ! curl -fL \
            --connect-timeout 15 \
            -o "$BUILD_DIR/$ASSET" \
            "$BASE/$ASSET"; then

            echo "==> asset unavailable: $TARGET"
            continue
        fi

        # -------------------------------------------------------------
        # CHECKSUM
        # -------------------------------------------------------------

        if curl -fsSL \
            --connect-timeout 15 \
            -o "$BUILD_DIR/SHA256SUMS" \
            "$BASE/SHA256SUMS"; then

            if grep -q " $ASSET\$" "$BUILD_DIR/SHA256SUMS"; then

                expected="$(grep " $ASSET\$" "$BUILD_DIR/SHA256SUMS" \
                    | awk '{print $1}')"

                if command -v sha256sum >/dev/null 2>&1; then

                    actual="$(sha256sum "$BUILD_DIR/$ASSET" \
                        | awk '{print $1}')"

                    if [ "$expected" != "$actual" ]; then
                        echo "✗ checksum mismatch"
                        continue
                    fi

                    echo "==> checksum OK"

                fi
            fi
        fi

        # -------------------------------------------------------------
        # EXTRACT
        # -------------------------------------------------------------

        if ! tar -xzf "$BUILD_DIR/$ASSET" -C "$BUILD_DIR"; then
            echo "✗ failed to extract binary"
            continue
        fi

        if [ ! -f "$BUILD_DIR/laudacode" ]; then
            echo "✗ laudacode binary not found in archive"
            continue
        fi

        install_binary "$BUILD_DIR/laudacode"

        echo ""
        echo "=========================================="
        echo " Laudacode installed successfully"
        echo "=========================================="
        echo ""
        echo "Binary:"
        echo "${PREFIX%/}/bin/laudacode"
        echo ""

        "${PREFIX%/}/bin/laudacode" --version 2>/dev/null || true

        return 0
    done

    return 1
}

# ---------------------------------------------------------------------
# BUILD FROM SOURCE
# ---------------------------------------------------------------------

build_from_source() {

    command -v cargo >/dev/null 2>&1 || {

        echo "✗ cargo not found."

        if [ -n "${TERMUX_VERSION:-}" ]; then
            echo "Install it with:"
            echo ""
            echo "  pkg install rust"
        else
            echo "Install Rust from https://rustup.rs"
        fi

        exit 1
    }

    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"

    trap 'rm -rf "$BUILD_DIR"' EXIT INT TERM

    # -------------------------------------------------------------
    # SOURCE REF
    # -------------------------------------------------------------

    if [ -n "$VERSION" ]; then

        SOURCE_URL="https://github.com/${REPO}/archive/refs/tags/${VERSION}.tar.gz"

        echo "==> downloading source:"
        echo "    ${REPO}@${VERSION}"

    else

        SOURCE_URL="https://github.com/${REPO}/archive/refs/heads/main.tar.gz"

        echo "==> downloading source:"
        echo "    ${REPO}@main"

    fi

    # -------------------------------------------------------------
    # DOWNLOAD
    # -------------------------------------------------------------

    curl -fL \
        --connect-timeout 15 \
        -o "$BUILD_DIR/laudacode.tar.gz" \
        "$SOURCE_URL"

    # -------------------------------------------------------------
    # VALIDATE ARCHIVE
    # -------------------------------------------------------------

    tar -tzf "$BUILD_DIR/laudacode.tar.gz" >/dev/null || {
        echo "✗ downloaded source is not a valid tar.gz"
        exit 1
    }

    # -------------------------------------------------------------
    # EXTRACT
    # -------------------------------------------------------------

    cd "$BUILD_DIR"

    tar -xzf laudacode.tar.gz

    SRC_DIR="$(find . -maxdepth 1 -type d \
        -name 'Laudacode-*' \
        | head -n 1)"

    if [ -z "$SRC_DIR" ]; then
        echo "✗ could not find Laudacode source directory"
        exit 1
    fi

    cd "$SRC_DIR"

    # -------------------------------------------------------------
    # BUILD
    # -------------------------------------------------------------

    echo ""
    echo "==> building Laudacode"
    echo "==> this can take several minutes..."
    echo ""

    CARGO_PROFILE_RELEASE_LTO="${CARGO_PROFILE_RELEASE_LTO:-off}" \
        cargo build --release --locked

    # -------------------------------------------------------------
    # CHECK BINARY
    # -------------------------------------------------------------

    if [ ! -f "target/release/laudacode" ]; then
        echo "✗ build finished but binary is missing"
        exit 1
    fi

    # -------------------------------------------------------------
    # INSTALL
    # -------------------------------------------------------------

    install_binary "target/release/laudacode"

    echo ""
    echo "=========================================="
    echo " Laudacode installed successfully"
    echo "=========================================="
    echo ""
    echo "Binary:"
    echo "${PREFIX%/}/bin/laudacode"
    echo ""

    "${PREFIX%/}/bin/laudacode" --version 2>/dev/null || true

    echo ""
    echo "Run:"
    echo "  laudacode"
    echo ""
}

# ---------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------

if try_prebuilt; then
    exit 0
fi

echo "==> building Laudacode from source"

build_from_source
