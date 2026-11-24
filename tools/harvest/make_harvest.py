"""Installs Lorebound Harvest in the game with the quest list to ask about (the quests whose rewards aren't known
first, then the rest), or takes it out again.

    python make_harvest.py           # writes LoreboundHarvest/Quests.lua and copies the add-on into the game
    python make_harvest.py --remove  # takes it out of the game once import_harvest.py has read its answers

The whole round: make_harvest.py, then in game /lbh start and /reload when it's done; import_harvest.py; quit the
game (it writes its quest cache on quitting); import_cache.py (the choices and counts); make_lore.py.
"""
import os
import shutil
import sys

import lupa

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.join(HERE, "..", "..")
ADDON = os.path.join(HERE, "LoreboundHarvest")
GAME = r"C:\Games\World of Warcraft\_forever_\Interface\AddOns\LoreboundHarvest"


def main():
    if "--remove" in sys.argv:
        if os.path.isdir(GAME):
            shutil.rmtree(GAME)
        print("Lorebound Harvest taken out of the game")
        return
    lua = lupa.LuaRuntime()
    lua.execute(open(os.path.join(REPO, "Lorebound_Data", "Data.lua"), encoding="utf-8").read())
    data = lua.globals().LoreboundData
    every = sorted(int(q) for q in data.quests.keys())
    wanted = sorted(int(q) for q in data.wantRewards.values())
    known = set(wanted)
    order = wanted + [q for q in every if q not in known]
    with open(os.path.join(ADDON, "Quests.lua"), "w", encoding="utf-8", newline="\n") as out:
        out.write("-- Written by make_harvest.py from Lorebound_Data: the quests to ask about, those whose rewards aren't\n"
                  "-- known first.\nLoreboundHarvestQuests = {\n")
        for i in range(0, len(order), 20):
            out.write(",".join(str(q) for q in order[i:i + 20]) + ",\n")
        out.write("}\n")
    if os.path.isdir(GAME):
        shutil.rmtree(GAME)
    shutil.copytree(ADDON, GAME)
    print("Lorebound Harvest installed: %d quests (%d without rewards first)" % (len(order), len(wanted)))


if __name__ == "__main__":
    main()
