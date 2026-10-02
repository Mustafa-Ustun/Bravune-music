#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-release}"
APP="$ROOT/dist/Bravune.app"
DENIED_TEAMS="W3GBW2G7KJ 75KU2C8UUD"

verify_identity() {
    local hash="$1" team="$2" denied
    for denied in $DENIED_TEAMS; do
        if [ "$team" = "$denied" ]; then
            echo "refused: team $team is on the deny list" >&2
            exit 3
        fi
    done
    local line name
    line="$(security find-identity -v -p codesigning | grep -F "$hash" || true)"
    if [ -z "$line" ]; then
        echo "refused: no valid code signing identity with SHA-1 $hash" >&2
        exit 3
    fi
    name="$(printf '%s' "$line" | sed -E 's/^[^"]*"([^"]*)".*$/\1/')"
    local pem
    pem="$(security find-certificate -a -Z -p -c "$name" | awk -v want="$hash" '/^SHA-1 hash:/{cur=$3} /BEGIN CERTIFICATE/{keep=(cur==want)} keep{print}')"
    if [ -z "$pem" ]; then
        echo "refused: certificate $hash could not be read" >&2
        exit 3
    fi
    local ou
    ou="$(printf '%s\n' "$pem" | openssl x509 -noout -subject -nameopt multiline | awk -F' = ' '/organizationalUnitName/{print $2}')"
    if [ "$ou" != "$team" ]; then
        echo "refused: certificate team is '$ou' but TEAM_ID is '$team'" >&2
        exit 3
    fi
    if ! printf '%s\n' "$pem" | openssl x509 -noout -checkend 0 >/dev/null; then
        echo "refused: certificate $hash is expired" >&2
        exit 3
    fi
    echo "identity verified: $name, team $ou"
}

if [ -n "${SIGN_IDENTITY:-}" ]; then
    if [ -z "${TEAM_ID:-}" ]; then
        echo "refused: SIGN_IDENTITY needs TEAM_ID" >&2
        exit 3
    fi
    verify_identity "$SIGN_IDENTITY" "$TEAM_ID"
fi

# UNIVERSAL=1 builds arm64 and x86_64 into one binary. Default stays the host architecture.
ARCH_ARGS=()
if [ -n "${UNIVERSAL:-}" ]; then
    ARCH_ARGS=(--arch arm64 --arch x86_64)
fi

swift build -c "$CONFIG" --package-path "$ROOT" ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"}
BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} --show-bin-path)/Bravune"
if [ -n "${UNIVERSAL:-}" ]; then
    ARCHS="$(lipo -archs "$BIN")"
    case "$ARCHS" in
        *arm64*x86_64*|*x86_64*arm64*) echo "universal binary: $ARCHS" ;;
        *) echo "refused: expected arm64 and x86_64, got '$ARCHS'" >&2; exit 4 ;;
    esac
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Bravune"
cp "$ROOT/Packaging/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [ -z "${SIGN_IDENTITY:-}" ]; then
    codesign --force --sign - "$APP"
    echo "packaged with an ad-hoc signature (no certificate, no team): $APP"
    exit 0
fi

ARGS=(--force --sign "$SIGN_IDENTITY")
if [ -n "${HARDENED_RUNTIME:-}" ]; then
    ARGS+=(--options runtime --timestamp)
fi
if [ -n "${ENTITLEMENTS:-}" ]; then
    ARGS+=(--entitlements "$ENTITLEMENTS")
fi
codesign "${ARGS[@]}" "$APP"
echo "packaged and signed: $APP"
