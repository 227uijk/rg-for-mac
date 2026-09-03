#!/bin/zsh
set -euo pipefail

SRC_DIR="${0:A:h:h}"
PLIST="$SRC_DIR/Info.plist"
MAIN="$SRC_DIR/main.m"

/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$PLIST" | /usr/bin/grep -Fx 'true' >/dev/null
/usr/bin/grep -F 'NSApplicationActivationPolicyAccessory' "$MAIN" >/dev/null
/usr/bin/grep -F 'ensureCurrentUserPath:[self logFile]' "$MAIN" >/dev/null
/usr/bin/grep -F 'ensureCurrentUserPath:[self pidFile]' "$MAIN" >/dev/null
/usr/bin/grep -F 'runtimePathsAreSafe' "$MAIN" >/dev/null
/usr/bin/grep -F -- '--conf-file /dev/null' "$MAIN" >/dev/null
/usr/bin/grep -F 'stopRequestedWhileStarting' "$MAIN" >/dev/null
/usr/bin/grep -F 'force:YES' "$MAIN" >/dev/null
/usr/bin/grep -F 'isExecutableFileAtPath' "$MAIN" >/dev/null
/usr/bin/grep -F 'DNS2' "$MAIN" >/dev/null
/usr/bin/grep -F 'miniEAPPID' "$MAIN" >/dev/null
/usr/bin/grep -F 'O_NOFOLLOW' "$MAIN" >/dev/null
/usr/bin/grep -F 'MINIEAP_REQUIRE_EXISTING_FILES=1' "$MAIN" >/dev/null
if /usr/bin/grep -F '/bin/cat' "$MAIN" >/dev/null; then
    exit 1
fi
/usr/bin/grep -F -- '--fake-dns2' "$MAIN" >/dev/null
if /usr/bin/grep -F 'pgrep' "$MAIN" >/dev/null; then
    exit 1
fi
PID_LOCK="$SRC_DIR/../minieap-src/util/pid_lock.c"
/usr/bin/grep -F 'O_NOFOLLOW' "$PID_LOCK" >/dev/null
LOGGING="$SRC_DIR/../minieap-src/util/logging.c"
/usr/bin/grep -F 'O_NOFOLLOW' "$LOGGING" >/dev/null
/usr/bin/grep -F 'MINIEAP_REQUIRE_EXISTING_FILES' "$PID_LOCK" >/dev/null
/usr/bin/grep -F 'MINIEAP_REQUIRE_EXISTING_FILES' "$LOGGING" >/dev/null
MINIEAP="$SRC_DIR/../minieap-src/minieap.c"
/usr/bin/grep -F 'IS_FAIL(pid_lock_save_pid())' "$MINIEAP" >/dev/null
BUILD="$SRC_DIR/build.sh"
/usr/bin/grep -F '/usr/bin/make -C "$BASE/minieap-src" -j2' "$BUILD" >/dev/null
/usr/bin/grep -F '/bin/cp "$BASE/minieap-src/minieap"' "$BUILD" >/dev/null
