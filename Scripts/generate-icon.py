#!/usr/bin/env python3
"""Erzeugt die App-Icon-PNGs für reichi Sync ohne externe Abhängigkeiten.

Motiv: abgerundetes Quadrat mit Farbverlauf und zwei gegenläufigen Pfeilen
(Kreis-Synchronisierung). Aufruf:

    python3 Scripts/generate-icon.py [Zielordner]

Standardziel: Sources/ReichiSyncApp/Resources/Assets.xcassets/AppIcon.appiconset
"""
import math
import os
import struct
import sys
import zlib

SIZES = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]


def write_png(path, width, height, rows):
    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    raw = b"".join(b"\x00" + bytes(row) for row in rows)
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


def smoothstep(edge0, edge1, x):
    t = max(0.0, min(1.0, (x - edge0) / (edge1 - edge0)))
    return t * t * (3 - 2 * t)


def rounded_rect_coverage(x, y, size, radius, inset):
    # Signed distance to rounded rectangle; coverage via smoothstep for anti-aliasing.
    half = size / 2 - inset
    cx, cy = x - size / 2, y - size / 2
    qx, qy = abs(cx) - half + radius, abs(cy) - half + radius
    d = math.hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - radius
    return 1 - smoothstep(-0.8, 0.8, d)


def arrow_coverage(x, y, size):
    """Zwei Kreisbogen-Pfeile (oben und unten) in Weiß."""
    cx, cy = size / 2, size / 2
    r = size * 0.27
    thickness = size * 0.075
    dx, dy = x - cx, y - cy
    dist = math.hypot(dx, dy)
    angle = math.atan2(dy, dx)  # -pi..pi, y nach unten
    cov = 0.0
    ring = 1 - smoothstep(thickness / 2 - 0.8, thickness / 2 + 0.8, abs(dist - r))
    # Bogen 1: von 200° bis 330° (oben), Bogen 2: von 20° bis 150° (unten)
    deg = (math.degrees(angle) + 360) % 360
    in_arc1 = 200 <= deg <= 320
    in_arc2 = 20 <= deg <= 140
    if in_arc1 or in_arc2:
        cov = max(cov, ring)
    # Pfeilspitzen als Dreiecke an den Bogenenden
    for tip_deg, direction in ((320, 1), (140, 1)):
        a = math.radians(tip_deg)
        tx, ty = cx + r * math.cos(a), cy + r * math.sin(a)
        # Tangentenrichtung
        tdx, tdy = -math.sin(a) * direction, math.cos(a) * direction
        # lokaler Koordinatenrahmen
        px, py = x - tx, y - ty
        along = px * tdx + py * tdy
        across = abs(px * -tdy + py * tdx)
        head_len = size * 0.16
        head_w = size * 0.11
        if 0 <= along <= head_len:
            w = head_w * (1 - along / head_len)
            cov = max(cov, 1 - smoothstep(w - 0.8, w + 0.8, across))
    return cov


def render(size):
    rows = []
    inset = size * 0.04
    radius = size * 0.22
    for y in range(size):
        row = bytearray()
        for x in range(size):
            px, py = x + 0.5, y + 0.5
            bg = rounded_rect_coverage(px, py, size, radius, inset)
            t = (px + py) / (2 * size)
            r = int(30 + (70 - 30) * t)
            g = int(110 + (160 - 110) * t)
            b = int(230 + (245 - 230) * t)
            a = arrow_coverage(px, py, size)
            # Weiß über Verlauf mischen
            r = int(r + (255 - r) * a)
            g = int(g + (255 - g) * a)
            b = int(b + (255 - b) * a)
            row += bytes((r, g, b, int(255 * bg)))
        rows.append(row)
    return rows


def main():
    target = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        "Sources", "ReichiSyncApp", "Resources", "Assets.xcassets", "AppIcon.appiconset")
    os.makedirs(target, exist_ok=True)
    for base, scale in SIZES:
        px = base * scale
        name = f"icon_{base}x{base}.png" if scale == 1 else f"icon_{base}x{base}@{scale}x.png"
        write_png(os.path.join(target, name), px, px, render(px))
        print("wrote", name)


if __name__ == "__main__":
    main()
