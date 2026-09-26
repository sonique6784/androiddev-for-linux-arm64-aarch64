#!/usr/bin/env python3
"""Fetch one Android system image from Google's published SDK metadata."""

import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import sys
import tempfile
import urllib.parse
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
import zipfile


REPOSITORY = "https://dl.google.com/android/repository/"
FEEDS = ("android", "google_apis", "google_apis_playstore")
REQUIRED = ("kernel-ranchu", "ramdisk.img", "system.img", "vendor.img")


def usable_image(directory):
    return (
        directory.is_dir()
        and all((directory / part).is_file() for part in REQUIRED)
        and ((directory / "userdata.img").is_file() or (directory / "data").is_dir())
    )


def local_name(element):
    return element.tag.rsplit("}", 1)[-1]


def descendant(element, name):
    return next((item for item in element.iter() if local_name(item) == name), None)


def text_of(element, name):
    item = descendant(element, name)
    return item.text.strip() if item is not None and item.text else None


def feed_for(package):
    parts = package.split(";")
    if len(parts) != 4 or parts[0] != "system-images" or parts[3] != "arm64-v8a" or any(
        not re.fullmatch(r"[A-Za-z0-9._-]+", part) or part in (".", "..") for part in parts
    ):
        raise ValueError(f"Unsupported system image package {package!r}")
    variant = parts[2]
    if variant.startswith("google_apis_playstore"):
        return "google_apis_playstore"
    if variant.startswith("google_apis"):
        return "google_apis"
    if variant == "default":
        return "android"
    raise ValueError(f"No known Google SDK feed for AVD image variant {variant!r}")


def feed_packages(feed):
    feed_url = urllib.parse.urljoin(REPOSITORY, f"sys-img/{feed}/sys-img2-2.xml")
    with urllib.request.urlopen(feed_url, timeout=30) as response:
        return feed_url, [item for item in ET.fromstring(response.read()).iter() if local_name(item) == "remotePackage"]


def archive_details(package, feed_url):
    archives = [item for item in package.iter() if local_name(item) == "archive"]
    for archive in archives:
        host = text_of(archive, "host-os")
        if host not in (None, "linux"):
            continue
        complete = descendant(archive, "complete")
        if complete is None:
            continue
        filename = text_of(complete, "url")
        checksum = descendant(complete, "checksum")
        size = text_of(complete, "size")
        if not filename or checksum is None or not checksum.text or checksum.get("type") not in ("sha1", "sha256") or not size or not size.isdigit():
            continue
        if PurePosixPath(filename).name != filename:
            raise ValueError("Unexpected SDK archive URL in Google metadata")
        return urllib.parse.urljoin(feed_url, filename), checksum.get("type"), checksum.text.strip(), int(size)
    return None


def package_archive(package):
    feed_url, packages = feed_packages(feed_for(package))
    for item in packages:
        if item.get("path") == package:
            details = archive_details(item, feed_url)
            if details:
                return details
    raise ValueError(f"Google's current SDK repository has no usable archive for {package}")


def installed_images(sdk_root):
    result = {}
    base = sdk_root / "system-images"
    if not base.is_dir():
        return result
    for directory in base.glob("*/*/arm64-v8a"):
        if directory.is_symlink() or os.path.commonpath((directory.resolve(), sdk_root.resolve())) != str(sdk_root.resolve()) or not usable_image(directory):
            continue
        parts = directory.relative_to(sdk_root).parts
        package = ";".join(parts)
        try:
            feed_for(package)
        except ValueError:
            continue
        result[package] = {"id": package, "installed": True, "download_size": None}
    return result


def catalog(sdk_root):
    images = installed_images(sdk_root)
    failures = []
    for feed in FEEDS:
        try:
            feed_url, packages = feed_packages(feed)
            for item in packages:
                package = item.get("path", "")
                try:
                    if feed_for(package) != feed:
                        continue
                except ValueError:
                    continue
                details = archive_details(item, feed_url)
                if details and package not in images:
                    images[package] = {"id": package, "installed": False, "download_size": details[3]}
        except (OSError, ET.ParseError, urllib.error.URLError, ValueError) as error:
            failures.append(f"{feed}: {error}")
    if failures:
        print("AVD image catalog: could not read " + "; ".join(failures), file=sys.stderr)
    if not images and failures:
        raise ValueError("No installed images and remote image catalog is unavailable")
    return sorted(images.values(), key=lambda image: image["id"], reverse=True)


def list_images(sdk_root, as_json):
    images = catalog(sdk_root)
    if as_json:
        print(json.dumps(images))
    else:
        for image in images:
            status = "installed" if image["installed"] else f"download {image['download_size'] / 1024**3:.2f} GiB"
            print(f"{image['id']}  [{status}]")
        if not images:
            print("No ARM64 Android images are available.")


def cached_archive(cache_dir, url, algorithm, expected, expected_size):
    if not re.fullmatch(r"[0-9a-fA-F]+", expected):
        raise ValueError("Google SDK metadata contains an invalid archive checksum")
    name = PurePosixPath(urllib.parse.urlparse(url).path).name
    if not name or name in (".", ".."):
        raise ValueError("Google SDK metadata contains an invalid archive filename")
    cache_dir.mkdir(parents=True, exist_ok=True)
    cache_path = cache_dir / f"{name}.{algorithm}-{expected.lower()}.zip"
    if cache_path.is_symlink():
        raise ValueError(f"Refusing symlink in SDK image cache: {cache_path}")
    if cache_path.is_file():
        digest = hashlib.new(algorithm)
        size = 0
        with cache_path.open("rb") as archive:
            while chunk := archive.read(1024 * 1024):
                digest.update(chunk)
                size += len(chunk)
        if size == expected_size and digest.hexdigest().lower() == expected.lower():
            print(f"Using cached SDK image archive: {cache_path}", flush=True)
            return cache_path
        print(f"Discarding invalid cached SDK image archive: {cache_path}", file=sys.stderr)
        cache_path.unlink()
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(prefix=f".{name}.", suffix=".partial", dir=cache_dir, delete=False) as output:
            temporary = Path(output.name)
            digest = hashlib.new(algorithm)
            size = 0
            print(f"Downloading {url}", flush=True)
            with urllib.request.urlopen(url, timeout=60) as response:
                while chunk := response.read(1024 * 1024):
                    output.write(chunk)
                    digest.update(chunk)
                    size += len(chunk)
        if size != expected_size or digest.hexdigest().lower() != expected.lower():
            raise ValueError("Downloaded SDK image size or checksum does not match Google's metadata")
        os.replace(temporary, cache_path)
        return cache_path
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def install(sdk_root, package, cache_dir=None):
    feed_for(package)
    parts = package.split(";")
    destination = sdk_root.joinpath(*parts)
    if destination.exists():
        raise ValueError(f"Incomplete system image directory already exists: {destination}; inspect it before retrying")
    url, algorithm, expected, expected_size = package_archive(package)
    if cache_dir is None:
        cache_dir = sdk_root.parent / "cache" / "avd-images"
    archive_path = cached_archive(Path(cache_dir), url, algorithm, expected, expected_size)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".avd-image-", dir=destination.parent) as temporary:
        extracted = Path(temporary) / "extracted"
        extracted.mkdir()
        with zipfile.ZipFile(archive_path) as archive:
            files = [member for member in archive.infolist() if not member.is_dir()]
            prefix = f"{parts[3]}/" if files and all(member.filename.startswith(f"{parts[3]}/") for member in files) else ""
            for member in files:
                relative = PurePosixPath(member.filename.removeprefix(prefix))
                if relative.is_absolute() or ".." in relative.parts or not relative.parts:
                    raise ValueError(f"Unsafe path in SDK image archive: {member.filename}")
                target = extracted.joinpath(*relative.parts)
                target.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(member) as source, target.open("wb") as output:
                    shutil.copyfileobj(source, output)
        for required in REQUIRED:
            if not (extracted / required).is_file():
                raise ValueError(f"Downloaded SDK image lacks {required}")
        if not ((extracted / "userdata.img").is_file() or (extracted / "data").is_dir()):
            raise ValueError("Downloaded SDK image has neither userdata.img nor a data directory")
        os.replace(extracted, destination)
    print(f"Installed {package} at {destination}")


if __name__ == "__main__":
    try:
        if len(sys.argv) == 3 and sys.argv[1] == "list":
            list_images(Path(sys.argv[2]), False)
        elif len(sys.argv) == 4 and sys.argv[1] == "list" and sys.argv[3] == "--json":
            list_images(Path(sys.argv[2]), True)
        elif len(sys.argv) in (3, 4):
            cache = Path(sys.argv[3]) if len(sys.argv) == 4 else None
            install(Path(sys.argv[1]), sys.argv[2], cache)
        else:
            raise ValueError("Usage: avd_image.py list SDK_ROOT [--json] | SDK_ROOT PACKAGE_ID [CACHE_DIR]")
    except (OSError, ValueError, ET.ParseError, zipfile.BadZipFile, urllib.error.URLError) as error:
        sys.exit(f"AVD system image: {error}")
