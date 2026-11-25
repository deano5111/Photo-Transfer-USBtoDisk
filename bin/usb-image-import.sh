#!/usr/bin/env bash
# usb-image-import — copy all images from a newly inserted USB/SD device to a destination drive.
# Invoked by systemd (usb-image-import@<kernel-name>.service) via a udev rule.
#   Usage: usb-image-import.sh sdb1 | mmcblk0p1 | /path/to/dir (test mode)
set -uo pipefail

CONF=${USB_IMPORT_CONF:-/etc/usb-image-import.conf}
[[ -r $CONF ]] && source "$CONF"
: "${DEST_UUID:?DEST_UUID not set}" "${DEST_SUBDIR:=Imported Images}" "${DEST_MOUNTPOINT:=/mnt/image-dest}"
: "${TARGET_USER:=root}" "${INCLUDE_VIDEOS:=no}" "${SETTLE_SECONDS:=5}"

ARG=${1:?usage: $0 <kernel-device-name|directory>}
RUN_ID="$(basename "$ARG")-$$"
TUID=$(id -u "$TARGET_USER" 2>/dev/null || echo 0)
TGID=$(id -g "$TARGET_USER" 2>/dev/null || echo 0)

log() { echo "[usb-image-import] $*"; }

# Run a command as TARGET_USER (directly if we already are that user — test mode)
as_user() { if [[ $EUID -eq 0 ]]; then runuser -u "$TARGET_USER" -- "$@"; else "$@"; fi; }
# systemctl/systemd-run against TARGET_USER's user manager
user_sd() { local tool=$1; shift
    if [[ $EUID -eq 0 ]]; then "$tool" --user -M "$TARGET_USER@" "$@"; else "$tool" --user "$@"; fi; }

notify() {  # desktop notification to TARGET_USER's session (best effort)
    [[ -S /run/user/$TUID/bus ]] || return 0
    as_user env DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$TUID/bus" \
        notify-send -a "USB Image Import" -i drive-removable-media "$1" "${2:-}" 9>&- 2>/dev/null || true
}

# ---- Per-run working dir (status file for the window, cancel flag written by the window) ----
WORK=$(mktemp -d "${TMPDIR:-/tmp}/usb-image-import.XXXXXX")
chown "$TUID:$TGID" "$WORK" 2>/dev/null; chmod 755 "$WORK"
STATUSF=$WORK/status; CANCELF=$WORK/cancel; LIST=$WORK/files; STATSF=$WORK/stats
: > "$STATUSF"; chmod 644 "$STATUSF"

# ---- Progress window: runs as its own unit in the user's session (outside this service) ----
HERE="$(dirname "$(readlink -f "$0")")"
WIN_PY=/usr/local/lib/usb-image-import/progress-window.py
for c in "$HERE/progress-window.py" "$HERE/../lib/progress-window.py"; do  # dev/test copies win
    [[ -f $c ]] && { WIN_PY=$c; break; }
done
WIN_UNIT=""
start_window() {  # $1 = heading text
    local wl
    wl=$(ls "/run/user/$TUID/" 2>/dev/null | grep -m1 -E '^wayland-[0-9]+$')
    [[ -f $WIN_PY && ( -n $wl || -S /tmp/.X11-unix/X0 ) ]] || return 0
    local unit="usb-image-import-window-$RUN_ID"
    if user_sd systemd-run --quiet --collect --unit="$unit" \
            ${wl:+-E WAYLAND_DISPLAY=$wl} -E DISPLAY=:0 \
            python3 "$WIN_PY" --file "$STATUSF" --cancel-file "$CANCELF" --text "$1" 9>&- 2>/dev/null; then
        WIN_UNIT=$unit
    else
        log "Could not open progress window (no user session?) — using notifications"
    fi
}
window_up() { [[ -n $WIN_UNIT ]] && user_sd systemctl is-active --quiet "$WIN_UNIT" 2>/dev/null; }
status()    { printf '%s\n' "$@" >> "$STATUSF"; }
finish_ok() { FINISHED=1; if window_up; then status "# $2" "!done $1"; else notify "$1" "$2"; fi; }
die() {
    log "ERROR: $*"
    if window_up; then status "# $*" "!error Image import failed"; else notify "Image import failed" "$*"; fi
    exit 1
}

# ---- Cleanup ----
OUR_SRC_MOUNT=""; OUR_DEST_MOUNT=""; WATCH_PID=""
unmount_retry() {  # $1 mountpoint — retries while busy, logs who is using it if it gives up
    local mp=$1 i err
    sync
    for i in 1 2 3 4 5; do
        err=$(umount "$mp" 2>&1 9>&-) && { log "Unmounted $mp"; return 0; }
        sleep 2
    done
    log "WARNING: could not unmount $mp: $err"
    log "In use by: $(fuser -vm "$mp" 2>&1 | tail -n +2 | tr -s ' ' | head -5)"
    return 1
}
FINISHED=""
cleanup() {
    [[ -n $WATCH_PID ]] && kill "$WATCH_PID" 2>/dev/null
    if [[ -z $FINISHED && -n $WIN_UNIT ]] && ! tail -1 "$STATUSF" 2>/dev/null | grep -q '^!'; then
        status "# Stopped before finishing (drive removed or read error). Reinsert to resume — already-copied files are kept." \
               "!error Import interrupted"
    fi
    [[ -n $OUR_SRC_MOUNT ]] && { unmount_retry "$OUR_SRC_MOUNT" && rmdir "$OUR_SRC_MOUNT" 2>/dev/null; }
    if [[ -n $OUR_DEST_MOUNT ]] && ! unmount_retry "$OUR_DEST_MOUNT"; then
        notify "Destination drive still mounted" "Close any windows using $OUR_DEST_MOUNT, then eject it before unplugging."
    fi
    rm -f "$LIST" "$STATSF"   # status file is left for the window; WORK dir is tiny and in /tmp
}
trap cleanup EXIT
trap 'exit 143' TERM   # systemd stops us with SIGTERM when the drive is pulled; run cleanup

# ---- One import at a time (two cards inserted together queue up; never wait forever) ----
exec 9>"${USB_IMPORT_LOCK:-/run/usb-image-import.lock}"
flock -w 7200 9 || die "another import has been running for 2 hours — giving up"

mount_opts_for() {  # $1=fstype $2=ro|rw -> mount options giving TARGET_USER ownership where relevant
    local o="$2,nosuid,nodev,noexec"
    case $1 in vfat|exfat|ntfs|ntfs3|ntfs-3g) o+=",uid=$TUID,gid=$TGID" ;; esac
    echo "$o"
}
# Mount via systemd so long-lived helpers (e.g. the ntfs-3g FUSE daemon) live in their own
# mount unit — not in this service, and without inheriting our lock.
sd_mount() {  # $1 fstype $2 options $3 device $4 mountpoint
    if command -v systemd-mount >/dev/null && [[ $EUID -eq 0 ]]; then
        systemd-mount --no-ask-password --collect -t "$1" -o "$2" "$3" "$4" 9>&- 2>&1
    else
        mount -t "$1" -o "$2" "$3" "$4" 9>&- 2>&1
    fi
}

# ---------- Source ----------
if [[ -d $ARG ]]; then                      # test mode: treat argument as an already-mounted source
    SRC=$ARG; SRC_UUID=test; SRC_LABEL=$(basename "$ARG")
else
    DEV=/dev/$ARG
    [[ -b $DEV ]] || die "$DEV is not a block device"
    USB_SERIAL=$(udevadm info -q property -n "$DEV" | sed -n 's/^ID_SERIAL_SHORT=//p')
    for s in ${IGNORE_SERIALS:-}; do
        [[ $USB_SERIAL == "$s" ]] && { log "$DEV (serial $USB_SERIAL) is on the ignore list, skipping"; exit 0; }
    done
    SRC_UUID=$(blkid -s UUID -o value "$DEV")
    SRC_LABEL=$(blkid -s LABEL -o value "$DEV")
    SRC_FS=$(blkid -s TYPE -o value "$DEV")
    if [[ -z $SRC_FS ]]; then
        # blkid can fail when a worn stick has unreadable sectors at the end (it probes there for
        # RAID/GPT signatures). Fall back to reading the boot sector ourselves.
        BOOT=$(file -bs "$DEV" 2>/dev/null)
        case $BOOT in
            *"FAT (32 bit)"*|*"FAT (16 bit)"*|*"FAT (12 bit)"*) SRC_FS=vfat ;;
            *exFAT*) SRC_FS=exfat ;;
            *NTFS*)  SRC_FS=ntfs3 ;;
            *) log "$DEV has no recognisable filesystem (${BOOT:-unreadable}), skipping"; exit 0 ;;
        esac
        [[ $BOOT =~ label:\ \"([^\"]*)\" ]] && SRC_LABEL=$(sed 's/ *$//' <<<"${BASH_REMATCH[1]}")
        if [[ $BOOT =~ serial\ number\ 0x([0-9a-fA-F]{8}) ]]; then
            h=${BASH_REMATCH[1]^^}; SRC_UUID="${h:0:4}-${h:4:4}"          # same format blkid uses for FAT
        else
            SRC_UUID=$USB_SERIAL
        fi
        log "WARNING: blkid could not probe $DEV (drive may be failing) — boot sector says $SRC_FS"
        notify "Drive has read errors" "${SRC_LABEL:-$DEV} has unreadable sectors. Importing anyway — back it up and replace it."
    fi
    [[ $SRC_UUID == "$DEST_UUID" ]] && { log "$DEV is the destination drive, skipping"; exit 0; }
    log "Detected $DEV  fs=$SRC_FS label='${SRC_LABEL}' uuid=$SRC_UUID"

    # Give the desktop a moment to auto-mount; reuse its mount if present
    SRC=""
    for ((i=0; i<SETTLE_SECONDS; i++)); do
        SRC=$(findmnt -nr -o TARGET -S "$DEV" | head -1); [[ -n $SRC ]] && break; sleep 1
    done
    if [[ -z $SRC ]]; then
        MP=/run/usb-image-import/$ARG; mkdir -p "$MP"
        out=$(sd_mount "$SRC_FS" "$(mount_opts_for "$SRC_FS" ro)" "$DEV" "$MP") \
          || out=$(sd_mount auto ro "$DEV" "$MP") || die "could not mount $DEV: $out"
        OUR_SRC_MOUNT=$MP
        SRC=$(findmnt -nr -o TARGET -S "$DEV" | head -1)   # unescaped path
    fi
    SRC=$(printf '%b' "$SRC")   # findmnt -r escapes spaces etc. as \x20
fi
log "Source mounted at $SRC"

# ---------- Destination ----------
if [[ -n ${TEST_DEST_DIR:-} ]]; then
    DEST_ROOT=$TEST_DEST_DIR                                   # test mode
else
    DEST_DEV=$(blkid -U "$DEST_UUID") || die "destination drive (UUID $DEST_UUID) is not connected"
    DEST_ROOT=$(findmnt -nr -o TARGET -S "$DEST_DEV" | head -1)
    DEST_ROOT=$(printf '%b' "$DEST_ROOT")
    if [[ $DEST_ROOT == "$DEST_MOUNTPOINT" ]]; then
        OUR_DEST_MOUNT=$DEST_MOUNTPOINT                        # left over from an earlier run: tidy it up after
    elif [[ -z $DEST_ROOT ]]; then
        DEST_FS=$(blkid -s TYPE -o value "$DEST_DEV")
        mkdir -p "$DEST_MOUNTPOINT"
        if [[ $DEST_FS == ntfs ]]; then
            out=$(sd_mount ntfs3 "$(mount_opts_for ntfs3 rw)" "$DEST_DEV" "$DEST_MOUNTPOINT") \
              || { log "ntfs3 refused (drive marked dirty?) — trying ntfs-3g"
                   out=$(sd_mount ntfs-3g "$(mount_opts_for ntfs-3g rw)" "$DEST_DEV" "$DEST_MOUNTPOINT"); } \
              || die "could not mount destination: $out"
        else
            out=$(sd_mount "$DEST_FS" "$(mount_opts_for "$DEST_FS" rw)" "$DEST_DEV" "$DEST_MOUNTPOINT") \
              || die "could not mount destination: $out"
        fi
        OUR_DEST_MOUNT=$DEST_MOUNTPOINT; DEST_ROOT=$DEST_MOUNTPOINT
        log "Mounted destination at $DEST_ROOT"
    fi
    findmnt -nr -o OPTIONS "$DEST_ROOT" | grep -qw ro && die "destination is mounted read-only"
fi

# One folder per source device, so reinserting the same card only copies new photos
NAME=${SRC_LABEL:-NO_LABEL}; NAME=${NAME//[^A-Za-z0-9._-]/_}
DEST="$DEST_ROOT/$DEST_SUBDIR/${NAME}_${SRC_UUID}"
mkdir -p "$DEST" || die "cannot create $DEST"

# ---------- Find images ----------
EXTS=$IMAGE_EXTS; [[ $INCLUDE_VIDEOS == yes ]] && EXTS+=" $VIDEO_EXTS"
name_expr=(); for e in $EXTS; do name_expr+=(-o -iname "*.$e"); done; name_expr=("${name_expr[@]:1}")

( cd "$SRC" && find . \
    \( -name '.Trash*' -o -name '.Spotlight-V100' -o -name '.fseventsd' -o -name 'System Volume Information' \
       -o -name '$RECYCLE.BIN' -o -name '.thumbnails' \) -prune -o \
    -type f ! -name '._*' \( "${name_expr[@]}" \) -print0 ) > "$LIST"

COUNT=$(tr -cd '\0' < "$LIST" | wc -c)
log "Found $COUNT image file(s)"
if (( COUNT == 0 )); then notify "No images found" "${SRC_LABEL:-device} — nothing to copy"; exit 0; fi
start_window "Importing $COUNT images from ${SRC_LABEL:-device}"
status "# Copying to $DEST_SUBDIR/${NAME}_${SRC_UUID}"

# ---------- Copy ----------
# Watch for the window's Cancel button (it creates $CANCELF) and stop rsync if pressed
( while sleep 0.5; do [[ -e $CANCELF ]] && { pkill -f -- "files-from=$LIST"; exit 0; }; done ) 9>&- &
WATCH_PID=$!

# rsync's overall progress -> window commands (percent line + status line); everything else -> stats file
rsync -rt --ignore-existing --from0 --files-from="$LIST" --info=progress2 --stats "$SRC/" "$DEST/" 2>&1 \
  | stdbuf -o0 tr '\r' '\n' \
  | awk -v stats="$STATSF" -v total="$COUNT" -v out="$STATUSF" '
      / [0-9]+% / && /\/s/ {
          match($0, /[0-9]+%/); p = substr($0, RSTART, RLENGTH-1) + 0
          x = 0; if (match($0, /xfr#[0-9]+/)) x = substr($0, RSTART+4, RLENGTH-4)
          printf "%d\n# %d new files copied (of %d found)  •  %s  •  %s left\n", p, x, total, $3, $4 >> out
          fflush(out); next }
      NF { print > stats }'
RC=${PIPESTATUS[0]}
kill "$WATCH_PID" 2>/dev/null; WATCH_PID=""
STATS=$(cat "$STATSF" 2>/dev/null)
sync

if [[ -e $CANCELF ]]; then
    log "Cancelled by user"; notify "Image import cancelled" "Files copied so far were kept; reinsert to resume."
    exit 0
fi

COPIED=$(awk -F': ' '/Number of regular files transferred/ {gsub(/,/,"",$2); print $2}' <<<"$STATS")
SIZE=$(awk -F': ' '/Total transferred file size/ {print $2}' <<<"$STATS" | cut -d' ' -f1)
echo "$(date '+%F %T')  src='${SRC_LABEL}' uuid=$SRC_UUID found=$COUNT copied=${COPIED:-?} rc=$RC" >> "$DEST_ROOT/$DEST_SUBDIR/import-log.txt"

if (( RC == 0 )); then
    log "Done: copied ${COPIED:-0} new file(s) (${SIZE:-0} bytes) to $DEST"
    finish_ok "Import complete — safe to remove ${SRC_LABEL:-device}" "Copied ${COPIED:-0} new of $COUNT images to $DEST_SUBDIR/${NAME}_${SRC_UUID}"
else
    log "$STATS"; die "rsync exited with code $RC — some files may not have copied"
fi
