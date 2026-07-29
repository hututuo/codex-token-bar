#!/usr/bin/env python3
"""Generate the Windows application ICO from the macOS artwork.

The notification-area icon is intentionally drawn separately in Rust because
it needs to stay legible at tiny sizes. The executable, taskbar, shortcuts and
installer should instead use the same glass squircle artwork as macOS.

This script intentionally uses only the Python standard library so the checked
in ICO can be reproduced on either the macOS or Windows build host.
"""

from __future__ import annotations

import argparse
import math
import struct
import sys
import zlib
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SOURCE_PATH = PROJECT_ROOT / "tauri-app" / "src-tauri" / "icons" / "icon.png"
ICO_PATH = PROJECT_ROOT / "tauri-app" / "src-tauri" / "icons" / "icon.ico"
ICON_SIZES = (16, 24, 32, 48, 64, 128, 256)
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def clamp(value: float, low: int = 0, high: int = 255) -> int:
    return max(low, min(high, int(round(value))))


def paeth_predictor(left: int, up: int, upper_left: int) -> int:
    prediction = left + up - upper_left
    distance_left = abs(prediction - left)
    distance_up = abs(prediction - up)
    distance_upper_left = abs(prediction - upper_left)
    if distance_left <= distance_up and distance_left <= distance_upper_left:
        return left
    if distance_up <= distance_upper_left:
        return up
    return upper_left


def read_rgba_png(path: Path) -> tuple[int, int, bytes]:
    encoded = path.read_bytes()
    if not encoded.startswith(PNG_SIGNATURE):
        raise ValueError(f"Not a PNG file: {path}")

    offset = len(PNG_SIGNATURE)
    width = height = None
    compressed = bytearray()
    saw_end = False
    while offset < len(encoded):
        if offset + 12 > len(encoded):
            raise ValueError(f"Truncated PNG chunk in {path}")
        length = struct.unpack_from(">I", encoded, offset)[0]
        kind = encoded[offset + 4 : offset + 8]
        payload_start = offset + 8
        payload_end = payload_start + length
        crc_end = payload_end + 4
        if crc_end > len(encoded):
            raise ValueError(f"Truncated {kind!r} PNG chunk in {path}")
        payload = encoded[payload_start:payload_end]
        expected_crc = struct.unpack_from(">I", encoded, payload_end)[0]
        actual_crc = zlib.crc32(kind + payload) & 0xFFFFFFFF
        if expected_crc != actual_crc:
            raise ValueError(f"Invalid {kind!r} PNG checksum in {path}")

        if kind == b"IHDR":
            if length != 13 or width is not None:
                raise ValueError(f"Invalid PNG header in {path}")
            (
                width,
                height,
                bit_depth,
                color_type,
                compression,
                filtering,
                interlace,
            ) = struct.unpack(">IIBBBBB", payload)
            if (
                bit_depth != 8
                or color_type != 6
                or compression != 0
                or filtering != 0
                or interlace != 0
            ):
                raise ValueError(
                    f"{path} must be a non-interlaced 8-bit RGBA PNG"
                )
        elif kind == b"IDAT":
            compressed.extend(payload)
        elif kind == b"IEND":
            saw_end = True
            break
        offset = crc_end

    if width is None or height is None or not compressed or not saw_end:
        raise ValueError(f"Incomplete PNG structure in {path}")
    if width != height:
        raise ValueError(f"Icon artwork must be square, got {width}x{height}")

    bytes_per_pixel = 4
    stride = width * bytes_per_pixel
    filtered = zlib.decompress(bytes(compressed))
    expected_length = height * (stride + 1)
    if len(filtered) != expected_length:
        raise ValueError(
            f"Unexpected PNG payload length in {path}: "
            f"{len(filtered)} != {expected_length}"
        )

    rgba = bytearray(width * height * bytes_per_pixel)
    source_offset = 0
    previous = bytearray(stride)
    for row_index in range(height):
        filter_type = filtered[source_offset]
        source_offset += 1
        row = bytearray(filtered[source_offset : source_offset + stride])
        source_offset += stride
        for index in range(stride):
            left = row[index - bytes_per_pixel] if index >= bytes_per_pixel else 0
            up = previous[index]
            upper_left = (
                previous[index - bytes_per_pixel]
                if index >= bytes_per_pixel
                else 0
            )
            if filter_type == 1:
                row[index] = (row[index] + left) & 0xFF
            elif filter_type == 2:
                row[index] = (row[index] + up) & 0xFF
            elif filter_type == 3:
                row[index] = (row[index] + ((left + up) // 2)) & 0xFF
            elif filter_type == 4:
                row[index] = (
                    row[index] + paeth_predictor(left, up, upper_left)
                ) & 0xFF
            elif filter_type != 0:
                raise ValueError(
                    f"Unsupported PNG filter {filter_type} in row {row_index}"
                )
        row_start = row_index * stride
        rgba[row_start : row_start + stride] = row
        previous = row

    corner_alpha = (
        rgba[3],
        rgba[(width - 1) * 4 + 3],
        rgba[(height - 1) * stride + 3],
        rgba[(height * width - 1) * 4 + 3],
    )
    if any(corner_alpha):
        raise ValueError(
            "Windows icon source must keep transparent corners; "
            f"found alpha values {corner_alpha}"
        )
    if not any(rgba[index] for index in range(3, len(rgba), 4)):
        raise ValueError("Windows icon source is fully transparent")
    return width, height, bytes(rgba)


def sample_spans(source_size: int, target_size: int) -> list[list[tuple[int, float]]]:
    scale = source_size / target_size
    spans: list[list[tuple[int, float]]] = []
    for target_index in range(target_size):
        start = target_index * scale
        end = (target_index + 1) * scale
        first = int(math.floor(start))
        last = min(source_size, int(math.ceil(end)))
        spans.append(
            [
                (
                    source_index,
                    min(end, source_index + 1.0) - max(start, source_index),
                )
                for source_index in range(first, last)
            ]
        )
    return spans


def resize_rgba(
    source: bytes,
    source_size: int,
    target_size: int,
) -> bytes:
    """Area-resample straight RGBA while averaging colors in premultiplied form."""

    spans = sample_spans(source_size, target_size)
    pixel_area = (source_size / target_size) ** 2
    target = bytearray(target_size * target_size * 4)
    for target_y, y_span in enumerate(spans):
        for target_x, x_span in enumerate(spans):
            alpha_sum = 0.0
            premultiplied_red = 0.0
            premultiplied_green = 0.0
            premultiplied_blue = 0.0
            for source_y, y_weight in y_span:
                row_offset = source_y * source_size * 4
                for source_x, x_weight in x_span:
                    weight = x_weight * y_weight
                    source_offset = row_offset + source_x * 4
                    alpha = source[source_offset + 3]
                    weighted_alpha = alpha * weight
                    alpha_sum += weighted_alpha
                    premultiplied_red += source[source_offset] * weighted_alpha
                    premultiplied_green += (
                        source[source_offset + 1] * weighted_alpha
                    )
                    premultiplied_blue += (
                        source[source_offset + 2] * weighted_alpha
                    )

            target_offset = (target_y * target_size + target_x) * 4
            target[target_offset + 3] = clamp(alpha_sum / pixel_area)
            if alpha_sum > 0:
                target[target_offset] = clamp(premultiplied_red / alpha_sum)
                target[target_offset + 1] = clamp(
                    premultiplied_green / alpha_sum
                )
                target[target_offset + 2] = clamp(
                    premultiplied_blue / alpha_sum
                )
    return bytes(target)


def write_png(width: int, height: int, rgba: bytes) -> bytes:
    rows = []
    stride = width * 4
    for y in range(height):
        rows.append(b"\x00" + rgba[y * stride : (y + 1) * stride])
    raw = b"".join(rows)

    def chunk(kind: bytes, payload: bytes) -> bytes:
        return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)

    return (
        PNG_SIGNATURE
        + chunk(
            b"IHDR",
            struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0),
        )
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )


def build_ico(source_path: Path) -> bytes:
    source_width, source_height, source = read_rgba_png(source_path)
    if source_width != source_height:
        raise ValueError(
            f"Icon artwork must be square, got {source_width}x{source_height}"
        )
    pngs = [
        (
            size,
            write_png(
                size,
                size,
                resize_rgba(source, source_width, size),
            ),
        )
        for size in ICON_SIZES
    ]
    header = struct.pack("<HHH", 0, 1, len(pngs))
    directory = bytearray()
    offset = len(header) + len(pngs) * 16
    payload = bytearray()
    for size, png in pngs:
        directory.extend(
            struct.pack(
                "<BBBBHHII",
                0 if size == 256 else size,
                0 if size == 256 else size,
                0,
                0,
                1,
                32,
                len(png),
                offset,
            )
        )
        payload.extend(png)
        offset += len(png)
    return header + bytes(directory) + bytes(payload)


def update_ico(path: Path, encoded: bytes) -> bool:
    if path.exists() and path.read_bytes() == encoded:
        return False
    temporary = path.with_name(f".{path.name}.tmp")
    try:
        temporary.write_bytes(encoded)
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--check",
        action="store_true",
        help="fail when the checked-in ICO does not match the macOS artwork",
    )
    arguments = parser.parse_args()

    encoded = build_ico(SOURCE_PATH)
    if arguments.check:
        if not ICO_PATH.exists() or ICO_PATH.read_bytes() != encoded:
            print(
                f"{ICO_PATH} is stale; run {Path(__file__).name}",
                file=sys.stderr,
            )
            return 1
        print(f"Verified {ICO_PATH} matches {SOURCE_PATH}")
        return 0

    changed = update_ico(ICO_PATH, encoded)
    action = "Wrote" if changed else "Already current"
    print(f"{action} {ICO_PATH} from {SOURCE_PATH}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
