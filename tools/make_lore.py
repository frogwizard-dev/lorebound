"""Builds Lorebound's quest list: Lorebound_Data/Data.lua (every quest on WoW Forever that Lorebound counts, with
its zone, levels, who may take it, what it needs first, what shuts it off and where its quest giver stands),
the quest pages' text (lore_pages.py; Lorebound_Text, Lorebound_Text_EasternKingdoms and Lorebound_Text_Kalimdor) and
the site's copy (site/public/data).

    python make_lore.py                  # in tools/
    python make_lore.py --pull           # first saves the open quest reports you've approved into lore_reports (gh)
    python make_lore.py --pull --close   # and closes those issues afterwards, with a thank-you
    python make_lore.py --close-pulled   # only closes the issues lore_reports/issue-<n>.txt came from (the weekly
                                         # update runs it once the build is committed)
    python make_lore.py --trust          # takes reported quests without checking them online

Sources (the addons' files are copied into sources/ by refresh_sources.py; the weekly update builds from those):
- Zquest's Data folder (an export of QuestieDB's Forever database, GPL-3.0): quests with their chains,
  breadcrumbs and exclusive groups, the Horde view's differences, and the NPCs, objects and items
  that start and end them (names and spawn points, with Zquest's zone-to-map table).
- Quest Completist's Forever data: quests the first hasn't got (name, level, zone, faction, classes,
  one prerequisite, minimum level). Its holiday and profession quests are left out.
- Questie's quest blacklist: quests it hides on Forever ("Welcome!" in each starting zone, duplicates,
  flags), which Zquest leaves out and Quest Completist doesn't.
- ForeverDungeonJournal's dungeon list: which quests belong to which dungeon (each wing's quests on its
  dungeon's page), and the dungeon quests the others haven't got (Forever's new dungeons). Without it, a
  quest moves to a dungeon when what it's about is inside one (Zquest's rule, stricter).
- Players' reports (lore_reports/*.txt): the codes Lorebound's "Share new quests" box makes, for
  quests none of the above has. Each LM1 line adds its quest (name, zone, level, sides that met it,
  quest giver and where, who takes it in); "before" (the quest turned in just before at the same giver)
  is a hint for a person, not a prerequisite. A reported quest is only taken when its ID is in the
  game's own quest list and its name matches Wowhead's (Forever section, through the tooltip endpoint
  its embed script uses; answers cached in lore_reports/.verified.json); the rest go to
  lore_reports/needs-a-look.txt with the reason. LT1 lines carry a quest's Forever text as players read
  it, and LR1 lines its rewards as the game showed them (lore_pages.py puts both on the quest's page where
  Classic's don't apply). ForeverDungeonJournal's rewards fill its dungeon quests' pages the same way.
- The game's files (game_files.py: this PC's client, else wago.tools's copy of Forever's newest build):
  the dungeon journal's art (interface/encounterjournal/ui-ej-background-*, named in the listfile) for each
  dungeon's and raid's badge, row and page; the WorldMapOverlay tables, so the journal shows each zone's map
  fully revealed; QuestV2 (the quest IDs Forever has; anything missing from it is left out) and AreaTable
  (zone names in Forever's spelling, continent, parent zone). Map.csv from wago_classic says which instance
  maps are dungeons and which raids.

Also left out: repeatable quests, quests needing a world event, seasonal categories (holidays, the
Darkmoon Faire, invasions) and unused ones, because none of those is something you finish once.
"""
import csv
import hashlib
import io
import json
import os
import re
import struct
import subprocess
import sys
import time
import urllib.request

import lupa
import numpy as np
from PIL import Image

import db2
import lore_pages
from game_files import AGENT, GameFiles, wago_csv

HERE = os.path.dirname(os.path.abspath(__file__))
# The quest addons' data, copied into the repository (refresh_sources.py copies them from the AddOns folder).
ADDON_SOURCES = os.path.join(HERE, "..", "sources")
ZQUEST = os.path.join(ADDON_SOURCES, "Zquest", "Data")
COMPLETIST = os.path.join(ADDON_SOURCES, "QuestCompletist", "qcQuestData.lua")
BLACKLIST = os.path.join(ADDON_SOURCES, "Questie", "QuestieQuestBlacklist.lua")
JOURNAL = os.path.join(ADDON_SOURCES, "ForeverDungeonJournal", "Dungeons.lua")
ONE_FOR_ALL = os.path.join(ADDON_SOURCES, "OneForAll", "QuestRewards.lua")  # GPL-3: gear rewards by quest
GAME_REWARDS = os.path.join(ADDON_SOURCES, "Game", "rewards.json")  # the game server's own answers (tools/harvest)
REPORTS = os.path.join(HERE, "lore_reports")
REPORT_REPO = "frogwizard-dev/loremaster-reports"  # where lb.frogwizard.net files reports (site/)
APPROVED = "approved"  # the label you add to a report issue once you've read it and it's right
OUT = os.path.join(HERE, "..", "Lorebound_Data", "Data.lua")
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
NPC_NAME, NPC_SPAWNS, NPC_ZONE, NPC_FRIENDLY = 1, 7, 9, 13
ITEM_NPC_DROPS, ITEM_OBJECT_DROPS, ITEM_VENDORS = 2, 3, 14
OBJECT_NAME, OBJECT_SPAWNS, OBJECT_ZONE = 1, 4, 5

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

# The capitals by map, and whose they are (1 Alliance, 2 Horde): the other side's guards attack on sight.
CAPITALS = {1453: 1, 1455: 1, 1457: 1, 1454: 2, 1456: 2, 1458: 2}
GROUPS = ["Eastern Kingdoms", "Kalimdor", "Dungeons", "Raids", "Class", "Professions", "PvP", "Other"]
EK, KALIMDOR, DUNGEONS, RAIDS, CLASS, PROFESSIONS, PVP, OTHER = range(1, 9)
# Professions and PvP aren't in the Lorebound total (Core.lua's IN_TOTAL), so they hold what one
# character can't finish: a quest per profession or per craftable item.
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


EJ_PREFIX = "interface/encounterjournal/ui-ej-background-"
# Where the journal's name differs from the zone's; a zone outside Dungeons and Raids listed here gets its painting
# too (Blackrock Mountain has no map of its own).
EJ_NAMES = {"Ahn'Qiraj": "templeofahnqiraj", "Blackrock Mountain": "blackrockdepths"}
SCREEN_DIR = os.path.join(HERE, "..", "Lorebound_Data", "Media")  # Forever dungeons' paintings, packaged
SCREEN_PATH = r"Interface\AddOns\Lorebound_Data\Media\Screen%d"
SCREEN_SIZE = (512, 256)
# Zones with no map of their own, painted with the game's art instead: { file ID, width, height, top row, rows }
# (the shape it's shown at; Classic's loading screens are 512 x 512 files the game stretches to 4:3).
TALENT_ART = {"Warrior": 136983, "Paladin": 136918, "Hunter": 136890, "Rogue": 136942, "Priest": 136930,
              "Shaman": 136950, "Mage": 136902, "Warlock": 136967, "Druid": 136878}  # talentframe/<tree>-topleft
ZONE_ART = {name: [fid, 256, 256, 0, 256, fid] for name, fid in TALENT_ART.items()}
ZONE_ART["Deeprun Tram"] = [131834, 683, 512, 0, 512, 131834]  # glues/loadingscreens/loadscreendeepruntram


def blp_bytes(raw):
    """A BLP texture as a Pillow image (Pillow can't read the uncompressed BGRA kind)."""
    if raw[8] == 3:
        width, height = struct.unpack_from("<II", raw, 12)
        offset = struct.unpack_from("<I", raw, 20)[0]
        return Image.frombytes("RGBA", (width, height), raw[offset:offset + width * height * 4], "raw", "BGRA")
    return Image.open(io.BytesIO(raw)).convert("RGBA")


def painted_rows(image):
    """The rows a loading screen's painting fills: the grey letterbox bands above and below are flat."""
    spread = np.asarray(image.convert("L"), dtype=float).std(axis=1)
    rows = np.where(spread > 8)[0]
    return (int(rows.min()), int(rows.max()) + 1) if len(rows) else (0, image.height)


def packaged_screen(casc, fid):
    """A loading screen's painting packaged with Lorebound_Data (Media/Screen<fid>.tga, 512 x 256, the painting
    in its top rows), since a client without the content's key holds it encrypted and would show nothing.
    Returns the zone's painting entry: { texture path, file width and height, painting's top row and height,
    the game's file ID (for the site's copy) }."""
    image = blp_bytes(casc.read_fdid(fid)).convert("RGB")
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
    screens = {row["ID"]: row for row in wago_csv("LoadingScreens")}
    screen_of = {}
    for map_row in wago_csv("Map"):
        screen = screens.get(map_row["LoadingScreenID"])
        fid = screen and int(screen["MainImageFileDataID"] or 0)
        if fid and map_row["InstanceType"] in ("1", "2"):
            screen_of.setdefault(plain(map_row["MapName_lang"]), fid)
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
        tile_row, tile_col, layer, file_id, ref = row[0], row[1], row[2], row[3], row[-1]
        if layer == 0 and isinstance(ref, tuple):
            files.setdefault(ref[1], []).append((tile_row, tile_col, file_id))
    out = {}
    for oid, row in sorted(overlays.items()):
        art, width, height, x, y = row[1], row[2], row[3], row[4], row[5]
        parts = sorted(files.get(oid, []))
        if not parts or not width or not height:
            continue
        out.setdefault(art, []).append([width, height, x, y] + [file_id for _, _, file_id in parts])
    return out


VERIFIED = os.path.join(REPORTS, ".verified.json")
TEXT_FIELDS = {"d": "description", "o": "objective", "c": "completion", "p": "progress"}  # an LT1 line's field
QUEST_ID = re.compile(r"[1-9][0-9]{0,6}")  # ASCII digits only ("²".isdigit() is True)


REWARD_ITEMS = re.compile(r"([1-9][0-9]{0,6}:[1-9][0-9]{0,3}(,[1-9][0-9]{0,6}:[1-9][0-9]{0,3}){0,9})?")


def gear_rewards():
    """OneForAll's gear rewards by quest ({ quest: [(item, name)] }): only the gear a quest can give, not whether it's
    a choice or what else comes with it, so it's used only where nothing better is known."""
    found = {}
    if not os.path.exists(ONE_FOR_ALL):
        return found
    for line in open(ONE_FOR_ALL, encoding="utf-8"):
        match = re.fullmatch(r"([0-9]+),[0-9]+,([0-9/]+),(.+)", line.strip())
        if match:
            for qid in match.group(2).split("/"):
                found.setdefault(int(qid), []).append((int(match.group(1)), match.group(3)))
    return found


def journal_extras(quest):
    """What ForeverDungeonJournal says of a quest beyond the list: its rewards (items, either-or when rewardChoice;
    money, reputation by faction name and XP read from its reward text and summary), its note, and where it's picked
    up and handed in, described ("inside the dungeon, near the sewer entrance")."""
    def listed(found):  # { { item, name, quality, count }, ... } as (item, name, quality, count)
        return [(found[i][1], found[i][2], found[i][3], found[i][4] or 1) for i in range(1, (len(found) if found else 0) + 1)
                if found[i] and isinstance(found[i][1], int)]
    items, extra = listed(quest.rewardItems), listed(quest.additionalRewardItems)
    money, xp, rep = 0, 0, {}
    for line in "\n".join(text for text in (quest.rewards, quest.rewardSummary) if text).split("\n"):
        for piece in (part.strip() for part in line.split("\u2022")):
            if re.fullmatch(r"[0-9,]+ XP", piece):
                xp = int(piece[:-3].replace(",", ""))
            elif re.fullmatch(r"([0-9]+g)? ?([0-9]+s)? ?([0-9]+c)?", piece) and piece:
                coins = dict((unit, int(amount)) for amount, unit in re.findall(r"([0-9]+)([gsc])", piece))
                money = coins.get("g", 0) * 10000 + coins.get("s", 0) * 100 + coins.get("c", 0)
            else:
                match = re.fullmatch(r"(.+?) \+([0-9]+)", piece)
                if match and not piece.startswith(("Choose:", "Also:")):
                    rep[match.group(1)] = int(match.group(2))
    return {"choice": bool(quest.rewardChoice), "items": items, "extra": extra, "money": money, "xp": xp,
            "rep": [[name, value] for name, value in rep.items()], "note": quest.note or None,
            "pickup": quest.pickup or None, "turnin": quest.turnin or None}


def reward_line(parts):
    """An LR1 line's rewards ("LR1^quest^choose^items^money", choose and items as item:count,item:count), or None
    when it doesn't read or holds nothing."""
    _, _, choose, items, money = parts
    if not (REWARD_ITEMS.fullmatch(choose) and REWARD_ITEMS.fullmatch(items) and re.fullmatch(r"[0-9]{0,9}", money)):
        return None
    def read(text):
        return [[int(item), int(count)] for item, count in (pair.split(":") for pair in text.split(",") if pair)]
    found = {"choose": read(choose), "items": read(items), "money": int(money or 0)}
    return found if found["choose"] or found["items"] or found["money"] else None


def report_order(name):
    """Report files oldest first (issue-9 before issue-10), so a later report's text wins."""
    number = "".join(ch for ch in name if ch.isdigit())
    return (int(number) if number else 0, name)
WOWHEAD_TOOLTIP = "https://nether.wowhead.com/forever/tooltip/quest/%d"


def same_name(a, b):
    def norm(text):
        return "".join(ch for ch in (text or "").lower() if ch.isalnum())
    return norm(a) == norm(b) and norm(a) != ""


def wowhead_names(ids):
    """{quest: Wowhead's name or None}, from the cache, else one gentle lookup each."""
    cache = json.load(open(VERIFIED, encoding="utf-8")) if os.path.exists(VERIFIED) else {}
    for qid in ids:
        if str(qid) in cache:
            continue
        name = None
        try:
            req = urllib.request.Request(WOWHEAD_TOOLTIP % qid, headers=AGENT)
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


# The quest pages' text, in three load-on-demand parts by the quest's group, so a page loads only its third.
TEXT_PARTS = {EK: "Lorebound_Text_EasternKingdoms", KALIMDOR: "Lorebound_Text_Kalimdor"}
TEXT_REST = "Lorebound_Text"  # dungeons, raids, class, professions, PvP and the rest


def text_parts(rows, zone_rows, horde):
    """{ quest: the text parts that hold its page }: its zone's group's, and the Horde view's too when that differs."""
    out = {}
    for qid, row in rows.items():
        seen = {row[I["zone"]], horde.get(qid, {}).get(I["zone"] + 1) or row[I["zone"]]}
        out[qid] = {TEXT_PARTS.get(zone_rows[zone - 1][1], TEXT_REST) for zone in seen}
    return out


def write_text(pages, part_of):
    """The journal's quest pages, the same as the site's (lore_pages), in the parts text_parts names:
    <part>/Text.lua adds LoreboundText[id] = the page as Lua source, made into a table only when that page is shown
    (Core.lua's ns.QuestText), so only the strings stay in memory. The page: { o = Forever's objective,
    n = { { what, count } }, d, p, c = description, progress and completion text (Classic's, only where Forever's
    objective matches Classic's or isn't checked yet; k is true once checked; s is true when it's players' text from
    Forever instead), nt = a note, ws and we = where it's picked up and handed in (ForeverDungeonJournal's), r = {
    xp, so = some of them (gear only, choice or not unknown), ch = choose one, it = receive
    ({ item, count, name, quality, icon }), m = money, rep = { { faction ID or name, value } }, sp = a spell } }."""
    def text(paragraphs):
        return BLANK_LINE.join(paragraphs) if paragraphs else None
    parts = {name: [] for name in list(TEXT_PARTS.values()) + [TEXT_REST]}
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
                                             ("rep", rewards["rep"]), ("sp", rewards["spell"]), ("xp", rewards.get("xp")),
                                             ("so", rewards.get("some")))
                          if v}
        for key, field in (("nt", "note"), ("ws", "pickup"), ("we", "turnin")):
            if page.get(field):
                entry[key] = page[field]
        if not entry:
            continue
        entry["k"] = page["same"] is True
        if page.get("shared"):
            entry["s"] = True  # Forever's own text, as players read it
        fields = []
        for key, value in entry.items():
            if isinstance(value, dict):
                value_text = "{" + ",".join("%s=%s" % (k, lua_value(v)) for k, v in value.items()) + "}"
            else:
                value_text = lua_value(value)
            fields.append("%s=%s" % (key, value_text))
        source = "{%s}" % ",".join(fields)
        level = "="
        while "]" + level + "]" in source:
            level += "="
        for name in part_of[qid]:
            parts[name].append("[%d]=[%s[%s]%s]," % (qid, level, source, level))
    for name, entries in parts.items():
        path = os.path.join(HERE, "..", name, "Text.lua")
        lines = ["-- Generated by tools/make_lore.py (lore_pages.py: Wowhead's tooltips for Forever's objectives, CMaNGOS's",
                 "-- classic-db (GPL-3.0) for the text and rewards). Each page is Lua source, read when it's shown.",
                 "-- Don't edit by hand.",
                 "local pages = {"] + entries + ["}",
                 "LoreboundText = LoreboundText or {} -- every part adds its pages; Core.lua takes them",
                 "for id, source in pairs(pages) do LoreboundText[id] = source end"]
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8", newline=NEWLINE) as f:
            f.write(NEWLINE.join(lines) + NEWLINE)
        print("quest pages in %s: %d quests, %d KB" % (name, len(entries), os.path.getsize(path) // 1024))


def chain_field(qid, chain_of):
    """A quest's chain field: [its first quest, this one's step, steps in all], or None (a branch off a chain
    stands alone)."""
    chain = chain_of.get(qid)
    return [chain[0], chain.index(qid) + 1, len(chain)] if chain and qid in chain else None


def write_site_data(version, rows, zone_rows, horde, chain_of):
    """The site's quest list (data/quests-<version>.json) and pointer (data/latest.json). Each version's file
    stays, so a progress code made with an older Lorebound still reads against its own quest order. Zones
    carry their map and journal painting (make_lore_site_art.py draws them); horde holds the Horde view's
    differences by the site's field numbers (null: none for the Horde)."""
    os.makedirs(SITE_DATA, exist_ok=True)
    fields = ["zone", "level", "minLevel", "name", "objective", "starter", "starterKind", "races", "classes",
              "needsAll", "needsAny", "breadcrumbFor", "faction", "finisher", "map", "x", "y", "exclusiveTo",
              "minRep", "chain"]
    quests = {}
    for qid in sorted(rows):
        row = rows[qid]
        entry = [row[I[field]] for field in fields[:-1]] + [chain_field(qid, chain_of)]
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
    """Saves each open quest-report issue you've approved (labelled "approved" on GitHub, after reading it) as
    lore_reports/issue-<number>.txt; returns their numbers. Reports only pass the automatic checks (a real quest
    ID, Wowhead's name) after that; the details a player sends (zone, level, giver, place) are yours to judge."""
    out = subprocess.run(["gh", "issue", "list", "--repo", REPORT_REPO, "--label", "quest-report", "--label",
                          APPROVED, "--state", "open",
                          "--limit", "500", "--json", "number,body"], capture_output=True, text=True, check=True)
    issues = json.loads(out.stdout)
    os.makedirs(REPORTS, exist_ok=True)
    for issue in issues:
        # Split as the report page does (line feeds only): splitlines() would also break on U+2028 and the like.
        lines = [line.rstrip("\r") for line in issue["body"].split("\n") if line.startswith(("LM1^", "LT1^"))]
        with open(os.path.join(REPORTS, "issue-%d.txt" % issue["number"]), "w", encoding="utf-8", newline="\n") as f:
            f.write("\n".join(lines) + "\n")
    print("pulled", len(issues), "approved report issues from", REPORT_REPO)
    return [issue["number"] for issue in issues]


def close_reports(numbers):
    for number in numbers:
        subprocess.run(["gh", "issue", "close", str(number), "--repo", REPORT_REPO, "--comment",
                        "Thank you. This report is in Lorebound's data now and ships with its next version (a quest"
                        " that doesn't check out against the game's list and Wowhead waits for a look first)."],
                       check=True)
    print("closed", len(numbers), "report issues")


def pulled_numbers():
    """The issue numbers of the reports pulled into lore_reports (issue-<number>.txt)."""
    names = os.listdir(REPORTS) if os.path.isdir(REPORTS) else []
    return sorted(int(name[6:-4]) for name in names if re.fullmatch(r"issue-[0-9]+\.txt", name))


def main():
    if "--close-pulled" in sys.argv:
        close_reports(pulled_numbers())
        return
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

    def spots(field):
        """Where a quest's objectives are, for its page's map: { uiMap: [[x, y], ...] } from the spawns of its
        creatures and objects, and of what drops its items."""
        objectives = field(OBJECTIVES)
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

    def make_row(field, zone):
        """Our row for a QuestieDB-style quest (q may be a dict of field overrides over a lupa row)."""
        objective = " ".join(text for text in seq(field(OBJ_TEXT)) if isinstance(text, str) and text).strip() or None
        name, kind, faction, ui, x, y = giver(field(STARTED_BY))
        row = [None] * len(ROW)
        row[I["zone"]] = zone
        row[I["level"]] = field(QUEST_LEVEL)
        row[I["minLevel"]] = field(REQ_LEVEL)
        row[I["name"]] = field(NAME)
        row[I["objective"]] = objective
        row[I["starter"]], row[I["starterKind"]], row[I["faction"]] = name, kind, faction
        row[I["map"]], row[I["x"]], row[I["y"]] = ui, x, y
        row[I["races"]] = field(RACES) or None
        if row[I["races"]]:
            row[I["faction"]] = None  # the race mask says who may take it; a giver's side can contradict it
        elif row[I["faction"]] is None:
            row[I["faction"]] = capital_side(ui, zone)
        row[I["classes"]] = field(CLASSES) or None
        row[I["needsAll"]] = seq(field(PRE_GROUP)) or None
        row[I["needsAny"]] = seq(field(PRE_SINGLE)) or None
        row[I["exclusiveTo"]] = seq(field(EXCLUSIVE)) or None
        row[I["nextInChain"]] = field(NEXT_IN_CHAIN) or None
        row[I["breadcrumbFor"]] = field(BREADCRUMB_FOR) or None
        row[I["parent"]] = field(PARENT) or None
        row[I["skill"]] = seq(field(REQ_SKILL)) or None
        row[I["minRep"]] = seq(field(MIN_REP)) or None
        row[I["maxRep"]] = seq(field(MAX_REP)) or None
        row[I["maxLevel"]] = field(REQ_MAX_LEVEL) or None
        row[I["untilDone"]] = field(UNTIL_COMPLETED) or None
        row[I["finisher"]] = finisher(field(FINISHED_BY))
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

    # A map's zone, for quests the export gives no zone (Forever's newest, like Smuggler's Paradise): the area that
    # map shows, as the quest list files its other quests.
    map_area = {}
    for area, ui in zones.area_to_map.items():
        if ui not in map_area or zones.top(area) == area:
            map_area[ui] = area

    def zone_of_map(ui):
        area = map_area.get(ui)
        return zones.of(area) if area else None

    placed_by_giver = 0
    for qid, quest in quests.items():
        if qid not in client:
            dropped["not on Forever"] += 1
            if (quest[SPECIAL_FLAGS] or 0) & REPEATABLE:
                skip.add(qid)  # in case the game offers it after all
            continue
        if (quest[SPECIAL_FLAGS] or 0) & REPEATABLE:
            dropped["repeatable"] += 1
            skip.add(qid)
            continue
        if unused(quest[NAME]) or qid in blacklisted:
            dropped["unused or blacklisted"] += 1
            skip.add(qid)
            continue
        zone = zones.of(quest[ZONE_OR_SORT])
        if zone is None and not quest[ZONE_OR_SORT]:  # the export gives it no zone at all: where its giver stands
            zone = zone_of_map(giver(quest[STARTED_BY])[3] or giver(quest[FINISHED_BY])[3])
            placed_by_giver += zone is not None
        if zone is None:
            dropped["seasonal or no zone"] += 1
            skip.add(qid)
            if (quest[ZONE_OR_SORT] or 0) >= 0:
                unplaced.add(qid)  # no zone, or one the game doesn't know: the dungeon journal may
            continue
        row = make_row(lambda field: quest[field], zone)
        extras[qid] = {"end": giver(quest[FINISHED_BY])[3:], "spots": spots(lambda field: quest[field])}  # for its page
        rows[qid] = row
        fix = horde_fix[qid]
        if fix is not None:
            overrides = {field: value for field, value in fix.items()}
            def horde_field(field, quest=quest, overrides=overrides):
                if field in overrides:
                    return overrides[field] if overrides[field] is not False else None
                return quest[field]
            horde_zone = zones.of(horde_field(ZONE_OR_SORT)) or zone
            horde_row = make_row(horde_field, horde_zone)
            diff = {i + 1: (horde_row[i] if horde_row[i] is not None else False)
                    for i in range(len(ROW)) if horde_row[i] != row[i]}
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
        npc = npcs[nid]
        if npc is None:
            return None
        spawns = npc[NPC_SPAWNS]
        areas = list(spawns.keys()) if spawns is not None else []
        return only_dungeon(areas or ([npc[NPC_ZONE]] if npc[NPC_ZONE] else []))

    def object_dungeon(oid):
        obj = objects[oid]
        if obj is None:
            return None
        spawns = obj[OBJECT_SPAWNS]
        areas = list(spawns.keys()) if spawns is not None else []
        return only_dungeon(areas or ([obj[OBJECT_ZONE]] if obj[OBJECT_ZONE] else []))

    def item_dungeon(iid):
        item = items[iid]
        if item is None or item[ITEM_VENDORS]:  # sold by a vendor: not a dungeon item
            return None
        sources = [npc_dungeon(npc) for npc in seq(item[ITEM_NPC_DROPS])] + [object_dungeon(obj) for obj in seq(item[ITEM_OBJECT_DROPS])]
        for zone in {source for source in sources if source}:
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
    print("quests the export gives no zone, placed where their giver stands", placed_by_giver)

    # Quest Completist's quests that Zquest hasn't got.
    qc_db = completist.qcQuestDatabase
    holiday, profession = completist.qcQuestHoliday, completist.qcQuestProfession
    prereq, min_level = completist.qcQuestPrereq, completist.qcQuestMinLevel
    unavailable = completist.qcUnavailableQuests or lua.eval("{}")
    added = 0
    for qid, entry in qc_db.items():
        if qid in rows:
            continue
        if quests[qid] is not None:
            # Zquest has it but couldn't place it (no zone, no giver): Completist's zone, with Zquest's links.
            usable = (qid in client and unavailable[qid] is None and holiday[qid] is None and profession[qid] is None
                      and entry[4] == 1)
            zone = qid in unplaced and usable and zones.of(entry[3])
            if zone:
                rows[qid] = make_row(lambda field, zq=quests[qid]: zq[field], zone)
                skip.discard(qid)
                unplaced.discard(qid)
                added += 1
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
        name, level, sort, kind, faction, races, classes = (entry[i] for i in range(1, 8))
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
        for i, zone_row in enumerate(zones.list, 1):
            if zone_row[0].lower() in wanted:
                if zone_row[1] == OTHER:
                    zone_row[1] = DUNGEONS  # a dungeon the zone list didn't know as one (Forever's new ones)
                return i
        ui_map = None
        for area, dungeon in (data.dungeons or {}).items():
            title = (dungeon[1] or "").lower()
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
    journal_rewards = {}  # quest -> what ForeverDungeonJournal says of it beyond the list (journal_extras)
    for name, dungeon in sorted((journal or {}).items()):
        zone = journal_zone(name)
        listed = dungeon.quests
        for index in range(1, (len(listed) if listed else 0) + 1):
            listed_quest = listed[index]
            qid = listed_quest.id
            if qid:
                journal_rewards[qid] = journal_extras(listed_quest)
            if not qid or (qid in skip and qid not in unplaced):
                continue
            if qid in unplaced and qid not in rows:
                # Left out for its zone alone: the journal says which dungeon it is. Zquest's full entry
                # (links and all) on that page where it has one; else the journal's own fields, below.
                skip.discard(qid)
                unplaced.discard(qid)
                if quests[qid] is not None:
                    rows[qid] = make_row(lambda field, quest=quests[qid]: quest[field], zone)
                    journal_added += 1
                    continue
            if qid in rows:
                if rows[qid][I["zone"]] != zone and zones.list[rows[qid][I["zone"]] - 1][1] not in (CLASS, PROFESSIONS):
                    rows[qid][I["zone"]] = zone
                    if qid in horde and I["zone"] + 1 in horde[qid]:
                        horde[qid][I["zone"] + 1] = zone
                    journal_moved += 1
                continue
            if not listed_quest.name:
                continue
            row = [None] * len(ROW)
            row[I["zone"]], row[I["name"]] = zone, listed_quest.name
            row[I["level"]], row[I["minLevel"]] = listed_quest.level, listed_quest.requires
            row[I["objective"]] = listed_quest.objective or None
            row[I["starter"]], row[I["finisher"]] = first_part(listed_quest.pickup), first_part(listed_quest.turnin)
            row[I["faction"]] = {"Alliance": 1, "Horde": 2}.get(listed_quest.faction)
            rows[qid] = row
            journal_added += 1
    if journal is not None:
        print("dungeon journal: quests moved to their dungeon", journal_moved, "added", journal_added)

    # Players' reports of quests none of the sources has.
    reported = 0
    zone_names = {}
    for i, zone_row in enumerate(zones.list, 1):
        zone_names.setdefault(zone_row[0], i)
    reports = {}  # quest -> its first report's fields, with the sides of every report
    shared_text = {}  # quest -> { field: its Forever text as players read it }, the latest report's
    shared_rewards = {}  # quest -> { choose, items: [[item, count]], money } as the game showed them, the latest's
    for name in sorted(os.listdir(REPORTS), key=report_order) if os.path.isdir(REPORTS) else []:
        if not name.endswith(".txt"):
            continue
        for line in open(os.path.join(REPORTS, name), encoding="utf-8", errors="replace", newline="\n"):
            parts = line.strip().split("^", 3) if line.startswith("LT1^") else line.strip().split("^")
            if len(parts) == 4 and parts[0] == "LT1" and QUEST_ID.fullmatch(parts[1]) and parts[2] in TEXT_FIELDS and parts[3].strip():
                shared_text.setdefault(int(parts[1]), {})[TEXT_FIELDS[parts[2]]] = parts[3].strip()
                continue
            if len(parts) == 5 and parts[0] == "LR1" and QUEST_ID.fullmatch(parts[1]):
                found = reward_line(parts)
                if found:
                    shared_rewards[int(parts[1])] = found
                continue
            if len(parts) < 15 or parts[0] != "LM1" or not QUEST_ID.fullmatch(parts[1]):
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
    shared_text = {qid: text for qid, text in shared_text.items() if qid in rows}
    shared_rewards = {qid: found for qid, found in shared_rewards.items() if qid in rows}
    print("quests with players' text", len(shared_text))
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
    zone_list = zones.list
    order = sorted(range(1, len(zone_list) + 1), key=lambda i: (zone_list[i - 1][1], middle(i), zone_list[i - 1][0]))
    renumber = {old: new for new, old in enumerate(order, 1)}
    zone_rows = [zone_list[old - 1] for old in order]
    art_found = journal_art(casc, zone_rows)
    for row in rows.values():
        row[I["zone"]] = renumber[row[I["zone"]]]
    for diff in horde.values():
        if diff.get(I["zone"] + 1):
            diff[I["zone"] + 1] = renumber[diff[I["zone"] + 1]]

    # The list's version: progress codes name it, so the site reads them against the same quest order.
    version = hashlib.sha1(json.dumps([sorted(rows), [z[0] for z in zone_rows]]).encode()).hexdigest()[:10]
    chain_of = lore_pages.chains(rows, I)
    write_site_data(version, rows, zone_rows, horde, chain_of)
    game = json.load(open(GAME_REWARDS, encoding="utf-8")) if os.path.exists(GAME_REWARDS) else None
    pages = lore_pages.write(rows, extras, I, chain_of, shared_text, journal_rewards, shared_rewards, gear_rewards(),
                             game)
    write_text(pages, text_parts(rows, zone_rows, horde))
    # Quests whose Forever text isn't known: not Classic's (checked against Forever), and players' text hasn't given
    # both the description and the completion yet (what's missing is still asked for).
    want_text = sorted(qid for qid, page in pages.items() if page["same"] is not True and not (
        page.get("shared") and page["text"]["description"] and page["text"]["completion"]))
    want_rewards = sorted(qid for qid, page in pages.items()
                          if not page.get("rewards") or page.get("rewardsFrom") == "gear")  # gear alone: only part
    want_choices = sorted(qid for qid, page in pages.items()
                          if page.get("choicesUnknown") and qid not in set(want_rewards))

    lines = [
        "-- Generated by tools/make_lore.py from Zquest's QuestieDB export (GPL-3.0), Quest Completist's",
        "-- Forever data and the game's own quest and zone tables. Don't edit by hand.",
        "-- zones[i] = { name, group, uiMapID, journal art (a dungeon's or raid's painting, a file ID) }",
        "-- quests[id] = { " + ", ".join(ROW) + ", (26 unused), chain = { first quest, step, steps } }",
        "-- horde[id] = { [field] = value or false }: the Horde view's differences.",
        "-- skip = { id, ... }: quests left out on purpose (repeatable, seasonal, blacklisted), never learned.",
        "-- wantText = { id, ... }: quests whose Forever text isn't known yet (Share.lua asks players for it).",
        "-- wantRewards = { id, ... }: quests whose rewards aren't known yet (likewise; Lorebound also asks the game).",
        "-- wantChoices = { id, ... }: quests whose rewards are known but for any choice (the game tells those only",
        "--   for quests in your log, so players' logs share them).",
        "-- reveal[uiMapArtID] = { { width, height, x, y, tile files row by row }, ... }: every sub-zone's overlay.",
        "LoreboundData = {",
        "version = " + lua_string(version) + ",",
        "groups = " + lua_value(GROUPS) + ",",
        "zones = {",
    ]
    lines += [lua_value(z) + "," for z in zone_rows]
    lines += ["},", "quests = {"]
    for qid in sorted(rows):
        row = list(rows[qid])
        chain = chain_field(qid, chain_of)
        if chain:  # field 27 (26 is the addon's own, for learned quests)
            row += [None, chain]
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
    lines.append("wantText = {" + ",".join(str(q) for q in want_text) + "},")
    lines.append("wantRewards = {" + ",".join(str(q) for q in want_rewards) + "},")
    lines.append("wantChoices = {" + ",".join(str(q) for q in want_choices) + "},")
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
