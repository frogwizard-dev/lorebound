"""Reads the game's quest cache (Cache/WDB/enUS/questcache.wdb: each quest's record as the server sent it, written
when the game quits) into sources/Game/rewards.json beside import_harvest.py's answers. The cache has what the
game's Lua calls won't tell for a quest outside your log: its choices, so every cached quest's choices become known
(none included). Run import_harvest.py first, quit the game (a /reload doesn't write the cache), then:

    python import_cache.py

The record's layout isn't documented, so it's checked against the harvest every run: the items each record holds
must be the ones the game's calls answered, or nothing is written. The cache's counts win (the calls answered 1 for
82 stacks, Raptor Horns' 5 Raptor Punch among them); the harvest's money stays (the record's money field is
negative where a quest costs money).
"""
import json
import os
import struct

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.join(HERE, "..", "..")
CACHE = r"C:\Games\World of Warcraft\_forever_\Cache\WDB\enUS\questcache.wdb"
OUT = os.path.join(REPO, "sources", "Game", "rewards.json")

# Offsets in a record (build 71037): money; 4 items received (item, count, then two more fields); 6 choices
# (item, count, display).
MONEY, ITEMS, ITEM_SIZE, CHOICES, CHOICE_SIZE = 48, 116, 16, 180, 12


def records(path):
    data = open(path, "rb").read()
    magic, build, locale = struct.unpack_from("<4sI4s", data, 0)
    if magic != b"TSQW":
        raise SystemExit("not a quest cache: %r" % magic)
    found, pos = {}, 24
    while pos + 8 <= len(data):
        qid, size = struct.unpack_from("<II", data, pos)
        if size == 0:
            break
        found[qid] = data[pos + 8:pos + 8 + size]
        pos += 8 + size
    return build, locale[::-1].decode(), found


def rewards(record):
    if len(record) < CHOICES + 6 * CHOICE_SIZE:
        return None
    items = [list(struct.unpack_from("<2I", record, ITEMS + ITEM_SIZE * i)) for i in range(4)]
    choose = [list(struct.unpack_from("<2I", record, CHOICES + CHOICE_SIZE * i)) for i in range(6)]
    return {"items": [[item, max(1, count)] for item, count in items if item],
            "choose": [[item, max(1, count)] for item, count in choose if item],
            "money": struct.unpack_from("<i", record, MONEY)[0]}


def main():
    build, locale, cached = records(CACHE)
    game = json.load(open(OUT, encoding="utf-8"))
    quests = game["quests"]
    checked = agree = 0
    for qid, entry in quests.items():
        record = cached.get(int(qid))
        found = record and rewards(record)
        if found:
            checked += 1
            agree += sorted(item for item, _ in found["items"]) == sorted(item for item, _ in entry["items"])
    print("questcache.wdb: build %d, %s, %d quests; item IDs agree with the harvest on %d of %d"
          % (build, locale, len(cached), agree, checked))
    if checked < 20 or agree < checked * 0.95:
        raise SystemExit("the cache's layout doesn't match the harvest: nothing written (has the game updated?)")
    added = choices = 0
    for qid, entry in quests.items():
        record = cached.get(int(qid))
        found = record and rewards(record)
        if found:
            entry["choose"] = found["choose"]  # known now, none included
            entry["items"] = found["items"]  # with their counts (the game's calls answer 1 for some stacks)
            added += 1
            choices += bool(found["choose"])
    game["cache"] = {"build": build, "quests": added}
    with open(OUT, "w", encoding="utf-8", newline="\n") as out:
        json.dump(game, out, separators=(",", ":"))
    print("choices known for %d quests (%d with choices)" % (added, choices))


if __name__ == "__main__":
    main()
