local _, ns = ...

-- What each quest is to this character: done, in the log, available, later (a level, a quest first,
-- reputation, a profession's skill), locked out (gone for good, with the reason) or not for them at all
-- (another race, class or faction, a profession they haven't got). Worked out afresh by Refresh from the
-- game's completed quests and quest log, so a breadcrumb locks the moment you turn in its quest.
--
-- Skipped, and counted as done: a quest you only missed because you'd already gone further.
-- - breadcrumbFor: the quest it points to is done (or a quest that needs it is).
-- - nextInChain: the quest after it is done.
-- - untilDone: it was only there until a quest you've now done.
-- - exclusiveTo: you did the other quest of the pair (only one of them can ever be done), so both count.
--   Except another race's version of a class quest (OtherRacesVersion): not for you, unless you took it.
-- (While the later or other quest is only in your log, this one shows as locked out until it's done.)
--
-- Locked out, from the list's links (QuestieDB's rules): cut off from later stages for good.
-- - maxLevel, maxRep: only up to a level, below a reputation.
-- - parent: only while the parent quest is in your log, and the parent's done.
-- - A quest that needs a locked-out (or skipped) quest first is locked out too: the game never marks a
--   skipped quest done. A needsAll entry also counts as met when one of its own exclusiveTo quests is
--   done (a negative entry means exactly that quest).

local F = ns.F
local Lore = {}
ns.Lore = Lore

local DONE, ACTIVE, AVAILABLE, LATER, LOCKED, HIDDEN = 1, 2, 3, 4, 5, 6
Lore.DONE, Lore.ACTIVE, Lore.AVAILABLE, Lore.LATER, Lore.LOCKED, Lore.HIDDEN = DONE, ACTIVE, AVAILABLE, LATER, LOCKED, HIDDEN
local VISITING = 0
local EMPTY = {}

-- Groups (make_lore.py's GROUPS) in the Lorebound total: not Professions or PvP, which hold quests one
-- character can't all do (one per profession, per craftable item, per battleground faction).
local CLASS_GROUP, PROFESSION_GROUP, OTHER_GROUP = 5, 6, 8
Lore.IN_TOTAL = { [1] = true, [2] = true, [3] = true, [4] = true, [5] = true, [OTHER_GROUP] = true }
local IN_TOTAL = Lore.IN_TOTAL

-- Forever's Skyborne have race IDs past the mask's classic bits: their playable-race bits instead.
local RACE_BIT = { [95] = 32, [96] = 33 }
local FACTION_BITS = { { 0, 2, 3, 6 }, { 1, 4, 5, 7 } } -- classic races' bits: Alliance, Horde

-- Each race's home by race ID: its starting zone and capital (uiMap IDs; Zephras Isle is the Skyborne's).
local HOMES = {
    [1] = { 1429, 1453 }, [2] = { 1411, 1454 }, [3] = { 1426, 1455 }, [4] = { 1438, 1457 },
    [5] = { 1420, 1458 }, [6] = { 1412, 1456 }, [7] = { 1426, 1455 }, [8] = { 1411, 1454 },
    [95] = { 2521 }, [96] = { 2521 },
}
local ANY_HOME = {}
for _, maps in pairs(HOMES) do
    for _, map in ipairs(maps) do ANY_HOME[map] = true end
end

local PROFESSIONS = {
    [164] = "Blacksmithing", [165] = "Leatherworking", [171] = "Alchemy", [182] = "Herbalism",
    [186] = "Mining", [197] = "Tailoring", [202] = "Engineering", [333] = "Enchanting", [393] = "Skinning",
    [129] = "First Aid", [185] = "Cooking", [356] = "Fishing",
}
local PROFESSION_BY_NAME = {}
for id, name in pairs(PROFESSIONS) do PROFESSION_BY_NAME[name] = id end

local STANDINGS = { { 42000, "Exalted" }, { 21000, "Revered" }, { 9000, "Honored" }, { 3000, "Friendly" },
    { 0, "Neutral" }, { -3000, "Unfriendly" }, { -6000, "Hostile" } }

-- Why a quest is locked out or not yet: a code and up to two arguments, made into text only for the
-- rows on screen.
local NEEDS_GONE, TOOK, HOLDING, LEADS, PAST, UNUSED, MAX_LEVEL, MAX_REP, ONLY_WHILE,
    AFTER, WHILE, LEVEL, REP, SKILL, SKIP_LEADS, SKIP_PAST, SKIP_UNTIL =
    1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17

local quests, zones, groups
local skip = {}         -- [questID] = true: left out of the list on purpose, never learned
local byZone = {}       -- [zone] = { questID, ... }
local children = {}     -- [questID] = { quests that need it (needsAll) }
local zoneByName = {}   -- [name] = zone (outdoor zones win, being first)
local learnedRow = {}   -- [questID] = true: learned in game, not from the list
local versionOf = {}    -- [questID] = the first quest of the one race's version it's part of (OtherRacesVersion)
local versionSteps = {} -- [first quest] = the quests of its version
local wantText = {}     -- [questID] = true: its Forever text isn't known (Share.lua asks for it)
local wantRewards = {}  -- [questID] = true: its rewards aren't known (likewise, and Core.lua asks the game)
local wantChoices = {}  -- [questID] = true: its rewards are known but for any choice (shared from players' logs)
local lowerNames        -- [questID] = name in lower case, made on the first search

local me = {}           -- level, raceBit, home ({ [uiMap] = true }), faction (1 Alliance, 2 Horde), classBit, skills
local status = {}
local passed = {}       -- [questID] = true: skipped, counted done, but the game never marked it (see above)
local whyCode, whyA, whyB = {}, {}, {}
local doneCache, reached, active = {}, {}, {}
local justDone = {}     -- turned in this session: the completed flag can lag behind the event
local counts = {}       -- [zone] = { total, done, locked }
local groupCounts = {}  -- [group] = { total, done }
local total = { 0, 0 }
local levelRange = {}   -- [zone] = { low, high }, for the quests this character can have
Lore.fresh = false

------------------------------------------------------------------------------
-- The list
------------------------------------------------------------------------------

local function Faction()
    local name = UnitFactionGroup("player")
    return name == "Alliance" and 1 or name == "Horde" and 2 or nil
end
Lore.Faction = Faction

local function Index(id, row)
    local zone = row[F.zone]
    byZone[zone] = byZone[zone] or {}
    table.insert(byZone[zone], id)
    for _, need in ipairs(row[F.needsAll] or EMPTY) do
        need = math.abs(need)
        children[need] = children[need] or {}
        table.insert(children[need], id)
    end
end

local function Lists(list, id)
    for _, entry in ipairs(list or EMPTY) do
        if math.abs(entry) == id then return true end
    end
    return false
end

-- A class quest of a group only one of which can be done, given in a race's home, starts that race's version:
-- it and the quests after it (nextInChain) while each is a class quest that needs the step before, up to where
-- the steps are shared: reached from another version too, open without the step before (a breadcrumb's target),
-- or not a class quest at all (the warlock's Burning Blade Medallion follows any race's way to it).
local function MarkVersions()
    for id, row in pairs(quests) do
        if row[F.classes] and row[F.exclusiveTo] and ANY_HOME[row[F.map]] then
            local at, before, steps, shared = id, nil, 0, false
            while at and quests[at] and steps < 40 do
                local step = quests[at]
                if before and not (step[F.classes] and (Lists(step[F.needsAny], before) or Lists(step[F.needsAll], before))) then
                    shared = true
                end
                local mark = versionOf[at]
                versionOf[at] = not shared and (mark == nil or mark == id) and id or false
                at, before, steps = step[F.nextInChain], at, steps + 1
            end
        end
    end
    for id, first in pairs(versionOf) do
        if first then
            versionSteps[first] = versionSteps[first] or {}
            table.insert(versionSteps[first], id)
        end
    end
end

local function ZoneNamed(name)
    local zone = zoneByName[name]
    if not zone then
        zones[#zones + 1] = { name, OTHER_GROUP }
        zone = #zones
        zoneByName[name] = zone
    end
    return zone
end

function Lore.Init(data)
    quests, zones, groups = data.quests, data.zones, data.groups
    Lore.listZones = #zones -- the list's own zones; learned ones are added after these
    if Faction() == 2 and data.horde then
        for id, diff in pairs(data.horde) do
            local row = quests[id]
            if row then
                for field, value in pairs(diff) do row[field] = value or nil end
            end
        end
    end
    for _, id in ipairs(data.skip or EMPTY) do skip[id] = true end
    for _, id in ipairs(data.wantText or EMPTY) do wantText[id] = true end
    for _, id in ipairs(data.wantRewards or EMPTY) do wantRewards[id] = true end
    for _, id in ipairs(data.wantChoices or EMPTY) do wantChoices[id] = true end
    for id in pairs(ns.db.rewards or EMPTY) do -- kept from quest windows, but the list has them now
        if not wantRewards[id] and not wantChoices[id] and quests[id] then
            ns.db.rewards[id], ns.db.rewardsShared[id] = nil, nil
        end
    end
    data.horde, data.skip, data.wantText, data.wantRewards, data.wantChoices = nil, nil, nil, nil, nil
    for i, zone in ipairs(zones) do
        if not zoneByName[zone[1]] then zoneByName[zone[1]] = i end
    end
    for id, row in pairs(quests) do Index(id, row) end
    MarkVersions()
    local learned = ns.db.learned
    for id, entry in pairs(learned) do
        if type(entry) ~= "table" or type(entry[1]) ~= "string" or type(entry[2]) ~= "string" then
            learned[id] = nil -- damaged: a learned quest needs its name and zone
        elseif quests[id] or skip[id] then
            learned[id] = nil -- met before the list was loaded, and the list has it (or leaves it out)
            ns.db.shared[id] = nil
        else
            Lore.AddLearned(id, entry)
        end
    end
end

-- Left out of the list on purpose (repeatable, seasonal, blacklisted): never learned in game.
function Lore.IsLeftOut(id)
    return skip[id] == true
end

-- A quest met in game that the list hasn't got: counted in its zone (a new zone if need be) from now on.
-- entry = { name, zone, level, factions seen (1 Alliance, 2 Horde, 3 both) }.
function Lore.AddLearned(id, entry)
    if not quests or skip[id] then return end
    local row = quests[id]
    if row and not learnedRow[id] then return end
    local name, zoneName, level, seen = entry[1], entry[2], entry[3], entry[4]
    local faction = (seen == 1 or seen == 2) and seen or nil
    local zone = ZoneNamed(zoneName)
    -- Shared by every character: a class quest only for its class, a profession quest only for the
    -- characters that met it.
    local group = zones[zone][2]
    local class = group == CLASS_GROUP and entry.i and entry.i.class
    local mine = group == PROFESSION_GROUP or nil
    if row then
        row[F.name], row[F.level], row[F.faction] = name, level, faction
        row[F.classes] = class and 2 ^ (class - 1) or nil
        row[F.mine] = mine
        if row[F.zone] ~= zone then -- first met elsewhere: the quest log has named its zone since
            local list = byZone[row[F.zone]]
            for i = #list, 1, -1 do
                if list[i] == id then table.remove(list, i) end
            end
            levelRange[row[F.zone]] = nil
            row[F.zone] = zone
            byZone[zone] = byZone[zone] or {}
            table.insert(byZone[zone], id)
        end
    else
        row = { zone, level, nil, name }
        row[F.faction] = faction
        row[F.classes] = class and 2 ^ (class - 1) or nil
        row[F.mine] = mine
        quests[id] = row
        learnedRow[id] = true
        Index(id, row)
    end
    levelRange[zone] = nil
    if lowerNames then lowerNames[id] = name and name:lower() end
    Lore.fresh = false
end

------------------------------------------------------------------------------
-- This character
------------------------------------------------------------------------------

local function Has(mask, bit)
    return math.floor(mask / 2 ^ bit) % 2 == 1
end

local function AddProfessions(skills, ...)
    for i = 1, select("#", ...) do
        local index = select(i, ...)
        if index then
            local _, _, rank, _, _, _, line = GetProfessionInfo(index)
            if line then skills[line] = rank or 0 end
        end
    end
end

-- Each profession's skill: the professions list, and the skill list too where the game has one
-- (First Aid isn't always among the professions).
local function Skills()
    local skills, any = {}, false
    if GetProfessions and GetProfessionInfo then
        AddProfessions(skills, GetProfessions())
        any = true
    end
    if GetNumSkillLines and GetSkillLineInfo then
        for i = 1, GetNumSkillLines() or 0 do
            local name, header, _, rank = GetSkillLineInfo(i)
            local line = not header and PROFESSION_BY_NAME[name]
            if line and not skills[line] then skills[line] = rank or 0 end
        end
        any = true
    end
    return any and skills or nil
end

local function Facts()
    me.level = UnitLevel("player") or 1
    local _, _, raceID = UnitRace("player")
    me.raceBit = raceID and (raceID <= 31 and raceID - 1 or RACE_BIT[raceID]) or nil
    me.home = nil
    for _, map in ipairs(HOMES[raceID] or EMPTY) do
        me.home = me.home or {}
        me.home[map] = true
    end
    me.faction = Faction()
    local _, _, classID = UnitClass("player")
    me.classBit = classID and classID - 1 or nil
    me.skills = Skills()
end

local function RaceOK(mask)
    if not mask or not me.raceBit then return true end
    if Has(mask, me.raceBit) then return true end
    if me.raceBit < 8 or not me.faction then return false end
    -- A race the mask doesn't name: it counts when the mask takes every classic race of its faction.
    for _, bit in ipairs(FACTION_BITS[me.faction]) do
        if not Has(mask, bit) then return false end
    end
    return true
end

-- Open to this character by race, class and side alone.
local function ForMe(row)
    if row[F.races] and not RaceOK(row[F.races]) then return false end
    if row[F.classes] and me.classBit and not Has(row[F.classes], me.classBit) then return false end
    local faction = row[F.faction]
    return not (faction and me.faction and faction ~= me.faction)
end

-- Your standing with a faction and its name; nil standing when you haven't met it.
local function Standing(factionID)
    if C_Reputation and C_Reputation.GetFactionDataByID then
        local info = C_Reputation.GetFactionDataByID(factionID)
        if info then return info.currentStanding, info.name end
        return nil
    end
    if GetFactionInfoByID then
        local name, _, _, _, _, value = GetFactionInfoByID(factionID)
        return value, name
    end
end

local function StandingName(value)
    for _, step in ipairs(STANDINGS) do
        if value >= step[1] then return step[2] end
    end
    return "Hated"
end

local function IsDone(id)
    local done = doneCache[id]
    if done == nil then
        done = justDone[id] or C_QuestLog.IsQuestFlaggedCompleted(id) or false
        doneCache[id] = done
    end
    return done
end

local function ReadLog()
    wipe(active)
    local entries = C_QuestLog.GetNumQuestLogEntries() or 0
    for i = 1, entries do
        local info = C_QuestLog.GetInfo(i)
        if info and not info.isHeader and info.questID then active[info.questID] = true end
    end
end

------------------------------------------------------------------------------
-- Status
------------------------------------------------------------------------------

local function Name(id)
    local row = quests[id]
    return row and row[F.name] or ("quest " .. id)
end

-- Past a quest: it's done, or a quest that needs it done is.
local function Reached(id, depth)
    if IsDone(id) then return true end
    local known = reached[id]
    if known ~= nil then return known end
    reached[id] = false -- also stops a loop in the links
    if depth < 30 then
        for _, kid in ipairs(children[id] or EMPTY) do
            if Reached(kid, depth + 1) then
                reached[id] = true
                return true
            end
        end
    end
    return false
end

local Status

-- Another race's version of a class quest (MarkVersions): Call of Earth in Durotar, in Mulgore and on Zephras
-- Isle, only one of which can be done. Left out, not counted done, when the version starts in another race's home
-- and the group has one in yours that's open to you, unless you took it.
-- A quest of the list outside every race's version, done or in your log (a version's own steps are Took's to judge;
-- Call of Earth's second step needs either race's first).
local function Begun(list)
    for _, need in ipairs(list or EMPTY) do
        need = math.abs(need)
        if not versionOf[need] and (IsDone(need) or active[need]) then return true end
    end
    return false
end

-- Whether you took a version: its first quest done or in your log. Except that the game marks the other quest of
-- the pair done too (a Tauren who finishes Kranal Fiss's Call of Fire has the Skyborne's first one marked done):
-- with both marked, only a later step of the version done or in your log says you took it.
local function Took(first)
    if active[first] then return true end
    if not IsDone(first) then return false end
    local pairDone = false
    for _, other in ipairs(quests[first][F.exclusiveTo] or EMPTY) do
        if IsDone(other) then pairDone = true end
    end
    if not pairDone then return true end
    for _, step in ipairs(versionSteps[first] or EMPTY) do
        if step ~= first and (IsDone(step) or active[step]) then return true end
    end
    return false
end

local function OtherRacesVersion(id, row)
    local first = versionOf[id]
    if not first or not me.home or me.home[row[F.map]] then return false end
    local firstRow = quests[first]
    if me.home[firstRow[F.map]] or Took(first) then return false end
    -- On your way to it some other way (a quest it needs is done or in your log): yours too.
    if Begun(row[F.needsAny]) or Begun(row[F.needsAll]) then return false end
    -- The group has a version that's yours: in your home and open to you, or one you've done or picked up.
    for _, other in ipairs(firstRow[F.exclusiveTo]) do
        local otherRow = quests[other]
        if otherRow and ((me.home[otherRow[F.map]] and ForMe(otherRow)) or IsDone(other) or active[other]) then
            return true
        end
    end
    return false
end

-- Not to be had: hidden, locked out, or skipped (the game never marked it done, so what needs it can't
-- follow).
local function Settled(id)
    local state = Status(id)
    if state == DONE and passed[id] then return LOCKED end
    return state
end

local function Gone(state)
    return state == HIDDEN or state == LOCKED
end

-- A needsAll entry: "met", "open" (still to do), "locked" or "hidden", and the quest that decides it.
local function Entry(need)
    local id = math.abs(need)
    if IsDone(id) then return "met", id end
    local partners = need > 0 and quests[id] and quests[id][F.exclusiveTo] or EMPTY
    for _, other in ipairs(partners) do
        if IsDone(other) then return "met", other end
    end
    local state = Settled(id)
    if not Gone(state) then return "open", id end
    for _, other in ipairs(partners) do
        local otherState = Settled(other)
        if not Gone(otherState) then return "open", other end
        if otherState == LOCKED then state = LOCKED end
    end
    return state == LOCKED and "locked" or "hidden", id
end

local followers -- [questID] = { quests that need it (needsAll or needsAny) }, made the first time OnTheWay asks

local function AddFollowers(id, list)
    for _, need in ipairs(list or EMPTY) do
        need = math.abs(need)
        followers[need] = followers[need] or {}
        table.insert(followers[need], id)
    end
end

local function Followers(id)
    if not followers then
        followers = {}
        for other, row in pairs(quests) do
            AddFollowers(other, row[F.needsAll])
            AddFollowers(other, row[F.needsAny])
        end
    end
    return followers[id] or EMPTY
end

-- Whether a mask names a classic race of your side.
local function OnMySide(mask)
    for _, bit in ipairs(FACTION_BITS[me.faction]) do
        if Has(mask, bit) then return true end
    end
    return false
end

-- Whether quest id is your way on from need: not when your race has its own step after it (the Skyborne hunter's
-- Training the Beast, not the Night Elf's Taming the Beast), nor when it splits into several races' own steps
-- (Furen's Armor leads to a Human's, a Night Elf's and a Dwarf's or Gnome's): which is yours isn't known.
local function WayOn(need, id)
    local branches = 0
    for _, after in ipairs(Followers(need)) do
        local races = quests[after] and quests[after][F.races]
        if races then
            if Has(races, me.raceBit) then
                if after ~= id then return false end
            elseif not RaceOK(races) and OnMySide(races) then
                branches = branches + 1
            end
        end
    end
    return branches <= 1
end

-- A class quest in the list, done or in your log, that leads on to quest id (a starting zone's first quest, which
-- leads to every race's own level 1 class letter, isn't one).
local function Reaching(list, id)
    for _, need in ipairs(list or EMPTY) do
        need = math.abs(need)
        if quests[need] and quests[need][F.classes] and (IsDone(need) or active[need]) and WayOn(need, id) then
            return true
        end
    end
    return false
end

-- A class quest the list gives only classic races (the Tauren's Trial of the Sea Lion), for one of Forever's races
-- of that class who is on its way: a class quest it needs done or in the log. Never when Forever gives this race
-- its own version (an exclusive partner naming the race: the Skyborne's Great Windborne Cat Spirit), and a quest
-- whose start isn't reached stays hidden (the Tauren's Moonglade trips, which Forever replaces for the Skyborne).
local function OnTheWay(id, row)
    if not me.raceBit or me.raceBit < 8 or not me.faction or not me.classBit then return false end
    if not row[F.classes] or not Has(row[F.classes], me.classBit) then return false end
    if not OnMySide(row[F.races]) then return false end
    for _, other in ipairs(row[F.exclusiveTo] or EMPTY) do
        local races = quests[other] and quests[other][F.races]
        if races and Has(races, me.raceBit) then return false end
    end
    return Reaching(row[F.needsAll], id) or Reaching(row[F.needsAny], id)
end

-- The status, and why (a code and its arguments) for locked out and later.
local function Work(id, row)
    if active[id] then return ACTIVE end -- in your log: yours, whatever the list says
    if row[F.races] and not RaceOK(row[F.races]) and not OnTheWay(id, row) then return HIDDEN end
    -- A learned profession quest: only for characters that have met it (the skill it needs is unknown).
    if row[F.mine] and not ns.charDB.met[id] then return HIDDEN end
    if row[F.classes] and me.classBit and not Has(row[F.classes], me.classBit) then return HIDDEN end
    local faction = row[F.faction]
    if faction and me.faction and faction ~= me.faction then return HIDDEN end
    local skill, short = row[F.skill], false
    if skill and me.skills and PROFESSIONS[skill[1]] then
        local rank = me.skills[skill[1]]
        if not rank then return HIDDEN end
        short = rank < (skill[2] or 0)
    end
    if OtherRacesVersion(id, row) then return HIDDEN end

    -- Prerequisites that rule it out, and the first one still to do.
    local waitFor
    for _, need in ipairs(row[F.needsAll] or EMPTY) do
        local state, which = Entry(need)
        if state == "hidden" then return HIDDEN end
        if state == "locked" then return LOCKED, NEEDS_GONE, which end
        if state == "open" and not waitFor then waitFor = which end
    end
    local any = row[F.needsAny]
    if any then
        local met, open, locked = false, nil, nil
        for _, need in ipairs(any) do
            if IsDone(need) then
                met = true
                break
            end
            local needState = Settled(need)
            if needState == LOCKED then
                locked = locked or need
            elseif needState ~= HIDDEN then
                open = open or need
            end
        end
        if not met then
            if not open then
                if not locked then return HIDDEN end
                return LOCKED, NEEDS_GONE, locked
            end
            waitFor = waitFor or open
        end
    end

    -- Shut off by what you've done (or hold).
    local exclusive = row[F.exclusiveTo] or EMPTY
    for _, other in ipairs(exclusive) do
        if IsDone(other) then return DONE, TOOK, other end -- the pair is done: this one counts too
    end
    for _, other in ipairs(exclusive) do
        if active[other] then return LOCKED, HOLDING, other end
    end
    -- Gone past it: counted done once the later quest is done, locked out while it's only in the log.
    local skip, code, why = false, nil, nil
    local target = row[F.breadcrumbFor]
    if target then
        if Reached(target, 0) then
            skip, code, why = true, SKIP_LEADS, target
        elseif active[target] then
            return LOCKED, LEADS, target
        end
    end
    local after = row[F.nextInChain]
    if not skip and after then
        if IsDone(after) then
            skip, code, why = true, SKIP_PAST, after
        elseif active[after] then
            return LOCKED, PAST, after
        end
    end
    local untilDone = row[F.untilDone]
    if not skip and untilDone and IsDone(untilDone) then skip, code, why = true, SKIP_UNTIL, untilDone end
    if skip then return DONE, code, why end
    local maxLevel = row[F.maxLevel]
    if maxLevel and me.level > maxLevel then return LOCKED, MAX_LEVEL, maxLevel end
    local maxRep = row[F.maxRep]
    if maxRep then
        local standing = Standing(maxRep[1])
        if standing and standing >= maxRep[2] then return LOCKED, MAX_REP, maxRep[1], maxRep[2] end
    end
    local parent = row[F.parent]
    if parent then
        local parentState = Status(parent)
        if parentState == HIDDEN then return HIDDEN end
        if parentState == DONE or parentState == LOCKED then return LOCKED, ONLY_WHILE, parent end
    end

    -- Not yet.
    if waitFor then return LATER, AFTER, waitFor end
    if parent and not active[parent] then return LATER, WHILE, parent end
    local minLevel = row[F.minLevel]
    if minLevel and me.level < minLevel then return LATER, LEVEL, minLevel end
    local minRep = row[F.minRep]
    if minRep then
        local standing = Standing(minRep[1])
        if not standing or standing < minRep[2] then return LATER, REP, minRep[1], minRep[2] end
    end
    if short then return LATER, SKILL, skill[1], skill[2] end
    return AVAILABLE
end

Status = function(id)
    local known = status[id]
    if known then
        if known == VISITING then return AVAILABLE end -- a loop in the links: don't let it lock anything
        return known
    end
    local row = quests[id]
    if not row then return HIDDEN end
    if IsDone(id) then
        -- Marked done by the game for another race's version you didn't take (Took): not yours either way.
        local state = versionOf[id] and OtherRacesVersion(id, row) and HIDDEN or DONE
        status[id] = state
        return state
    end
    status[id] = VISITING
    local state, code, a, b = Work(id, row)
    status[id] = state
    if state == DONE then passed[id] = true end
    if code then whyCode[id], whyA[id], whyB[id] = code, a, b end
    return state
end

local function FactionName(factionID)
    local _, name = Standing(factionID)
    return name or "a faction you haven't met"
end

-- Each reason's words: "%s" is the quest it names, apart from the levels, standings and skills below.
local WHY = {
    [NEEDS_GONE] = "Needs %s, which you can't get any more.",
    [TOOK] = "You did %s instead (only one of the pair can be done). Counted as done.",
    [HOLDING] = "You have %s in your log instead: abandon it to get this one back.",
    [LEADS] = "It leads to %s, which you've picked up: counted done once you finish that.",
    [PAST] = "You're past it: %s is in your log. Counted done once you finish that.",
    [ONLY_WHILE] = "Only while %s is in your log.",
    [AFTER] = "After %s",
    [WHILE] = "While %s is in your log",
    [SKIP_LEADS] = "Skipped: you went straight to %s. Counted as done.",
    [SKIP_PAST] = "Skipped: you've done %s, which comes after it. Counted as done.",
    [SKIP_UNTIL] = "No longer needed: %s is done. Counted as done.",
    [MAX_LEVEL] = "Only up to level %d.",
    [LEVEL] = "Level %d",
    [MAX_REP] = "Only below %s with %s.",
    [REP] = "%s with %s",
    [SKILL] = "%s %d",
}

local function Why(code, a, b)
    local words = WHY[code]
    if not words then return nil end
    if code == MAX_LEVEL or code == LEVEL then return words:format(a) end
    if code == MAX_REP or code == REP then return words:format(StandingName(b), FactionName(a)) end
    if code == SKILL then return words:format(PROFESSIONS[a] or "Skill", b or 0) end
    return words:format(Name(a))
end

------------------------------------------------------------------------------
-- Counting
------------------------------------------------------------------------------

function Lore.Refresh()
    if not quests then return end
    wipe(status)
    wipe(passed)
    wipe(whyCode)
    wipe(whyA)
    wipe(whyB)
    wipe(doneCache)
    wipe(reached)
    wipe(levelRange)
    Facts()
    ReadLog()
    for zone in ipairs(zones) do
        local tally = counts[zone]
        if tally then
            tally[1], tally[2], tally[3] = 0, 0, 0
        else
            counts[zone] = { 0, 0, 0 }
        end
    end
    for id, row in pairs(quests) do
        local state = Status(id)
        local tally = counts[row[F.zone]]
        if state == DONE then
            tally[1], tally[2] = tally[1] + 1, tally[2] + 1
        elseif state == LOCKED then
            tally[3] = tally[3] + 1
        elseif state ~= HIDDEN then
            tally[1] = tally[1] + 1
        end
    end
    for group = 1, math.max(#groups, OTHER_GROUP) do
        local groupTally = groupCounts[group]
        if groupTally then groupTally[1], groupTally[2] = 0, 0 else groupCounts[group] = { 0, 0 } end
    end
    total[1], total[2] = 0, 0
    for zone, tally in pairs(counts) do
        local group = zones[zone][2]
        local groupTally = groupCounts[group]
        groupTally[1], groupTally[2] = groupTally[1] + tally[1], groupTally[2] + tally[2]
        if IN_TOTAL[group] then total[1], total[2] = total[1] + tally[1], total[2] + tally[2] end
    end
    Lore.fresh = true
end

-- Quest turned in: counted done now (the game's flag can lag), and what changed for the toast.
function Lore.TurnedIn(id)
    justDone[id] = true
    local row = quests and quests[id]
    Lore.Refresh()
    if not row then return nil end
    local zone = row[F.zone]
    local group = zones[zone][2]
    local tally, groupTally = counts[zone], groupCounts[group]
    return {
        id = id, zone = zone, group = group, counted = IN_TOTAL[group],
        zoneDone = tally[2], zoneTotal = tally[1], groupDone = groupTally[2], groupTotal = groupTally[1],
        allDone = total[2], allTotal = total[1],
    }
end

-- Done, total and locked out for a zone.
function Lore.Count(zone)
    local tally = counts[zone]
    if not tally then return 0, 0, 0 end
    return tally[2], tally[1], tally[3]
end

function Lore.GroupCount(group)
    local groupTally = groupCounts[group]
    if not groupTally then return 0, 0 end
    return groupTally[2], groupTally[1]
end

function Lore.TotalCount()
    return total[2], total[1]
end

-- The status and, for locked out and later, why (as text).
function Lore.StatusOf(id)
    local state = Status(id)
    local code = whyCode[id]
    if not code then return state end
    return state, Why(code, whyA[id], whyB[id])
end

function Lore.Row(id)
    return quests and quests[id]
end

function Lore.Name(id)
    return quests and Name(id)
end

-- The list's quests in ID order (not ones learned in game): the order a progress code's statuses follow.
local listIds
function Lore.ListIds()
    if not listIds then
        listIds = {}
        for id in pairs(quests) do
            if not learnedRow[id] then listIds[#listIds + 1] = id end
        end
        table.sort(listIds)
    end
    return listIds
end

-- Why a quest is locked out, later or skipped, as the code and arguments Why() reads (for the export).
function Lore.Reason(id)
    Status(id)
    return whyCode[id], whyA[id], whyB[id]
end

-- Counted done without the game marking it: passed by on the way to a later quest.
function Lore.IsPassed(id)
    Status(id)
    return passed[id] == true
end

local chainSteps -- [first quest] = its chain's quests in step order, made the first time it's asked

-- A chain's quests (by its first quest, the row's chain field), in step order, whatever their zones.
function Lore.ChainSteps(first)
    if not chainSteps then
        chainSteps = {}
        for id, row in pairs(quests) do
            local chain = row[F.chain]
            if chain then
                local list = chainSteps[chain[1]] or {}
                chainSteps[chain[1]] = list
                list[#list + 1] = id
            end
        end
        for _, list in pairs(chainSteps) do
            table.sort(list, function(a, b) return quests[a][F.chain][2] < quests[b][F.chain][2] end)
        end
    end
    return chainSteps[first] or EMPTY
end

-- A chain's steps as this character sees them, in order: the ones it can't have left out, and where the chain starts
-- with another race's version of a quest (Call of Air from Orgrimmar, for a Tauren), its own version of that quest
-- (Thunder Bluff's, which the list keeps outside the chain) in its place.
function Lore.ChainFor(first)
    local all, steps = Lore.ChainSteps(first), {}
    for _, id in ipairs(all) do
        if Status(id) ~= HIDDEN then steps[#steps + 1] = id end
    end
    local head = all[1]
    if head and versionOf[head] and Status(head) == HIDDEN then -- another race's version of the first step
        local own, inChain = nil, {}
        for _, id in ipairs(all) do inChain[id] = true end
        for _, other in ipairs(quests[head][F.exclusiveTo] or EMPTY) do
            local row = quests[other]
            local state = row and not row[F.chain] and not inChain[other] and Status(other)
            if state and state ~= HIDDEN and (not own or state == DONE) then own = other end
        end
        if own then table.insert(steps, 1, own) end
    end
    return steps
end

-- The chain a quest belongs to (its first quest), also for a race's own version of a chain's first step.
function Lore.ChainOf(id)
    local row = quests[id]
    if not row then return nil end
    if row[F.chain] then return row[F.chain][1] end
    for _, other in ipairs(row[F.exclusiveTo] or EMPTY) do
        local chain = quests[other] and quests[other][F.chain]
        if chain and chain[1] == other then
            for _, step in ipairs(Lore.ChainFor(other)) do
                if step == id then return other end -- only a chain it's shown in (a race's own first step)
            end
        end
    end
    return nil
end

-- Whether the list lacks this quest's Forever text (changed or new in Forever, or learned in game).
function Lore.WantsText(id)
    return wantText[id] or learnedRow[id] or false
end

-- Whether the list lacks this quest's rewards (or it's learned in game).
function Lore.WantsRewards(id)
    return wantRewards[id] or wantChoices[id] or learnedRow[id] or false
end

-- Whether the list knows none of this quest's rewards (or it's learned in game): worth asking the game for.
function Lore.LacksRewards(id)
    return wantRewards[id] or learnedRow[id] or false
end

function Lore.IsLearned(id)
    return learnedRow[id] == true
end

-- A zone's name, group, map (uiMapID) and, for a dungeon or raid, its journal painting (a file ID).
function Lore.Zone(zone)
    local z = zones[zone]
    if not z then return nil end
    return z[1], z[2], z[3], z[4]
end

function Lore.Zones()
    return zones
end

function Lore.Groups()
    return groups
end

function Lore.ZoneQuests(zone)
    return byZone[zone] or EMPTY
end

-- The levels most of a zone's quests are for, among those this character can have (the middle 80%, so
-- a stray quest doesn't stretch it).
function Lore.ZoneLevels(zone)
    local range = levelRange[zone]
    if range then return range[1], range[2] end
    local levels = {}
    for _, id in ipairs(byZone[zone] or EMPTY) do
        local level = quests[id][F.level]
        if level and level > 0 and Status(id) ~= HIDDEN then levels[#levels + 1] = level end
    end
    if #levels == 0 then
        levelRange[zone] = EMPTY
        return nil
    end
    table.sort(levels)
    local low = levels[math.max(1, math.ceil(#levels * 0.1))]
    local high = levels[math.max(1, math.ceil(#levels * 0.9))]
    levelRange[zone] = { low, high }
    return low, high
end

-- The zone whose name starts with the text (or holds it), outdoor zones first.
function Lore.FindZone(text)
    if not zones then return nil end
    text = text:lower()
    local holds
    for i, zone in ipairs(zones) do
        local name = zone[1]:lower()
        if name == text or name:sub(1, #text) == text then return i end
        if not holds and name:find(text, 1, true) then holds = i end
    end
    return holds
end

-- Every quest this character can have whose name holds the text, for the journal's search.
function Lore.Search(text, found)
    wipe(found)
    if not quests or #text < 3 then return found end
    if not lowerNames then
        lowerNames = {}
        for id, row in pairs(quests) do lowerNames[id] = row[F.name] and row[F.name]:lower() end
    end
    text = text:lower()
    for id, name in pairs(lowerNames) do
        if name:find(text, 1, true) and Status(id) ~= HIDDEN then found[#found + 1] = id end
    end
    return found
end
