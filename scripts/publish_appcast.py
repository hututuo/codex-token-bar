#!/usr/bin/env python3
"""Atomically publish a fully verified staged appcast.

The destination must still match the release job's earlier snapshot exactly.
This keeps failed or concurrent release jobs from rewriting public history.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

from merge_appcast import (
    fail,
    parse_appcast,
    publish_with_snapshot,
    validated_items,
)


def checked_regular_input(path: Path, label: str) -> str:
    if path.is_symlink():
        fail(f"{label} must not be a symlink: {path}")
    if not path.is_file():
        fail(f"{label} is not a regular file: {path}")
    return path.read_text(encoding="utf-8")


def main() -> None:
    if len(sys.argv) != 4:
        fail(
            "usage: publish_appcast.py STAGED_APPCAST "
            "EXISTING_SNAPSHOT OUTPUT_APPCAST"
        )
    staged_path = Path(sys.argv[1])
    snapshot_path = Path(sys.argv[2])
    output_path = Path(sys.argv[3])
    if os.path.abspath(staged_path) == os.path.abspath(output_path):
        fail("staged appcast and output appcast must be different files")

    staged = checked_regular_input(staged_path, "staged appcast")
    _, channel = parse_appcast(staged, "staged appcast")
    if not validated_items(channel, "staged appcast"):
        fail("staged appcast contains no release items")

    if snapshot_path.is_symlink():
        fail(f"existing appcast snapshot must not be a symlink: {snapshot_path}")
    expected_existing = (
        snapshot_path.read_text(encoding="utf-8")
        if snapshot_path.exists()
        else None
    )
    publish_with_snapshot(
        output_path,
        staged,
        expected_existing,
        require_exact_snapshot=True,
    )


if __name__ == "__main__":
    main()
