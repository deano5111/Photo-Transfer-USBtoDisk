#!/usr/bin/env bash
# Install / uninstall Photo-Transfer-USBtoDisk (usb-image-import).
#
#   sudo ./install.sh                     interactive: pick the destination drive from a list
#   sudo ./install.sh --dest /dev/sdb1    non-interactive
#   sudo ./install.sh --uninstall         remove everything except /etc/usb-image-import.conf
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo $0 $*"; exit 1; }
cd "$(dirname "$(readlink -f "$0")")"

CONF=/etc/usb-image-import.conf
BIN=/usr/local/bin/usb-image-import.sh
LIB=/usr/local/lib/usb-image-import
UNIT=/etc/systemd/system/usb-image-import@.service
RULE=/etc/udev/rules.d/99-usb-image-import.rules

reload() { systemctl daemon-reload; udevadm control --reload-rules; }

if [[ ${1:-} == --uninstall ]]; then
    rm -f "$BIN" "$UNIT" "$RULE"; rm -rf "$LIB"
    reload
    echo "Removed. Config kept at $CONF (delete it by hand if you no longer need it)."
    exit 0
fi

DEST_DEV=""
[[ ${1:-} == --dest ]] && DEST_DEV=${2:?--dest needs a device, e.g. /dev/sdb1}

# ---- Dependencies ----
missing=()
for c in rsync notify-send python3 file; do command -v "$c" >/dev/null || missing+=("$c"); done
python3 -c 'import gi; gi.require_version("Gtk","4.0"); gi.require_version("Adw","1")' 2>/dev/null \
    || missing+=("python3-gi + gir1.2-adw-1 (progress window)")
if ((${#missing[@]})); then
    echo "Missing: ${missing[*]}"
    echo "On Ubuntu/Debian: sudo apt install rsync libnotify-bin python3-gi gir1.2-gtk-4.0 gir1.2-adw-1 file"
    exit 1
fi

# ---- Files ----
install -m 755 bin/usb-image-import.sh "$BIN"
install -D -m 755 lib/progress-window.py "$LIB/progress-window.py"
install -m 644 systemd/usb-image-import@.service "$UNIT"
install -m 644 udev/99-usb-image-import.rules "$RULE"
[[ -e $CONF ]] || install -m 644 usb-image-import.conf "$CONF"

setconf() {  # setconf KEY VALUE — only fills keys that are empty
    grep -q "^$1=\"\"" "$CONF" && sed -i "s|^$1=\"\"|$1=\"$2\"|" "$CONF" && echo "  $1=\"$2\""
    return 0
}

# ---- Desktop user ----
USER_NAME=${SUDO_USER:-}
[[ -n $USER_NAME && $USER_NAME != root ]] || read -rp "Desktop user who should see the progress window: " USER_NAME
id "$USER_NAME" >/dev/null || { echo "No such user: $USER_NAME"; exit 1; }

# ---- Destination drive ----
source "$CONF"
if [[ -z ${DEST_UUID:-} ]]; then
    if [[ -z $DEST_DEV ]]; then
        echo; echo "Connected drives with a filesystem (internal system disk excluded):"
        printf '  %-16s %-8s %-6s %-14s %s\n' DEVICE SIZE FS LABEL MOUNTED
        field() { [[ $line =~ (^|[[:space:]])$1=\"([^\"]*)\" ]] && printf '%b' "${BASH_REMATCH[2]}"; }
        while read -r line; do   # lsblk -P: NAME="..." SIZE="..." ... (parsed without eval; labels are untrusted)
            NAME=$(field NAME); SIZE=$(field SIZE); FSTYPE=$(field FSTYPE)
            LABEL=$(field LABEL); MOUNTPOINT=$(field MOUNTPOINT); TYPE=$(field TYPE)
            [[ $TYPE == part || $TYPE == disk ]] && [[ -n $FSTYPE && $FSTYPE != swap ]] || continue
            [[ $MOUNTPOINT == / || $MOUNTPOINT == /boot* ]] && continue
            printf '  %-16s %-8s %-6s %-14s %s\n' "$NAME" "$SIZE" "$FSTYPE" "${LABEL:--}" "${MOUNTPOINT:--}"
        done < <(lsblk -pnPo NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT,TYPE -e 7)
        echo
        read -rp "Device to copy photos TO (e.g. /dev/sdb1): " DEST_DEV
    fi
    [[ -b $DEST_DEV ]] || { echo "$DEST_DEV is not a block device"; exit 1; }
    UUID=$(blkid -s UUID -o value "$DEST_DEV")
    [[ -n $UUID ]] || { echo "$DEST_DEV has no filesystem UUID"; exit 1; }
fi

echo "Config ($CONF):"
setconf TARGET_USER "$USER_NAME"
[[ -n ${UUID:-} ]] && setconf DEST_UUID "$UUID"

reload
echo
echo "Installed. Insert a USB stick or SD card to import its photos."
echo "Logs:   journalctl -u 'usb-image-import@*' -f"
echo "Config: $CONF"
