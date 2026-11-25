"""Each quest's page data for Lorebound's site (site/public/data/q/<id>.json) and the journal's quest pages
(make_lore.write_text). Called by make_lore.py.

- Forever's objective and requirements: Wowhead's tooltips (lore_wowhead.py's cache).
- The description, progress and completion text and the rewards: CMaNGOS's classic-db (GPL-3.0; its full
  database in lore_sources/classicdb.sql.gz), shown only where Forever's objective is Classic's word for word
  ("same"), since Forever rewrote many quests. Where it doesn't apply, players' text from Forever (LT1 lines in
  the reports you've approved, lore_reports) fills the page, marked "shared".
- ForeverDungeonJournal, for its dungeon quests: Forever's own rewards (over Classic's), its notes and where each is
  picked up and handed in. Rewards otherwise unknown come from players' reports (LR1 lines), else OneForAll's list of
  the gear a quest gives (GPL-3; shown as "rewards include"). "rewardsFrom" says which.
- Where it's handed in and where its objectives are (Zquest's spawns), and its chain (the list's links).
"""
import gzip
import json
import os
import re

from game_files import GameFiles, wago_csv

HERE = os.path.dirname(os.path.abspath(__file__))
SOURCES = os.path.join(HERE, "lore_sources")
CLASSIC_SQL = os.path.join(SOURCES, "classicdb.sql.gz")
CLASSIC_CACHE = os.path.join(SOURCES, "classic_quests.json")
WOWHEAD = os.path.join(SOURCES, "wowhead_quests.json")
OUT = os.path.join(HERE, "..", "site", "public", "data", "q")
MAX_SPOTS = 80
QUEST_COLUMNS = ("entry", "Title", "Details", "Objectives", "OfferRewardText", "RequestItemsText",
                 "RewChoiceItemId1", "RewChoiceItemId2", "RewChoiceItemId3", "RewChoiceItemId4", "RewChoiceItemId5",
                 "RewChoiceItemId6", "RewChoiceItemCount1", "RewChoiceItemCount2", "RewChoiceItemCount3",
                 "RewChoiceItemCount4", "RewChoiceItemCount5", "RewChoiceItemCount6", "RewItemId1", "RewItemId2",
                 "RewItemId3", "RewItemId4", "RewItemCount1", "RewItemCount2", "RewItemCount3", "RewItemCount4",
                 "RewRepFaction1", "RewRepFaction2", "RewRepFaction3", "RewRepFaction4", "RewRepFaction5",
                 "RewRepValue1", "RewRepValue2", "RewRepValue3", "RewRepValue4", "RewRepValue5", "RewOrReqMoney",
                 "RewSpell")


# ---------------------------------------------------------------- CMaNGOS's SQL dump

def _rows(sql, table):
    """Each row of `table`'s INSERTs as a dict, by the column names of its CREATE TABLE."""
    create = re.search(r"CREATE TABLE `%s` \((.*?)\n\) ENGINE" % table, sql, re.S)
    columns = re.findall(r"^\s*`(\w+)`", create.group(1), re.M)
    for insert in re.finditer(r"INSERT INTO `%s` VALUES (.*?);\n" % table, sql, re.S):
        text = insert.group(1)
        i, length = 0, len(text)
        while i < length:
            if text[i] != "(":
                i += 1
                continue
            values, i = [], i + 1
            while True:
                if text[i] == "'":  # a string: backslash escapes
                    j, out = i + 1, []
                    while text[j] != "'":
                        if text[j] == "\\":
                            j += 1
                            out.append({"n": "\n", "r": "", "t": "\t", "0": ""}.get(text[j], text[j]))
                        else:
                            out.append(text[j])
                        j += 1
                    values.append("".join(out))
                    i = j + 1
                else:
                    j = i
                    while text[j] not in ",)":
                        j += 1
                    token = text[i:j].strip()
                    values.append(None if token == "NULL" else float(token) if "." in token else int(token))
                    i = j
                if text[i] == ",":
                    i += 1
                    continue
                i += 1  # the closing ")"
                break
            yield dict(zip(columns, values))


def classic():
    """{ quest: CMaNGOS's fields we use }, and { item: (name, quality) }, cached beside the dump."""
    if os.path.exists(CLASSIC_CACHE) and os.path.getmtime(CLASSIC_CACHE) > os.path.getmtime(CLASSIC_SQL):
        cached = json.load(open(CLASSIC_CACHE, encoding="utf-8"))
        return {int(key): value for key, value in cached["quests"].items()}, {int(key): value for key, value in cached["items"].items()}
    sql = gzip.open(CLASSIC_SQL, "rt", encoding="utf-8", errors="replace").read()
    quests = {row["entry"]: {column: row[column] for column in QUEST_COLUMNS} for row in _rows(sql, "quest_template")}
    wanted = {row[column] for row in quests.values() for column in QUEST_COLUMNS if column.startswith(("RewItemId", "RewChoiceItemId"))}
    items = {row["entry"]: (row["name"], row["Quality"]) for row in _rows(sql, "item_template") if row["entry"] in wanted}
    with open(CLASSIC_CACHE, "w", encoding="utf-8") as f:
        json.dump({"quests": quests, "items": items}, f, ensure_ascii=False, separators=(",", ":"))
    return quests, items


# ---------------------------------------------------------------- text

def game_text(text):
    """The game's markup made readable: $B line breaks, $N your name, $C class, $R race, $Gman:woman;."""
    if not text:
        return []
    text = re.sub(r"\$[Gg]\s*([^:;]*):([^;]*);", r"\1/\2", text)
    text = re.sub(r"\$[Bb]", "\n", text)
    text = re.sub(r"\$[Nn]", "<name>", text)
    text = re.sub(r"\$[Cc]", "<class>", text)
    text = re.sub(r"\$[Rr]", "<race>", text)
    return [part.strip() for part in re.split(r"\n\s*\n|\n", text) if part.strip()]


def plain(text):
    return re.sub(r"[^a-z0-9]+", "", (text or "").lower())


def same_objective(classic_objective, forever_paragraphs):
    """Forever's objective (Wowhead) is Classic's, ignoring spacing, punctuation and markup."""
    return plain(" ".join(game_text(classic_objective))) == plain(" ".join(forever_paragraphs))


def forever_items():
    """{ item: (name, quality, icon) } from Forever's own item tables (wago.tools' CSVs of ItemSparse and Item,
    in lore_sources) with icon names from the community listfile; {} when they aren't there."""
    icon_fid = {int(row["ID"]): int(row["IconFileDataID"] or 0) for row in wago_csv("Item")}
    wanted = set(icon_fid.values())
    names = {fid: path[len("interface/icons/"):-4] for path, fid in GameFiles(local=False).paths().items()
             if fid in wanted and path.startswith("interface/icons/") and path.endswith(".blp")}
    out = {item: (None, None, names.get(fid)) for item, fid in icon_fid.items()}  # ItemSparse has only some items
    for row in wago_csv("ItemSparse"):
        item = int(row["ID"])
        out[item] = (row["Display_lang"], int(row["OverallQualityID"] or 1), names.get(icon_fid.get(item)))
    return out


def rewards(entry, items, forever):
    def listed(ids, counts):
        found = []
        for id_key, count_key in zip(ids, counts):
            if entry[id_key]:
                name, quality = items.get(entry[id_key], (None, None))
                forever_name, forever_quality, icon = forever.get(entry[id_key], (None, None, None))
                name, quality = forever_name or name, forever_quality if forever_name else quality
                found.append([entry[id_key], entry[count_key] or 1, name, quality, icon])
        return found
    choose = listed(["RewChoiceItemId%d" % number for number in range(1, 7)], ["RewChoiceItemCount%d" % number for number in range(1, 7)])
    receive = listed(["RewItemId%d" % number for number in range(1, 5)], ["RewItemCount%d" % number for number in range(1, 5)])
    rep = [[entry["RewRepFaction%d" % number], entry["RewRepValue%d" % number]] for number in range(1, 6)
           if entry["RewRepFaction%d" % number] and entry["RewRepValue%d" % number]]
    money = entry["RewOrReqMoney"] if (entry["RewOrReqMoney"] or 0) > 0 else 0
    out = {"choose": choose, "items": receive, "rep": rep, "money": money, "spell": entry["RewSpell"] or 0}
    return out if (choose or receive or rep or money or out["spell"]) else None


def other_rewards(qid, journal_rewards, shared_rewards, forever, gear=None, game=None, classic_items=None):
    """A quest's rewards from ForeverDungeonJournal or players' reports, in rewards()'s shape, and where from; names,
    quality and icons from Forever's own item tables where it has them."""
    def entry(item, count, name=None, quality=None):
        forever_name, forever_quality, icon = forever.get(item, (None, None, None))
        if name and name.startswith("Item "):  # the journal's placeholder for an item it hadn't named
            name = None
        if not name and classic_items and item in classic_items:  # Classic's own items keep Classic's names
            name, quality = classic_items[item]
        return [item, count, forever_name or name, forever_quality if forever_name else quality, icon]
    journal = (journal_rewards or {}).get(qid)
    mine = (game or {}).get(str(qid))
    if mine:  # the game server's own answer: the items and money; reputation and experience from the journal
        found = {"choose": [entry(item, count) for item, count in mine.get("choose", [])],
                 "items": [entry(item, count) for item, count in mine["items"]],
                 "rep": journal["rep"] if journal else [], "money": mine["money"], "spell": 0,
                 "xp": (journal and journal["xp"]) or mine.get("xp")}
        return found, "game"
    if journal and (journal["items"] or journal["extra"] or journal["money"] or journal["rep"] or journal["xp"]):
        listed = [entry(item, count, name, quality) for item, name, quality, count in journal["items"]]
        extra = [entry(item, count, name, quality) for item, name, quality, count in journal["extra"]]
        found = {"choose": listed if journal["choice"] else [], "items": extra + ([] if journal["choice"] else listed),
                 "rep": journal["rep"], "money": journal["money"], "spell": 0, "xp": journal["xp"]}
        return found, "journal"
    players = (shared_rewards or {}).get(qid)
    if players:
        found = {"choose": [entry(item, count) for item, count in players["choose"]],
                 "items": [entry(item, count) for item, count in players["items"]],
                 "rep": [], "money": players["money"], "spell": 0}
        return found, "players"
    some = (gear or {}).get(qid)
    if some:
        found = {"choose": [], "items": [], "some": [entry(item, 1, name) for item, name in some], "rep": [],
                 "money": 0, "spell": 0}
        return found, "gear"
    return None, None


# ---------------------------------------------------------------- chains

def chains(rows, I):
    """{ quest: [the chain it's in, in order] } from nextInChain, else a single prerequisite."""
    next_of, before = {}, {}
    for qid, row in rows.items():
        if row[I["nextInChain"]] in rows:
            next_of[qid] = row[I["nextInChain"]]
            before.setdefault(row[I["nextInChain"]], qid)
    for qid, row in rows.items():
        needs = row[I["needsAll"]] or []
        if len(needs) == 1 and abs(needs[0]) in rows and qid not in before:
            before[qid] = abs(needs[0])
            next_of.setdefault(abs(needs[0]), qid)
    # Each chain once, walked from its first quest (one with no step before it); every quest on it gets that same
    # list, so the first quest, the step and the count agree. Chains don't share quests: where two meet, the second
    # stops; a quest only reached by a branch stands alone.
    out = {}
    for first in sorted(qid for qid in next_of if qid not in before):
        chain, at = [first], first
        while at in next_of and next_of[at] not in out and next_of[at] not in chain and len(chain) < 40:  # stops where it joins
            at = next_of[at]                                                                   # a chain already built
            chain.append(at)
        if len(chain) > 1:
            for qid in chain:
                out[qid] = chain
    return out


# ---------------------------------------------------------------- pages

def write(rows, extras, I, chain_of, shared_text=None, journal_rewards=None, shared_rewards=None, gear=None,
          game=None):
    """Writes every quest's page and returns them { quest: page }; chain_of is chains()'s, shared_text the players'
    text by quest ({ field: text }), journal_rewards ForeverDungeonJournal's rewards ({ choice, items: [(item, name,
    quality)] }), shared_rewards the players' ({ choose, items: [[item, count]], money }) and gear OneForAll's gear
    rewards ([(item, name)]: part of them, shown as "some"), all make_lore.py's. game is the game server's own
    answers (sources/Game/rewards.json, tools/harvest): { "player": {...}, "quests": { quest: {...} } }."""
    game_quests = (game or {}).get("quests") or {}
    game_at_cap = bool(((game or {}).get("player") or {}).get("atCap"))
    compared = {"items": {True: 0, False: 0}, "money": {True: 0, False: 0}}
    mismatches = []
    os.makedirs(OUT, exist_ok=True)
    quests, items = classic() if os.path.exists(CLASSIC_SQL) else ({}, {})
    wowhead = json.load(open(WOWHEAD, encoding="utf-8")) if os.path.exists(WOWHEAD) else {}
    item_names = forever_items()
    counts = {"same": 0, "changed": 0, "unchecked": 0, "new": 0, "shared": 0}
    pages = {}
    for qid, row in rows.items():
        forever = wowhead.get(str(qid))
        old = quests.get(qid)
        if old is None:
            same = None
            counts["new"] += 1
        elif not forever:
            same = None
            counts["unchecked"] += 1
        else:
            same = same_objective(old["Objectives"], forever["objective"])
            counts["same" if same else "changed"] += 1
        page = {
            "objective": forever["objective"] if forever else game_text(row[I["objective"]]),
            "needs": forever["needs"] if forever else [],
            "same": same,
            "start": [row[I["starter"]], row[I["map"]], row[I["x"]], row[I["y"]]] + ([row[I["starterFrom"]]] if row[I["starterFrom"]] else []),
            "end": [row[I["finisher"]]] + list(extras.get(qid, {}).get("end") or (None, None, None)),
            "chain": chain_of.get(qid, []),
        }
        if old is not None and same is not False:  # Classic's text: unchanged, or not checkable yet (said so)
            page["text"] = {"description": game_text(old["Details"]), "progress": game_text(old["RequestItemsText"]),
                            "completion": game_text(old["OfferRewardText"])}
            page["rewards"] = rewards(old, items, item_names)
        players = (shared_text or {}).get(qid)
        journal = (journal_rewards or {}).get(qid)
        found, source = other_rewards(qid, journal_rewards, shared_rewards, item_names, gear, game_quests, items)
        classic_rewards = page.get("rewards")
        if found and source == "game":
            # The game tells choices only for quests in the harvester's log: none means not known. What it doesn't
            # carry comes from the next source down (the journal, players), then Classic's.
            choices_known = "choose" in game_quests[str(qid)]  # the game's cache tells them, none included
            if classic_rewards:
                matches = {"items": sorted(map(tuple, (e[:2] for e in found["items"])))
                           == sorted(map(tuple, (e[:2] for e in classic_rewards["items"]))),
                           "money": found["money"] == classic_rewards["money"]}
                for key, agrees in matches.items():
                    compared[key][agrees] += 1
                if not matches["items"] and len(mismatches) < 8:
                    mismatches.append(qid)
                if game_at_cap:  # money at the cap may carry the experience as gold: Classic's, where it has it
                    found["money"] = classic_rewards["money"] or found["money"]
            below, below_source = other_rewards(qid, journal_rewards, shared_rewards, item_names, gear, None, items)
            for other in ((below if below_source in ("journal", "players") else None), classic_rewards):
                if not other:
                    continue
                if not choices_known and not found["choose"] and other.get("choose"):
                    found["choose"] = other["choose"]
                if not choices_known and not found["items"] and other.get("items"):
                    # none from the game, whose answer had no choices either: kept. (A complete answer stands:
                    # Forever often made Classic's one reward a choice among new ones.)
                    offered = {e[0] for e in found["choose"]}
                    found["items"] = [e for e in other["items"] if e[0] not in offered]
                for field in ("rep", "spell"):
                    if not found[field] and other.get(field):
                        found[field] = other[field]
            if not choices_known and not found["choose"]:
                given = {e[0] for e in found["items"]}
                some = [e for e in (below or {}).get("some", []) if e[0] not in given] if below_source == "gear" else []
                if some:
                    found["some"] = some
                if not classic_rewards and below_source not in ("journal", "players"):
                    page["choicesUnknown"] = True  # Forever's own quest: still asked of players
            page["rewards"], page["rewardsFrom"] = found, source
        elif found and source == "journal" and classic_rewards:  # Forever's own, field by field: what it doesn't say, Classic's
            for field in ("choose", "items", "rep", "money", "spell"):
                if not found[field]:
                    found[field] = classic_rewards[field]
            page["rewards"], page["rewardsFrom"] = found, source
        elif found and not classic_rewards:
            page["rewards"], page["rewardsFrom"] = found, source
        if journal:
            for key in ("note", "pickup", "turnin"):
                if journal[key]:
                    page[key] = journal[key]
        if players and same is not True:  # Forever's own text, as players read it, field by field over Classic's
            if not forever and game_text(players.get("objective")):   # unchecked text (Wowhead's objective wins)
                page["objective"] = game_text(players["objective"])
            text = dict(page.get("text") or {"description": [], "progress": [], "completion": []})
            for field in ("description", "progress", "completion"):
                if game_text(players.get(field)):
                    text[field] = game_text(players[field])
                    page["shared"] = True
            if page.get("shared"):
                page["text"] = text
                counts["shared"] += 1
        spots = extras.get(qid, {}).get("spots") or {}
        kept, total = {}, 0
        for ui in sorted(spots, key=lambda ui: (ui != row[I["map"]], -len(spots[ui]))):
            kept[ui] = spots[ui][:max(0, MAX_SPOTS - total)]
            total += len(kept[ui])
        page["spots"] = {str(ui): found for ui, found in kept.items() if found}
        with open(os.path.join(OUT, "%d.json" % qid), "w", encoding="utf-8", newline="\n") as f:
            json.dump(page, f, ensure_ascii=False, separators=(",", ":"))
        pages[qid] = page
    print("quest pages %d: Classic's text kept %d, changed in Forever %d, not on Wowhead yet %d, new in Forever %d;"
          " players' text on %d" % (len(rows), counts["same"], counts["changed"], counts["unchecked"], counts["new"],
                                    counts["shared"]))
    if game_quests:
        print("game rewards on %d quests; against Classic's: items agree %d, differ %d (e.g. %s); money agrees %d,"
              " differs %d" % (sum(1 for page in pages.values() if page.get("rewardsFrom") == "game"),
                               compared["items"][True], compared["items"][False], mismatches,
                               compared["money"][True], compared["money"][False]))
    return pages
