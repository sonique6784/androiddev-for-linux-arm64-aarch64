#!/usr/bin/env python3
"""Create and select managed Android ARM64 virtual devices."""

import os
from pathlib import Path
import re
import shutil
import sys

from avd_image import REQUIRED, catalog, feed_for, install, usable_image


NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*\Z")


def check_name(name):
    if not NAME.fullmatch(name) or name in (".", "..") or len(name) > 100:
        raise ValueError("AVD name must be 1-100 ASCII letters, digits, dots, underscores, or hyphens, starting with a letter or digit")


def properties(path):
    return dict(line.split("=", 1) for line in path.read_text().splitlines() if "=" in line and not line.startswith("#"))


def avd_home(state):
    return state / "avd" / "home"


def avd_paths(state, name):
    home = avd_home(state)
    return home / f"{name}.avd", home / f"{name}.ini"


def ensure_switchable(state, name):
    running_name = (state / "avd" / "name").read_text().strip() if (state / "avd" / "name").is_file() else ""
    pid_file = state / "avd" / "pid"
    if running_name != name and pid_file.is_file():
        try:
            os.kill(int(pid_file.read_text().strip()), 0)
        except (ValueError, ProcessLookupError):
            pass
        else:
            raise ValueError(f"AVD {running_name} is running; stop it before selecting {name}")


def activate(state, sdk_root, name):
    ensure_switchable(state, name)
    directory, ini = avd_paths(state, name)
    if not directory.is_dir() or not ini.is_file() or directory.is_symlink() or ini.is_symlink():
        raise ValueError(f"No managed AVD named {name}")
    config = properties(directory / "config.ini")
    if config.get("AvdId") != name or config.get("abi.type") != "arm64-v8a" or config.get("hw.cpu.arch") != "arm64":
        raise ValueError(f"Invalid ARM64 AVD configuration: {directory / 'config.ini'}")
    sysdir = config.get("image.sysdir.1", "").strip("/")
    package = ";".join(sysdir.split("/"))
    feed_for(package)
    if not usable_image(sdk_root / sysdir):
        raise ValueError(f"System image for {name} is missing from {sdk_root / sysdir}")
    avd_state = state / "avd"
    avd_state.mkdir(parents=True, exist_ok=True)
    (avd_state / "name").write_text(name + "\n")
    (avd_state / "sdk-root").write_text(str(sdk_root) + "\n")
    (avd_state / "active-origin").write_text("created\n" if (directory / ".android-arm64-created").is_file() else "imported\n")
    (state / "emulator").write_text("avd\n")
    print(f"Selected AVD: {name}")


def create(state, sdk_root, name, package):
    check_name(name)
    feed_for(package)
    ensure_switchable(state, name)
    directory, ini = avd_paths(state, name)
    if directory.exists() or ini.exists() or directory.is_symlink() or ini.is_symlink():
        raise ValueError(f"AVD {name} already exists; choose a different name")
    parts = package.split(";")
    sysdir = "/".join(parts)
    image = sdk_root / sysdir
    if image.is_symlink():
        raise ValueError(f"System image directory must not be a symlink: {image}")
    if image.exists():
        if not image.is_dir():
            raise ValueError(f"System image path exists but is not a directory: {image}")
        if not all((image / part).is_file() for part in REQUIRED):
            missing = [part for part in REQUIRED if not (image / part).is_file()]
            raise ValueError(f"System image already exists but is incomplete at {image}; missing: {', '.join(missing)}. It was not downloaded or changed.")
        if not usable_image(image):
            raise ValueError(f"System image already exists at {image} but contains neither userdata.img nor a data directory. It was not downloaded or changed.")
        print(f"Using installed system image: {package}")
    else:
        if package not in {entry["id"] for entry in catalog(sdk_root)}:
            raise ValueError(f"Image {package} is neither installed nor in Google's current catalog")
        install(sdk_root, package, state / "cache" / "avd-images")
    if not usable_image(image):
        raise ValueError(f"Image {package} lacks the files required to create an AVD")

    home = avd_home(state)
    home.mkdir(parents=True, exist_ok=True)
    tag = parts[2]
    tag_id = "google_apis_playstore" if tag.startswith("google_apis_playstore") else "google_apis" if tag.startswith("google_apis") else "default"
    display = "Google Play" if tag_id == "google_apis_playstore" else "Google APIs" if tag_id == "google_apis" else "Android"
    config = "\n".join((
        "avd.ini.encoding=UTF-8", f"AvdId={name}", f"avd.ini.displayname={name}",
        f"PlayStore.enabled={'true' if tag_id == 'google_apis_playstore' else 'false'}",
        "abi.type=arm64-v8a", "hw.cpu.arch=arm64", "hw.cpu.ncore=4",
        "hw.device.manufacturer=Generic", "hw.device.name=medium_phone",
        "hw.gpu.enabled=yes", "hw.gpu.mode=auto", "hw.keyboard=yes",
        "hw.lcd.density=420", "hw.lcd.height=2400", "hw.lcd.width=1080",
        "hw.ramSize=2048", "vm.heapSize=228", "disk.dataPartition.size=10G",
        "showDeviceFrame=no", f"tag.id={tag_id}", f"tag.display={display}",
        f"image.sysdir.1={sysdir}/", f"target={parts[1]}", "",
    ))
    # Reserve the name before creating the directory. The exclusive open protects
    # an existing AVD's .ini even when two creation commands race.
    reserved = False
    try:
        with ini.open("x") as output:
            reserved = True
            output.write(f"avd.ini.encoding=UTF-8\npath={directory}\npath.rel={name}.avd\ntarget={parts[1]}\n")
        directory.mkdir()
        (directory / "config.ini").write_text(config)
        if (image / "userdata.img").is_file():
            shutil.copyfile(image / "userdata.img", directory / "userdata.img")
        (directory / ".android-arm64-created").write_text("1\n")
    except Exception:
        if reserved:
            ini.unlink(missing_ok=True)
        raise
    activate(state, sdk_root, name)
    print(f"Created {directory}. Start it with qemu-system-aarch64; the AVD backend uses KVM when available and TCG otherwise.")


def list_avds(state):
    home = avd_home(state)
    active = (state / "avd" / "name").read_text().strip() if (state / "avd" / "name").is_file() else ""
    for ini in sorted(home.glob("*.ini")) if home.is_dir() else []:
        name = ini.stem
        if NAME.fullmatch(name) and (home / f"{name}.avd" / "config.ini").is_file():
            print(f"{'*' if name == active else ' '} {name}")


if __name__ == "__main__":
    try:
        action, state_arg, sdk_arg, *args = sys.argv[1:]
        state, sdk = Path(state_arg), Path(sdk_arg)
        if action == "create" and len(args) == 2:
            create(state, sdk, *args)
        elif action == "select" and len(args) == 1:
            check_name(args[0])
            activate(state, sdk, args[0])
        elif action == "list" and not args:
            list_avds(state)
        else:
            raise ValueError("Usage: avd_manage.py create STATE SDK NAME PACKAGE | select STATE SDK NAME | list STATE SDK")
    except (OSError, ValueError) as error:
        sys.exit(f"AVD management: {error}")
