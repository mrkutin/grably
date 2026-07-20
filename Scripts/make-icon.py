#!/usr/bin/env python3
"""Generate the Grably app icon (Pac-Man eating one YouTube button).

Renders a master SVG to icon.png / lockup.png and all AppIcon sizes.
Requires: rsvg-convert (brew install librsvg), Pillow.
"""
import math
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# --- Brand palette (sampled from the original icon) ---------------------------
NAVY = "#1E2A4A"
YELLOW = "#FFC43D"
RED = "#FF0000"
WHITE = "#FFFFFF"
AMBER = "#C9821A"

S = 1024  # master canvas


def pac_and_button_svg(cx, cy, r, button_gap, button_size, mouth_deg=38.0):
    """Return SVG fragment: a Pac-Man centred at (cx,cy) with radius r, mouth
    opening to the right, plus one YouTube play button just past the mouth."""
    a = math.radians(mouth_deg)
    ux, uy = cx + r * math.cos(-a), cy + r * math.sin(-a)  # upper lip
    lx, ly = cx + r * math.cos(a), cy + r * math.sin(a)    # lower lip
    # Large arc the long way round (exclude the wedge), sweep clockwise.
    pac = (f'<path d="M {cx:.2f} {cy:.2f} L {ux:.2f} {uy:.2f} '
           f'A {r:.2f} {r:.2f} 0 1 0 {lx:.2f} {ly:.2f} Z" fill="{YELLOW}"/>')
    # Eye: upper area, slightly forward of centre.
    eye_r = r * 0.11
    ex, ey = cx + r * 0.05, cy - r * 0.42
    eye = f'<circle cx="{ex:.2f}" cy="{ey:.2f}" r="{eye_r:.2f}" fill="{NAVY}"/>'

    # YouTube button in the mouth.
    bs = button_size
    bx = cx + r + button_gap          # left edge of button
    by = cy - bs / 2
    rad = bs * 0.22
    # play triangle centred in the button
    tw = bs * 0.30
    th = bs * 0.34
    tcx, tcy = bx + bs / 2, by + bs / 2
    tri = (f'<path d="M {tcx - tw*0.4:.2f} {tcy - th/2:.2f} '
           f'L {tcx + tw*0.6:.2f} {tcy:.2f} '
           f'L {tcx - tw*0.4:.2f} {tcy + th/2:.2f} Z" fill="{WHITE}"/>')
    btn = (f'<rect x="{bx:.2f}" y="{by:.2f}" width="{bs:.2f}" height="{bs:.2f}" '
           f'rx="{rad:.2f}" ry="{rad:.2f}" fill="{RED}"/>{tri}')
    return pac + eye + btn


def icon_inner():
    """The icon artwork (rounded navy tile + Pac-Man + button) in 0..S space."""
    inset = S * 0.03125
    rside = S - 2 * inset
    rx = S * 0.18
    cx, cy = S / 2, S / 2
    r = S * 0.27
    # button tucked into the mouth, close to the lips
    body = pac_and_button_svg(cx, cy, r, button_gap=-r*0.30, button_size=r*0.70)
    return (f'<rect x="{inset:.2f}" y="{inset:.2f}" width="{rside:.2f}" '
            f'height="{rside:.2f}" rx="{rx:.2f}" ry="{rx:.2f}" fill="{NAVY}"/>'
            f'{body}')


def icon_svg():
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{S}" height="{S}" '
            f'viewBox="0 0 {S} {S}">{icon_inner()}</svg>')


def lockup_svg():
    """Horizontal brand lockup: icon + 'Grably' wordmark + motto (680x240)."""
    W, H = 680, 240
    tile = 200            # rendered icon size
    scale = tile / S
    icon = (f'<g transform="translate(20,20) scale({scale:.5f})">'
            f'{icon_inner()}</g>')
    tx = 250
    title = (f'<text x="{tx}" y="150" font-family="Helvetica" font-weight="bold" '
             f'font-size="100" fill="{NAVY}" '
             f'letter-spacing="-2">Grably</text>')
    motto = (f'<text x="{tx+4}" y="185" font-family="Helvetica" '
             f'font-size="31" fill="{AMBER}">grab any video</text>')
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" '
            f'viewBox="0 0 {W} {H}">{icon}{title}{motto}</svg>')


def render(svg, out_png, w, h=None):
    h = h or w
    svg_path = out_png + ".svg"
    with open(svg_path, "w") as f:
        f.write(svg)
    subprocess.run(["rsvg-convert", "-w", str(w), "-h", str(h),
                    svg_path, "-o", out_png], check=True)
    os.remove(svg_path)


def main():
    svg = icon_svg()
    render(svg, os.path.join(ROOT, "icon.png"), 256)
    render(lockup_svg(), os.path.join(ROOT, "lockup.png"), 680, 240)
    # AppIcon set
    appicon = os.path.join(ROOT, "Resources/Assets.xcassets/AppIcon.appiconset")
    sizes = {"16x16@1x":16, "16x16@2x":32, "32x32@1x":32, "32x32@2x":64,
             "128x128@1x":128, "128x128@2x":256, "256x256@1x":256,
             "256x256@2x":512, "512x512@1x":512, "512x512@2x":1024}
    for name, px in sizes.items():
        render(svg, os.path.join(appicon, f"icon_{name}.png"), px)
    print("Icon regenerated.")


if __name__ == "__main__":
    main()
