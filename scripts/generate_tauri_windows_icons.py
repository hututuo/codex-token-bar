#!/usr/bin/env python3
"""Generate the cross-platform application icon set from the macOS artwork.

The notification-area icon is intentionally drawn separately in Rust because
it needs to stay legible at tiny sizes. The executable, taskbar, shortcuts and
installer should instead use the same glass squircle artwork as macOS. The
macOS source includes a white canvas and a cast shadow, so the Tauri artwork is
cropped to the squircle itself and receives a deterministic rounded mask.

This script intentionally uses only the Python standard library so every
checked-in PNG and ICO can be reproduced on either build host.
"""

from __future__ import annotations

import argparse
import math
import struct
import sys
import zlib
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SOURCE_PATH = PROJECT_ROOT / "Assets" / "AppIcon.png"
ICON_DIRECTORY = PROJECT_ROOT / "tauri-app" / "src-tauri" / "icons"
MASTER_PNG_PATH = ICON_DIRECTORY / "icon.png"
PNG_PATHS = {
    32: ICON_DIRECTORY / "32x32.png",
    128: ICON_DIRECTORY / "128x128.png",
    256: ICON_DIRECTORY / "128x128@2x.png",
}
ICO_PATH = ICON_DIRECTORY / "icon.ico"
SOURCE_SIZE = 1254
MASTER_SIZE = 1024

# The original 1254 px artwork contains a white canvas and a soft cast shadow.
# These bounds keep the real blue glass edge on every side while excluding the
# white/grey cast shadow outside it. The source artwork is slightly taller than
# it is wide, so it is normalized onto the square Tauri icon canvas.
SOURCE_CROP_LEFT = 122
SOURCE_CROP_TOP = 103
SOURCE_CROP_WIDTH = 1009
SOURCE_CROP_HEIGHT = 1036
CORNER_RADIUS_RATIO = 160 / MASTER_SIZE
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


def read_png(path: Path) -> tuple[int, int, bytes]:
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
                or color_type not in (2, 6)
                or compression != 0
                or filtering != 0
                or interlace != 0
            ):
                raise ValueError(
                    f"{path} must be a non-interlaced 8-bit RGB/RGBA PNG"
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

    bytes_per_pixel = 4 if color_type == 6 else 3
    stride = width * bytes_per_pixel
    filtered = zlib.decompress(bytes(compressed))
    expected_length = height * (stride + 1)
    if len(filtered) != expected_length:
        raise ValueError(
            f"Unexpected PNG payload length in {path}: "
            f"{len(filtered)} != {expected_length}"
        )

    decoded = bytearray(width * height * bytes_per_pixel)
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
        decoded[row_start : row_start + stride] = row
        previous = row

    if bytes_per_pixel == 4:
        rgba = decoded
    else:
        rgba = bytearray(width * height * 4)
        for pixel_index in range(width * height):
            source_offset = pixel_index * 3
            target_offset = pixel_index * 4
            rgba[target_offset : target_offset + 3] = decoded[
                source_offset : source_offset + 3
            ]
            rgba[target_offset + 3] = 255
    return width, height, bytes(rgba)


def crop_rgba(
    source: bytes,
    source_width: int,
    source_height: int,
    left: int,
    top: int,
    width: int,
    height: int,
) -> bytes:
    if (
        left < 0
        or top < 0
        or left + width > source_width
        or top + height > source_height
    ):
        raise ValueError(
            f"Icon crop {left},{top},{width}x{height} exceeds "
            f"{source_width}x{source_height}"
        )
    cropped = bytearray(width * height * 4)
    source_stride = source_width * 4
    target_stride = width * 4
    for target_y in range(height):
        source_start = (top + target_y) * source_stride + left * 4
        target_start = target_y * target_stride
        cropped[target_start : target_start + target_stride] = source[
            source_start : source_start + target_stride
        ]
    return bytes(cropped)


def rounded_rect_coverage(x: int, y: int, size: int, radius: float) -> float:
    center_x = x + 0.5
    center_y = y + 0.5
    nearest_x = min(max(center_x, radius), size - radius)
    nearest_y = min(max(center_y, radius), size - radius)
    distance = math.hypot(center_x - nearest_x, center_y - nearest_y)
    return max(0.0, min(1.0, radius + 0.5 - distance))


def apply_squircle_mask(source: bytes, size: int) -> bytes:
    radius = size * CORNER_RADIUS_RATIO
    masked = bytearray(source)
    for y in range(size):
        for x in range(size):
            offset = (y * size + x) * 4
            coverage = rounded_rect_coverage(x, y, size, radius)
            masked[offset + 3] = clamp(masked[offset + 3] * coverage)
    return bytes(masked)


def validate_transparent_icon(source: bytes, size: int) -> None:
    corner_alpha = (
        source[3],
        source[(size - 1) * 4 + 3],
        source[(size - 1) * size * 4 + 3],
        source[(size * size - 1) * 4 + 3],
    )
    if any(corner_alpha):
        raise ValueError(
            "Cross-platform icon must keep transparent corners; "
            f"found alpha values {corner_alpha}"
        )
    if not any(source[index] for index in range(3, len(source), 4)):
        raise ValueError("Cross-platform icon is fully transparent")


def clear_corner_pixels(source: bytes, size: int) -> bytes:
    cleaned = bytearray(source)
    for x, y in ((0, 0), (size - 1, 0), (0, size - 1), (size - 1, size - 1)):
        cleaned[(y * size + x) * 4 + 3] = 0
    return bytes(cleaned)


def build_master_icon(source_path: Path) -> bytes:
    source_width, source_height, source = read_png(source_path)
    if (source_width, source_height) != (SOURCE_SIZE, SOURCE_SIZE):
        raise ValueError(
            f"Expected {source_path} to be {SOURCE_SIZE}x{SOURCE_SIZE}, "
            f"got {source_width}x{source_height}"
        )
    cropped = crop_rgba(
        source,
        source_width,
        source_height,
        SOURCE_CROP_LEFT,
        SOURCE_CROP_TOP,
        SOURCE_CROP_WIDTH,
        SOURCE_CROP_HEIGHT,
    )
    resized = resize_rgba_rect(
        cropped,
        SOURCE_CROP_WIDTH,
        SOURCE_CROP_HEIGHT,
        MASTER_SIZE,
        MASTER_SIZE,
    )
    masked = clear_corner_pixels(
        apply_squircle_mask(resized, MASTER_SIZE),
        MASTER_SIZE,
    )
    validate_transparent_icon(masked, MASTER_SIZE)
    return masked


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
    return resize_rgba_rect(
        source,
        source_size,
        source_size,
        target_size,
        target_size,
    )


def resize_rgba_rect(
    source: bytes,
    source_width: int,
    source_height: int,
    target_width: int,
    target_height: int,
) -> bytes:
    """Area-resample straight RGBA while averaging colors in premultiplied form."""

    x_spans = sample_spans(source_width, target_width)
    y_spans = sample_spans(source_height, target_height)
    pixel_area = (source_width / target_width) * (source_height / target_height)
    target = bytearray(target_width * target_height * 4)
    for target_y, y_span in enumerate(y_spans):
        for target_x, x_span in enumerate(x_spans):
            alpha_sum = 0.0
            premultiplied_red = 0.0
            premultiplied_green = 0.0
            premultiplied_blue = 0.0
            for source_y, y_weight in y_span:
                row_offset = source_y * source_width * 4
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

            target_offset = (target_y * target_width + target_x) * 4
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


def build_ico(source: bytes, source_size: int) -> bytes:
    pngs = [
        (
            size,
            write_png(
                size,
                size,
                clear_corner_pixels(
                    resize_rgba(source, source_size, size),
                    size,
                ),
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


def update_file(path: Path, encoded: bytes) -> bool:
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

    master = build_master_icon(SOURCE_PATH)
    outputs = {
        MASTER_PNG_PATH: write_png(MASTER_SIZE, MASTER_SIZE, master),
        **{
            path: write_png(
                size,
                size,
                clear_corner_pixels(
                    resize_rgba(master, MASTER_SIZE, size),
                    size,
                ),
            )
            for size, path in PNG_PATHS.items()
        },
        ICO_PATH: build_ico(master, MASTER_SIZE),
    }
    if arguments.check:
        stale = [
            path for path, encoded in outputs.items()
            if not path.exists() or path.read_bytes() != encoded
        ]
        if stale:
            for path in stale:
                print(
                    f"{path} is stale; run {Path(__file__).name}",
                    file=sys.stderr,
                )
            return 1
        print(f"Verified cross-platform icon set matches {SOURCE_PATH}")
        return 0

    changed = [path for path, encoded in outputs.items() if update_file(path, encoded)]
    if changed:
        for path in changed:
            print(f"Wrote {path} from {SOURCE_PATH}")
    else:
        print(f"Cross-platform icon set already matches {SOURCE_PATH}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
