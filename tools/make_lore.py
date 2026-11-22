"""Writes Lorebound_Data/Data.lua: every quest on WoW Forever that Lorebound counts, with its zone,
levels, who may take it, what it needs first, what shuts it off and where its quest giver stands.

    python make_lore.py                  # from _tools; reads the game and two quest addons in its AddOns folder
    python make_lore.py --pull           # first saves the open quest-report issues into lore_reports (gh)
    python make_lore.py --pull --close   # and closes those issues afterwards, with a thank-you
    python make_lore.py --trust          # takes reported quests without checking them online

Sources (Lorebound is personal and never released):
- Zquest's Data folder (an export of QuestieDB's Forever database, GPL-3.0): quests with their chains,
  breadcrumbs and exclusive groups, the Horde view's differences, and the NPCs, objects and items
  that start and end them (names and spawn points, with Zquest's zone-to-map table).
- Quest Completist's Forever data: quests the first hasn't got (name, level, zone, faction, classes,
  one prerequisite, minimum level). Its holiday and profession quests are left out.
- Questie's quest blacklist (Questie only has to be in the AddOns folder too): quests it hides on
  Forever ("Welcome!" in each starting zone, duplicates, flags), which Zquest leaves out and Quest
  Completist doesn't.
- ForeverDungeonJournal's dungeon list (Data/Dungeons.lua; only has to be in the AddOns folder): which
  quests belong to which dungeon (each wing's quests on its dungeon's page), and the dungeon quests the
  others haven't got (Forever's new dungeons). Without it, a quest moves to a dungeon when what it's
  about is inside one (Zquest's rule, stricter).
- Players' reports (lore_reports/*.txt): the codes Lorebound's "Share new quests" box makes, for
  quests none of the above has. Each LM1 line adds its quest (name, zone, level, sides that met it,
  quest giver and where, who takes it in); "before" (the quest turned in just before at the same giver)
  is a hint for a person, not a prerequisite. A reported quest is only taken when its ID is in the
  game's own quest list and its name matches Wowhead's (Forever section, through the tooltip endpoint
  its embed script uses; answers cached in lore_reports/.verified.json); the rest go to
  lore_reports/needs-a-look.txt with the reason.
- The dungeon journal's art in the game files (interface/encounterjournal/ui-ej-background-*, named in
  the community listfile): each dungeon's and raid's painting, for its badge, row and page.
- The game's WorldMapOverlay tables: every explorable sub-zone's painted overlay, so the journal shows
  each zone's map fully revealed (the game only paints the parts you've explored).
- The game's own tables: QuestV2 (the quest IDs Forever has; anything missing from it is left out),
  AreaTable (zone names in Forever's spelling, continent, parent zone) and Map.csv from wago_classic
  (which instance maps are dungeons and which raids).
Both addons only have to be in the AddOns folder, not enabled. Re-run after either updates.

Also left out: repeatable quests, quests needing a world event, seasonal categories (holidays, the
Darkmoon Faire, invasions) and unused ones, because none of those is something you finish once.
"""
import csv
import os
import sys
import urllib.request

import lupa
from PIL import Image

from game_files import GameFiles
import db2

HERE = os.path.dirname(os.path.abspath(__file__))
# The quest addons' data, copied into the repository (refresh_sources.py copies them from the AddOns folder).
ADDON_SOURCES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "sources")
ZQUEST = os.path.join(ADDON_SOURCES, "Zquest", "Data")
COMPLETIST = os.path.join(ADDON_SOURCES, "QuestCompletist", "qcQuestData.lua")
BLACKLIST = os.path.join(ADDON_SOURCES, "Questie", "QuestieQuestBlacklist.lua")
JOURNAL = os.path.join(ADDON_SOURCES, "ForeverDungeonJournal", "Dungeons.lua")
REPORTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "lore_reports")
REPORT_REPO = "frogwizard-dev/loremaster-reports"  # where lb.frogwizard.net files reports (loremaster-report/)
OUT = os.path.join(HERE, "..", "Lorebound_Data", "Data.lua")
TEXT_OUT = os.path.join(HERE, "..", "Lorebound_Text", "Text.lua")  # the journal's quest pages (write_text)
NEWLINE, BLANK_LINE = chr(10), chr(10) * 2
SITE_DATA = os.path.join(HERE, "..", "site", "public", "data")  # the site's copy (lb.frogwizard.net)

QUEST_V2, AREA_TABLE = 1139443, 1353545  # community listfile IDs
WORLD_MAP_OVERLAY, WORLD_MAP_OVERLAY_TILE = 1134579, 1957212

# QuestieDB's quest fields (its questKeys).
NAME, STARTED_BY, FINISHED_BY, REQ_LEVEL, QUEST_LEVEL, RACES, CLASSES, OBJ_TEXT = 1, 2, 3, 4, 5, 6, 7, 8
OBJECTIVES = 10  # { creatures, objects, items, ... }, each { { id, text }, ... }
PRE_GROUP, PRE_SINGLE, EXCLUSIVE, ZONE_OR_SORT, REQ_SKILL, MIN_REP, MAX_REP = 12, 13, 16, 17, 18, 19, 20
NEXT_IN_CHAIN, SPECIAL_FLAGS, PARENT, BREADCRUMB_FOR = 22, 24, 25, 27
REQ_MAX_LEVEL, UNTIL_COMPLETED = 32, 33
REPEATABLE = 1  # specialFlags bit 2 is exploration or a scripted objective, not an event: kept
NPC_NAME, NPC_SPAWNS, NPC_FRIENDLY = 1, 7, 13
ITEM_NPC_DROPS, ITEM_OBJECT_DROPS = 2, 3
OBJECT_NAME, OBJECT_SPAWNS = 1, 4

# QuestSort IDs (stored negated), named by Forever's own QuestSort table.
SEASONAL = {22, 364, 365, 366, 368, 369}  # Seasonal, Darkmoon Faire, AQ war, Lunar Festival, Invasion, Midsummer
CLASS_IDS = {"Warrior": 1, "Paladin": 2, "Hunter": 3, "Rogue": 4, "Priest": 5, "Shaman": 7, "Mage": 8,
             "Warlock": 9, "Druid": 11}
CLASS_SORTS = {61: "Warlock", 81: "Warrior", 82: "Shaman", 141: "Paladin", 161: "Mage", 162: "Rogue",
               261: "Hunter", 262: "Priest", 263: "Druid"}
PROFESSION_SORTS = {24: "Herbalism", 101: "Fishing", 121: "Blacksmithing", 181: "Alchemy",
                    182: "Leatherworking", 201: "Engineering", 264: "Tailoring", 304: "Cooking",
                    324: "First Aid"}
OTHER_SORTS = {1: "Epic", 221: "Treasure Maps", 284: "Special", 344: "Legendary", 367: "Reputation",
               641: "Nightmare Incursions", 644: "Blackrock Eruption", 660: "The High Order",
               676: "Night Elf"}

# Professions and PvP aren't in the Lorebound total (Core.lua's IN_TOTAL), so they hold what one
# character can't finish: a quest per profession or per craftable item.
# The capitals by map, and whose they are (1 Alliance, 2 Horde): the other side's guards attack on sight.
CAPITALS = {1453: 1, 1455: 1, 1457: 1, 1454: 2, 1456: 2, 1458: 2}
GROUPS = ["Eastern Kingdoms", "Kalimdor", "Dungeons", "Raids", "Class", "Professions", "PvP", "Other"]
EK, KALIMDOR, DUNGEONS, RAIDS, CLASS, PROFESSIONS, PVP, OTHER = range(1, 9)
PROFESSION_SORTS[666] = "Camping"                                   # Camping 101: one per profession
RENAMED = {"Crafting": ("Craftsman's Writs", PROFESSIONS)}          # one writ per craftable item

# Race masks: classic races' bits, plus the playable-race bits of Forever's Skyborne (race 95 is
# bit 32, Alliance; race 96 is bit 33, Horde). Quest Completist marks both with bit 26 instead.
ALLIANCE_CLASSIC, HORDE_CLASSIC = 77, 178
SKYBORNE_A, SKYBORNE_H, COMPLETIST_NEW = 2 ** 32, 2 ** 33, 2 ** 26

# Our row: the field positions Lorebound reads (Core.lua's F table matches these, 1-based in Lua).
ROW = ["zone", "level", "minLevel", "name", "objective", "starter", "starterKind", "races", "classes",
       "needsAll", "needsAny", "exclusiveTo", "nextInChain", "breadcrumbFor", "parent", "skill",
       "minRep", "maxRep", "maxLevel", "untilDone", "faction", "finisher", "map", "x", "y"]
I = {name: i for i, name in enumerate(ROW)}
LINKS_MANY = ("needsAll", "needsAny", "exclusiveTo")
LINKS_ONE = ("nextInChain", "breadcrumbFor", "parent", "untilDone")


def run_addon_file(lua, path, ns):
    """Runs a Zquest data file (`local _, ns = ...`) against our own ns table."""
    src = open(path, encoding="utf-8").read()
    lua.eval("function(src, ns) return assert(load(src))('Zquest', ns) end")(src, ns)


def seq(value):
    if value is None:
        return []
    return [value[i] for i in range(1, len(value) + 1) if value[i] is not None]


def lua_string(text):
    out = text.replace("\\", "\\\\").replace('"', '\\"').replace("\r", "").replace("\n", "\\n")
    return '"' + out + '"'


def lua_value(value):
    if value is None:
        return "nil"
    if value is False:
        return "false"
    if value is True:
        return "true"
    if isinstance(value, str):
        return lua_string(value)
    if isinstance(value, (list, tuple)):
        return "{" + ",".join(lua_value(v) for v in value) + "}"
    if isinstance(value, float):
        return str(int(value)) if value.is_integer() else ("%.1f" % value)
    return str(value)


class Zones:
    def __init__(self, casc):
        self.areas, _ = db2.read(casc.read_fdid(AREA_TABLE), string_fields=(0, 1))
        self.instance = {}
        # A zone's name decides its group when areas disagree: Blackrock Depths' outdoor entrance is
        # on the Eastern Kingdoms map but its quests belong with the dungeon; a stray Ashenvale area on
        # some other map belongs with Kalimdor's. Dungeon and raid names are their maps' own names (an
        # instance map can hold an area called Westfall).
        self.instance_names, self.continent_names = {}, {}
        for row in csv.DictReader(open(os.path.join(HERE, "wago_classic", "Map.csv"), encoding="utf-8")):
            kind = int(row["InstanceType"] or 0)
            self.instance[int(row["ID"])] = kind
            if kind in (1, 2):
                self.instance_names[row["MapName_lang"]] = DUNGEONS if kind == 1 else RAIDS
        self.list, self.index = [], {}  # list: [name, group, uiMapID]
        self.area_to_map = {}
        for row in self.areas.values():
            if not row[3] and row[2] in (0, 1) and row[1] not in self.instance_names:
                self.continent_names[row[1]] = EK if row[2] == 0 else KALIMDOR

    def top(self, area):
        seen = set()
        while area in self.areas and self.areas[area][3] and self.areas[area][3] in self.areas and area not in seen:
            seen.add(area)
            area = self.areas[area][3]
        return area

    def of(self, sort):
        """The zone index for a quest's zoneOrSort, or None when Lorebound doesn't count it."""
        if not sort:
            return None
        ui_map = None
        if sort < 0:
            sort = -sort
            if sort in SEASONAL:
                return None
            if sort in CLASS_SORTS:
                name, group = CLASS_SORTS[sort], CLASS
            elif sort in PROFESSION_SORTS:
                name, group = PROFESSION_SORTS[sort], PROFESSIONS
            else:
                name, group = OTHER_SORTS.get(sort, "Other"), OTHER
        else:
            area = self.top(sort)
            row = self.areas.get(area)
            if not row:
                return None
            name, continent = row[1], row[2]
            if continent == 0:
                group = EK
            elif continent == 1:
                group = KALIMDOR
            else:
                kind = self.instance.get(continent, 0)
                group = DUNGEONS if kind == 1 else RAIDS if kind == 2 else PVP if kind in (3, 4) else OTHER
            if name in self.instance_names:
                group = self.instance_names[name]
            elif group == OTHER and name in self.continent_names:
                group = self.continent_names[name]
            if name in RENAMED:
                name, group = RENAMED[name]
            ui_map = self.area_to_map.get(area) or self.area_to_map.get(sort)
        key = (name, group)
        if key not in self.index:
            self.list.append([name, group, ui_map])
            self.index[key] = len(self.list)
        elif ui_map and not self.list[self.index[key] - 1][2]:
            self.list[self.index[key] - 1][2] = ui_map
        return self.index[key]


LISTFILE = os.path.join(HERE, "listfile", "community-listfile.csv")
EJ_PREFIX = "interface/encounterjournal/ui-ej-background-"
# Where the journal's name differs from the zone's; a zone outside Dungeons and Raids listed here gets its painting
# too (Blackrock Mountain has no map of its own).
EJ_NAMES = {"Ahn'Qiraj": "templeofahnqiraj", "Blackrock Mountain": "blackrockdepths"}
SOURCES = os.path.join(HERE, "lore_sources")  # downloaded sources (wago.tools tables and files, CMaNGOS, Wowhead)
WAGO_CSV = "https://wago.tools/db2/%s/csv?product=wowf"
WAGO_FILE = "https://wago.tools/api/casc/%d?download"
SCREEN_DIR = os.path.join(HERE, "..", "Lorebound_Data", "Media")  # Forever dungeons' paintings, packaged
SCREEN_PATH = r"Interface\AddOns\Lorebound_Data\Media\Screen%d"
SCREEN_SIZE = (512, 256)
# Zones with no map of their own, painted with the game's art instead: { file ID, width, height, top row, rows }
# (the shape it's shown at; Classic's loading screens are 512 x 512 files the game stretches to 4:3).
TALENT_ART = {"Warrior": 136983, "Paladin": 136918, "Hunter": 136890, "Rogue": 136942, "Priest": 136930,
              "Shaman": 136950, "Mage": 136902, "Warlock": 136967, "Druid": 136878}  # talentframe/<tree>-topleft
ZONE_ART = {name: [fid, 256, 256, 0, 256, fid] for name, fid in TALENT_ART.items()}
ZONE_ART["Deeprun Tram"] = [131834, 683, 512, 0, 512, 131834]  # glues/loadingscreens/loadscreendeepruntram


def wago_csv(table):
    """Forever's table from wago.tools as CSV rows (cached in lore_sources for a day): the client's own data,
    also for tables our DB2 reader can't parse."""
    import time
    path = os.path.join(SOURCES, table + ".csv")
    if not os.path.exists(path) or time.time() - os.path.getmtime(path) > 24 * 3600:
        req = urllib.request.Request(WAGO_CSV % table, headers={"User-Agent": "Mozilla/5.0 (compatible; loremaster-data)"})
        with urllib.request.urlopen(req, timeout=60) as res, open(path, "wb") as f:
            f.write(res.read())
    with open(path, encoding="utf-8") as f:
        return list(csv.DictReader(f))


def game_file(files, fid):
    """A file of the game by ID (game_files.GameFiles: the local client's, or wago.tools's when the client holds
    it encrypted or there's no client)."""
    return files.read_fdid(fid)


def blp_bytes(raw):
    """A BLP texture as a Pillow image (Pillow can't read the uncompressed BGRA kind)."""
    import io
    import struct
    from PIL import Image
    if raw[8] == 3:
        width, height = struct.unpack_from("<II", raw, 12)
        offset = struct.unpack_from("<I", raw, 20)[0]
        return Image.frombytes("RGBA", (width, height), raw[offset:offset + width * height * 4], "raw", "BGRA")
    return Image.open(io.BytesIO(raw)).convert("RGBA")


def painted_rows(image):
    """The rows a loading screen's painting fills: the grey letterbox bands above and below are flat."""
    import numpy as np
    spread = np.asarray(image.convert("L"), dtype=float).std(axis=1)
    rows = np.where(spread > 8)[0]
    return (int(rows.min()), int(rows.max()) + 1) if len(rows) else (0, image.height)


def packaged_screen(casc, fid):
    """A loading screen's painting packaged with Lorebound_Data (Media/Screen<fid>.tga, 512 x 256, the painting
    in its top rows), since a client without the content's key holds it encrypted and would show nothing.
    Returns the zone's painting entry: { texture path, file width and height, painting's top row and height,
    the game's file ID (for the site's copy) }."""
    image = blp_bytes(game_file(casc, fid)).convert("RGB")
    top, bottom = painted_rows(image)
    band = image.crop((0, top, image.width, bottom))
    height = round(SCREEN_SIZE[0] * band.height / band.width)
    page = Image.new("RGB", SCREEN_SIZE)
    page.paste(band.resize((SCREEN_SIZE[0], height), Image.LANCZOS), (0, 0))
    os.makedirs(SCREEN_DIR, exist_ok=True)
    page.save(os.path.join(SCREEN_DIR, "Screen%d.tga" % fid), compression="tga_rle")  # Pillow's BLPs show green
    return [SCREEN_PATH % fid, SCREEN_SIZE[0], SCREEN_SIZE[1], 0, height, fid]


def journal_art(casc, zone_rows):
    """Each dungeon's and raid's painting, by zone row: the dungeon journal's (a file ID; it fills 394 x 425 of
    its file), else, for Forever's new dungeons, its loading screen's painting, packaged (packaged_screen), found through the game's Map and LoadingScreens tables."""
    files = {path[len(EJ_PREFIX):-4]: fid for path, fid in casc.paths().items()
             if path.startswith(EJ_PREFIX) and path.endswith(".blp")}
    plain = lambda name: "".join(ch for ch in name.lower() if ch.isalnum()).removeprefix("the")
    screens = {r["ID"]: r for r in wago_csv("LoadingScreens")}
    screen_of = {}
    for m in wago_csv("Map"):
        screen = screens.get(m["LoadingScreenID"])
        fid = screen and int(screen["MainImageFileDataID"] or 0)
        if fid and m["InstanceType"] in ("1", "2"):
            screen_of.setdefault(plain(m["MapName_lang"]), fid)
    found = 0
    for row in zone_rows:
        while len(row) < 4:
            row.append(None)
        if row[0] in ZONE_ART:
            row[3] = ZONE_ART[row[0]]
            found += 1
            continue
        if row[1] not in (DUNGEONS, RAIDS) and row[0] not in EJ_NAMES:
            continue
        token = EJ_NAMES.get(row[0]) or "".join(ch for ch in row[0].lower() if ch.isalnum())
        fid = files.get(token) or (token.startswith("the") and files.get(token[3:]))
        if fid and casc.read_fdid(fid):
            row[3] = fid
            found += 1
        elif plain(row[0]) in screen_of:
            fid = screen_of[plain(row[0])]
            row[3] = packaged_screen(casc, fid)
            found += 1
    return found


def reveal(casc):
    """{ uiMapArtID: [ (width, height, offsetX, offsetY, tile files row by row), ... ] }."""
    overlays, _ = db2.read(casc.read_fdid(WORLD_MAP_OVERLAY))
    tiles, _ = db2.read(casc.read_fdid(WORLD_MAP_OVERLAY_TILE))
    files = {}
    for row in tiles.values():
        r, c, layer, file, ref = row[0], row[1], row[2], row[3], row[-1]
        if layer == 0 and isinstance(ref, tuple):
            files.setdefault(ref[1], []).append((r, c, file))
    out = {}
    for oid, row in sorted(overlays.items()):
        art, w, h, x, y = row[1], row[2], row[3], row[4], row[5]
        parts = sorted(files.get(oid, []))
        if not parts or not w or not h:
            continue
        out.setdefault(art, []).append([w, h, x, y] + [f for _, _, f in parts])
    return out


VERIFIED = os.path.join(REPORTS, ".verified.json")
WOWHEAD_TOOLTIP = "https://nether.wowhead.com/forever/tooltip/quest/%d"


def same_name(a, b):
    def norm(text):
        return "".join(ch for ch in (text or "").lower() if ch.isalnum())
    return norm(a) == norm(b) and norm(a) != ""


def wowhead_names(ids):
    """{quest: Wowhead's name or None}, from the cache, else one gentle lookup each."""
    import json
    import time
    cache = json.load(open(VERIFIED, encoding="utf-8")) if os.path.exists(VERIFIED) else {}
    for qid in ids:
        if str(qid) in cache:
            continue
        name = None
        try:
            req = urllib.request.Request(WOWHEAD_TOOLTIP % qid, headers={"User-Agent": "Mozilla/5.0 (compatible; loremaster-data)"})
            with urllib.request.urlopen(req, timeout=20) as res:
                name = json.loads(res.read().decode("utf-8")).get("name")
        except Exception as error:  # not found, or Wowhead unreachable: left unconfirmed
            print("  wowhead: quest %d: %s" % (qid, error))
        cache[str(qid)] = name
        time.sleep(0.6)
    os.makedirs(REPORTS, exist_ok=True)
    with open(VERIFIED, "w", encoding="utf-8") as f:
        json.dump(cache, f, indent=0, sort_keys=True)
    return {qid: cache.get(str(qid)) for qid in ids}


def write_text(pages):
    """Lorebound_Text/Text.lua: each quest's details for the journal's quest page, the same as the site's
    (lore_pages), loaded only when a quest page is first opened. LoreboundText[id] = { o = Forever's objective,
    n = { { what, count } }, d, p, c = description, progress and completion text (Classic's, only where Forever's
    objective matches Classic's or isn't checked yet; k is true once checked), r = { ch = choose one, it = receive
    ({ item, count, name, quality, icon }), m = money, rep = { { faction, value } }, sp = a spell } }."""
    def text(paragraphs):
        return BLANK_LINE.join(paragraphs) if paragraphs else None
    lines = ["-- Generated by _tools/make_lore.py (lore_pages.py: Wowhead's tooltips for Forever's objectives, CMaNGOS's",
             "-- classic-db (GPL-3.0) for the text and rewards). Don't edit by hand.",
             "LoreboundText = {"]
    kept = 0
    for qid in sorted(pages):
        page = pages[qid]
        entry = {}
        if page["same"] is not None and page["objective"]:
            entry["o"] = text(page["objective"])
        if page["needs"]:
            entry["n"] = page["needs"]
        words = page.get("text") or {}
        for key, field in (("d", "description"), ("p", "progress"), ("c", "completion")):
            if words.get(field):
                entry[key] = text(words[field])
        rewards = page.get("rewards")
        if rewards:
            entry["r"] = {k: v for k, v in (("ch", rewards["choose"]), ("it", rewards["items"]), ("m", rewards["money"]),
                                             ("rep", rewards["rep"]), ("sp", rewards["spell"])) if v}
        if entry:
            entry["k"] = page["same"] is True
            fields = []
            for key, value in entry.items():
                if isinstance(value, dict):
                    value_text = "{" + ",".join("%s=%s" % (k, lua_value(v)) for k, v in value.items()) + "}"
                else:
                    value_text = lua_value(value)
                fields.append("%s=%s" % (key, value_text))
            lines.append("[%d]={%s}," % (qid, ",".join(fields)))
            kept += 1
    lines.append("}")
    os.makedirs(os.path.dirname(TEXT_OUT), exist_ok=True)
    with open(TEXT_OUT, "w", encoding="utf-8", newline=NEWLINE) as f:
        f.write(NEWLINE.join(lines) + NEWLINE)
    print("quest details for the journal:", kept, "quests,", os.path.getsize(TEXT_OUT) // 1024, "KB")


def write_site_data(version, rows, zone_rows, horde):
    """The site's quest list (data/quests-<version>.json) and pointer (data/latest.json). Each version's file
    stays, so a progress code made with an older Lorebound still reads against its own quest order. Zones
    carry their map and journal painting (make_lore_site_art.py draws them); horde holds the Horde view's
    differences by the site's field numbers (null: none for the Horde)."""
    import json
    os.makedirs(SITE_DATA, exist_ok=True)
    import lore_pages
    fields = ["zone", "level", "minLevel", "name", "objective", "starter", "starterKind", "races", "classes",
              "needsAll", "needsAny", "breadcrumbFor", "faction", "finisher", "map", "x", "y", "exclusiveTo",
              "minRep", "chain"]
    chain_of = lore_pages.chains(rows, I)  # chain: [its first quest, this one's step, steps in all]
    quests = {}
    for qid in sorted(rows):
        row = rows[qid]
        chain = chain_of.get(qid) if qid in chain_of.get(qid, []) else None  # a branch off a chain stands alone
        entry = [row[I[f]] for f in fields[:-1]] + [[chain[0], chain.index(qid) + 1, len(chain)] if chain else None]
        while entry and entry[-1] is None:
            entry.pop()
        quests[qid] = entry
    site_horde = {}
    for qid, diff in sorted(horde.items()):
        changes = {fields.index(ROW[i - 1]): (None if v is False else v) for i, v in diff.items() if ROW[i - 1] in fields}
        if changes:
            site_horde[qid] = changes
    zones = [[z[0], z[1], z[2] if len(z) > 2 else None, z[3] if len(z) > 3 else None] for z in zone_rows]
    site = {"version": version, "groups": GROUPS, "zones": zones, "fields": fields, "ids": sorted(rows),
            "quests": quests, "horde": site_horde}
    name = "quests-%s.json" % version
    with open(os.path.join(SITE_DATA, name), "w", encoding="utf-8", newline="\n") as f:
        json.dump(site, f, separators=(",", ":"), ensure_ascii=False)
    with open(os.path.join(SITE_DATA, "latest.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump({"version": version, "file": name}, f)
    print("site data", name, os.path.getsize(os.path.join(SITE_DATA, name)) // 1024, "KB")


def pull_reports():
    """Saves each open quest-report issue as lore_reports/issue-<number>.txt; returns their numbers."""
    import json
    import subprocess
    out = subprocess.run(["gh", "issue", "list", "--repo", REPORT_REPO, "--label", "quest-report", "--state", "open",
                          "--limit", "500", "--json", "number,body"], capture_output=True, text=True, check=True)
    issues = json.loads(out.stdout)
    os.makedirs(REPORTS, exist_ok=True)
    for issue in issues:
        lines = [line for line in issue["body"].splitlines() if line.startswith("LM1^")]
        with open(os.path.join(REPORTS, "issue-%d.txt" % issue["number"]), "w", encoding="utf-8", newline="\n") as f:
            f.write("\n".join(lines) + "\n")
    print("pulled", len(issues), "report issues from", REPORT_REPO)
    return [issue["number"] for issue in issues]


def close_reports(numbers):
    import subprocess
    for number in numbers:
        subprocess.run(["gh", "issue", "close", str(number), "--repo", REPORT_REPO, "--comment",
                        "Thank you! These quests are in Lorebound's list now and ship with its next version."],
                       check=True)
    print("closed", len(numbers), "report issues")


def main():
    pulled = pull_reports() if "--pull" in sys.argv else []
    build()
    if pulled and "--close" in sys.argv:
        close_reports(pulled)


def build():
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    ns = lua.eval("{ Data = { Q = {}, N = {}, O = {}, I = {}, HordeFix = {} } }")
    for name in ("Quests", "Npcs1", "Npcs2", "Objects", "Items", "FactionFixes", "Zones"):
        run_addon_file(lua, os.path.join(ZQUEST, name + ".lua"), ns)
    data = ns.Data
    quests, npcs, objects, items = data.Q, data.N, data.O, data.I
    horde_fix = data.HordeFix.Q or lua.eval("{}")

    completist = lua.eval("function(src) local env = {} ; assert(load(src, 'qc', 't', env))() ; return env end")(
        open(COMPLETIST, encoding="utf-8").read())

    lua.execute('''
        local modules = {}
        local function Module(_, name) modules[name] = modules[name] or {} return modules[name] end
        QuestieLoader = { CreateModule = Module, ImportModule = Module }
        local expansions = Module(nil, "Expansions")
        expansions.Era, expansions.Tbc, expansions.Wotlk, expansions.Cata, expansions.MoP, expansions.Current = 1, 2, 3, 4, 5, 1
        setmetatable(Module(nil, "ContentPhases"), { __index = function()
            return setmetatable({}, { __index = function() return false end })
        end })
        Questie = { IsForever = true, Debug = function() end, DEBUG_CRITICAL = 1 }
    ''')
    lua.execute(open(BLACKLIST, encoding="utf-8").read())
    blacklist = lua.eval('QuestieLoader:ImportModule("QuestieQuestBlacklist"):Load()')
    blacklisted = {qid for qid, flag in blacklist.items() if flag is True}

    casc = GameFiles()  # the local client's files, or wago.tools's copy of Forever's newest build
    client, _ = db2.read(casc.read_fdid(QUEST_V2))
    zones = Zones(casc)

    def capital_side(giver_map, zone):
        """1 or 2 when a quest open to both sides can only be had in one side's capital: its giver stands
        there, or (no giver known) the quest itself is set there. The other side's guards attack on sight."""
        if giver_map is not None:
            return CAPITALS.get(giver_map)
        return CAPITALS.get(zones.list[zone - 1][2]) if zone else None
    for area, ui in (data.areaToMap or {}).items():
        if ui:
            zones.area_to_map[area] = ui

    def side(started):
        """1 Alliance or 2 Horde when every NPC that starts it is friendly to that side only, else None."""
        sides = set()
        for i in seq(started[1]) if started is not None else []:
            row = npcs[i]
            friendly = row[NPC_FRIENDLY] if row is not None else None
            sides.add(friendly if friendly in ("A", "H") else "both")
        if len(sides) != 1 or "both" in sides:
            return None
        return 1 if "A" in sides else 2

    def giver(started):
        """(name, kind, faction, map, x, y): kind None NPC, 2 object, 3 item; faction 1 A, 2 H."""
        if started is None:
            return (None,) * 6
        for kind, table in ((1, npcs), (2, objects), (3, items)):
            for i in seq(started[kind]):
                row = table[i]
                if row is None or not row[1]:
                    continue
                faction = side(started)
                where = (None, None, None)
                spawns = row[NPC_SPAWNS] if kind == 1 else row[OBJECT_SPAWNS] if kind == 2 else None
                if spawns is not None:
                    for area, points in sorted(spawns.items()):
                        ui = zones.area_to_map.get(area)
                        point = points and points[1]
                        if ui and point is not None and point[1] and point[1] > 0:
                            where = (ui, round(point[1], 1), round(point[2], 1))
                            break
                return (row[1], None if kind == 1 else kind, faction) + where
        return (None,) * 6

    def spots(q):
        """Where a quest's objectives are, for its page's map: { uiMap: [[x, y], ...] } from the spawns of its
        creatures and objects, and of what drops its items."""
        objectives = q(OBJECTIVES)
        points = {}
        if objectives is None:
            return points

        def add(spawns):
            for area, places in (spawns.items() if spawns is not None else []):
                ui = zones.area_to_map.get(area)
                bucket = points.setdefault(ui, []) if ui else None
                for place in (seq(places) if bucket is not None else []):
                    if len(bucket) < 60 and place[1] and place[1] > 0:
                        bucket.append([round(place[1], 1), round(place[2], 1)])

        def npc(i):
            row = npcs[i]
            if row is not None:
                add(row[NPC_SPAWNS])

        def obj(i):
            row = objects[i]
            if row is not None:
                add(row[OBJECT_SPAWNS])

        for entry in seq(objectives[1]):
            npc(entry[1])
        for entry in seq(objectives[2]):
            obj(entry[1])
        for entry in seq(objectives[3]):
            item = items[entry[1]]
            if item is not None:
                for i in seq(item[ITEM_NPC_DROPS])[:6]:
                    npc(i)
                for i in seq(item[ITEM_OBJECT_DROPS])[:6]:
                    obj(i)
        return {ui: found for ui, found in points.items() if found}

    def finisher(finished):
        if finished is None:
            return None
        for kind, table in ((1, npcs), (2, objects)):
            for i in seq(finished[kind]):
                row = table[i]
                if row is not None and row[1]:
                    return row[1]
        return None

    def build(q, zone):
        """Our row for a QuestieDB-style quest (q may be a dict of field overrides over a lupa row)."""
        objective = " ".join(s for s in seq(q(OBJ_TEXT)) if isinstance(s, str) and s).strip() or None
        name, kind, faction, ui, x, y = giver(q(STARTED_BY))
        row = [None] * len(ROW)
        row[I["zone"]] = zone
        row[I["level"]] = q(QUEST_LEVEL)
        row[I["minLevel"]] = q(REQ_LEVEL)
        row[I["name"]] = q(NAME)
        row[I["objective"]] = objective
        row[I["starter"]], row[I["starterKind"]], row[I["faction"]] = name, kind, faction
        row[I["map"]], row[I["x"]], row[I["y"]] = ui, x, y
        row[I["races"]] = q(RACES) or None
        if row[I["races"]]:
            row[I["faction"]] = None  # the race mask says who may take it; a giver's side can contradict it
        elif row[I["faction"]] is None:
            row[I["faction"]] = capital_side(ui, zone)
        row[I["classes"]] = q(CLASSES) or None
        row[I["needsAll"]] = seq(q(PRE_GROUP)) or None
        row[I["needsAny"]] = seq(q(PRE_SINGLE)) or None
        row[I["exclusiveTo"]] = seq(q(EXCLUSIVE)) or None
        row[I["nextInChain"]] = q(NEXT_IN_CHAIN) or None
        row[I["breadcrumbFor"]] = q(BREADCRUMB_FOR) or None
        row[I["parent"]] = q(PARENT) or None
        row[I["skill"]] = seq(q(REQ_SKILL)) or None
        row[I["minRep"]] = seq(q(MIN_REP)) or None
        row[I["maxRep"]] = seq(q(MAX_REP)) or None
        row[I["maxLevel"]] = q(REQ_MAX_LEVEL) or None
        row[I["untilDone"]] = q(UNTIL_COMPLETED) or None
        row[I["finisher"]] = finisher(q(FINISHED_BY))
        return row

    rows, horde = {}, {}
    extras = {}  # per quest, for its page on the site: where it is handed in, where its objectives are
    skip = set()  # quests left out on purpose: Lorebound mustn't learn them back in game
    unplaced = set()  # left out only for a zone the game's tables don't know (a new dungeon's, say)
    dropped = {"not on Forever": 0, "repeatable": 0, "seasonal or no zone": 0, "unused or blacklisted": 0,
               "holiday/profession (Completist)": 0}

    def unused(name):
        upper = (name or "").upper()
        return not name or name.startswith(("[", "<")) or "UNUSED" in upper or "DEPRECATED" in upper

    for qid, q in quests.items():
        if qid not in client:
            dropped["not on Forever"] += 1
            if (q[SPECIAL_FLAGS] or 0) & REPEATABLE:
                skip.add(qid)  # in case the game offers it after all
            continue
        if (q[SPECIAL_FLAGS] or 0) & REPEATABLE:
            dropped["repeatable"] += 1
            skip.add(qid)
            continue
        if unused(q[NAME]) or qid in blacklisted:
            dropped["unused or blacklisted"] += 1
            skip.add(qid)
            continue
        zone = zones.of(q[ZONE_OR_SORT])
        if zone is None:
            dropped["seasonal or no zone"] += 1
            skip.add(qid)
            if (q[ZONE_OR_SORT] or 0) >= 0:
                unplaced.add(qid)  # no zone, or one the game doesn't know: the dungeon journal may
            continue
        row = build(lambda f: q[f], zone)
        extras[qid] = {"end": giver(q[FINISHED_BY])[3:], "spots": spots(lambda f: q[f])}  # for its page
        rows[qid] = row
        fix = horde_fix[qid]
        if fix is not None:
            overrides = {k: v for k, v in fix.items()}
            def hq(f, q=q, overrides=overrides):
                if f in overrides:
                    return overrides[f] if overrides[f] is not False else None
                return q[f]
            hzone = zones.of(hq(ZONE_OR_SORT)) or zone
            hrow = build(hq, hzone)
            diff = {i + 1: (hrow[i] if hrow[i] is not None else False)
                    for i in range(len(ROW)) if hrow[i] != row[i]}
            if diff:
                horde[qid] = diff

    # Dungeon quests filed under the zone outside (Uldaman's under the Badlands, Gnomeregan's under Dun
    # Morogh): moved to the dungeon when what you kill, use or loot for them is in it. Zquest's dungeon
    # rule, stricter: a creature or object counts only when every place it spawns is in that one dungeon,
    # and an item only when at least half of what drops it is (cloth and other world drops aren't).
    dungeon_zones = {}
    for area in (data.dungeons or {}).keys():
        dungeon_zones[area] = None  # made into a zone only when a quest moves there

    def dungeon_of_area(area):
        if area not in dungeon_zones:
            return None
        if dungeon_zones[area] is None:
            zone = zones.of(area)
            dungeon_zones[area] = zone if zone and zones.list[zone - 1][1] in (DUNGEONS, RAIDS) else False
        return dungeon_zones[area] or None

    def only_dungeon(areas):
        found = {dungeon_of_area(a) for a in areas}
        return found.pop() if len(found) == 1 and None not in found else None

    def npc_dungeon(nid):
        n = npcs[nid]
        if n is None:
            return None
        spawns = n[NPC_SPAWNS]
        areas = list(spawns.keys()) if spawns is not None else []
        return only_dungeon(areas or ([n[9]] if n[9] else []))

    def object_dungeon(oid):
        o = objects[oid]
        if o is None:
            return None
        spawns = o[OBJECT_SPAWNS]
        areas = list(spawns.keys()) if spawns is not None else []
        return only_dungeon(areas or ([o[5]] if o[5] else []))

    def item_dungeon(iid):
        it = items[iid]
        if it is None or it[14]:  # sold by a vendor: not a dungeon item
            return None
        sources = [npc_dungeon(n) for n in seq(it[2])] + [object_dungeon(o) for o in seq(it[3])]
        for zone in {s for s in sources if s}:
            if sources.count(zone) * 2 >= len(sources):
                return zone
        return None

    journal = None
    if os.path.exists(JOURNAL):
        journal = lua.eval("{ Constants = setmetatable({}, { __index = function() return '' end }) }")
        lua.eval("function(src, ns) return assert(load(src))('ForeverDungeonJournal', ns) end")(
            open(JOURNAL, encoding="utf-8").read(), journal)
        journal = journal.DB

    moved = 0
    for qid, row in ([] if journal is not None else rows.items()):
        if zones.list[row[I["zone"]] - 1][1] not in (EK, KALIMDOR, OTHER):
            continue  # already a dungeon's, or a class's, profession's or battleground's
        objectives = quests[qid][OBJECTIVES]
        if objectives is None:
            continue
        target = None
        for kind, find in ((1, npc_dungeon), (2, object_dungeon), (3, item_dungeon)):
            for entry in seq(objectives[kind]):
                target = find(entry[1]) if entry is not None and not isinstance(entry, (int, float)) else None
                if target:
                    break
            if target:
                break
        if target:
            row[I["zone"]] = target
            if qid in horde and I["zone"] + 1 in horde[qid]:
                horde[qid][I["zone"] + 1] = target
            moved += 1
    print("dungeon quests moved from the zone outside to their dungeon", moved)

    # Quest Completist's quests that Zquest hasn't got.
    qc_db = completist.qcQuestDatabase
    holiday, profession = completist.qcQuestHoliday, completist.qcQuestProfession
    prereq, min_level = completist.qcQuestPrereq, completist.qcQuestMinLevel
    unavailable = completist.qcUnavailableQuests or lua.eval("{}")
    added = 0
    for qid, q in qc_db.items():
        if qid in rows or quests[qid] is not None:
            continue
        if qid not in client or unavailable[qid] is not None:
            dropped["not on Forever"] += 1
            continue
        if holiday[qid] is not None:
            dropped["holiday/profession (Completist)"] += 1
            skip.add(qid)
            continue
        if profession[qid] is not None:  # no skill to check it by: learned in game if you do it
            dropped["holiday/profession (Completist)"] += 1
            continue
        name, level, sort, kind, faction, races, classes = (q[i] for i in range(1, 8))
        if kind != 1:
            dropped["repeatable"] += 1
            skip.add(qid)
            continue
        if unused(name) or qid in blacklisted:
            dropped["unused or blacklisted"] += 1
            skip.add(qid)
            continue
        zone = zones.of(sort)
        if zone is None:
            dropped["seasonal or no zone"] += 1
            skip.add(qid)
            if (sort or 0) >= 0:
                unplaced.add(qid)  # the dungeon journal may know where it goes
            continue
        mask = None
        if races:
            mask = races % 256
            if races & COMPLETIST_NEW:
                if mask & ALLIANCE_CLASSIC:
                    mask += SKYBORNE_A
                if mask & HORDE_CLASSIC:
                    mask += SKYBORNE_H
                if mask == 0:  # Skyborne only
                    mask = SKYBORNE_A + SKYBORNE_H
        row = [None] * len(ROW)
        row[I["zone"]], row[I["level"]], row[I["name"]] = zone, level, name
        row[I["minLevel"]] = min_level[qid]
        row[I["races"]] = mask or None
        row[I["classes"]] = classes if classes and classes != 8191 else None
        row[I["faction"]] = faction if faction in (1, 2) else (None if mask else capital_side(None, zone))
        if prereq[qid]:
            row[I["needsAll"]] = [prereq[qid]]
        rows[qid] = row
        added += 1

    # ForeverDungeonJournal: its dungeons' quests go on their dungeon's page (wings on their dungeon's),
    # and the ones the others haven't got are added from it.
    def journal_zone(name):
        base = name if name.startswith("Excavation Site") else name.split(":")[0]
        base = base.replace("Lower ", "").replace("Upper ", "").strip()
        wanted = {base.lower(), ("the " + base).lower(), base.lower().replace("the ", "", 1)}
        for i, z in enumerate(zones.list, 1):
            if z[0].lower() in wanted:
                if z[1] == OTHER:
                    z[1] = DUNGEONS  # a dungeon the zone list didn't know as one (Forever's new ones)
                return i
        ui_map = None
        for area, d in (data.dungeons or {}).items():
            title = (d[1] or "").lower()
            if title in wanted or title.replace("the ", "", 1) in wanted:
                ui_map = zones.area_to_map.get(area)
                if ui_map:
                    break
        zones.list.append([base, DUNGEONS, ui_map])
        return len(zones.list)

    def first_part(text):
        text = (text or "").split(",")[0].strip()
        return text or None

    journal_moved = journal_added = 0
    for name, dungeon in sorted((journal or {}).items()):
        zone = journal_zone(name)
        listed = dungeon.quests
        for k in range(1, (len(listed) if listed else 0) + 1):
            q = listed[k]
            qid = q.id
            if not qid or (qid in skip and qid not in unplaced):
                continue
            if qid in unplaced and qid not in rows:
                # Left out for its zone alone: the journal says which dungeon it is. Zquest's full entry
                # (links and all) on that page where it has one; else the journal's own fields, below.
                skip.discard(qid)
                unplaced.discard(qid)
                if quests[qid] is not None:
                    rows[qid] = build(lambda f, zq=quests[qid]: zq[f], zone)
                    journal_added += 1
                    continue
            if qid in rows:
                if rows[qid][I["zone"]] != zone and zones.list[rows[qid][I["zone"]] - 1][1] not in (CLASS, PROFESSIONS):
                    rows[qid][I["zone"]] = zone
                    if qid in horde and I["zone"] + 1 in horde[qid]:
                        horde[qid][I["zone"] + 1] = zone
                    journal_moved += 1
                continue
            if not q.name:
                continue
            row = [None] * len(ROW)
            row[I["zone"]], row[I["name"]] = zone, q.name
            row[I["level"]], row[I["minLevel"]] = q.level, q.requires
            row[I["objective"]] = q.objective or None
            row[I["starter"]], row[I["finisher"]] = first_part(q.pickup), first_part(q.turnin)
            row[I["faction"]] = {"Alliance": 1, "Horde": 2}.get(q.faction)
            rows[qid] = row
            journal_added += 1
    if journal is not None:
        print("dungeon journal: quests moved to their dungeon", journal_moved, "added", journal_added)

    # Players' reports of quests none of the sources has.
    reported = 0
    zone_names = {}
    for i, z in enumerate(zones.list, 1):
        zone_names.setdefault(z[0], i)
    reports = {}  # quest -> its first report's fields, with the sides of every report
    for name in sorted(os.listdir(REPORTS)) if os.path.isdir(REPORTS) else []:
        if not name.endswith(".txt"):
            continue
        for line in open(os.path.join(REPORTS, name), encoding="utf-8", errors="replace"):
            parts = line.strip().split("^")
            if len(parts) < 15 or parts[0] != "LM1" or not parts[1].isdigit():
                continue
            qid = int(parts[1])
            sides = int(parts[5]) if parts[5] in ("1", "2", "3") else 0
            if qid in reports:
                reports[qid][0] |= sides
            else:
                reports[qid] = [sides, parts]
    # Only quests that check out: the game has the ID, and Wowhead calls it by the reported name.
    fresh = [qid for qid, (_, parts) in reports.items() if qid not in rows and qid not in skip]
    names = {} if "--trust" in sys.argv else wowhead_names(sorted(fresh))
    doubtful = []
    for qid, (sides, parts) in sorted(reports.items()):
        if True:
            title, zone_name = parts[2].strip(), parts[3].strip()
            if qid in rows or qid in skip or not title or not zone_name:
                continue
            if zone_name in PROFESSION_SORTS.values():
                continue  # no skill to check it by: each character learns it in game
            if "--trust" not in sys.argv:
                if qid not in client:
                    doubtful.append((qid, title, "not in the game's quest list"))
                    continue
                if not same_name(names.get(qid), title):
                    found = names.get(qid)
                    doubtful.append((qid, title, "Wowhead calls it %r" % found if found else "not found on Wowhead"))
                    continue
            zone = zone_names.get(zone_name)
            if zone is None:
                zones.list.append([zone_name, OTHER, None])
                zone = zone_names[zone_name] = len(zones.list)
            row = [None] * len(ROW)
            row[I["zone"]], row[I["name"]] = zone, title
            row[I["level"]] = int(parts[4]) if parts[4].isdigit() else None
            row[I["faction"]] = sides if sides in (1, 2) else None
            row[I["starter"]] = parts[7].strip() or None
            if parts[6].startswith("o"):
                row[I["starterKind"]] = 2  # an object
            if parts[8].isdigit() and parts[9] and parts[10]:
                try:
                    row[I["map"]], row[I["x"]], row[I["y"]] = int(parts[8]), float(parts[9]), float(parts[10])
                except ValueError:
                    pass
            row[I["finisher"]] = parts[12].strip() or None
            if zones.list[zone - 1][1] == CLASS and parts[14].isdigit():
                row[I["classes"]] = 2 ** (int(parts[14]) - 1)
            rows[qid] = row
            reported += 1
    print("quests from players' reports", reported)
    if doubtful:
        with open(os.path.join(REPORTS, "needs-a-look.txt"), "w", encoding="utf-8", newline="\n") as f:
            f.write("# Reported quests left out until checked by hand (python make_lore.py --trust takes them).\n")
            for qid, title, why in doubtful:
                f.write("%d %s: %s\n" % (qid, title, why))
        print("reported quests needing a look", len(doubtful), "(lore_reports/needs-a-look.txt)")

    # Links to quests left out point nowhere: a prerequisite that isn't on Forever can't hold one back.
    def prune(row):
        for key in LINKS_MANY:
            i = I[key]
            if row[i]:
                row[i] = [x for x in row[i] if abs(x) in rows] or None
        for key in LINKS_ONE:
            i = I[key]
            if row[i] and row[i] not in rows:
                row[i] = None
    for row in rows.values():
        prune(row)
        # Class quests the list gives no class: their category says whose they are.
        zone_name, group, _ = zones.list[row[I["zone"]] - 1]
        if group == CLASS and not row[I["classes"]] and zone_name in CLASS_IDS:
            row[I["classes"]] = 2 ** (CLASS_IDS[zone_name] - 1)
    for qid, diff in horde.items():
        for key in LINKS_MANY:
            i = I[key] + 1
            if diff.get(i):
                diff[i] = [x for x in diff[i] if abs(x) in rows] or False
        for key in LINKS_ONE:
            i = I[key] + 1
            if diff.get(i) and diff[i] not in rows:
                diff[i] = False

    # Zones in the order you'd meet them: by group, then their quests' middle level.
    levels = {}
    for row in rows.values():
        if row[I["level"]] and row[I["level"]] > 0:
            levels.setdefault(row[I["zone"]], []).append(row[I["level"]])

    def middle(i):
        values = sorted(levels.get(i, [99]))
        return values[len(values) // 2]
    zl = zones.list
    order = sorted(range(1, len(zl) + 1), key=lambda i: (zl[i - 1][1], middle(i), zl[i - 1][0]))
    renumber = {old: new for new, old in enumerate(order, 1)}
    zone_rows = [zl[old - 1] for old in order]
    art_found = journal_art(casc, zone_rows)
    for row in rows.values():
        row[I["zone"]] = renumber[row[I["zone"]]]
    for diff in horde.values():
        if diff.get(I["zone"] + 1):
            diff[I["zone"] + 1] = renumber[diff[I["zone"] + 1]]

    # The list's version: progress codes name it, so the site reads them against the same quest order.
    import hashlib
    import json
    version = hashlib.sha1(json.dumps([sorted(rows), [z[0] for z in zone_rows]]).encode()).hexdigest()[:10]
    write_site_data(version, rows, zone_rows, horde)
    import lore_pages
    write_text(lore_pages.write(rows, extras, I))

    lines = [
        "-- Generated by _tools/make_lore.py from Zquest's QuestieDB export (GPL-3.0), Quest Completist's",
        "-- Forever data and the game's own quest and zone tables. Personal; don't edit by hand.",
        "-- zones[i] = { name, group, uiMapID, journal art (a dungeon's or raid's painting, a file ID) }",
        "-- quests[id] = { " + ", ".join(ROW) + ", (26 unused), chain = { first quest, step, steps } }",
        "-- horde[id] = { [field] = value or false }: the Horde view's differences.",
        "-- skip = { id, ... }: quests left out on purpose (repeatable, seasonal, blacklisted), never learned.",
        "-- reveal[uiMapArtID] = { { width, height, x, y, tile files row by row }, ... }: every sub-zone's overlay.",
        "LoreboundData = {",
        "version = " + lua_string(version) + ",",
        "groups = " + lua_value(GROUPS) + ",",
        "zones = {",
    ]
    lines += [lua_value(z) + "," for z in zone_rows]
    lines += ["},", "quests = {"]
    import lore_pages
    chain_of = lore_pages.chains(rows, I)
    for qid in sorted(rows):
        row = list(rows[qid])
        chain = chain_of.get(qid) if qid in chain_of.get(qid, []) else None
        if chain:  # field 27 (26 is the addon's own, for learned quests): { first quest, this step, steps in all }
            row += [None, [chain[0], chain.index(qid) + 1, len(chain)]]
        while row and row[-1] is None:
            row.pop()
        lines.append("[%d]=%s," % (qid, lua_value(row)))
    lines += ["},", "horde = {"]
    for qid in sorted(horde):
        parts = ",".join("[%d]=%s" % (i, lua_value(v)) for i, v in sorted(horde[qid].items()))
        lines.append("[%d]={%s}," % (qid, parts))
    lines += ["},", "reveal = {"]
    overlay_sets = reveal(casc)
    for art in sorted(overlay_sets):
        lines.append("[%d]={%s}," % (art, ",".join(lua_value(o) for o in overlay_sets[art])))
    lines += ["},"]
    skip -= set(rows)
    skip -= unplaced  # no zone anyone knows: learned (and reported) in game with the quest log's zone
    lines.append("skip = {" + ",".join(str(q) for q in sorted(skip)) + "},")
    lines += ["}"]
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    print("dungeon and raid art", art_found)
    print("quests", len(rows), "(Completist added %d)" % added, "horde fixes", len(horde), "zones", len(zone_rows))
    print("dropped", dropped)
    print("wrote", os.path.normpath(OUT), os.path.getsize(OUT) // 1024, "KB")
    new_in_client(set(client), rows, skip)


def new_in_client(client, rows, skip):
    """Quest IDs a patch added to the game that no source has yet: named from Wowhead (cached) into
    lore_reports/new-in-client.txt. Lorebound learns them in game and players report them; this says
    what to expect. The first run only notes the client's list."""
    import json
    seen_file = os.path.join(REPORTS, ".client_quests.json")
    seen = set(json.load(open(seen_file, encoding="utf-8"))) if os.path.exists(seen_file) else None
    os.makedirs(REPORTS, exist_ok=True)
    with open(seen_file, "w", encoding="utf-8") as f:
        json.dump(sorted(client), f, separators=(",", ":"))
    if seen is None:
        print("client quest list noted:", len(client), "IDs (the next run lists the new ones)")
        return
    new = sorted(client - seen - set(rows) - skip)
    if not new:
        print("no new quests in the client since the last run")
        return
    names = wowhead_names(new)
    with open(os.path.join(REPORTS, "new-in-client.txt"), "a", encoding="utf-8", newline="\n") as f:
        for qid in new:
            f.write("%d\t%s\n" % (qid, names.get(qid) or "(not on Wowhead yet)"))
    print("new in the client:", len(new), "quests no source has (lore_reports/new-in-client.txt)")


if __name__ == "__main__":
    main()
