#!/usr/bin/env python3
"""Generates the LLMProbe app icon as an .icns bundle.

The mark is a rounded-square gradient tile with a signal pulse and a probe dot:
upstream connectivity plus measured output, which is what the app reports.

Usage: python3 scripts/make_icon.py docs/images/AppIcon.icns
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

try:
    from PIL import Image, ImageDraw
except ImportError:  # pragma: no cover - helper script
    print("Pillow is required: python3 -m pip install pillow", file=sys.stderr)
    raise SystemExit(1)

SIZE = 1024
BACKGROUND_TOP = (86, 108, 255)
BACKGROUND_BOTTOM = (150, 84, 240)
PULSE = (255, 255, 255)
ACCENT = (120, 255, 214)


def rounded_mask(size: int, radius_ratio: float = 0.2237) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    radius = int(size * radius_ratio)
    draw.rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return mask


def gradient(size: int) -> Image.Image:
    image = Image.new("RGB", (size, size))
    draw = ImageDraw.Draw(image)
    for y in range(size):
        t = y / max(1, size - 1)
        # Ease the blend so the top-left stays saturated.
        t = t ** 0.85
        color = tuple(
            int(BACKGROUND_TOP[i] + (BACKGROUND_BOTTOM[i] - BACKGROUND_TOP[i]) * t)
            for i in range(3)
        )
        draw.line([(0, y), (size, y)], fill=color)
    return image


def draw_pulse(image: Image.Image) -> None:
    draw = ImageDraw.Draw(image)
    size = image.size[0]
    stroke = int(size * 0.055)
    mid = size * 0.54

    # Control points describe a heartbeat: flat, small dip, tall spike, flat.
    points = [
        (0.14, mid),
        (0.31, mid),
        (0.38, mid - size * 0.10),
        (0.46, mid + size * 0.18),
        (0.55, mid - size * 0.26),
        (0.64, mid + size * 0.06),
        (0.72, mid),
        (0.86, mid),
    ]
    coords = [(size * x, y) for x, y in points]
    draw.line(coords, fill=PULSE, width=stroke, joint="curve")

    for x, y in (coords[0], coords[-1]):
        r = stroke * 0.62
        draw.ellipse([x - r, y - r, x + r, y + r], fill=PULSE)

    # Probe dot: the measurement point.
    cx, cy = size * 0.72, mid
    r_outer = size * 0.072
    r_inner = size * 0.033
    draw.ellipse([cx - r_outer, cy - r_outer, cx + r_outer, cy + r_outer], fill=PULSE)
    draw.ellipse([cx - r_inner, cy - r_inner, cx + r_inner, cy + r_inner], fill=ACCENT)


def build_master() -> Image.Image:
    base = gradient(SIZE)
    draw_pulse(base)
    base.putalpha(rounded_mask(SIZE))
    return base


def write_icns(master: Image.Image, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        iconset = Path(tmp) / "AppIcon.iconset"
        iconset.mkdir()
        specs = [
            (16, "icon_16x16.png"),
            (32, "icon_16x16@2x.png"),
            (32, "icon_32x32.png"),
            (64, "icon_32x32@2x.png"),
            (128, "icon_128x128.png"),
            (256, "icon_128x128@2x.png"),
            (256, "icon_256x256.png"),
            (512, "icon_256x256@2x.png"),
            (512, "icon_512x512.png"),
            (1024, "icon_512x512@2x.png"),
        ]
        for pixels, name in specs:
            master.resize((pixels, pixels), Image.LANCZOS).save(iconset / name)
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(destination)], check=True)


def main() -> None:
    target = Path(sys.argv[1] if len(sys.argv) > 1 else "docs/images/AppIcon.icns")
    master = build_master()
    png_target = target.with_suffix(".png")
    png_target.parent.mkdir(parents=True, exist_ok=True)
    master.save(png_target)
    write_icns(master, target)
    print(f"wrote {png_target} and {target}")


if __name__ == "__main__":
    main()
