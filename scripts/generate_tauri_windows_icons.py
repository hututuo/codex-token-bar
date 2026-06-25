#!/usr/bin/env python3
"""Generate the Windows taskbar ICO for the Tauri app.

The tray icon is intentionally drawn separately in Rust: the Windows taskbar
needs a transparent, darker icon, while the notification area is more legible
with a small white-backed icon.
"""

from __future__ import annotations

import math
import struct
import zlib
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
ICO_PATH = PROJECT_ROOT / "tauri-app" / "src-tauri" / "icons" / "icon.ico"
ICON_SIZES = (16, 24, 32, 48, 64, 128, 256)


def clamp(value: float, low: int = 0, high: int = 255) -> int:
    return max(low, min(high, int(round(value))))


def blend_pixel(buf: bytearray, width: int, x: int, y: int, color: tuple[int, int, int, int]) -> None:
    if x < 0 or y < 0 or x >= width or y >= width:
        return
    r, g, b, a = color
    if a <= 0:
        return
    idx = (y * width + x) * 4
    dr, dg, db, da = buf[idx], buf[idx + 1], buf[idx + 2], buf[idx + 3]
    sa = a / 255.0
    da_f = da / 255.0
    out_a = sa + da_f * (1.0 - sa)
    if out_a <= 0:
        return
    buf[idx] = clamp((r * sa + dr * da_f * (1.0 - sa)) / out_a)
    buf[idx + 1] = clamp((g * sa + dg * da_f * (1.0 - sa)) / out_a)
    buf[idx + 2] = clamp((b * sa + db * da_f * (1.0 - sa)) / out_a)
    buf[idx + 3] = clamp(out_a * 255)


def rounded_rect_contains(px: float, py: float, x0: float, y0: float, x1: float, y1: float, r: float) -> bool:
    cx = min(max(px, x0 + r), x1 - r)
    cy = min(max(py, y0 + r), y1 - r)
    return (px - cx) * (px - cx) + (py - cy) * (py - cy) <= r * r


def fill_rounded_rect(
    buf: bytearray,
    width: int,
    x0: float,
    y0: float,
    x1: float,
    y1: float,
    radius: float,
    color_at,
) -> None:
    left = max(0, int(math.floor(x0)))
    top = max(0, int(math.floor(y0)))
    right = min(width, int(math.ceil(x1)))
    bottom = min(width, int(math.ceil(y1)))
    for y in range(top, bottom):
        for x in range(left, right):
            px, py = x + 0.5, y + 0.5
            if rounded_rect_contains(px, py, x0, y0, x1, y1, radius):
                blend_pixel(buf, width, x, y, color_at((px - x0) / max(1.0, x1 - x0), (py - y0) / max(1.0, y1 - y0)))


def draw_circle(buf: bytearray, width: int, cx: float, cy: float, radius: float, color: tuple[int, int, int, int]) -> None:
    left = max(0, int(math.floor(cx - radius)))
    top = max(0, int(math.floor(cy - radius)))
    right = min(width, int(math.ceil(cx + radius)))
    bottom = min(width, int(math.ceil(cy + radius)))
    rr = radius * radius
    for y in range(top, bottom):
        for x in range(left, right):
            px, py = x + 0.5, y + 0.5
            if (px - cx) * (px - cx) + (py - cy) * (py - cy) <= rr:
                blend_pixel(buf, width, x, y, color)


def draw_line(buf: bytearray, width: int, p0: tuple[float, float], p1: tuple[float, float], stroke: float, color: tuple[int, int, int, int]) -> None:
    x0, y0 = p0
    x1, y1 = p1
    distance = math.hypot(x1 - x0, y1 - y0)
    steps = max(1, int(distance / max(1.0, stroke * 0.35)))
    for i in range(steps + 1):
        t = i / steps
        draw_circle(buf, width, x0 + (x1 - x0) * t, y0 + (y1 - y0) * t, stroke / 2.0, color)


def draw_polyline(buf: bytearray, width: int, points: list[tuple[float, float]], stroke: float, color: tuple[int, int, int, int]) -> None:
    for start, end in zip(points, points[1:]):
        draw_line(buf, width, start, end, stroke, color)


def draw_arc(buf: bytearray, width: int, center: tuple[float, float], radius: float, start_deg: float, end_deg: float, stroke: float, color: tuple[int, int, int, int]) -> None:
    steps = max(16, int(abs(end_deg - start_deg) / 3))
    cx, cy = center
    prev = None
    for i in range(steps + 1):
        angle = math.radians(start_deg + (end_deg - start_deg) * (i / steps))
        point = (cx + math.cos(angle) * radius, cy + math.sin(angle) * radius)
        if prev is not None:
            draw_line(buf, width, prev, point, stroke, color)
        prev = point


def downsample(buf: bytearray, render_size: int, size: int, scale: int) -> bytes:
    out = bytearray(size * size * 4)
    for y in range(size):
        for x in range(size):
            total = [0, 0, 0, 0]
            for yy in range(scale):
                for xx in range(scale):
                    idx = ((y * scale + yy) * render_size + (x * scale + xx)) * 4
                    total[0] += buf[idx]
                    total[1] += buf[idx + 1]
                    total[2] += buf[idx + 2]
                    total[3] += buf[idx + 3]
            dst = (y * size + x) * 4
            count = scale * scale
            out[dst : dst + 4] = bytes(clamp(v / count) for v in total)
    return bytes(out)


def write_png(width: int, height: int, rgba: bytes) -> bytes:
    rows = []
    stride = width * 4
    for y in range(height):
        rows.append(b"\x00" + rgba[y * stride : (y + 1) * stride])
    raw = b"".join(rows)

    def chunk(kind: bytes, payload: bytes) -> bytes:
        return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)

    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")


def render_icon(size: int) -> bytes:
    scale = 4 if size >= 32 else 5
    width = size * scale
    buf = bytearray(width * width * 4)
    s = float(width)

    def u(v: float) -> float:
        return v * s

    def panel_gradient(tx: float, ty: float) -> tuple[int, int, int, int]:
        mix = (tx * 0.38 + ty * 0.62)
        return (
            clamp(254 - 12 * mix),
            clamp(255 - 10 * mix),
            clamp(255),
            255,
        )

    fill_rounded_rect(buf, width, u(0.055), u(0.08), u(0.945), u(0.94), u(0.19), panel_gradient)

    # Subtle glass edge.
    fill_rounded_rect(
        buf,
        width,
        u(0.06),
        u(0.085),
        u(0.94),
        u(0.935),
        u(0.18),
        lambda _tx, _ty: (255, 255, 255, 46),
    )

    # Soft blue lower-right tint, kept inside the rounded card.
    fill_rounded_rect(
        buf,
        width,
        u(0.10),
        u(0.12),
        u(0.90),
        u(0.90),
        u(0.16),
        lambda tx, ty: (160, 210, 255, clamp(3 + 8 * tx * ty)),
    )

    cols, rows = 7, 6
    cell, gap = u(0.077), u(0.023)
    grid_x, grid_y = u(0.21), u(0.31)
    for row in range(rows):
        for col in range(cols):
            power = (col / max(1, cols - 1)) * 0.58 + (row / max(1, rows - 1)) * 0.42
            color = (
                clamp(236 - 38 * power),
                clamp(246 - 30 * power),
                255,
                clamp(28 + 58 * power),
            )
            x0 = grid_x + col * (cell + gap)
            y0 = grid_y + row * (cell + gap)
            fill_rounded_rect(buf, width, x0, y0, x0 + cell, y0 + cell, u(0.017), lambda _tx, _ty, c=color: c)

    navy = (24, 64, 124, 250)
    draw_arc(buf, width, (u(0.24), u(0.21)), u(0.055), 52, 308, u(0.026), navy)
    draw_line(buf, width, (u(0.324), u(0.165)), (u(0.388), u(0.255)), u(0.025), navy)
    draw_line(buf, width, (u(0.388), u(0.165)), (u(0.324), u(0.255)), u(0.025), navy)

    points = [
        (u(0.16), u(0.74)),
        (u(0.30), u(0.61)),
        (u(0.40), u(0.66)),
        (u(0.54), u(0.52)),
        (u(0.64), u(0.58)),
        (u(0.75), u(0.43)),
        (u(0.86), u(0.35)),
    ]
    draw_polyline(buf, width, points, u(0.040), (255, 255, 255, 230))
    draw_polyline(buf, width, points, u(0.024), (26, 190, 232, 255))
    for point in points[1:]:
        draw_circle(buf, width, point[0], point[1], u(0.030), (255, 255, 255, 245))
        draw_circle(buf, width, point[0], point[1], u(0.019), (30, 187, 229, 255))

    return downsample(buf, width, size, scale)


def write_ico(path: Path) -> None:
    pngs = [(size, write_png(size, size, render_icon(size))) for size in ICON_SIZES]
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
    path.write_bytes(header + bytes(directory) + bytes(payload))


if __name__ == "__main__":
    write_ico(ICO_PATH)
    print(f"Wrote {ICO_PATH}")
