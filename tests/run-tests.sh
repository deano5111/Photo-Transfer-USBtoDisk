#!/usr/bin/env bash
# Self-contained tests for usb-image-import, runnable as a normal user (no root, no real drives).
# Uses the script's test mode: a directory stands in for the mounted card, TEST_DEST_DIR for the drive.
#   ./tests/run-tests.sh            (set SHOW_WINDOW=1 to also show the progress window)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()   { echo "  PASS  $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $1"; FAIL=$((FAIL+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# Sample "card"
C=$T/card; mkdir -p "$C/DCIM/100CANON" "$C/.Trashes" "$C/My Pics"
head -c 2M /dev/urandom > "$C/DCIM/100CANON/IMG_0001.JPG"
head -c 2M /dev/urandom > "$C/DCIM/100CANON/IMG_0001.CR2"
head -c 1M /dev/urandom > "$C/My Pics/beach day.heic"
touch "$C/notes.txt" "$C/DCIM/._IMG_0001.JPG" "$C/.Trashes/old.jpg" "$C/clip.MP4"

sed -e "s|^DEST_UUID=.*|DEST_UUID=\"test\"|" -e "s|^TARGET_USER=.*|TARGET_USER=\"$(whoami)\"|" \
    "$ROOT/usb-image-import.conf" > "$T/test.conf"

# Without SHOW_WINDOW, hide the desktop so no window opens
run() {
    local env=(USB_IMPORT_CONF="$T/test.conf" USB_IMPORT_LOCK="$T/lock" TEST_DEST_DIR="$T/dest" TMPDIR="$T")
    [[ ${SHOW_WINDOW:-0} == 1 ]] || env+=(XDG_RUNTIME_DIR=/nonexistent)
    env "${env[@]}" "$ROOT/bin/usb-image-import.sh" "$C" >"$T/out.log" 2>&1
}
D="$T/dest/Imported Images/card_test"

echo "1. First import"
run; rc=$?
check "exit code 0"                       "[[ $rc -eq 0 ]]"
check "JPG copied"                        "[[ -f '$D/DCIM/100CANON/IMG_0001.JPG' ]]"
check "RAW (CR2) copied"                  "[[ -f '$D/DCIM/100CANON/IMG_0001.CR2' ]]"
check "HEIC in folder with space copied"  "[[ -f '$D/My Pics/beach day.heic' ]]"
check "text file skipped"                 "[[ ! -e '$D/notes.txt' ]]"
check "video skipped by default"          "[[ ! -e '$D/clip.MP4' ]]"
check "macOS ._ file skipped"             "[[ ! -e '$D/DCIM/._IMG_0001.JPG' ]]"
check "Trash folder skipped"              "[[ ! -e '$D/.Trashes' ]]"
check "import log written"                "grep -q 'found=3 copied=3' '$T/dest/Imported Images/import-log.txt'"

echo "2. Re-insert with one new photo"
head -c 1M /dev/urandom > "$C/DCIM/100CANON/IMG_0002.JPG"
run
check "only the new file copied"          "grep -q 'found=4 copied=1' '$T/dest/Imported Images/import-log.txt'"

echo "3. Videos enabled"
sed -i 's/^INCLUDE_VIDEOS=.*/INCLUDE_VIDEOS="yes"/' "$T/test.conf"
run
check "video copied when enabled"         "[[ -f '$D/clip.MP4' ]]"

echo "4. Interrupted import (SIGTERM, as when a drive is pulled)"
rm -rf "$T/dest"; sed -i 's/^INCLUDE_VIDEOS=.*/INCLUDE_VIDEOS="no"/' "$T/test.conf"
for i in 1 2 3 4 5 6; do head -c 3M /dev/urandom > "$C/DCIM/big$i.jpg"; done
slow=$T/slow.sh; sed 's/rsync -rt /rsync --bwlimit=2m -rt /' "$ROOT/bin/usb-image-import.sh" > "$slow"; chmod +x "$slow"
cp "$ROOT/lib/progress-window.py" "$T/"
( env USB_IMPORT_CONF="$T/test.conf" USB_IMPORT_LOCK="$T/lock" TEST_DEST_DIR="$T/dest" TMPDIR="$T" \
      XDG_RUNTIME_DIR=/nonexistent "$slow" "$C" >/dev/null 2>&1 ) & pid=$!
sleep 3; kill -TERM $pid 2>/dev/null; wait $pid; rc=$?
check "stopped with SIGTERM status"       "[[ $rc -eq 143 ]]"
check "lock released afterwards"          "flock -n '$T/lock' true"

echo "5. Lock does not leak into child processes"
check "mount/window commands close fd 9"  "grep -c '9>&-' '$ROOT/bin/usb-image-import.sh' | awk '{exit !(\$1>=5)}'"

echo "6. Syntax"
check "bash syntax"                       "bash -n '$ROOT/bin/usb-image-import.sh' && bash -n '$ROOT/install.sh'"
check "python compiles"                   "python3 -m py_compile '$ROOT/lib/progress-window.py'"

echo; echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
