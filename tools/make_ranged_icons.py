"""Draws placeholder icons for the ranged example weapons into
assets/test_item_icons/, 98 px per inventory cell like test_sword.png.
Run from the project root: python tools/make_ranged_icons.py"""
from PIL import Image, ImageDraw

CELL = 98
WOOD = (139, 94, 52, 255)
DARK_WOOD = (96, 62, 33, 255)
STEEL = (170, 176, 186, 255)
DARK_STEEL = (70, 74, 82, 255)
STRING = (230, 225, 205, 255)
GRIP = (52, 40, 32, 255)


def canvas(w, h):
    return Image.new("RGBA", (w * CELL, h * CELL), (0, 0, 0, 0))


def bow():
    im = canvas(1, 4)
    d = ImageDraw.Draw(im)
    W, H = im.size
    d.arc([-W * 0.9, 12, W * 0.75, H - 12], -80, 80, fill=WOOD, width=12)
    d.line([(W * 0.5, 22), (W * 0.5, H - 22)], fill=STRING, width=3)
    d.rectangle([W * 0.62, H * 0.45, W * 0.78, H * 0.55], fill=GRIP)
    return im


def crossbow():
    im = canvas(2, 3)
    d = ImageDraw.Draw(im)
    W, H = im.size
    d.rectangle([W * 0.44, H * 0.12, W * 0.56, H * 0.95], fill=WOOD)
    d.arc([W * 0.06, H * 0.12, W * 0.94, H * 0.5], 190, 350, fill=DARK_STEEL, width=12)
    d.line([(W * 0.1, H * 0.25), (W * 0.5, H * 0.38), (W * 0.9, H * 0.25)], fill=STRING, width=3)
    d.polygon([(W * 0.5, H * 0.04), (W * 0.45, H * 0.14), (W * 0.55, H * 0.14)], fill=STEEL)
    d.rectangle([W * 0.42, H * 0.7, W * 0.58, H * 0.95], fill=DARK_WOOD)
    return im


def throwing_axe():
    im = canvas(1, 2)
    d = ImageDraw.Draw(im)
    W, H = im.size
    d.rectangle([W * 0.44, H * 0.08, W * 0.56, H * 0.95], fill=WOOD)
    d.polygon([(W * 0.56, H * 0.1), (W * 0.95, H * 0.04), (W * 0.9, H * 0.36), (W * 0.56, H * 0.28)], fill=STEEL)
    d.line([(W * 0.95, H * 0.04), (W * 0.9, H * 0.36)], fill=(235, 240, 245, 255), width=4)
    d.rectangle([W * 0.42, H * 0.75, W * 0.58, H * 0.95], fill=GRIP)
    return im


def pistol():
    im = canvas(2, 2)
    d = ImageDraw.Draw(im)
    W, H = im.size
    d.rectangle([W * 0.1, H * 0.25, W * 0.9, H * 0.42], fill=DARK_STEEL)
    d.polygon([(W * 0.55, H * 0.42), (W * 0.85, H * 0.42), (W * 0.78, H * 0.88), (W * 0.58, H * 0.88)], fill=GRIP)
    d.arc([W * 0.4, H * 0.38, W * 0.6, H * 0.6], 0, 180, fill=DARK_STEEL, width=5)
    d.rectangle([W * 0.1, H * 0.25, W * 0.9, H * 0.28], fill=STEEL)
    return im


def rifle():
    im = canvas(2, 4)
    d = ImageDraw.Draw(im)
    W, H = im.size
    d.rectangle([W * 0.46, H * 0.03, W * 0.54, H * 0.5], fill=DARK_STEEL)
    d.rectangle([W * 0.4, H * 0.4, W * 0.6, H * 0.68], fill=DARK_STEEL)
    d.polygon([(W * 0.6, H * 0.5), (W * 0.82, H * 0.52), (W * 0.78, H * 0.6), (W * 0.6, H * 0.6)], fill=DARK_STEEL)
    d.polygon([(W * 0.4, H * 0.66), (W * 0.6, H * 0.66), (W * 0.66, H * 0.97), (W * 0.36, H * 0.97)], fill=WOOD)
    d.rectangle([W * 0.3, H * 0.5, W * 0.4, H * 0.62], fill=GRIP)
    return im


for name, draw in [("test_bow", bow), ("test_crossbow", crossbow), ("test_throwing_axe", throwing_axe),
                   ("test_pistol", pistol), ("test_rifle", rifle)]:
    draw().save(f"assets/test_item_icons/{name}.png")
    print(name)
