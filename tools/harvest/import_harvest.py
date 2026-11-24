"""Reads Lorebound Harvest's answers (the game's saved variables, after a /reload) into sources/Game/rewards.json,
which make_lore.py uses as Forever's own rewards.

    python import_harvest.py

Kept: quests the server said it loaded, whose title matches Lorebound's name for them and whose every reward slot
had an item ID. Choices are kept only where the game gave some: it tells them only for quests in your log (the
2026-11-24 harvest: 8 of the 339 quests Classic gives choices for), so none means not known. Experience is kept
only where the game didn't scale it to the character (more than five levels above the quest, or at the level cap,
it pays less); money is marked when read at the cap, where the game may add the experience to it as gold
(make_lore.py checks that against Classic's money before using it).
"""
import glob
import json
import os
import re

import lupa

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.join(HERE, "..", "..")
SAVED = r"C:\Games\World of Warcraft\_forever_\WTF\Account\*\SavedVariables\LoreboundHarvest.lua"
OUT = os.path.join(REPO, "sources", "Game", "rewards.json")


def table(lua_table):
    if lua_table is None or not hasattr(lua_table, "items"):
        return lua_table
    return {key: table(value) for key, value in lua_table.items()}


def slots(found):
    """{1: {1: item, 2: count}, ...} as [[item, count]], or None when partial (False) or missing."""
    if not isinstance(found, dict):
        return None
    return [[int(found[i][1]), max(1, int(found[i][2] or 1))] for i in sorted(found)]


def same_title(a, b):
    """Titles alike but for case, spaces and punctuation ("Look to the Stars", "Look To The Stars")."""
    plain = lambda title: re.sub(r"[^a-z0-9]", "", (title or "").lower())
    return bool(a) and plain(a) == plain(b)


def main():
    files = sorted(glob.glob(SAVED), key=os.path.getmtime)
    if not files:
        raise SystemExit("no LoreboundHarvest.lua in the saved variables: /lbh start, then /reload")
    lua = lupa.LuaRuntime()
    lua.execute(open(files[-1], encoding="utf-8").read())
    saved = table(lua.globals().LoreboundHarvestDB)
    player, answers = saved.get("player") or {}, saved.get("quests") or {}
    lua.execute(open(os.path.join(REPO, "Lorebound_Data", "Data.lua"), encoding="utf-8").read())
    quests = lua.globals().LoreboundData.quests

    level, cap = int(player.get("level") or 0), int(player.get("cap") or 60)
    at_cap = level >= cap
    kept, why = {}, {"not loaded": 0, "title differs": 0, "item without an ID": 0}
    differs = []
    for qid, got in answers.items():
        qid = int(qid)
        row = quests[qid]
        if not got.get("loaded"):
            why["not loaded"] += 1
            continue
        if row is None or not same_title(got.get("title"), row[4]):
            why["title differs"] += 1
            differs.append((qid, got.get("title"), row and row[4]))
            continue
        choose, items = slots(got.get("ch")), slots(got.get("it"))
        if choose is None or items is None:
            why["item without an ID"] += 1
            continue
        quest_level = row[2] or 0
        xp = int(got.get("xp") or 0)
        entry = {"items": items, "money": int(got.get("m") or 0)}
        if choose:  # the game answers choices only for quests in the log: none means not known
            entry["choose"] = choose
        if xp > 0 and not at_cap and quest_level > 0 and level <= quest_level + 5:
            entry["xp"] = xp
        if got.get("sp"):
            entry["spells"] = int(got["sp"])
        kept[qid] = entry
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8", newline="\n") as out:
        json.dump({"player": {"level": level, "cap": cap, "class": player.get("class"), "race": player.get("race"),
                              "faction": player.get("faction"), "build": player.get("build"), "atCap": at_cap},
                   "quests": {str(q): kept[q] for q in sorted(kept)}}, out, separators=(",", ":"))
    with_items = sum(1 for e in kept.values() if e.get("choose") or e["items"])
    print("%s: %d answers; kept %d (%d with items, %d with money); left out %s"
          % (os.path.basename(files[-1]), len(answers), len(kept), with_items,
             sum(1 for e in kept.values() if e["money"]), why))
    print("player level %d of %d%s" % (level, cap, " (at the cap: money checked against Classic's)" if at_cap else ""))
    for qid, title, name in differs[:10]:
        print("   title differs %d: game %r, Lorebound %r" % (qid, title, name))


if __name__ == "__main__":
    main()
