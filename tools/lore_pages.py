"""Each quest's page data for Lorebound's site: loremaster-report/public/data/q/<id>.json. Called by make_lore.py.

- Forever's objective and requirements: Wowhead's tooltips (lore_wowhead.py's cache).
- The description, progress and completion text and the rewards: CMaNGOS's classic-db (GPL-3.0; its full
  database in lore_sources/classicdb.sql.gz), shown only where Forever's objective is Classic's word for word
  ("same"), since Forever rewrote many quests. Players' shared text (lore_reports) will fill in the rest.
- Where it's handed in and where its objectives are (Zquest's spawns), and its chain (the list's links).
"""
import gzip
import json
import os
import re

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
        i, n = 0, len(text)
        while i < n:
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
        return {int(k): v for k, v in cached["quests"].items()}, {int(k): v for k, v in cached["items"].items()}
    sql = gzip.open(CLASSIC_SQL, "rt", encoding="utf-8", errors="replace").read()
    quests = {row["entry"]: {c: row[c] for c in QUEST_COLUMNS} for row in _rows(sql, "quest_template")}
    wanted = {row[c] for row in quests.values() for c in QUEST_COLUMNS if c.startswith(("RewItemId", "RewChoiceItemId"))}
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
    return [p.strip() for p in re.split(r"\n\s*\n|\n", text) if p.strip()]


def plain(text):
    return re.sub(r"[^a-z0-9]+", "", (text or "").lower())


def same_objective(classic_objective, forever_paragraphs):
    """Forever's objective (Wowhead) is Classic's, ignoring spacing, punctuation and markup."""
    return plain(" ".join(game_text(classic_objective))) == plain(" ".join(forever_paragraphs))


def forever_items():
    """{ item: (name, quality, icon) } from Forever's own item tables (wago.tools' CSVs of ItemSparse and Item,
    in lore_sources) with icon names from the community listfile; {} when they aren't there."""
    import csv
    from make_lore import wago_csv  # Forever's tables as CSV from wago.tools, cached a day in lore_sources
    csv.field_size_limit(10 ** 7)
    icon_fid = {int(r["ID"]): int(r["IconFileDataID"] or 0) for r in wago_csv("Item")}
    from game_files import GameFiles
    wanted = set(icon_fid.values())
    names = {fid: path[len("interface/icons/"):-4] for path, fid in GameFiles(local=False).paths().items()
             if fid in wanted and path.startswith("interface/icons/") and path.endswith(".blp")}
    out = {item: (None, None, names.get(fid)) for item, fid in icon_fid.items()}  # ItemSparse has only some items
    for r in wago_csv("ItemSparse"):
        item = int(r["ID"])
        out[item] = (r["Display_lang"], int(r["OverallQualityID"] or 1), names.get(icon_fid.get(item)))
    return out


def rewards(entry, items, forever):
    def listed(ids, counts):
        found = []
        for i, c in zip(ids, counts):
            if entry[i]:
                name, quality = items.get(entry[i], (None, None))
                forever_name, forever_quality, icon = forever.get(entry[i], (None, None, None))
                name, quality = forever_name or name, forever_quality if forever_name else quality
                found.append([entry[i], entry[c] or 1, name, quality, icon])
        return found
    choose = listed(["RewChoiceItemId%d" % n for n in range(1, 7)], ["RewChoiceItemCount%d" % n for n in range(1, 7)])
    receive = listed(["RewItemId%d" % n for n in range(1, 5)], ["RewItemCount%d" % n for n in range(1, 5)])
    rep = [[entry["RewRepFaction%d" % n], entry["RewRepValue%d" % n]] for n in range(1, 6)
           if entry["RewRepFaction%d" % n] and entry["RewRepValue%d" % n]]
    money = entry["RewOrReqMoney"] if (entry["RewOrReqMoney"] or 0) > 0 else 0
    out = {"choose": choose, "items": receive, "rep": rep, "money": money, "spell": entry["RewSpell"] or 0}
    return out if (choose or receive or rep or money or out["spell"]) else None


# ---------------------------------------------------------------- chains

def chains(rows, I):
    """{ quest: [the chain it's in, in order] } from nextInChain, else a single prerequisite."""
    nxt, prev = {}, {}
    for qid, row in rows.items():
        if row[I["nextInChain"]] in rows:
            nxt[qid] = row[I["nextInChain"]]
            prev.setdefault(row[I["nextInChain"]], qid)
    for qid, row in rows.items():
        needs = row[I["needsAll"]] or []
        if len(needs) == 1 and abs(needs[0]) in rows and qid not in prev:
            prev[qid] = abs(needs[0])
            nxt.setdefault(abs(needs[0]), qid)
    # Each chain once, walked from its first quest (one with no step before it); every quest on it gets that same
    # list, so the first quest, the step and the count agree. Chains don't share quests: where two meet, the second stops; a quest only reached by a branch stands alone.
    out = {}
    for first in sorted(q for q in nxt if q not in prev):
        chain, at = [first], first
        while at in nxt and nxt[at] not in out and nxt[at] not in chain and len(chain) < 40:  # stops where it joins
            at = nxt[at]                                                                   # a chain already built
            chain.append(at)
        if len(chain) > 1:
            for qid in chain:
                out[qid] = chain
    return out


# ---------------------------------------------------------------- pages

def write(rows, extras, I):
    os.makedirs(OUT, exist_ok=True)
    quests, items = classic() if os.path.exists(CLASSIC_SQL) else ({}, {})
    wowhead = json.load(open(WOWHEAD, encoding="utf-8")) if os.path.exists(WOWHEAD) else {}
    chain_of = chains(rows, I)
    item_names = forever_items()
    counts = {"same": 0, "changed": 0, "unchecked": 0, "new": 0}
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
            "start": [row[I["starter"]], row[I["map"]], row[I["x"]], row[I["y"]]],
            "end": [row[I["finisher"]]] + list(extras.get(qid, {}).get("end") or (None, None, None)),
            "chain": chain_of.get(qid, []),
        }
        if old is not None and same is not False:  # Classic's text: unchanged, or not checkable yet (said so)
            page["text"] = {"description": game_text(old["Details"]), "progress": game_text(old["RequestItemsText"]),
                            "completion": game_text(old["OfferRewardText"])}
            page["rewards"] = rewards(old, items, item_names)
        spots = extras.get(qid, {}).get("spots") or {}
        kept, total = {}, 0
        for ui in sorted(spots, key=lambda m: (m != row[I["map"]], -len(spots[m]))):
            kept[ui] = spots[ui][:max(0, MAX_SPOTS - total)]
            total += len(kept[ui])
        page["spots"] = {str(ui): found for ui, found in kept.items() if found}
        with open(os.path.join(OUT, "%d.json" % qid), "w", encoding="utf-8", newline="\n") as f:
            json.dump(page, f, ensure_ascii=False, separators=(",", ":"))
        pages[qid] = page
    print("quest pages %d: Classic's text kept %d, changed in Forever %d, not on Wowhead yet %d, new in Forever %d"
          % (len(rows), counts["same"], counts["changed"], counts["unchecked"], counts["new"]))
    return pages
