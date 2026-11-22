local ADDON, ns = ...

-- Lorebound: every zone's quests as rings to close. Core keeps the saved settings, loads the quest list
-- (the load-on-demand Lorebound_Data) when something needs it, keeps what the quest windows show (each
-- quest's text, and quests the list hasn't got, learned as you meet them) and turns quest events into
-- toasts. Nothing here touches Blizzard's frames: the journal and the toasts are our own frames on
-- UIParent, and quests are only ever read through the game's API.

-- Quest row fields, as _tools/make_lore.py writes them.
ns.F = {
    zone = 1, level = 2, minLevel = 3, name = 4, objective = 5, starter = 6, starterKind = 7, races = 8,
    classes = 9, needsAll = 10, needsAny = 11, exclusiveTo = 12, nextInChain = 13, breadcrumbFor = 14,
    parent = 15, skill = 16, minRep = 17, maxRep = 18, maxLevel = 19, untilDone = 20, faction = 21,
    finisher = 22, map = 23, x = 24, y = 25,
    mine = 26, -- not from the list: a learned profession quest, only for characters that met it
    chain = 27, -- { first quest, this one's step, steps in all } for a quest in a chain
}

ns.defaults = {
    point = { "CENTER", "CENTER", 0, 0 },
    toasts = true,       -- a toast with the zone's ring for each quest turned in
    sound = true,        -- a fanfare when a ring closes
    showLocked = false,  -- list the quests you're locked out of
    filter = "todo",     -- the quest list: "todo", "done" or "all"
    collapsed = {},      -- [group] = true: folded in the zone list
    pinned = {},         -- [zone name] = true: pinned to the top of the zone list and the overview
    size = { 980, 640 }, -- the journal's width and height (its resize grip)
    scale = 1,           -- the journal's scale (the grip with Shift held)
    text = {},           -- [questID] = { description, objective, reward }: what the quest windows showed
    learned = {},        -- [questID] = { name, zone, level, factions seen, i = { giver, giverName, map, x, y,
                         --   ender, enderName, before, class } }: quests the list hasn't got, met in game
    shared = {},         -- [questID] = true: learned quests already shared (Share.lua)
}
local CHAR_DEFAULTS = {
    days = {},           -- ["2026-11-21"] = quests turned in that day (the last 30 days)
    badges = {},         -- [zone name, "group:N" or "seal"] = when its badge was earned (Badge.lua)
    met = {},            -- [questID] = true: learned quests this character has met
    turned = {},         -- [questID] = when it was turned in (since Lorebound was installed)
}

local function CopyDefaults(defaults, saved)
    for key, value in pairs(defaults) do
        if type(value) == "table" then
            if type(saved[key]) ~= "table" then saved[key] = {} end
            CopyDefaults(value, saved[key])
        elseif saved[key] == nil then
            saved[key] = value
        end
    end
    return saved
end

------------------------------------------------------------------------------
-- Chat, never in combat (printing in combat taints the chat history)
------------------------------------------------------------------------------

local waiting = {}

-- Whether Forever's gamepad UI is on.
function ns.GamepadUI()
    local check = InputUtil and InputUtil.IsGamepadUIEnabled
    if not check then return false end
    local ok, on = pcall(check) -- no closure: the badge inspector asks every frame
    return ok and on and true or false
end

function ns.Say(text)
    if InCombatLockdown() then
        waiting[#waiting + 1] = text
        ns.events:RegisterEvent("PLAYER_REGEN_ENABLED")
        return
    end
    DEFAULT_CHAT_FRAME:AddMessage("|cff6fd3ffLorebound|r: " .. text)
end

-- A map pin link in chat for a quest giver. Clicking it runs Blizzard's own handler, which sets the
-- waypoint: addon code setting the waypoint itself would taint the world map.
function ns.ShowGiver(name, mapID, x, y)
    if not (mapID and x and y) then return end
    local where = C_Map.GetMapInfo(mapID)
    where = where and where.name or "?"
    if C_Map.CanSetUserWaypointOnMap and not C_Map.CanSetUserWaypointOnMap(mapID) then
        ns.Say(("%s: %s %.1f, %.1f"):format(name or "Quest giver", where, x, y))
        return
    end
    local link = ("|cffffff00|Hworldmap:%d:%d:%d|h[%s]|h|r"):format(mapID, math.floor(x * 100 + 0.5),
        math.floor(y * 100 + 0.5), MAP_PIN_HYPERLINK or "Map Pin")
    ns.Say(("%s, %s %.1f, %.1f: %s"):format(name or "Quest giver", where, x, y, link))
end

------------------------------------------------------------------------------
-- The quest list, loaded once something needs it
------------------------------------------------------------------------------

-- The list, or nil when Lorebound_Data can't load (said once).
-- The quest pages' text (Lorebound_Text, load on demand): LoreboundText[id], or nil when it's not there.
function ns.LoadText()
    if ns.text ~= nil then return ns.text or nil end
    local load = C_AddOns and C_AddOns.LoadAddOn or LoadAddOn
    if load then pcall(load, "Lorebound_Text") end
    ns.text = type(_G.LoreboundText) == "table" and _G.LoreboundText or false
    _G.LoreboundText = nil
    return ns.text or nil
end

function ns.LoadData()
    if ns.data ~= nil then return ns.data or nil end
    local load = C_AddOns and C_AddOns.LoadAddOn or LoadAddOn
    if load then pcall(load, "Lorebound_Data") end
    local data = _G.LoreboundData
    _G.LoreboundData = nil
    if type(data) ~= "table" then
        ns.data = false
        ns.Say("Lorebound_Data is missing or turned off in the AddOns list, so there's no quest list.")
        return nil
    end
    ns.Lore.Init(data)
    ns.data = data
    return data
end

------------------------------------------------------------------------------
-- What the quest windows show
------------------------------------------------------------------------------

local function Text(value)
    if type(value) ~= "string" or value == "" then return nil end
    return value
end

-- The zone you're standing in, for a quest met before it's in your log.
local function CurrentZone()
    return Text(GetRealZoneText and GetRealZoneText()) or Text(GetZoneText and GetZoneText())
end

-- The quest log heading above a quest: the zone (or category) the game files it under.
local function LogInfo(questID)
    local index = C_QuestLog.GetLogIndexForQuestID and C_QuestLog.GetLogIndexForQuestID(questID)
    if not index then return nil end
    local info = C_QuestLog.GetInfo(index)
    if not info then return nil end
    for i = index - 1, 1, -1 do
        local above = C_QuestLog.GetInfo(i)
        if above and above.isHeader then return info, Text(above.title) end
    end
    return info, nil
end

-- The quest window's NPC (or object): an ID (a number, or "o" and a number for an object) and a name.
local function Who()
    local guid = UnitGUID("npc")
    if not guid or (issecretvalue and issecretvalue(guid)) then return nil end
    local kind, _, _, _, _, id = strsplit("-", guid)
    local name = UnitName("npc")
    if issecretvalue and issecretvalue(name) then name = nil end
    if kind == "Creature" or kind == "Vehicle" then return tonumber(id), Text(name) end
    if kind == "GameObject" then return "o" .. id, Text(name) end
    return nil
end

-- Where you're standing: a map and x, y in percent (one decimal).
local function Where()
    local map = C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    local here = map and C_Map.GetPlayerMapPosition(map, "player")
    if not here then return nil end
    local ok, x, y = pcall(function()
        if here.GetXY then return here:GetXY() end
        return here.x, here.y
    end)
    if not ok or type(x) ~= "number" or type(y) ~= "number" or (issecretvalue and issecretvalue(x)) then return nil end
    return map, math.floor(x * 1000 + 0.5) / 10, math.floor(y * 1000 + 0.5) / 10
end

local lastTurnIn  -- { quest, giver, at }: the quest last turned in, and to whom
local completing  -- { quest, giver }: the quest whose reward window is open
local toldNew     -- said once a session that there are quests to share

-- A quest the list hasn't got: remembered with its zone so it counts there from now on, and with what
-- Share.lua sends (extra: fields for entry.i). Noted without loading the list (a quest window shouldn't
-- cost a 1 MB load); once it's loaded, quests the list has (or leaves out on purpose) are dropped again
-- (Lore.Init, Lore.AddLearned).
local function Learn(questID, name, zone, level, extra)
    if not questID or questID <= 0 then return end
    local data, Lore = ns.data, ns.Lore
    local learned = ns.db.learned
    if data and ((data.quests[questID] and not Lore.IsLearned(questID)) or Lore.IsLeftOut(questID)) then return end
    local fresh = learned[questID] == nil
    local entry = learned[questID] or {}
    entry.i = entry.i or {}
    for key, value in pairs(extra or {}) do
        entry.i[key] = value -- the latest look at the quest wins (nil fields don't erase what's known)
    end
    entry[1] = Text(name) or entry[1]
    entry[2] = zone or entry[2] or CurrentZone()
    entry[3] = (level and level > 0) and level or entry[3]
    -- Shared by every character: counted for a faction once one of its characters has met it
    -- (1 Alliance, 2 Horde, 3 both).
    local faction, seen = Lore.Faction(), entry[4] or 0
    if faction and seen % (faction * 2) < faction then entry[4] = seen + faction end
    if not entry[1] or not entry[2] then return end
    learned[questID] = entry
    ns.charDB.met[questID] = true
    if data then Lore.AddLearned(questID, entry) end
    if fresh and data and not toldNew then
        toldNew = true
        ns.Say(("%s isn't in Lorebound's list yet. It counts in %s from now on; share it from the journal's overview (/lb)."):format(entry[1], entry[2]))
    end
end

local function Repeatable(questID)
    if C_QuestLog.IsRepeatableQuest and C_QuestLog.IsRepeatableQuest(questID) then return true end
    return (QuestIsDaily and QuestIsDaily()) or (QuestIsWeekly and QuestIsWeekly())
end

local function QuestWindow(kind)
    local questID = GetQuestID and GetQuestID()
    if not questID or questID == 0 then return end
    local saved = ns.db.text[questID] or {}
    if kind == "detail" then
        saved[1] = Text(GetQuestText()) or saved[1]
        saved[2] = Text(GetObjectiveText()) or saved[2]
    else
        saved[3] = Text(GetRewardText()) or saved[3]
    end
    if next(saved) then ns.db.text[questID] = saved end
    local giver, giverName = Who()
    if kind == "detail" and not Repeatable(questID) then
        local map, x, y
        if giver then map, x, y = Where() end -- an item's quest: where you stood isn't the giver's spot
        local before = lastTurnIn and giver and lastTurnIn.giver == giver and GetTime() - lastTurnIn.at < 300
            and lastTurnIn.quest or nil
        local _, _, class = UnitClass("player")
        Learn(questID, GetTitleText(), nil, nil, { giver = giver, giverName = giverName, map = map, x = x, y = y,
            before = before, class = class })
    elseif kind == "reward" then
        completing = { quest = questID, giver = giver }
        local entry = ns.db.learned[questID]
        if entry and giver then
            entry.i = entry.i or {}
            if entry.i.ender ~= giver then
                entry.i.ender, entry.i.enderName = giver, giverName
                ns.db.shared[questID] = nil -- shared before it was turned in: offer it again, with this
            end
        end
    end
end

local function Accepted(questID)
    local info, zone = LogInfo(questID)
    if not info or info.isHidden or info.isTask or (info.frequency and info.frequency ~= 0) then return end
    if C_QuestLog.IsRepeatableQuest and C_QuestLog.IsRepeatableQuest(questID) then return end
    Learn(questID, info.title, zone, info.level)
end

local function TurnedIn(questID)
    lastTurnIn = { quest = questID, giver = completing and completing.quest == questID and completing.giver or nil,
        at = GetTime() }
    ns.charDB.turned[questID] = time()
    local days = ns.charDB.days
    local today = date("%Y-%m-%d")
    days[today] = (days[today] or 0) + 1
    if not ns.LoadData() then return end
    local info = ns.Lore.TurnedIn(questID)
    -- Before the toast, so the badge it awards shows as earned; only rings this turn-in closed are
    -- celebrated.
    ns.Toast.Show(info, ns.Badge.Record())
    ns.Journal:Schedule()
end

-- Turn-in counts for the overview: today and the last seven days.
function ns.TurnInCounts()
    local days, now = ns.charDB.days, time()
    local today = days[date("%Y-%m-%d", now)] or 0
    local week = 0
    for back = 0, 6 do week = week + (days[date("%Y-%m-%d", now - back * 86400)] or 0) end
    return today, week
end

------------------------------------------------------------------------------
-- Events and the slash command
------------------------------------------------------------------------------

local events = CreateFrame("Frame")
ns.events = events
for _, event in ipairs({ "ADDON_LOADED", "QUEST_DETAIL", "QUEST_ACCEPTED", "QUEST_COMPLETE", "QUEST_TURNED_IN" }) do
    events:RegisterEvent(event)
end
events:SetScript("OnEvent", function(_, event, arg1, arg2)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON then return end
        events:UnregisterEvent("ADDON_LOADED")
        LoreboundDB = CopyDefaults(ns.defaults, type(LoreboundDB) == "table" and LoreboundDB or {})
        LoreboundCharDB = CopyDefaults(CHAR_DEFAULTS, type(LoreboundCharDB) == "table" and LoreboundCharDB or {})
        ns.db, ns.charDB = LoreboundDB, LoreboundCharDB
        local cutoff = date("%Y-%m-%d", time() - 30 * 86400)
        for day in pairs(ns.charDB.days) do
            if day < cutoff then ns.charDB.days[day] = nil end
        end
    elseif event == "QUEST_DETAIL" then
        QuestWindow("detail")
    elseif event == "QUEST_COMPLETE" then
        QuestWindow("reward")
    elseif event == "QUEST_ACCEPTED" then
        Accepted(arg2 or arg1) -- (questID), or (logIndex, questID) on older clients
    elseif event == "QUEST_TURNED_IN" then
        TurnedIn(arg1)
    elseif event == "PLAYER_REGEN_ENABLED" then
        events:UnregisterEvent("PLAYER_REGEN_ENABLED")
        local lines = waiting
        waiting = {}
        for _, text in ipairs(lines) do ns.Say(text) end
    end
end)

function Lorebound_OnCompartmentClick()
    ns.Journal:Toggle()
end

-- Bindings.xml: the game's Key Bindings menu (AddOns), for a key or a controller button of your choice.
BINDING_HEADER_LOREBOUND = "Lorebound"
BINDING_NAME_LOREBOUND_TOGGLE = "Open or close the journal"
function Lorebound_Toggle()
    ns.Journal:Toggle()
end

SLASH_LOREBOUND1, SLASH_LOREBOUND2 = "/lb", "/lorebound"
SlashCmdList.LOREBOUND = function(text)
    text = strtrim(text or "")
    if text == "export" then
        ns.Export.Open()
    elseif text == "reset" then
        ns.Journal:ResetWindow()
        ns.Say("the journal is back to its first size, in the middle of the screen.")
    elseif text ~= "" then
        ns.Journal:Open(text) -- a zone's name, or the start of one
    else
        ns.Journal:Toggle()
    end
end
