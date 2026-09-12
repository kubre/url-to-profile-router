#!/bin/sh
set -eu

APP_NAME="URL to Profile Router"
APP_BUNDLE="build/$APP_NAME.app"
OUTPUT_DIR="${1:-$HOME/Documents/scrcap}"
VERSION="${2:-$(git describe --tags --dirty --always --match 'v*' 2>/dev/null || date +%Y%m%d-%H%M%S)}"
PACKAGE_NAME="URL-to-Profile-Router-$VERSION"
STAGE_DIR="$OUTPUT_DIR/$PACKAGE_NAME"

./build.sh
mkdir -p "$OUTPUT_DIR"

ZIP_OUT="$OUTPUT_DIR/$PACKAGE_NAME.zip"
DMG_OUT="$OUTPUT_DIR/$PACKAGE_NAME.dmg"
CONF_DST="$STAGE_DIR/url-router.conf"
INSTALLER_DST="$STAGE_DIR/install-url-to-profile-router.command"
ROUTER_DST="$STAGE_DIR/$APP_NAME.app"

rm -rf "$ZIP_OUT" "$DMG_OUT" "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
cp -R "$APP_BUNDLE" "$ROUTER_DST"
cp rules.conf "$CONF_DST"

cat > "$INSTALLER_DST" <<'EOF'
#!/bin/sh
set -eu

APP_NAME="URL to Profile Router"
DEST="/Applications/$APP_NAME.app"
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_APP="$SOURCE_DIR/$APP_NAME.app"
SOURCE_CONF="$SOURCE_DIR/url-router.conf"
TARGET_CONF="$HOME/.config/url-router.conf"
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

if [ ! -d "$SOURCE_APP" ]; then
  echo "missing app in installer package" >&2
  exit 1
fi

rm -rf "$DEST"
cp -R "$SOURCE_APP" "$DEST"
mkdir -p "$HOME/.config"
if [ -f "$SOURCE_CONF" ] && [ ! -e "$TARGET_CONF" ]; then
  cp "$SOURCE_CONF" "$TARGET_CONF"
  echo "created config at $TARGET_CONF"
else
  echo "kept existing $TARGET_CONF"
fi

"$LSREG" -f "$DEST"
if ! open "$DEST"; then
  if open -b com.vaibhav.urlrouter; then
    :
  else
    echo "Could not auto-open the app (LaunchServices error)."
    echo "Run:"
    echo "  open -a \"$APP_NAME\""
  fi
fi

echo "Installed $APP_NAME to $DEST"
echo "Open the app and click Set as Default Browser, or run:"
echo "\"$DEST/Contents/MacOS/Router\" --set-default"
EOF

chmod +x "$INSTALLER_DST"

ditto -c -k "$STAGE_DIR" "$ZIP_OUT"
hdiutil create -volname "URL to Profile Router" -srcfolder "$STAGE_DIR" -ov -format UDZO -fs HFS+ "$DMG_OUT"

echo "Created:"
echo "  $ZIP_OUT"
echo "  $DMG_OUT"
