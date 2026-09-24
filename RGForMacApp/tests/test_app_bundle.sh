#!/bin/zsh
# Checks the bundle build.sh produced: run after ./build.sh.
set -euo pipefail

BASE="${0:A:h:h:h}"
APP="$BASE/RG For Mac.app"
PLIST="$APP/Contents/Info.plist"
GUI="$APP/Contents/MacOS/RGForMac"
MINIEAP="$APP/Contents/Resources/minieap"

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -d "$APP" ] || fail "找不到 $APP，先运行 build.sh"
/usr/bin/plutil -lint "$PLIST" >/dev/null || fail "Info.plist 格式错误"
[ "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$PLIST")" = "true" ] || fail "LSUIElement 应为 true（只在菜单栏显示）"

for bin in "$GUI" "$MINIEAP"; do
  [ -x "$bin" ] || fail "$bin 不可执行"
  archs="$(/usr/bin/lipo -archs "$bin")"
  for arch in arm64 x86_64; do
    [[ " $archs " == *" $arch "* ]] || fail "$bin 缺少 $arch（实际：$archs）"
  done
done

/usr/bin/codesign --verify --deep --strict "$APP" || fail "签名校验失败"
help_text="$("$MINIEAP" -h 2>&1)" || fail "minieap -h 运行失败"
[[ "$help_text" == *"--password-env"* ]] || fail "minieap 不支持 --password-env"

echo "OK"
