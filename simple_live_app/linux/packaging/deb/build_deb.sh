#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:?Usage: build_deb.sh VERSION RELEASE_DIR}"
RELEASE_DIR="${2:?Usage: build_deb.sh VERSION RELEASE_DIR}"
if [[ ! "$VERSION" =~ ^[0-9]+([.+~:-][A-Za-z0-9.+~:-]+)*$ ]]; then
  printf 'Invalid Debian package version: %s\n' "$VERSION" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
RELEASE_DIR="$(cd "$RELEASE_DIR" && pwd)"
BUNDLE_DIR="$RELEASE_DIR/bundle"
if [[ ! -x "$BUNDLE_DIR/simple_live_app" ]]; then
  printf 'Flutter Linux bundle is missing: %s\n' "$BUNDLE_DIR" >&2
  exit 1
fi

DEB_ROOT="$(mktemp -d)"
trap 'rm -rf "$DEB_ROOT"' EXIT
mkdir -p \
  "$DEB_ROOT/DEBIAN" \
  "$DEB_ROOT/opt/simple-live" \
  "$DEB_ROOT/usr/share/applications" \
  "$DEB_ROOT/usr/share/icons/hicolor/512x512/apps"
cp -a "$BUNDLE_DIR/." "$DEB_ROOT/opt/simple-live/"
chmod 0755 "$DEB_ROOT/opt/simple-live/simple_live_app"
sed "s/@VERSION@/$VERSION/" "$SCRIPT_DIR/control.in" > "$DEB_ROOT/DEBIAN/control"
install -m 0644 "$SCRIPT_DIR/simple-live.desktop" "$DEB_ROOT/usr/share/applications/simple-live.desktop"
install -m 0644 "$APP_DIR/assets/logo.png" "$DEB_ROOT/usr/share/icons/hicolor/512x512/apps/simple-live.png"

PACKAGE="$RELEASE_DIR/SimpleLive-$VERSION-linux-x64.deb"
dpkg-deb --build --root-owner-group "$DEB_ROOT" "$PACKAGE"
printf 'Created %s\n' "$PACKAGE"
