#!/bin/zsh
set -euo pipefail

SRC="${0:A:h}"
BASE="${SRC:h}"
APP="$BASE/RG For Mac.app"
STASH_DIR="$BASE/.build-trash"

if [ -e "$APP" ]; then
  /bin/mkdir -p "$STASH_DIR"
  /bin/mv "$APP" "$STASH_DIR/RG For Mac-$(/bin/date +%Y%m%d-%H%M%S).app"
fi
/usr/bin/make -C "$BASE/minieap-src" -j2
python3 "$SRC/make_icon.py"
/bin/mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
/bin/cp "$SRC/Info.plist" "$APP/Contents/Info.plist"
/bin/cp "$SRC/RGForMac.icns" "$APP/Contents/Resources/RGForMac.icns"
/bin/cp "$BASE/minieap-src/minieap" "$APP/Contents/Resources/minieap"
/bin/chmod +x "$APP/Contents/Resources/minieap"

/usr/bin/clang "$SRC/main.m" \
  -fobjc-arc \
  -fmodules-cache-path="$BASE/.clang-module-cache" \
  -framework Cocoa \
  -framework Security \
  -framework SystemConfiguration \
  -Os \
  -o "$APP/Contents/MacOS/RGForMac"

/bin/chmod +x "$APP/Contents/MacOS/RGForMac"
/usr/bin/xattr -cr "$APP"
/usr/bin/codesign --force --deep --sign - "$APP"

if [ -d "$HOME/Desktop" ]; then
  /bin/rm -rf "$HOME/Desktop/RG For Mac.app"
  /bin/cp -R "$APP" "$HOME/Desktop/RG For Mac.app"
fi

echo "$APP"

