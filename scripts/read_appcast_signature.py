#!/usr/bin/env python3
"""Read one release's Sparkle signature from a validated appcast."""

from __future__ import annotations

import sys
from pathlib import Path

from merge_appcast import fail, item_version, local_name, parse_appcast


def main() -> None:
    if len(sys.argv) != 3:
        fail("usage: read_appcast_signature.py APPCAST VERSION")
    appcast_path = Path(sys.argv[1])
    version = sys.argv[2]
    text = appcast_path.read_text(encoding="utf-8")
    _, channel = parse_appcast(text, "appcast")
    matching_items = [
        item
        for item in channel
        if local_name(item.tag) == "item"
        and item_version(item, "appcast item") == version
    ]
    if len(matching_items) != 1:
        fail(
            f"appcast must contain exactly one item for version {version} "
            f"(found {len(matching_items)})"
        )
    enclosures = [
        child
        for child in matching_items[0]
        if local_name(child.tag) == "enclosure"
    ]
    if len(enclosures) != 1:
        fail(
            f"appcast item for version {version} must contain exactly one enclosure"
        )
    signatures = [
        value.strip()
        for key, value in enclosures[0].attrib.items()
        if local_name(key) == "edSignature" and value.strip()
    ]
    if len(signatures) != 1:
        fail(
            f"appcast item for version {version} must contain exactly one "
            "non-empty sparkle:edSignature"
        )
    print(signatures[0])


if __name__ == "__main__":
    main()
