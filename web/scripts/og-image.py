#!/usr/bin/env python3
"""Renders public/og.png (1200x630): the app icon, the name, the tagline and a small
dark notch alert on the site's graphite background, in Inter.

Run from web/:  INTER_FONTS=/path/to/inter/ttfs python3 scripts/og-image.py
(needs Pillow: pip install pillow). INTER_FONTS is a folder holding Inter-Regular.ttf,
Inter-Medium.ttf and Inter-SemiBold.ttf (Pillow cannot read the site's woff2 subsets).
Without it, the script falls back to Helvetica from macOS."""
import os
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

WEB = Path(__file__).resolve().parent.parent
W, H = 1200, 630
BG, TEXT, MUTED = (0x12, 0x12, 0x16), (0xF2, 0xF4, 0xF7), (0x9B, 0xA1, 0xAB)
PINK = (0xDE, 0x99, 0xB0)


def font(weight: str, size: int) -> ImageFont.FreeTypeFont:
    folder = os.environ.get("INTER_FONTS")
    if folder:
        return ImageFont.truetype(str(Path(folder) / f"Inter-{weight}.ttf"), size)
    index = {"Regular": 0, "Medium": 0, "SemiBold": 1}[weight]
    return ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", size, index=index)


card = Image.new("RGBA", (W, H), BG + (255,))

# The icon is full-bleed; round it like a macOS app icon.
icon = Image.open(WEB / "src/assets/icon.png").convert("RGBA").resize((200, 200), Image.LANCZOS)
mask = Image.new("L", (800, 800), 0)
ImageDraw.Draw(mask).rounded_rectangle((0, 0, 799, 799), radius=180, fill=255)
icon.putalpha(mask.resize((200, 200), Image.LANCZOS))
card.alpha_composite(icon, (96, 110))

draw = ImageDraw.Draw(card)
draw.text((340, 118), "Squish", font=font("SemiBold", 80), fill=TEXT)
lead = font("Regular", 34)
draw.text((340, 222), "Token costs, context alerts and live", font=lead, fill=TEXT)
draw.text((340, 268), "chats for your coding agents, on a Mac.", font=lead, fill=TEXT)

# A small black island hanging from the top edge, like the app's compact alert.
island = (720, 0, 1110, 92)
draw.rounded_rectangle(island, radius=30, fill=(0, 0, 0))
draw.rectangle((720, 0, 1110, 30), fill=(0, 0, 0))
draw.ellipse((744, 22, 790, 68), fill=(0x3A, 0x26, 0x2D))
draw.ellipse((759, 37, 775, 53), fill=PINK)
draw.text((806, 20), "COMPACT SOON", font=font("SemiBold", 14), fill=PINK)
draw.text((806, 40), "Claude Code session", font=font("Medium", 18), fill=(255, 255, 255))
draw.rounded_rectangle((806, 70, 966, 74), radius=2, fill=(0x33, 0x33, 0x33))
draw.rounded_rectangle((806, 70, 806 + int(160 * 0.84), 74), radius=2, fill=PINK)
draw.text((978, 63), "84%", font=font("Medium", 15), fill=(0xB3, 0xB3, 0xB3))

small = font("Medium", 26)
draw.text((96, 470), "Codex  ·  Claude Code  ·  Gemini CLI  ·  Free and open source  ·  Local only", font=small, fill=MUTED)
draw.text((96, 512), "squish.quassum.com", font=small, fill=MUTED)

card.convert("RGB").save(WEB / "public/og.png", optimize=True)
print("wrote", WEB / "public/og.png", card.size)
