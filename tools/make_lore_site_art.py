"""The game's own art for Lorebound's site (lb.frogwizard.net): each zone's map, fully revealed, and each
dungeon's and raid's journal painting, as small WebP files in site/public/art/; with the
addon's badge frames and masks (badge-<shape>.png) and the icons its class and profession badges show
(icon-<name>.webp, listed in icons.json by zone), so the site's badges are the journal's own.

    python make_lore_site_art.py

Reads the zones and the overlays (reveal) from Lorebound_Data/Data.lua, so run make_lore.py first. Names
follow what they show (map-<uiMapID>.webp, ej-<fileID>.webp), so a new quest list reuses them; files already
made are kept unless --force.
"""
import io
import json
import math
import os
import re
import sys

import lupa
from PIL import Image

import db2
from game_files import GameFiles
from make_lore import blp_bytes

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "..", "Lorebound_Data", "Data.lua")
OUT = os.path.join(HERE, "..", "site", "public", "art")
UI_MAP_ART, UI_MAP_ART_STYLE_LAYER, UI_MAP_ART_TILE, UI_MAP_X_MAP_ART = 1957202, 1957208, 1957210, 1957217
MAP_SIZE = (640, 427)      # a map's 1002 x 668, scaled
JOURNAL_CROP = (394, 425)  # the journal's paintings fill this much of their 512 x 512 file
JOURNAL_WIDTH = 320
EXTRA_MAPS = (947, 1415, 1414)  # Azeroth (the overview) and the continents (their crests)
QUALITY = 72
MEDIA = os.path.join(HERE, "..", "Media")
BADGE_LUA = os.path.join(HERE, "..", "Badge.lua")
SHAPES = ("Medal", "Shield", "Crest", "Hex")
SEAL_ICON = "INV_Misc_Book_09"  # the Lorebound Seal (Badge.lua)
ICON_SIZE = 64
PARCHMENT_BOX = (25, 84, 321, 418)  # the page inside the quest window (384 x 512), torn edges included
PLATE_BOX = (11, 11, 117, 53)       # the plate's drawn part of its 128 x 64 file


def load_data():
    lua = lupa.LuaRuntime()
    with open(DATA, encoding="utf-8") as f:
        lua.execute(f.read())
    data = lua.globals().LoreboundData
    zones = [tuple(zone[i] for i in range(1, 5)) for zone in data.zones.values()]
    reveal = {}
    for art, overlays in data.reveal.items():
        reveal[art] = [[overlay[i] for i in range(1, len(overlay) + 1)] for overlay in overlays.values()]
    return zones, reveal


def blp(casc, fid, name=None):
    raw = casc.read_name(name) if name else casc.read_fdid(fid)
    return blp_bytes(raw) if raw else None


def parchment(casc, force=False):
    """The page of Classic's quest window: its four corner textures (QuestFrameTemplates.xml's
    UI-QuestGreeting-*) put together as the game draws them, and the parchment cut out of the frame. Made once
    (kept unless force)."""
    if not force and all(os.path.exists(os.path.join(OUT, name)) for name in ("parchment.webp", "reward-plate.png")):
        return
    corners = {corner: blp(casc, None, "interface/questframe/ui-questgreeting-%s.blp" % corner)
               for corner in ("topleft", "topright", "botleft", "botright")}
    left, top = corners["topleft"].size
    window = Image.new("RGBA", (left + corners["topright"].width, top + corners["botleft"].height))
    window.paste(corners["topleft"], (0, 0))
    window.paste(corners["topright"], (left, 0))
    window.paste(corners["botleft"], (0, top))
    window.paste(corners["botright"], (left, top))
    window.convert("RGB").crop(PARCHMENT_BOX).save(os.path.join(OUT, "parchment.webp"), "WEBP", quality=85, method=6)
    # A reward's name plate (UI-QuestItemNameFrame, as ItemButtonTemplate.xml draws it beside the icon).
    plate = Image.open(io.BytesIO(casc.read_name("interface/questframe/ui-questitemnameframe.blp"))).convert("RGBA")
    plate.crop(PLATE_BOX).save(os.path.join(OUT, "reward-plate.png"), optimize=True)


class Maps:
    def __init__(self, casc):
        self.casc = casc
        read = lambda fid: db2.read(casc.read_fdid(fid))[0]
        self.art_of = {}
        for row in read(UI_MAP_X_MAP_ART).values():
            if row[0] == 0:  # no phase
                self.art_of[row[2][1]] = row[1]
        self.style_of = {art: row[2] for art, row in read(UI_MAP_ART).items()}
        self.layer = {}
        for row in read(UI_MAP_ART_STYLE_LAYER).values():
            if row[0] == 0:
                self.layer[row[-1][1]] = (row[1], row[2], row[3], row[4])  # width, height, tile width, height
        self.tiles = {}
        for row in read(UI_MAP_ART_TILE).values():
            if row[2] == 0:
                self.tiles.setdefault(row[-1][1], []).append((row[0], row[1], row[3]))  # row, column, file

    def draw(self, ui_map, reveal):
        """The map's art with every sub-zone's overlay painted on, at its own size; None without art."""
        art = self.art_of.get(ui_map)
        layer = art and self.layer.get(self.style_of.get(art))
        if not layer or art not in self.tiles:
            return None
        width, height, tile_w, tile_h = layer
        canvas = Image.new("RGBA", (width, height), (0, 0, 0, 255))
        for row, col, fid in self.tiles[art]:
            tile = blp(self.casc, fid)
            if tile:
                canvas.alpha_composite(tile.crop((0, 0, min(tile_w, width - col * tile_w), min(tile_h, height - row * tile_h))),
                                       (col * tile_w, row * tile_h))
        for overlay in reveal.get(art, []):
            overlay_w, overlay_h, x, y, files = overlay[0], overlay[1], overlay[2], overlay[3], overlay[4:]
            cols, rows = math.ceil(overlay_w / tile_w), math.ceil(overlay_h / tile_h)
            for tile_row in range(rows):
                for tile_col in range(cols):
                    index = tile_row * cols + tile_col
                    tile = index < len(files) and blp(self.casc, files[index])
                    if not tile:
                        continue
                    part_w = tile_w if tile_col < cols - 1 else overlay_w - tile_w * (cols - 1)
                    part_h = tile_h if tile_row < rows - 1 else overlay_h - tile_h * (rows - 1)
                    part_x, part_y = x + tile_w * tile_col, y + tile_h * tile_row
                    part = tile.crop((0, 0, min(part_w, width - part_x), min(part_h, height - part_y)))
                    if part.width > 0 and part.height > 0:
                        canvas.alpha_composite(part, (part_x, part_y))
        return canvas.convert("RGB")


def save(image, name):
    image.save(os.path.join(OUT, name), "WEBP", quality=QUALITY, method=6)


def zone_icons():
    """Badge.lua's ZONE_ICONS: { zone name: icon file name }, read from the addon so there's one list."""
    source = open(BADGE_LUA, encoding="utf-8").read()
    block = source[source.index("local ZONE_ICONS = {"):]
    block = block[:block.index("\n}")]
    found = re.findall(r'(?:\["([^"]+)"\]|(\w+))\s*=\s*"([^"]+)"', block)
    return {(quoted or bare): icon for quoted, bare, icon in found}


def badges_and_icons(casc, force=False):
    """The badge frames and masks as PNG, and each class and profession badge's icon (plus the Seal's)."""
    for shape in SHAPES:
        for suffix in ("", "Mask"):
            Image.open(os.path.join(MEDIA, "Badge%s%s.tga" % (shape, suffix))).save(
                os.path.join(OUT, "badge-%s%s.png" % (shape.lower(), "-mask" if suffix else "")), optimize=True)
    icons = dict(zone_icons(), **{"Lorebound Seal": SEAL_ICON})
    listing = {}
    for zone, icon in sorted(icons.items()):
        name = "icon-%s.webp" % re.sub(r"[^a-z0-9]+", "-", icon.lower()).strip("-")
        if not force and os.path.exists(os.path.join(OUT, name)):  # made before: no download
            listing[zone] = name
            continue
        raw = casc.read_name("interface/icons/%s.blp" % icon.lower())
        if not raw:
            print("  no icon", icon)
            continue
        image = Image.open(io.BytesIO(raw)).convert("RGB").resize((ICON_SIZE, ICON_SIZE), Image.LANCZOS)
        save(image, name)
        listing[zone] = name
    with open(os.path.join(OUT, "icons.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(listing, f, indent=0, sort_keys=True)
    return len(listing)


def main():
    force = "--force" in sys.argv
    os.makedirs(OUT, exist_ok=True)
    zones, reveal = load_data()
    casc = GameFiles()
    maps = Maps(casc)
    ui_maps = sorted({zone[2] for zone in zones if zone[2] and not zone[3]} | set(EXTRA_MAPS))  # dungeons show their painting
    journals = sorted({zone[3] for zone in zones if isinstance(zone[3], int)})
    paintings = [zone[3] for zone in zones if zone[3] is not None and not isinstance(zone[3], int)]
    made = kept = missing = 0
    for ui_map in ui_maps:
        name = "map-%d.webp" % ui_map
        if not force and os.path.exists(os.path.join(OUT, name)):
            kept += 1
            continue
        image = maps.draw(ui_map, reveal)
        if image is None:
            missing += 1
            continue
        save(image.resize(MAP_SIZE, Image.LANCZOS), name)
        made += 1
    for fid in journals:
        name = "ej-%d.webp" % fid
        if not force and os.path.exists(os.path.join(OUT, name)):
            kept += 1
            continue
        image = blp(casc, fid)
        if image is None:
            missing += 1
            continue
        painting = image.convert("RGB").crop((0, 0) + JOURNAL_CROP)
        save(painting.resize((JOURNAL_WIDTH, round(JOURNAL_WIDTH * JOURNAL_CROP[1] / JOURNAL_CROP[0])), Image.LANCZOS), name)
        made += 1
    for entry in paintings:  # a zone painted with other game art: { texture, width, height, top, rows, file ID }
        texture, width, height, top, rows, fid = (entry[i] for i in range(1, 7))
        name = "screen-%d.webp" % fid
        if not force and os.path.exists(os.path.join(OUT, name)):
            kept += 1
            continue
        if isinstance(texture, str):  # packaged with Lorebound_Data: its painting is in its top rows
            image = Image.open(os.path.join(HERE, "..", texture.replace("Interface\\AddOns\\", "") + ".tga"))
            image = image.crop((0, 0, image.width, rows))
        else:  # the game's own file, shown at width x rows of its width x height
            image = blp_bytes(casc.read_fdid(fid))
            scale = image.height / height
            image = image.crop((0, round(top * scale), image.width, round((top + rows) * scale)))
            image = image.resize((round(image.height * width / rows), image.height))
        save(image.convert("RGB").resize((MAP_SIZE[0], round(MAP_SIZE[0] * image.height / image.width)), Image.LANCZOS), name)
        made += 1
    parchment(casc, force)
    icons = badges_and_icons(casc, force)
    print("badge frames and %d icons" % icons)
    size = sum(os.path.getsize(os.path.join(OUT, file_name)) for file_name in os.listdir(OUT))
    print("site art: %d made, %d kept, %d without art; %d KB in all" % (made, kept, missing, size // 1024))


if __name__ == "__main__":
    main()
