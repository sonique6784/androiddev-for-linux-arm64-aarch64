#!/usr/bin/env python3
"""Terminal image picker; all AVD operations go through setup-android-arm64.sh."""

import curses
import json
import subprocess
import sys


def choose(screen, images):
    curses.curs_set(0)
    selected = offset = 0
    while True:
        screen.erase()
        height, width = screen.getmaxyx()
        if height < 7 or width < 45:
            screen.addnstr(0, 0, "Enlarge this terminal to choose an image.", max(1, width - 1))
            screen.refresh()
            if screen.getch() in (ord("q"), 27):
                return None
            continue
        screen.addnstr(0, 0, "Create Android ARM64 AVD", width - 1, curses.A_BOLD)
        screen.addnstr(1, 0, "Arrows/j/k: move   Enter: select   q: quit", width - 1)
        visible = height - 5
        offset = min(offset, selected)
        offset = max(offset, selected - visible + 1)
        for row, image in enumerate(images[offset:offset + visible], 3):
            status = "installed" if image["installed"] else f"download {image['download_size'] / 1024**3:.2f} GiB"
            label = f"{image['id']}  [{status}]"
            screen.addnstr(row, 0, label, width - 1, curses.A_REVERSE if offset + row - 3 == selected else 0)
        screen.addnstr(height - 1, 0, f"{selected + 1}/{len(images)}", width - 1)
        screen.refresh()
        key = screen.getch()
        if key in (ord("q"), 27):
            return None
        if key in (curses.KEY_DOWN, ord("j")):
            selected = min(selected + 1, len(images) - 1)
        elif key in (curses.KEY_UP, ord("k")):
            selected = max(selected - 1, 0)
        elif key in (10, 13, curses.KEY_ENTER):
            screen.erase()
            screen.addnstr(0, 0, images[selected]["id"], width - 1, curses.A_BOLD)
            screen.addnstr(2, 0, "New AVD name (blank cancels): ", width - 1)
            screen.refresh()
            curses.echo()
            curses.curs_set(1)
            try:
                name = screen.getstr(2, 30, min(100, width - 31)).decode("utf-8").strip()
            finally:
                curses.noecho()
                curses.curs_set(0)
            return (name, images[selected]["id"]) if name else None


def main(launcher, sdk_root):
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        raise ValueError("The AVD picker requires an interactive terminal")
    command = [launcher, "--sdk-root", sdk_root]
    print("Loading available Android ARM64 images...", flush=True)
    result = subprocess.run(command + ["--avd-list-images", "--json"], capture_output=True, text=True)
    if result.returncode:
        raise ValueError(result.stderr.strip() or "Unable to list Android images")
    if result.stderr.strip():
        print(result.stderr.strip(), file=sys.stderr)
    images = json.loads(result.stdout)
    if not images:
        print("No ARM64 Android images are available.")
        return 1
    choice = curses.wrapper(choose, images)
    if choice is None:
        print("AVD creation cancelled.")
        return 0
    name, package = choice
    return subprocess.run(command + ["--avd-create", name, "--avd-image", package]).returncode


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1], sys.argv[2]))
    except KeyboardInterrupt:
        sys.exit(130)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        sys.exit(f"AVD picker: {error}")
