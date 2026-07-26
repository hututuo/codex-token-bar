#!/usr/bin/env python3
"""Merge a freshly generated Sparkle appcast into the published appcast.

Published appcast items are immutable release history: silently replacing an
already published version would let a rebuilt artifact masquerade as the
original release. Republishing an existing version is therefore rejected
unless ALLOW_APPCAST_REPUBLISH=1 is set explicitly.
"""

import os
import re
import sys
from pathlib import Path


def main() -> None:
    if len(sys.argv) != 5:
        raise SystemExit(
            "usage: merge_appcast.py VERSION GENERATED_APPCAST EXISTING_APPCAST OUTPUT_APPCAST"
        )
    version, generated_path, existing_path, output_path = sys.argv[1:5]
    generated = Path(generated_path).read_text(encoding="utf-8")
    existing = (
        Path(existing_path).read_text(encoding="utf-8")
        if Path(existing_path).exists()
        else ""
    )

    item_pattern = re.compile(r"\n        <item>.*?\n        </item>", re.S)
    version_pattern = re.compile(
        r"<sparkle:shortVersionString>(.*?)</sparkle:shortVersionString>"
    )

    def item_version(item):
        match = version_pattern.search(item)
        return match.group(1) if match else None

    generated_items = item_pattern.findall(generated)
    current_items = [item for item in generated_items if item_version(item) == version]
    if not current_items:
        raise SystemExit(f"generated appcast missing current version {version}")

    published_items = item_pattern.findall(existing)
    if any(item_version(item) == version for item in published_items) and os.environ.get(
        "ALLOW_APPCAST_REPUBLISH"
    ) != "1":
        raise SystemExit(
            f"appcast already contains version {version}; published appcast items are "
            "immutable release history. Set ALLOW_APPCAST_REPUBLISH=1 to intentionally "
            "republish this version."
        )

    existing_items = [
        item for item in published_items if item_version(item) != version
    ]
    merged_items = (current_items + existing_items)[:5]

    first_match = item_pattern.search(generated)
    if not first_match:
        raise SystemExit("generated appcast has no item block")

    last_match = None
    for match in item_pattern.finditer(generated):
        last_match = match
    if last_match is None:
        raise SystemExit("generated appcast has no item block")

    merged = (
        generated[: first_match.start()]
        + "".join(merged_items)
        + generated[last_match.end() :]
    )
    Path(output_path).write_text(merged, encoding="utf-8")


if __name__ == "__main__":
    main()
