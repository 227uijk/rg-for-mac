#!/usr/bin/env python3
from __future__ import annotations

import math
import shutil
import subprocess
from datetime import datetime
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont


BASE = Path(__file__).resolve().parent
ICONSET = BASE / "RGForMac.iconset"
ICNS = BASE / "RGForMac.icns"
TRASH = BASE / ".build-trash"


def move_aside(path: Path) -> None:
    if not path.exists():
        return
    TRASH.mkdir(exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    shutil.move(str(path), str(TRASH / f"{path.name}.{stamp}"))


def rounded_rect_mask(size: int, radius: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle((0, 0, size - 1, size - 1), radius=radius, fill=255)
    return mask


def linear_gradient(size: int) -> Image.Image:
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    px = img.load()
    top = (20, 42, 58)
    bottom = (8, 95, 86)
    glow = (43, 167, 126)
    for y in range(size):
        t = y / (size - 1)
        for x in range(size):
            cx = (x - size * 0.72) / (size * 0.55)
            cy = (y - size * 0.26) / (size * 0.45)
            g = max(0.0, 1.0 - math.sqrt(cx * cx + cy * cy))
            r = int(top[0] * (1 - t) + bottom[0] * t + glow[0] * g * 0.30)
            gg = int(top[1] * (1 - t) + bottom[1] * t + glow[1] * g * 0.30)
            b = int(top[2] * (1 - t) + bottom[2] * t + glow[2] * g * 0.30)
            px[x, y] = (min(r, 255), min(gg, 255), min(b, 255), 255)
    return img


def font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    candidates = [
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf" if bold else "/System/Library/Fonts/Supplemental/Arial.ttf",
        "/System/Library/Fonts/Supplemental/Helvetica Bold.ttf" if bold else "/System/Library/Fonts/Supplemental/Helvetica.ttf",
        "/System/Library/Fonts/SFNS.ttf",
    ]
    for candidate in candidates:
        try:
            return ImageFont.truetype(candidate, size)
        except OSError:
            continue
    return ImageFont.load_default()


def draw_centered_text(draw: ImageDraw.ImageDraw, box: tuple[int, int, int, int], text: str, fnt: ImageFont.ImageFont, fill: tuple[int, int, int, int]) -> None:
    bbox = draw.textbbox((0, 0), text, font=fnt)
    width = bbox[2] - bbox[0]
    height = bbox[3] - bbox[1]
    x = box[0] + ((box[2] - box[0]) - width) / 2 - bbox[0]
    y = box[1] + ((box[3] - box[1]) - height) / 2 - bbox[1]
    draw.text((x, y), text, font=fnt, fill=fill)


def make_master() -> Image.Image:
    scale = 2
    size = 1024 * scale
    icon = Image.new("RGBA", (size, size), (0, 0, 0, 0))

    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow)
    shadow_draw.rounded_rectangle(
        (112 * scale, 124 * scale, 912 * scale, 924 * scale),
        radius=196 * scale,
        fill=(0, 0, 0, 95),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(34 * scale))
    icon.alpha_composite(shadow)

    base = linear_gradient(size)
    mask = Image.new("L", (size, size), 0)
    mask_draw = ImageDraw.Draw(mask)
    mask_draw.rounded_rectangle(
        (92 * scale, 84 * scale, 932 * scale, 924 * scale),
        radius=204 * scale,
        fill=255,
    )
    icon.paste(base, (0, 0), mask)

    draw = ImageDraw.Draw(icon)
    draw.rounded_rectangle(
        (92 * scale, 84 * scale, 932 * scale, 924 * scale),
        radius=204 * scale,
        outline=(255, 255, 255, 42),
        width=6 * scale,
    )

    # Soft signal arcs.
    arc_color = (119, 238, 190, 88)
    for inset, width in [(228, 22), (300, 18), (372, 14)]:
        draw.arc(
            (inset * scale, (inset - 28) * scale, (1024 - inset) * scale, (1024 - inset + 28) * scale),
            start=205,
            end=335,
            fill=arc_color,
            width=width * scale,
        )

    # Cable line.
    line = (88, 242, 183, 255)
    dark_line = (7, 67, 65, 180)
    points = [
        (258 * scale, 624 * scale),
        (376 * scale, 624 * scale),
        (460 * scale, 540 * scale),
        (564 * scale, 540 * scale),
        (650 * scale, 624 * scale),
        (770 * scale, 624 * scale),
    ]
    draw.line(points, fill=dark_line, width=54 * scale, joint="curve")
    draw.line(points, fill=line, width=34 * scale, joint="curve")

    # Connector blocks.
    for x in (198, 756):
        draw.rounded_rectangle(
            (x * scale, 570 * scale, (x + 112) * scale, 678 * scale),
            radius=30 * scale,
            fill=(216, 255, 238, 255),
        )
        draw.rounded_rectangle(
            ((x + 24) * scale, 604 * scale, (x + 88) * scale, 644 * scale),
            radius=12 * scale,
            fill=(17, 97, 84, 255),
        )

    # Center badge.
    badge_box = (360 * scale, 286 * scale, 664 * scale, 590 * scale)
    draw.ellipse(badge_box, fill=(232, 255, 246, 255))
    draw.ellipse(badge_box, outline=(58, 213, 164, 255), width=14 * scale)
    draw_centered_text(draw, badge_box, "R", font(178 * scale, bold=True), (10, 80, 75, 255))

    # Small online indicator.
    draw.ellipse((686 * scale, 302 * scale, 792 * scale, 408 * scale), fill=(55, 225, 134, 255))
    draw.ellipse((718 * scale, 334 * scale, 760 * scale, 376 * scale), fill=(237, 255, 245, 255))

    return icon.resize((1024, 1024), Image.Resampling.LANCZOS)


def main() -> None:
    move_aside(ICONSET)
    move_aside(ICNS)
    ICONSET.mkdir()
    master = make_master()
    sizes = [
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
    ]
    for name, size in sizes:
        master.resize((size, size), Image.Resampling.LANCZOS).save(ICONSET / name)
    try:
        subprocess.run(
            ["/usr/bin/iconutil", "-c", "icns", "-o", str(ICNS), str(ICONSET)],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except subprocess.CalledProcessError:
        master.save(
            ICNS,
            format="ICNS",
            sizes=[(16, 16), (32, 32), (64, 64), (128, 128), (256, 256), (512, 512), (1024, 1024)],
        )
    print(ICNS)


if __name__ == "__main__":
    main()
