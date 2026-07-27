#!/usr/bin/env python3
"""Merge a freshly generated Sparkle appcast into immutable release history.

The merge is based on parsed XML elements rather than indentation or line
endings. Malformed generated or published XML fails closed. Publishing also
compares the destination with the caller's existing-history snapshot while a
cross-process lock is held, so concurrent release jobs cannot silently replace
history that changed after the snapshot was taken.
"""

from __future__ import annotations

import copy
import hashlib
import os
import sys
import tempfile
import time
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import NoReturn

if os.name == "nt":
    import msvcrt
else:
    import fcntl


def fail(message: str) -> NoReturn:
    raise SystemExit(message)


def local_name(tag: object) -> str:
    if not isinstance(tag, str):
        return ""
    return tag.rsplit("}", 1)[-1]


def parse_appcast(text: str, label: str) -> tuple[ET.ElementTree, ET.Element]:
    if not text.strip():
        fail(f"{label} is empty")
    upper = text.upper()
    if "<!DOCTYPE" in upper or "<!ENTITY" in upper:
        fail(f"{label} contains a forbidden DTD or entity declaration")
    try:
        parser = ET.XMLParser(target=ET.TreeBuilder(insert_comments=True))
        root = ET.fromstring(text, parser=parser)
    except ET.ParseError as error:
        fail(f"{label} is not well-formed XML: {error}")
    if local_name(root.tag) != "rss":
        fail(f"{label} root element must be rss")
    channels = [
        child for child in root
        if local_name(child.tag) == "channel"
    ]
    if len(channels) != 1:
        fail(f"{label} must contain exactly one direct channel element")
    return ET.ElementTree(root), channels[0]


def item_version(item: ET.Element, label: str) -> str:
    version_nodes = [
        child for child in item
        if local_name(child.tag) == "shortVersionString"
    ]
    if len(version_nodes) != 1:
        fail(f"{label} item must contain exactly one shortVersionString")
    version = (version_nodes[0].text or "").strip()
    if not version:
        fail(f"{label} item has an empty shortVersionString")
    return version


def validated_items(channel: ET.Element, label: str) -> list[tuple[str, ET.Element]]:
    items = [
        child for child in channel
        if local_name(child.tag) == "item"
    ]
    seen: set[str] = set()
    result: list[tuple[str, ET.Element]] = []
    for index, item in enumerate(items):
        version = item_version(item, f"{label} item {index + 1}")
        if version in seen:
            fail(f"{label} contains duplicate version {version}")
        seen.add(version)
        result.append((version, item))
    return result


def register_sparkle_namespace(items: list[tuple[str, ET.Element]]) -> None:
    for _, item in items:
        for element in item.iter():
            if local_name(element.tag) != "shortVersionString":
                continue
            if isinstance(element.tag, str) and element.tag.startswith("{"):
                namespace = element.tag[1:].split("}", 1)[0]
                ET.register_namespace("sparkle", namespace)
            return


def install_merged_items(
    channel: ET.Element,
    generated_items: list[tuple[str, ET.Element]],
    merged_items: list[ET.Element],
) -> None:
    children = list(channel)
    item_elements = [item for _, item in generated_items]
    positions = [
        index for index, child in enumerate(children)
        if child in item_elements
    ]
    if not positions:
        fail("generated appcast has no item block")
    insertion_index = positions[0]
    for item in item_elements:
        channel.remove(item)
    for offset, item in enumerate(merged_items):
        item.tail = "\n        " if offset + 1 < len(merged_items) else "\n    "
        channel.insert(insertion_index + offset, item)


def serialize_appcast(tree: ET.ElementTree) -> str:
    payload = ET.tostring(
        tree.getroot(),
        encoding="utf-8",
        xml_declaration=True,
        short_empty_elements=True,
    )
    return payload.decode("utf-8") + ("" if payload.endswith(b"\n") else "\n")


def publish_with_snapshot(
    output_path: Path,
    content: str,
    expected_existing: str | None,
    require_exact_snapshot: bool = False,
) -> None:
    absolute_output = Path(os.path.abspath(output_path))
    lock_key = hashlib.sha256(os.fsencode(absolute_output)).hexdigest()
    lock_path = Path(tempfile.gettempdir()) / (
        f"codex-token-bar-appcast-{lock_key}.lock"
    )
    lock_descriptor = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
    temporary_path: Path | None = None
    locked = False
    try:
        lock_file(lock_descriptor)
        locked = True
        if absolute_output.is_symlink():
            fail(f"refusing to publish appcast through a symlink: {absolute_output}")
        if absolute_output.exists() and not absolute_output.is_file():
            fail(f"appcast destination is not a regular file: {absolute_output}")
        current = (
            absolute_output.read_text(encoding="utf-8")
            if absolute_output.exists()
            else None
        )
        snapshot_changed = (
            current != expected_existing
            if require_exact_snapshot
            else current is not None and current != expected_existing
        )
        if snapshot_changed:
            fail(
                "appcast destination changed after the existing-history snapshot "
                f"was captured: {absolute_output}"
            )
        descriptor, raw_temporary_path = tempfile.mkstemp(
            prefix=f".{absolute_output.name}.tmp-",
            dir=absolute_output.parent,
        )
        temporary_path = Path(raw_temporary_path)
        try:
            if hasattr(os, "fchmod"):
                os.fchmod(descriptor, 0o644)
            with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as file:
                file.write(content)
                file.flush()
                os.fsync(file.fileno())
            os.replace(temporary_path, absolute_output)
            temporary_path = None
            if os.name != "nt":
                directory_descriptor = os.open(absolute_output.parent, os.O_RDONLY)
                try:
                    os.fsync(directory_descriptor)
                finally:
                    os.close(directory_descriptor)
        except BaseException:
            if temporary_path is not None:
                temporary_path.unlink(missing_ok=True)
            raise
    finally:
        if locked:
            unlock_file(lock_descriptor)
        os.close(lock_descriptor)


def lock_file(descriptor: int) -> None:
    if os.name != "nt":
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        return
    if os.fstat(descriptor).st_size == 0:
        os.write(descriptor, b"\0")
        os.fsync(descriptor)
    deadline = time.monotonic() + 60
    while True:
        os.lseek(descriptor, 0, os.SEEK_SET)
        try:
            msvcrt.locking(descriptor, msvcrt.LK_NBLCK, 1)
            return
        except OSError:
            if time.monotonic() >= deadline:
                fail("timed out waiting for the appcast publication lock")
            time.sleep(0.05)


def unlock_file(descriptor: int) -> None:
    if os.name != "nt":
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        return
    os.lseek(descriptor, 0, os.SEEK_SET)
    msvcrt.locking(descriptor, msvcrt.LK_UNLCK, 1)


def main() -> None:
    if len(sys.argv) != 5:
        fail(
            "usage: merge_appcast.py VERSION GENERATED_APPCAST "
            "EXISTING_APPCAST OUTPUT_APPCAST"
        )
    version, generated_path, existing_path, output_path = sys.argv[1:5]
    generated = Path(generated_path).read_text(encoding="utf-8")
    existing_file = Path(existing_path)
    if existing_file.is_symlink():
        fail(f"existing appcast snapshot must not be a symlink: {existing_file}")
    existing = (
        existing_file.read_text(encoding="utf-8")
        if existing_file.exists()
        else None
    )

    generated_tree, generated_channel = parse_appcast(
        generated,
        "generated appcast",
    )
    generated_items = validated_items(
        generated_channel,
        "generated appcast",
    )
    current_items = [
        item for item_version_value, item in generated_items
        if item_version_value == version
    ]
    if not current_items:
        fail(f"generated appcast missing current version {version}")
    if len(current_items) != 1:
        fail(
            f"generated appcast must contain exactly one current version {version} "
            f"(found {len(current_items)})"
        )

    published_items: list[tuple[str, ET.Element]] = []
    if existing is not None:
        _, existing_channel = parse_appcast(existing, "published appcast")
        published_items = validated_items(existing_channel, "published appcast")
    if any(item_version_value == version for item_version_value, _ in published_items):
        if os.environ.get("ALLOW_APPCAST_REPUBLISH") != "1":
            fail(
                f"appcast already contains version {version}; published appcast "
                "items are immutable release history. Set "
                "ALLOW_APPCAST_REPUBLISH=1 to intentionally republish this version."
            )

    retained_published = [
        item for item_version_value, item in published_items
        if item_version_value != version
    ]
    merged_items = [
        copy.deepcopy(current_items[0]),
        *(copy.deepcopy(item) for item in retained_published),
    ][:5]
    register_sparkle_namespace(generated_items + published_items)

    # A fresh one-item appcast needs no structural rewrite after validation.
    # Preserve generate_appcast's exact bytes in that common case.
    if existing is None and len(generated_items) == 1:
        merged = generated
    else:
        install_merged_items(
            generated_channel,
            generated_items,
            merged_items,
        )
        merged = serialize_appcast(generated_tree)
    publish_with_snapshot(Path(output_path), merged, existing)


if __name__ == "__main__":
    main()
