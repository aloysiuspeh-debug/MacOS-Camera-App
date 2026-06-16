#!/usr/bin/env python3
from __future__ import annotations

import argparse
import math
import shutil
import struct
import subprocess
import tempfile
import zlib
from pathlib import Path


ICON_FILES = (
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
)


def clamp(value: float, low: float = 0.0, high: float = 1.0) -> float:
    return max(low, min(high, value))


def mix(a: int, b: int, t: float) -> int:
    return round(a + (b - a) * t)


def rgb(hex_value: str) -> tuple[int, int, int]:
    value = hex_value.lstrip("#")
    return tuple(int(value[index : index + 2], 16) for index in (0, 2, 4))


def coverage(distance: float) -> float:
    return clamp(0.5 - distance)


def round_rect_distance(
    x: float,
    y: float,
    x0: float,
    y0: float,
    x1: float,
    y1: float,
    radius: float,
) -> float:
    cx = (x0 + x1) * 0.5
    cy = (y0 + y1) * 0.5
    hx = (x1 - x0) * 0.5
    hy = (y1 - y0) * 0.5
    qx = abs(x - cx) - (hx - radius)
    qy = abs(y - cy) - (hy - radius)
    outside = math.hypot(max(qx, 0.0), max(qy, 0.0))
    inside = min(max(qx, qy), 0.0)
    return outside + inside - radius


def blend_pixel(
    pixels: bytearray,
    index: int,
    color: tuple[int, int, int],
    alpha: float,
) -> None:
    alpha = clamp(alpha)
    if alpha <= 0:
        return

    dst_alpha = pixels[index + 3] / 255.0
    out_alpha = alpha + dst_alpha * (1.0 - alpha)
    if out_alpha <= 0:
        return

    for channel in range(3):
        dst = pixels[index + channel]
        src = color[channel]
        pixels[index + channel] = round(
            (src * alpha + dst * dst_alpha * (1.0 - alpha)) / out_alpha
        )
    pixels[index + 3] = round(out_alpha * 255)


def draw_round_rect(
    pixels: bytearray,
    size: int,
    rect: tuple[float, float, float, float],
    radius: float,
    color: tuple[int, int, int],
    alpha: float = 1.0,
) -> None:
    scale = size / 1024.0
    x0, y0, x1, y1 = (value * scale for value in rect)
    radius *= scale
    margin = 2
    min_x = max(0, math.floor(x0 - margin))
    min_y = max(0, math.floor(y0 - margin))
    max_x = min(size, math.ceil(x1 + margin))
    max_y = min(size, math.ceil(y1 + margin))

    for py in range(min_y, max_y):
        y = py + 0.5
        for px in range(min_x, max_x):
            x = px + 0.5
            mask = coverage(round_rect_distance(x, y, x0, y0, x1, y1, radius))
            if mask:
                blend_pixel(pixels, (py * size + px) * 4, color, alpha * mask)


def draw_circle(
    pixels: bytearray,
    size: int,
    center: tuple[float, float],
    radius: float,
    color: tuple[int, int, int],
    alpha: float = 1.0,
) -> None:
    scale = size / 1024.0
    cx, cy = (value * scale for value in center)
    radius *= scale
    margin = 2
    min_x = max(0, math.floor(cx - radius - margin))
    min_y = max(0, math.floor(cy - radius - margin))
    max_x = min(size, math.ceil(cx + radius + margin))
    max_y = min(size, math.ceil(cy + radius + margin))

    for py in range(min_y, max_y):
        y = py + 0.5
        for px in range(min_x, max_x):
            x = px + 0.5
            mask = coverage(math.hypot(x - cx, y - cy) - radius)
            if mask:
                blend_pixel(pixels, (py * size + px) * 4, color, alpha * mask)


def draw_camera_icon(size: int) -> bytearray:
    pixels = bytearray(size * size * 4)
    top = rgb("#253347")
    bottom = rgb("#116f74")
    glow = rgb("#79eadf")
    scale = size / 1024.0
    radius = 216.0 * scale

    for py in range(size):
        y = py + 0.5
        for px in range(size):
            x = px + 0.5
            distance = round_rect_distance(
                x, y, 48.0 * scale, 48.0 * scale, 976.0 * scale, 976.0 * scale, radius
            )
            mask = coverage(distance)
            if not mask:
                continue

            diagonal = clamp((px / max(size - 1, 1)) * 0.42 + (py / max(size - 1, 1)) * 0.58)
            red = mix(top[0], bottom[0], diagonal)
            green = mix(top[1], bottom[1], diagonal)
            blue = mix(top[2], bottom[2], diagonal)

            highlight = clamp(1.0 - math.hypot(px - size * 0.28, py - size * 0.20) / (size * 0.62))
            red = mix(red, glow[0], highlight * 0.28)
            green = mix(green, glow[1], highlight * 0.28)
            blue = mix(blue, glow[2], highlight * 0.28)

            shade = clamp((math.hypot(px - size * 0.78, py - size * 0.82) - size * 0.20) / (size * 0.70))
            red = mix(red, 11, shade * 0.22)
            green = mix(green, 24, shade * 0.22)
            blue = mix(blue, 35, shade * 0.22)

            blend_pixel(pixels, (py * size + px) * 4, (red, green, blue), mask)

    draw_round_rect(pixels, size, (82, 82, 942, 942), 192, rgb("#ffffff"), 0.09)
    draw_round_rect(pixels, size, (160, 376, 864, 746), 112, rgb("#0a1420"), 0.26)
    draw_round_rect(pixels, size, (198, 334, 826, 706), 92, rgb("#f3f0e6"), 1.0)
    draw_round_rect(pixels, size, (304, 276, 536, 392), 52, rgb("#f3f0e6"), 1.0)
    draw_round_rect(pixels, size, (331, 304, 508, 358), 28, rgb("#d9d7cf"), 0.72)
    draw_round_rect(pixels, size, (624, 318, 764, 388), 34, rgb("#172336"), 0.92)
    draw_round_rect(pixels, size, (646, 334, 742, 370), 18, rgb("#8af2e5"), 0.95)
    draw_round_rect(pixels, size, (236, 396, 788, 674), 62, rgb("#fffdf5"), 0.22)
    draw_circle(pixels, size, (512, 535), 190, rgb("#0e1725"), 0.28)
    draw_circle(pixels, size, (512, 520), 174, rgb("#142032"), 1.0)
    draw_circle(pixels, size, (512, 520), 138, rgb("#97f0e3"), 1.0)
    draw_circle(pixels, size, (512, 520), 109, rgb("#1f5362"), 1.0)
    draw_circle(pixels, size, (512, 520), 76, rgb("#0e1929"), 1.0)
    draw_circle(pixels, size, (482, 484), 30, rgb("#d5fff8"), 0.65)
    draw_circle(pixels, size, (560, 574), 18, rgb("#61c9bd"), 0.42)
    draw_circle(pixels, size, (286, 430), 38, rgb("#182438"), 0.94)
    draw_circle(pixels, size, (286, 430), 19, rgb("#7ceee1"), 0.95)
    draw_round_rect(pixels, size, (238, 646, 786, 676), 15, rgb("#cfd1c7"), 0.85)

    return pixels


def png_chunk(chunk_type: bytes, data: bytes) -> bytes:
    checksum = zlib.crc32(chunk_type)
    checksum = zlib.crc32(data, checksum)
    return struct.pack(">I", len(data)) + chunk_type + data + struct.pack(">I", checksum)


def write_png(path: Path, width: int, height: int, pixels: bytearray) -> None:
    rows = bytearray()
    stride = width * 4
    for y in range(height):
        rows.append(0)
        rows.extend(pixels[y * stride : (y + 1) * stride])

    data = b"".join(
        (
            b"\x89PNG\r\n\x1a\n",
            png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)),
            png_chunk(b"IDAT", zlib.compress(bytes(rows), 9)),
            png_chunk(b"IEND", b""),
        )
    )
    path.write_bytes(data)


def build_icon(output: Path) -> None:
    iconutil = shutil.which("iconutil")
    if iconutil is None:
        raise SystemExit("iconutil is required to package the iconset into .icns")

    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="camera-app-icon-") as temp_dir:
        iconset = Path(temp_dir) / "AppIcon.iconset"
        iconset.mkdir()
        for filename, pixel_size in ICON_FILES:
            pixels = draw_camera_icon(pixel_size)
            write_png(iconset / filename, pixel_size, pixel_size, pixels)
        subprocess.run(
            [iconutil, "-c", "icns", "-o", str(output), str(iconset)],
            check=True,
        )


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(
        description="Generate the Camera macOS app icon without Xcode asset catalogs."
    )
    parser.add_argument(
        "output",
        nargs="?",
        type=Path,
        default=root / "resources" / "AppIcon.icns",
        help="Path to write the .icns file.",
    )
    args = parser.parse_args()

    build_icon(args.output)
    print(f"Wrote {args.output}")


if __name__ == "__main__":
    main()
