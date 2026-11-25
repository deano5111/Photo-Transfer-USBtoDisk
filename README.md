# Photo-Transfer-USBtoDisk

Do you have USB sticks or SD cards all over the place with photos on them? This little app detects the disk when you plug it in and transfers the photos (and optionally videos) to another drive automatically, with a progress window. No clicking, no dragging folders.

Built for Linux desktops (tested on Ubuntu 26.04 / GNOME on Wayland).

```
┌─ USB Image Import ───────────────────────────────┐
│  🖴  Importing 248 images from CANON_SD           │
│  ██████████████░░░░░░░░░░░░░░░░░░░  45%          │
│  45% • 112 new files copied (of 248 found)       │
│        • 38.2MB/s • 0:01:10 left                 │
│                                       [ Cancel ] │
└──────────────────────────────────────────────────┘
```

## What it does

1. **Detects** a USB stick or SD card being inserted (udev rule → systemd service).
2. **Mounts it read-only.** Nothing on the card is ever changed or deleted.
3. **Finds images:** JPG, PNG, HEIC/HEIF, WebP, AVIF, TIFF, GIF, BMP and camera RAW (Canon CR2/CR3, Nikon NEF, Sony ARW, Fuji RAF, Olympus ORF, Panasonic RW2, DNG and more). Videos are optional. System clutter such as `.Trashes`, `System Volume Information` and macOS `._` files is skipped.
4. **Copies them** to `Imported Images/<card label>_<card ID>/` on your destination drive, keeping the card's folder layout and the original file dates.
5. **Only copies what's new.** Insert the same card again and only photos added since last time are copied.
6. **Shows a progress window** with speed, time remaining and a Cancel button. It ends with "Import complete — safe to remove".

## Install

```bash
sudo apt install rsync libnotify-bin python3-gi gir1.2-gtk-4.0 gir1.2-adw-1 file
git clone https://github.com/deano5111/Photo-Transfer-USBtoDisk.git
cd Photo-Transfer-USBtoDisk
sudo ./install.sh
```

The installer lists your connected drives and asks which one the photos should go **to**:

```
Connected drives with a filesystem (internal system disk excluded):
  DEVICE           SIZE     FS     LABEL          MOUNTED
  /dev/sda1        465.8G   ntfs   Elements       -
  /dev/sdb1        57.7G    vfat   CANON_SD       /media/me/CANON_SD

Device to copy photos TO (e.g. /dev/sdb1): /dev/sda1
```

It stores that drive's UUID, so the drive is recognised whichever port it's plugged into. For a non-interactive install, use `sudo ./install.sh --dest /dev/sda1`.

To uninstall: `sudo ./install.sh --uninstall`

## Configuration

Edit `/etc/usb-image-import.conf`:

| Setting | Default | Meaning |
|---|---|---|
| `DEST_UUID` | *(set by installer)* | Filesystem UUID of the destination drive |
| `DEST_SUBDIR` | `Imported Images` | Folder on the destination drive |
| `TARGET_USER` | *(set by installer)* | Desktop user who sees the window and owns the copied files |
| `IMAGE_EXTS` | common photo + RAW types | File extensions to import |
| `INCLUDE_VIDEOS` | `no` | Set to `yes` to also copy `VIDEO_EXTS` |
| `IGNORE_SERIALS` | *(empty)* | USB serial numbers to never import, e.g. a failing stick you're rescuing |
| `DEST_MOUNTPOINT` | `/mnt/image-dest` | Where the destination is mounted if it isn't already |

## How it works

```
USB/SD inserted
   └─ udev rule (99-usb-image-import.rules)
        └─ systemd: usb-image-import@sdb1.service
             └─ usb-image-import.sh sdb1
                  ├─ mount card read-only        (systemd-mount)
                  ├─ mount destination drive     (systemd-mount; ntfs3, falls back to ntfs-3g)
                  ├─ find images → rsync --ignore-existing
                  ├─ progress window             (systemd-run --user → progress-window.py, GTK4/libadwaita)
                  └─ unmount destination, append to Imported Images/import-log.txt
```

| File | Installed to |
|---|---|
| `bin/usb-image-import.sh` | `/usr/local/bin/` |
| `lib/progress-window.py` | `/usr/local/lib/usb-image-import/` |
| `systemd/usb-image-import@.service` | `/etc/systemd/system/` |
| `udev/99-usb-image-import.rules` | `/etc/udev/rules.d/` |
| `usb-image-import.conf` | `/etc/` (not overwritten on reinstall) |

### Robustness

- **One import at a time.** Insert two cards and the second waits its turn. The lock has a 2-hour timeout and is never inherited by long-lived helpers such as the ntfs-3g daemon or the window.
- **Drive pulled mid-copy:** the window switches to "Import interrupted". Reinsert the drive to resume; files already copied are kept.
- **Destination busy at the end** (for example, a file manager window is open on it): the script retries, logs which process is holding it, and tells you to close it and eject.
- **Worn sticks with unreadable sectors:** if `blkid` can't identify the filesystem, the script reads the boot sector itself, imports anyway and warns you that the drive is failing.

## Troubleshooting

```bash
journalctl -u 'usb-image-import@*' -f          # live log
systemctl list-units 'usb-image-import@*'      # running / failed imports
cat "/path/to/drive/Imported Images/import-log.txt"
```

| Symptom | Cause / fix |
|---|---|
| "ntfs3 refused (drive marked dirty?)" | The NTFS drive was unplugged without ejecting. It still works through ntfs-3g, which is slower. Run `chkdsk X: /f` on Windows to clear it. |
| "Destination drive still mounted" | Close any file-manager windows showing the drive, then eject it. |
| Nothing happens on insert | Check `journalctl -u 'usb-image-import@*'`. Is the drive's serial in `IGNORE_SERIALS`? |
| No progress window | Notifications are used instead when no graphical session is found. Check that `TARGET_USER` is the logged-in desktop user. |

## Tests

These run as a normal user and need no root or real drives:

```bash
./tests/run-tests.sh                 # SHOW_WINDOW=1 to watch the progress window
```

They cover file-type filtering, skipping system files, re-insert deduplication, the video option, interrupted imports, lock release, and syntax checks.

## License

[MIT](LICENSE)
