"""Checks a change to Lore.lua changes nothing it should not: runs the committed Lore.lua (git HEAD) and the working
one on the same quest data for four made-up characters (both factions, levels 12 to 60, random quests done and in
the log) and compares every quest status and reason, word for word.

    python tools/check_lore.py      # exits 1 and shows the first differences when any quest differs
"""
import os
import random
import subprocess
import sys

import lupa

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = open(os.path.join(ROOT, "Lorebound_Data", "Data.lua"), encoding="utf-8").read()
NEW = open(os.path.join(ROOT, "Lore.lua"), encoding="utf-8").read()
OLD = subprocess.run(["git", "show", "HEAD:Lore.lua"], cwd=ROOT, capture_output=True, text=True, encoding="utf-8").stdout


def run(source, done, active, race, cls, level, faction):
    lua = lupa.LuaRuntime()
    lua.execute(DATA)
    stubs = """
    local done, active, race, cls, level, faction = ...
    wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
    UnitFactionGroup = function() return faction end
    UnitLevel = function() return level end
    UnitRace = function() return "R", "R", race end
    UnitClass = function() return "C", "C", cls end
    C_QuestLog = {
      IsQuestFlaggedCompleted = function(id) return done[id] == true end,
      GetNumQuestLogEntries = function() local n = 0 for _ in pairs(active) do n = n + 1 end return n end,
    }
    local list = {} for id in pairs(active) do list[#list + 1] = id end
    C_QuestLog.GetInfo = function(i) return list[i] and { questID = list[i] } end
    C_Reputation = { GetFactionDataByID = function() return nil end }
    """
    lua.execute("ns = { db = { learned = {}, shared = {} }, charDB = { met = {} } }")
    to_set = lua.eval("function(t) local out = {} for _, v in ipairs(t) do out[v] = true end return out end")
    lua.eval("function(...) " + stubs + " end")(to_set(lua.table_from(done)), to_set(lua.table_from(active)), race, cls, level, faction)
    loader = lua.eval("function(src) local f = assert(load(src)) f(nil, ns) end")
    lua.execute("ns.F = { zone = 1, level = 2, minLevel = 3, name = 4, objective = 5, starter = 6, starterKind = 7, races = 8, classes = 9, needsAll = 10, needsAny = 11, exclusiveTo = 12, nextInChain = 13, breadcrumbFor = 14, parent = 15, skill = 16, minRep = 17, maxRep = 18, maxLevel = 19, untilDone = 20, faction = 21, finisher = 22, map = 23, x = 24, y = 25, starterFrom = 26, chain = 27, mine = 28 }")
    loader(source)
    lua.execute("ns.Lore.Init(LoreboundData) ns.Lore.Refresh()")
    result = lua.eval("""function()
      local out = {}
      for id in pairs(LoreboundData.quests) do
        local s, why = ns.Lore.StatusOf(id)
        out[id] = tostring(s) .. "|" .. tostring(why)
      end
      local d, t = ns.Lore.TotalCount()
      out[0] = d .. "/" .. t
      return out
    end""")()
    return dict(result.items())


def main():
    ids = sorted(lupa.LuaRuntime().eval("function(src) local f = load(src) f() local t = {} for id in pairs(LoreboundData.quests) do t[#t+1] = id end return t end")(DATA).values())
    random.seed(7)
    differences = 0
    for trial, (race, cls, level, faction) in enumerate([(6, 7, 30, "Horde"), (1, 2, 45, "Alliance"), (8, 3, 12, "Horde"), (3, 1, 60, "Alliance")]):
        done_ids = random.sample(ids, 900)
        active_ids = random.sample([i for i in ids if i not in done_ids], 15)
        old = run(OLD, done_ids, active_ids, race, cls, level, faction)
        new = run(NEW, done_ids, active_ids, race, cls, level, faction)
        diff = [qid for qid in old if old[qid] != new.get(qid)]
        differences += len(diff)
        print("character %d: %d quests compared, %d differ, total %s" % (trial + 1, len(old), len(diff), new[0]))
        for qid in diff[:5]:
            print("  ", qid, old[qid], "->", new.get(qid))
    sys.exit(1 if differences else 0)


if __name__ == "__main__":
    main()
