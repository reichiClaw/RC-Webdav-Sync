#!/usr/bin/env python3
"""Erzeugt die App-Icon-PNGs für reichi Sync aus der Logo-Grafik.

Das Logo (schwarzes Hexagon mit „R“ und blau-türkiser Wolke) wird auf einen
abgerundeten, hellen Hintergrund im macOS-Stil gesetzt. Der Rand um die
Kachel bleibt transparent, wie bei macOS-Systemicons üblich.

Aufruf:
    python3 Scripts/generate-icon.py [Logo.png] [Zielordner]

Standard: Design/logo.png →
          Sources/ReichiSyncApp/Resources/Assets.xcassets/AppIcon.appiconset

Benötigt Pillow (`pip3 install pillow`).
"""
import os
import sys

try:
    from PIL import Image, ImageDraw, ImageFilter
except ImportError:  # pragma: no cover
    sys.exit("Pillow fehlt: pip3 install pillow")

SIZES = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
MASTER = 1024


def rounded_mask(size, inset, radius, supersample=4):
    s = size * supersample
    mask = Image.new("L", (s, s), 0)
    draw = ImageDraw.Draw(mask)
    i = inset * supersample
    draw.rounded_rectangle((i, i, s - i - 1, s - i - 1), radius=radius * supersample, fill=255)
    return mask.resize((size, size), Image.LANCZOS)


def vertical_gradient(size, top, bottom):
    grad = Image.new("RGBA", (1, size))
    for y in range(size):
        t = y / max(1, size - 1)
        grad.putpixel((0, y), tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)) + (255,))
    return grad.resize((size, size), Image.BILINEAR)


def render_master(logo_path):
    size = MASTER
    # macOS-Kachel: ~80 % der Fläche, Eckenradius ~22,4 % der Kachel
    inset = int(size * 0.0977)
    tile = size - 2 * inset
    radius = int(tile * 0.224)

    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))

    # Weicher Schatten unter der Kachel
    shadow_mask = rounded_mask(size, inset, radius)
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 90), mask=shadow_mask)
    shadow = shadow.filter(ImageFilter.GaussianBlur(size * 0.012))
    canvas.alpha_composite(shadow, (0, int(size * 0.01)))

    # Heller Verlauf als Hintergrund
    background = vertical_gradient(size, (252, 253, 255), (226, 232, 240))
    tile_mask = rounded_mask(size, inset, radius)
    tile_layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    tile_layer.paste(background, mask=tile_mask)
    canvas.alpha_composite(tile_layer)

    # Dezenter innerer Rand
    border = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    bd = ImageDraw.Draw(border)
    bd.rounded_rectangle((inset, inset, size - inset - 1, size - inset - 1), radius=radius, outline=(255, 255, 255, 160), width=max(2, size // 256))
    canvas.alpha_composite(border)

    # Logo zentriert, ca. 68 % der Kachelbreite
    logo = Image.open(logo_path).convert("RGBA")
    bbox = logo.getbbox()
    if bbox:
        logo = logo.crop(bbox)
    target = int(tile * 0.68)
    scale = target / max(logo.size)
    logo = logo.resize((max(1, int(logo.width * scale)), max(1, int(logo.height * scale))), Image.LANCZOS)
    x = (size - logo.width) // 2
    y = (size - logo.height) // 2
    canvas.alpha_composite(logo, (x, y))
    return canvas


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    logo_path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(root, "Design", "logo.png")
    target = sys.argv[2] if len(sys.argv) > 2 else os.path.join(
        root, "Sources", "ReichiSyncApp", "Resources", "Assets.xcassets", "AppIcon.appiconset")
    os.makedirs(target, exist_ok=True)
    master = render_master(logo_path)
    master.save(os.path.join(root, "Design", "AppIcon-1024.png"))
    for base, scale in SIZES:
        px = base * scale
        name = f"icon_{base}x{base}.png" if scale == 1 else f"icon_{base}x{base}@{scale}x.png"
        master.resize((px, px), Image.LANCZOS).save(os.path.join(target, name))
        print("wrote", name)


if __name__ == "__main__":
    main()
