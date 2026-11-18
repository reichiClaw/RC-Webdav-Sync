#!/usr/bin/env python3
"""Erzeugt die App-Icon-PNGs für reichi Sync aus der Logo-Grafik.

Das Logo (schwarzes Hexagon mit „R“ und blau-türkiser Wolke) wird auf einen
abgerundeten, hellen Hintergrund im macOS-Stil gesetzt. Der Rand um die
Kachel bleibt transparent, wie bei macOS-Systemicons üblich.

Aufruf:
    python3 Scripts/generate-icon.py [Logo.svg|Logo.png] [Zielordner]

Standard: Design/logo.svg (falls vorhanden, sonst Design/logo.png) →
          Sources/ReichiSyncApp/Resources/Assets.xcassets/AppIcon.appiconset

Eine SVG-Vorlage wird für jede Icon-Größe verlustfrei in der jeweils benötigten
Auflösung gerendert (per `cairosvg`, ersatzweise `rsvg-convert` oder
`inkscape`). Bei einer PNG-Vorlage wird aus einem 1024-px-Master skaliert.

Benötigt Pillow (`pip3 install pillow`); für SVG zusätzlich
`pip3 install cairosvg` oder `brew install librsvg`.
"""
import io
import os
import shutil
import subprocess
import sys
import tempfile

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


def render_svg(svg_path, px):
    """Rendert das SVG mit `px` Pixeln auf der längeren Seite (Seitenverhältnis bleibt erhalten)."""
    try:
        import cairosvg  # type: ignore
    except ImportError:
        cairosvg = None
    if cairosvg is not None:
        # Erst mit quadratischer Zielgröße rendern; cairosvg behält das Seitenverhältnis des
        # viewBox bei, deshalb anschließend auf den sichtbaren Inhalt zuschneiden.
        data = cairosvg.svg2png(url=svg_path, output_width=px, output_height=px)
        return Image.open(io.BytesIO(data)).convert("RGBA")
    for tool in ("rsvg-convert", "inkscape"):
        exe = shutil.which(tool)
        if not exe:
            continue
        with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as tmp:
            out = tmp.name
        try:
            if tool == "rsvg-convert":
                subprocess.run([exe, "-w", str(px), "-h", str(px), "--keep-aspect-ratio", "-o", out, svg_path], check=True)
            else:
                subprocess.run([exe, svg_path, "--export-type=png", f"--export-width={px}", f"--export-filename={out}"], check=True,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return Image.open(out).convert("RGBA")
        finally:
            try:
                os.remove(out)
            except OSError:
                pass
    sys.exit("Kein SVG-Renderer gefunden: pip3 install cairosvg  (oder brew install librsvg)")


def load_logo(logo_path, target_px):
    """Lädt das Logo so, dass die längere Seite mindestens `target_px` Pixel hat."""
    if logo_path.lower().endswith(".svg"):
        # Etwas größer rendern und dann mit Lanczos auf Zielgröße bringen → glattere Kanten.
        logo = render_svg(logo_path, target_px * 2)
    else:
        logo = Image.open(logo_path).convert("RGBA")
    bbox = logo.getbbox()
    if bbox:
        logo = logo.crop(bbox)
    return logo


def render_icon(logo_path, size):
    """Rendert das fertige Icon (Kachel + Logo) in `size` × `size` Pixeln."""
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

    # Dezenter innerer Rand, proportional zur Größe (4 px bei 1024 px); unter 256 px entfällt er (width=0 zeichnet nichts)
    border = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    bd = ImageDraw.Draw(border)
    bd.rounded_rectangle((inset, inset, size - inset - 1, size - inset - 1), radius=radius, outline=(255, 255, 255, 160), width=size // 256)
    canvas.alpha_composite(border)

    # Logo zentriert, ca. 68 % der Kachelbreite
    target = int(tile * 0.68)
    logo = load_logo(logo_path, target)
    scale = target / max(logo.size)
    logo = logo.resize((max(1, int(logo.width * scale)), max(1, int(logo.height * scale))), Image.LANCZOS)
    x = (size - logo.width) // 2
    y = (size - logo.height) // 2
    canvas.alpha_composite(logo, (x, y))
    return canvas


def default_logo(root):
    svg = os.path.join(root, "Design", "logo.svg")
    return svg if os.path.exists(svg) else os.path.join(root, "Design", "logo.png")


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    logo_path = sys.argv[1] if len(sys.argv) > 1 else default_logo(root)
    target = sys.argv[2] if len(sys.argv) > 2 else os.path.join(
        root, "Sources", "ReichiSyncApp", "Resources", "Assets.xcassets", "AppIcon.appiconset")
    if not os.path.exists(logo_path):
        sys.exit(f"Logo nicht gefunden: {logo_path}")
    os.makedirs(target, exist_ok=True)
    is_vector = logo_path.lower().endswith(".svg")
    print("Vorlage:", logo_path, "(Vektor, pro Größe gerendert)" if is_vector else "(Raster, aus 1024-px-Master skaliert)")
    master = render_icon(logo_path, MASTER)
    master.save(os.path.join(root, "Design", "AppIcon-1024.png"))
    for base, scale in SIZES:
        px = base * scale
        name = f"icon_{base}x{base}.png" if scale == 1 else f"icon_{base}x{base}@{scale}x.png"
        image = render_icon(logo_path, px) if is_vector and px != MASTER else master.resize((px, px), Image.LANCZOS)
        image.save(os.path.join(target, name))
        print("wrote", name)


if __name__ == "__main__":
    main()
