#!/usr/bin/env python3
"""Progress window for usb-image-import.

Follows a status file that the import script appends to, one command per line:
    <number>        set progress percentage (0-100)
    # <text>        set the status line
    !title <text>   set the heading
    !done <text>    finished OK   (bar to 100%, button becomes Close)
    !error <text>   finished with an error
Cancel: creates --cancel-file (the import script watches for it). Exit code 10 if cancelled.
"""
import argparse
import sys

import gi
gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gio, GLib, Gtk  # noqa: E402

CANCEL_EXIT = 10
AUTO_CLOSE_SECONDS = 120


class ProgressWindow(Adw.ApplicationWindow):
    def __init__(self, app, args):
        super().__init__(application=app, title="USB Image Import",
                         default_width=500, resizable=False)
        self.app = app
        self.finished = False
        self.cancel_file = args.cancel_file
        self.buf = ""
        try:
            self.fh = open(args.file, "r", encoding="utf-8", errors="replace")
        except OSError as e:
            print(f"cannot open status file: {e}", file=sys.stderr)
            self.fh = None

        content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14,
                          margin_top=12, margin_bottom=20, margin_start=24, margin_end=24)

        top = Gtk.Box(spacing=16)
        self.icon = Gtk.Image.new_from_icon_name("drive-removable-media-symbolic")
        self.icon.set_pixel_size(48)
        self.heading = Gtk.Label(label=args.text, wrap=True, xalign=0, hexpand=True)
        self.heading.add_css_class("title-3")
        top.append(self.icon)
        top.append(self.heading)

        self.bar = Gtk.ProgressBar(show_text=True)
        self.bar.set_text("0%")

        self.status = Gtk.Label(label="Starting…", wrap=True, xalign=0)
        self.status.add_css_class("dim-label")

        self.button = Gtk.Button(label="Cancel", halign=Gtk.Align.END)
        self.button.add_css_class("pill")
        self.button.connect("clicked", self.on_button)

        for w in (top, self.bar, self.status, self.button):
            content.append(w)

        view = Adw.ToolbarView()
        view.add_top_bar(Adw.HeaderBar())
        view.set_content(content)
        self.set_content(view)

        self.connect("close-request", self.on_close_request)
        GLib.timeout_add(200, self.poll)

    # ---- input ----
    def poll(self):
        if self.fh is None:
            return False
        chunk = self.fh.read()
        if chunk:
            self.buf += chunk
            *lines, self.buf = self.buf.split("\n")
            for line in lines:
                self.handle(line.rstrip("\r"))
        return not self.finished

    def handle(self, line):
        if not line:
            return
        if line.startswith("#"):
            self.status.set_label(line[1:].strip())
        elif line.startswith("!title "):
            self.heading.set_label(line[7:])
        elif line.startswith("!done "):
            self.finish(line[6:], ok=True)
        elif line.startswith("!error "):
            self.finish(line[7:], ok=False)
        else:
            try:
                pct = max(0.0, min(100.0, float(line)))
            except ValueError:
                return
            self.bar.set_fraction(pct / 100)
            self.bar.set_text(f"{pct:.0f}%")

    # ---- states ----
    def finish(self, text, ok):
        self.finished = True
        self.heading.set_label(text)
        if ok:
            self.bar.set_fraction(1.0)
            self.bar.set_text("100%")
            self.icon.set_from_icon_name("emblem-ok-symbolic")
            self.icon.add_css_class("success")
        else:
            self.icon.set_from_icon_name("dialog-error-symbolic")
            self.icon.add_css_class("error")
        self.button.set_label("Close")
        self.button.add_css_class("suggested-action")
        GLib.timeout_add_seconds(AUTO_CLOSE_SECONDS, self.quit_with, 0)

    def request_cancel(self):
        if self.cancel_file:
            try:
                open(self.cancel_file, "w").close()
            except OSError as e:
                print(f"cannot write cancel file: {e}", file=sys.stderr)

    def on_button(self, _btn):
        if not self.finished:
            self.request_cancel()
        self.quit_with(0 if self.finished else CANCEL_EXIT)

    def on_close_request(self, _win):
        if not self.finished:
            self.request_cancel()
        self.app.exit_code = 0 if self.finished else CANCEL_EXIT
        return False  # allow close

    def quit_with(self, code):
        self.app.exit_code = code
        self.app.quit()
        return False


class App(Adw.Application):
    def __init__(self, args):
        super().__init__(application_id="local.usb-image-import.progress",
                         flags=Gio.ApplicationFlags.NON_UNIQUE)
        self.args = args
        self.exit_code = 0

    def do_activate(self):
        ProgressWindow(self, self.args).present()


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--file", required=True, help="status file to follow")
    p.add_argument("--cancel-file", help="file to create when the user cancels")
    p.add_argument("--text", default="Importing images…", help="initial heading")
    args = p.parse_args()
    app = App(args)
    app.run([sys.argv[0]])
    sys.exit(app.exit_code)


if __name__ == "__main__":
    main()
