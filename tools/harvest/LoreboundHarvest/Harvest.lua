-- Lorebound Harvest: asks the game server for every listed quest's rewards (C_QuestLog.RequestLoadQuestByID, then
-- the quest log's reward calls by quest ID, as ForeverDungeonJournal reads them) and keeps the raw answers in
-- LoreboundHarvestDB for tools/harvest/import_harvest.py. One quest at a time, never in combat; it carries on where
-- it stopped after a /reload. Not released: tools/harvest/make_harvest.py installs it, and removes it after.
--   /lbh start    ask every quest not answered yet
--   /lbh stop     stop (the answers so far are kept: /reload writes them to disk)
--   /lbh again    forget the answers and start over
--   /lbh          how far it is

local TIMEOUT, GAP = 3, 0.05 -- seconds: a quest the server never answers for; between quests

local frame = CreateFrame("Frame")
local ids = LoreboundHarvestQuests or {}
local index, waiting, running, started = 0, nil, false, 0
local Next

local function Say(text)
    print("|cff6fd3ffLorebound Harvest|r: " .. text)
end

local function Counts()
    local answered, loaded = 0, 0
    for _, got in pairs(LoreboundHarvestDB.quests) do
        answered = answered + 1
        if got.loaded then loaded = loaded + 1 end
    end
    return answered, loaded
end

-- A reward list, or false when an entry has no item ID (not loaded), or nil when the call isn't there.
local function Items(countOf, infoOf, id)
    if type(countOf) ~= "function" or type(infoOf) ~= "function" then return nil end
    local ok, count = pcall(countOf, id)
    if not ok or type(count) ~= "number" then return nil end
    local list = {}
    for i = 1, count do
        local okItem, _, _, amount, _, _, item = pcall(infoOf, i, id)
        if not okItem or type(item) ~= "number" then return false end
        list[#list + 1] = { item, type(amount) == "number" and amount or 1 }
    end
    return list
end

local function Number(fn, id)
    if type(fn) ~= "function" then return nil end
    local ok, value = pcall(fn, id)
    return ok and type(value) == "number" and value or nil
end

local function Keep(id, loaded)
    local title = C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(id)
    LoreboundHarvestDB.quests[id] = {
        loaded = loaded or nil,
        title = type(title) == "string" and title or nil,
        ch = Items(GetNumQuestLogChoices, GetQuestLogChoiceInfo, id),
        it = Items(GetNumQuestLogRewards, GetQuestLogRewardInfo, id),
        m = Number(GetQuestLogRewardMoney, id),
        xp = Number(GetQuestLogRewardXP, id),
        sp = Number(GetNumQuestLogRewardSpells, id),
    }
end

local function Answered(id, loaded)
    if id ~= waiting then return end
    waiting = nil
    Keep(id, loaded)
    if index % 250 == 0 then Say(("%d of %d asked."):format(index, #ids)) end
    C_Timer.After(GAP, Next)
end

function Next()
    if not running or waiting then return end
    if InCombatLockdown() then
        frame:RegisterEvent("PLAYER_REGEN_ENABLED")
        return
    end
    local id
    repeat
        index = index + 1
        id = ids[index]
    until not id or not LoreboundHarvestDB.quests[id] or not LoreboundHarvestDB.quests[id].loaded
    if not id then
        running = false
        frame:UnregisterEvent("QUEST_DATA_LOAD_RESULT")
        local answered, loaded = Counts()
        Say(("done in %d s: %d quests answered, %d loaded. Type /reload to save them to disk.")
            :format(math.floor(GetTime() - started), answered, loaded))
        return
    end
    waiting = id
    if not pcall(C_QuestLog.RequestLoadQuestByID, id) then return Answered(id, false) end
    C_Timer.After(TIMEOUT, function()
        if waiting == id then Answered(id, false) end
    end)
end

frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(_, event, arg1, arg2)
    if event == "ADDON_LOADED" then
        if arg1 ~= "LoreboundHarvest" then return end
        frame:UnregisterEvent("ADDON_LOADED")
        LoreboundHarvestDB = type(LoreboundHarvestDB) == "table" and LoreboundHarvestDB or {}
        LoreboundHarvestDB.quests = LoreboundHarvestDB.quests or {}
    elseif event == "QUEST_DATA_LOAD_RESULT" then
        Answered(arg1, arg2 ~= false)
    elseif event == "PLAYER_REGEN_ENABLED" then
        frame:UnregisterEvent("PLAYER_REGEN_ENABLED")
        Next()
    end
end)

SLASH_LOREBOUNDHARVEST1 = "/lbh"
SlashCmdList.LOREBOUNDHARVEST = function(text)
    text = strtrim(text or ""):lower()
    if text == "start" or text == "again" then
        if not (C_QuestLog and C_QuestLog.RequestLoadQuestByID) then return Say("this client can't ask for quest data.") end
        if text == "again" then wipe(LoreboundHarvestDB.quests) end
        local _, race = UnitRace("player")
        local _, class = UnitClass("player")
        LoreboundHarvestDB.player = { level = UnitLevel("player"), cap = GetMaxPlayerLevel and GetMaxPlayerLevel(),
            race = race, class = class, faction = UnitFactionGroup("player"), locale = GetLocale(),
            build = select(2, GetBuildInfo()), when = time() }
        index, running, started = 0, true, GetTime()
        frame:RegisterEvent("QUEST_DATA_LOAD_RESULT")
        Say(("asking for %d quests, one at a time (about %d minutes). Stay out of combat; /lbh stop stops.")
            :format(#ids, math.ceil(#ids * 0.15 / 60)))
        Next()
    elseif text == "stop" then
        running = false
        Say("stopped. /reload saves what's answered; /lbh start carries on.")
    else
        local answered, loaded = Counts()
        Say(("%d of %d quests answered (%d loaded)%s."):format(answered, #ids, loaded, running and ", asking" or ""))
    end
end
