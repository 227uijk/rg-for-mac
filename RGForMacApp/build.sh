#!/bin/zsh
set -euo pipefail

SRC="${0:A:h}"
BASE="${SRC:h}"
APP="$BASE/RG For Mac.app"
STASH_DIR="$BASE/.build-trash"
KEEP_OLD_BUILDS=3
# Universal binary, so the .app also runs on a classmate's Intel/Apple Silicon Mac.
ARCHS=(arm64 x86_64)
MIN_MACOS=12.0

INSTALL_DESKTOP=0
for arg in "$@"; do
  case "$arg" in
    --desktop) INSTALL_DESKTOP=1 ;;
    *) echo "用法：$0 [--desktop]" >&2; exit 2 ;;
  esac
done

if [ -e "$APP" ]; then
  /bin/mkdir -p "$STASH_DIR"
  /bin/mv "$APP" "$STASH_DIR/RG For Mac-$(/bin/date +%Y%m%d-%H%M%S).app"
fi
# Only keep the newest few old builds around
old_builds=("$STASH_DIR"/*.app(N/om))
/bin/rm -rf "${old_builds[@]:$KEEP_OLD_BUILDS}"

# minieap's Makefile generates deps with `cc -MM`, which refuses multiple -arch
# flags, so build one slice per arch and glue them together with lipo.
SLICE_DIR="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf "$SLICE_DIR"' EXIT
slices=()
for arch in "${ARCHS[@]}"; do
  flags="-arch $arch -mmacosx-version-min=$MIN_MACOS"
  /usr/bin/make -C "$BASE/minieap-src" clean >/dev/null
  /usr/bin/make -C "$BASE/minieap-src" -j"$(/usr/sbin/sysctl -n hw.ncpu)" CFLAGS="$flags" LDFLAGS="$flags"
  /bin/cp "$BASE/minieap-src/minieap" "$SLICE_DIR/minieap-$arch"
  slices+=("$SLICE_DIR/minieap-$arch")
done
arch_args=()
for arch in "${ARCHS[@]}"; do arch_args+=(-arch "$arch"); done
/usr/bin/lipo -create "${slices[@]}" -output "$BASE/minieap-src/minieap"
# The .icns is committed; only regenerate it (needs Pillow) when it is missing
if [ ! -f "$SRC/RGForMac.icns" ]; then
  python3 "$SRC/make_icon.py"
fi
/bin/mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
/bin/cp "$SRC/Info.plist" "$APP/Contents/Info.plist"
/bin/cp "$SRC/RGForMac.icns" "$APP/Contents/Resources/RGForMac.icns"
/bin/cp "$BASE/minieap-src/minieap" "$APP/Contents/Resources/minieap"
/bin/chmod +x "$APP/Contents/Resources/minieap"

/usr/bin/clang "$SRC/main.m" \
  "${arch_args[@]}" \
  -mmacosx-version-min="$MIN_MACOS" \
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

if (( INSTALL_DESKTOP )) && [ -d "$HOME/Desktop" ]; then
  /bin/rm -rf "$HOME/Desktop/RG For Mac.app"
  /bin/cp -R "$APP" "$HOME/Desktop/RG For Mac.app"
fi

echo "$APP"
