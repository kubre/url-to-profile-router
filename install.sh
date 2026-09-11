#!/bin/sh
set -eu
cd "$(dirname "$0")"
APP='URL to Profile Router'
ID='com.vaibhav.urlrouter'
DEST=${INSTALL_DIR:-/Applications}
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
./build.sh
mkdir -p "$DEST" || { echo "Cannot create $DEST. Try INSTALL_DIR=\"\$HOME/Applications\" ./install.sh" >&2; exit 1; }
[ -w "$DEST" ] || { echo "Cannot write to $DEST. Try INSTALL_DIR=\"\$HOME/Applications\" ./install.sh" >&2; exit 1; }
TARGET="$DEST/$APP.app"
[ ! -L "$TARGET" ] || { echo "Refusing to replace a symlink: $TARGET" >&2; exit 1; }
if [ -e "$TARGET" ]; then
    EXISTING_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$TARGET/Contents/Info.plist")
    [ "$EXISTING_ID" = "$ID" ] || { echo "Refusing to replace unrelated app: $TARGET ($EXISTING_ID)" >&2; exit 1; }
fi
STAGE=$(mktemp -d "$DEST/.url-router-install.XXXXXX")
COMMITTED=0
REPLACED=0
cleanup() {
    if [ "$COMMITTED" -eq 0 ]; then
        if [ -d "$STAGE/previous.app" ]; then
            [ "$REPLACED" -eq 0 ] || rm -rf "$TARGET"
            if ! mv "$STAGE/previous.app" "$TARGET"; then
                echo "Restore failed; previous app preserved at $STAGE/previous.app" >&2
                return 1
            fi
            "$LSREG" -f "$TARGET" || echo 'Warning: could not re-register the restored app.' >&2
        elif [ "$REPLACED" -eq 1 ]; then
            rm -rf "$TARGET"
        fi
    fi
    rm -rf "$STAGE"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
# Stage and verify before touching the installed app. Config and browser data
# are deliberately not part of installation or removal.
ditto "build/$APP.app" "$STAGE/$APP.app"
codesign --verify --strict "$STAGE/$APP.app"
if [ -e "$TARGET" ]; then mv "$TARGET" "$STAGE/previous.app"; fi
REPLACED=1
mv "$STAGE/$APP.app" "$TARGET"
"$LSREG" -f "$TARGET"
COMMITTED=1
printf '\nInstalled: %s\nOpen the app to edit rules, test a link, and make it your default browser.\n' "$TARGET"
# Never remove /Applications/Router.app: it may be an unrelated application.
