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
    starterFrom = 26, -- where a quest-starting item comes from ("Dropped by Rockjaw mobs in Dun Morogh")
    chain = 27, -- { first quest, this one's step, steps in all } for a quest in a chain
    mine = 28, -- not from the list: a learned profession quest, only for characters that met it
}

ns.defaults = {
    point = { "CENTER", "CENTER", 0, 0 },
    toasts = true,       -- a toast with the zone's ring for each quest turned in
    sound = true,        -- a fanfare when a ring closes
    showLocked = false,  -- list the quests you're locked out of
    filter = "todo",     -- the quest list: "todo", "done" or "all"
    collapsed = {},      -- [group] = true: folded in the zone list
    foldedSections = {}, -- [status] = true: a section of the zone's quests folded (Available now, Done...), in every zone
    foldedChains = {},   -- [first quest] = true: a chain folded to its heading
    pinned = {},         -- [zone name] = true: pinned to the top of the zone list and the overview
    size = { 980, 640 }, -- the journal's width and height (its resize grip)
    scale = 1,           -- the journal's scale (the grip with Shift held)
    -- toastPoint = { x, y }: where the toast's top sits from the top middle of the screen, once dragged (Toast.lua)
    text = {},           -- [questID] = { description, objective, completion, progress }: what the quest windows showed
    learned = {},        -- [questID] = { name, zone, level, factions seen, i = { giver, giverName, map, x, y,
                         --   ender, enderName, before, class } }: quests the list hasn't got, met in game
    shared = {},         -- [questID] = true: learned quests already shared (Share.lua)
    textShared = {},     -- [questID] = the text fields already shared ("d", "o", "c", "p" in a string; Share.lua)
    textClean = {},      -- [questID] = the text fields kept with the reader's name as $N (only those are shared)
    rewards = {},        -- [questID] = { ch = { { item, count } }, it = { { item, count } }, m = copper, xp = experience }: as the game showed
    rewardsShared = {},  -- [questID] = true: its rewards already shared (Share.lua)
    unanswered = {},     -- { version = the list's, [questID] = true }: the game gave nothing when asked (Core.lua)
}
local CHAR_DEFAULTS = {
    days = {},           -- ["2026-11-21"] = quests turned in that day (the last 30 days)
    badges = {},         -- [zone name, "group:N" or "seal"] = when its badge was earned (Badge.lua)
    met = {},            -- [questID] = true: learned quests this character has met
    turned = {},         -- [questID] = when it was turned in (since Lorebound was installed)
}

-- Fills in what saved variables lack, and puts back a default where a saved value is of the wrong kind (a
-- damaged or hand-edited file).
local function CopyDefaults(defaults, saved)
    for key, value in pairs(defaults) do
        if type(value) == "table" then
            if type(saved[key]) ~= "table" then saved[key] = {} end
            CopyDefaults(value, saved[key])
        elseif type(saved[key]) ~= type(value) then
            saved[key] = value
        end
    end
    return saved
end

------------------------------------------------------------------------------
-- Chat, never in combat (printing in combat taints the chat history)
------------------------------------------------------------------------------

local waiting = {}

-- A value made safe for the share and export codes: nil as "", and every character either code uses as a
-- separator (~ ; ^ |, line breaks) or the site refuses to keep (< > `) turned into a space.
function ns.Plain(value)
    if value == nil then return "" end
    return (tostring(value):gsub("[~;%^|\n<>`]", " "))
end

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

-- Loads a load-on-demand part; true when it's loaded (or was already).
local function LoadPart(name)
    local load = C_AddOns and C_AddOns.LoadAddOn or LoadAddOn
    if not load then return false end
    local ok, loaded, reason = pcall(load, name)
    return ok and (loaded and true or reason == nil)
end

-- The quest pages' text, in three load-on-demand parts by the quest's group (make_lore.py's TEXT_PARTS), each
-- holding every page as Lua source: only the part a page is in loads, and only the page shown is made a table.
local TEXT_PARTS = { [1] = "Lorebound_Text_EasternKingdoms", [2] = "Lorebound_Text_Kalimdor" }
local TEXT_REST = "Lorebound_Text"
local textLoaded, textSource = {}, {}   -- [part] = true; [questID] = its page's source, from the parts loaded
local shownId, shownPage                 -- the last page made

local function LoadTextPart(name)
    if not textLoaded[name] then
        textLoaded[name] = true
        if not LoadPart(name) then
            ns.Say(("%s is missing or turned off in the AddOns list, so some quest pages have no text."):format(name))
        end
    end
    local found = _G.LoreboundText -- every part adds its pages to it
    _G.LoreboundText = nil
    if type(found) ~= "table" then return end
    for id, source in pairs(found) do textSource[id] = source end
end

-- A quest's page in its group (Lore.Zone's second value): { o, n, d, p, c, r, k } (make_lore.write_text), or nil
-- when there's none or its part is missing.
function ns.QuestText(id, group)
    if shownId == id then return shownPage end
    LoadTextPart(TEXT_PARTS[group] or TEXT_REST)
    local source, page = textSource[id], nil
    local make = source and loadstring("return " .. source)
    if make then
        setfenv(make, {})
        local ok, made = pcall(make)
        page = ok and type(made) == "table" and made or nil
    end
    shownId, shownPage = id, page
    return page
end

-- The list, or nil when Lorebound_Data can't load (said once).
function ns.LoadData()
    if ns.data ~= nil then return ns.data or nil end
    LoadPart("Lorebound_Data")
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

-- A string with something in it, else nil (the game's text calls give "" for nothing).
local function NonEmpty(value)
    if type(value) ~= "string" or value == "" then return nil end
    return value
end

-- The zone you're standing in, for a quest met before it's in your log.
local function CurrentZone()
    return NonEmpty(GetRealZoneText and GetRealZoneText()) or NonEmpty(GetZoneText and GetZoneText())
end

-- The quest log heading above a quest: the zone (or category) the game files it under.
local function LogInfo(questID)
    local index = C_QuestLog.GetLogIndexForQuestID and C_QuestLog.GetLogIndexForQuestID(questID)
    if not index then return nil end
    local info = C_QuestLog.GetInfo(index)
    if not info then return nil end
    for i = index - 1, 1, -1 do
        local above = C_QuestLog.GetInfo(i)
        if above and above.isHeader then return info, NonEmpty(above.title) end
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
    if kind == "Creature" or kind == "Vehicle" then return tonumber(id), NonEmpty(name) end
    if kind == "GameObject" then return "o" .. id, NonEmpty(name) end
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
    entry[1] = NonEmpty(name) or entry[1]
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

local WORD_BYTE = "[%w\128-\255]" -- a letter, a digit, or part of a letter outside ASCII

-- The text with every whole-word use of words replaced (plain matching, so any name works, accents and all).
local function ReplaceWord(text, words, by)
    if not words or words == "" then return text end
    local out, at = {}, 1
    while true do
        local first, last = text:find(words, at, true)
        if not first then break end
        local whole = (first == 1 or not text:sub(first - 1, first - 1):find(WORD_BYTE))
            and not text:sub(last + 1, last + 1):find(WORD_BYTE)
        out[#out + 1] = text:sub(at, first - 1) .. (whole and by or words)
        at = last + 1
    end
    out[#out + 1] = text:sub(at)
    return table.concat(out)
end

-- What the quest window said, with this character's name as $N (the game's own markup), so the account-wide copy
-- can be shared without anyone's name.
local function Unnamed(text)
    text = NonEmpty(text)
    if not text then return nil end
    local name, surname = UnitName("player")
    if surname and surname ~= "" then text = ReplaceWord(text, (name or "") .. " " .. surname, "$N") end
    return ReplaceWord(text, name, "$N")
end

local function Keep(questID, saved, index, text)
    text = Unnamed(text)
    if not text then return end
    saved[index] = text
    local clean = ns.db.textClean[questID] or ""
    if not clean:find(tostring(index), 1, true) then ns.db.textClean[questID] = clean .. index end
end

-- Money is left out at the level cap, where the game pays the experience as gold on top.
local function AtCap()
    local cap = GetMaxPlayerLevel and GetMaxPlayerLevel() or 60
    return (UnitLevel("player") or 0) >= cap
end

-- The rewards a quest window shows (offered or handing in), or nil when it shows none, or an item it can't name yet
-- (not loaded): a partial list would be shared as the whole.
local function WindowRewards()
    local found = { ch = {}, it = {} }
    local function Read(kind, count, into)
        for i = 1, count or 0 do
            local _, _, amount, _, _, item = GetQuestItemInfo(kind, i)
            if type(item) ~= "number" then
                local link = GetQuestItemLink and GetQuestItemLink(kind, i)
                item = type(link) == "string" and tonumber(link:match("item:(%d+)"))
            end
            if not item then return false end
            into[#into + 1] = { item, type(amount) == "number" and amount > 0 and amount or 1 }
        end
        return true
    end
    if not Read("choice", GetNumQuestChoices and GetNumQuestChoices(), found.ch)
        or not Read("reward", GetNumQuestRewards and GetNumQuestRewards(), found.it) then
        return nil
    end
    local money = not AtCap() and GetRewardMoney and GetRewardMoney()
    found.m = type(money) == "number" and money or 0
    found.cap = AtCap() or nil -- read at the cap: its money unknown, so not shared
    if #found.ch == 0 and #found.it == 0 and found.m == 0 then return nil end
    return found
end

-- A quest's rewards by its ID (in your log, or loaded from the server), or nil when it gives none, or an item
-- has no ID (a partial list would be shared as the whole).
local function LogRewards(questID)
    local found = { ch = {}, it = {} }
    local function Read(countOf, infoOf, into)
        if type(countOf) ~= "function" or type(infoOf) ~= "function" then return false end
        local ok, count = pcall(countOf, questID)
        if not ok or type(count) ~= "number" then return false end
        for i = 1, count do
            local okItem, _, _, amount, _, _, item = pcall(infoOf, i, questID)
            if not okItem or type(item) ~= "number" or item <= 0 then return false end
            into[#into + 1] = { item, type(amount) == "number" and amount > 0 and amount or 1 }
        end
        return true
    end
    if not Read(GetNumQuestLogChoices, GetQuestLogChoiceInfo, found.ch)
        or not Read(GetNumQuestLogRewards, GetQuestLogRewardInfo, found.it) then
        return nil
    end
    local okMoney, money = pcall(GetQuestLogRewardMoney, questID)
    found.m = not AtCap() and okMoney and type(money) == "number" and money > 0 and money or 0
    found.cap = AtCap() or nil
    local okXP, xp = pcall(GetQuestLogRewardXP, questID)
    if okXP and type(xp) == "number" and xp > 0 then found.xp = xp end
    if #found.ch == 0 and #found.it == 0 and found.m == 0 and not found.xp then return nil end
    return found
end

-- Every quest in your log: its description and objective (kept as a quest window's are), and its rewards, choices
-- and all (asked by quest ID: nothing is selected or changed in Blizzard's quest log). Read when the journal opens.
-- A call that ignored which quest it's asked about would answer the same for every quest. The text (asked by its
-- place in the log) is kept only when two or more quests answer and differ; the rewards (asked by the quest itself,
-- which the game honours: 60 silver for Storm, Earth, and Fire) unless two or more answer and are all the same.
function ns.ReadQuestLog()
    local texts, rewards, textKeys, rewardKeys = {}, {}, {}, {}
    local entries = C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetNumQuestLogEntries() or 0
    for index = 1, entries do
        local info = C_QuestLog.GetInfo(index)
        local questID = info and not info.isHeader and info.questID
        if questID and questID > 0 then
            local ok, description, objective = pcall(GetQuestLogQuestText, index)
            if ok and type(description) == "string" and description ~= "" then
                texts[questID] = { description, objective }
                textKeys[description] = true
            end
            local found = LogRewards(questID)
            if found and (#found.ch > 0 or #found.it > 0 or found.m > 0) then
                local key = {}
                for _, list in ipairs({ found.ch, found.it }) do
                    for _, entry in ipairs(list) do key[#key + 1] = entry[1] .. "x" .. entry[2] end
                    key[#key + 1] = "/"
                end
                key[#key + 1] = found.m
                rewards[questID] = found
                rewardKeys[table.concat(key, ":")] = true
            end
        end
    end
    local function Varied(byQuest, keys)
        local quests, distinct = 0, 0
        for _ in pairs(byQuest) do quests = quests + 1 end
        for _ in pairs(keys) do distinct = distinct + 1 end
        return quests >= 2 and distinct >= 2
    end
    if Varied(texts, textKeys) then
        for questID, words in pairs(texts) do
            local saved = ns.db.text[questID] or {}
            if not saved[1] then Keep(questID, saved, 1, words[1]) end
            if not saved[2] then Keep(questID, saved, 2, words[2]) end
            if next(saved) then ns.db.text[questID] = saved end
        end
    end
    local rewardQuests, rewardKinds = 0, 0
    for _ in pairs(rewards) do rewardQuests = rewardQuests + 1 end
    for _ in pairs(rewardKeys) do rewardKinds = rewardKinds + 1 end
    if not (rewardQuests >= 2 and rewardKinds == 1) then
        for questID, found in pairs(rewards) do
            local saved = ns.db.rewards[questID]
            if not saved or saved.part then ns.db.rewards[questID] = found end -- the whole, over the server's part
        end
    end
    ns.shareStale = true
end

------------------------------------------------------------------------------
-- Rewards asked of the game: the server tells any quest's rewards, in your log or not (as ForeverDungeonJournal
-- reads them). Asked for a quest page that doesn't know them (first) and for the quests of the zone the journal
-- shows, one at a time and out of combat. An answer counts only once the server says the quest's data is loaded:
-- before that every count reads 0. (Already loaded, the answer comes during the call itself.)
------------------------------------------------------------------------------

local asked = {}   -- [questID] = true: queued or asked this session (each quest once)
local queue = {}   -- quests to ask next, in order
local waitingFor   -- the quest asked and not answered yet
local onAnswer = {} -- [questID] = a function to run once it's answered (its quest page redrawing)
local AskNext

-- A loaded quest's rewards. The game tells a quest's choices only while it's in your log: for any other it
-- answers none, so that answer is only part of them (kept for the quest page, not shared).
local function ServerRewards(questID)
    local found = LogRewards(questID)
    if found and #found.ch == 0
        and not (C_QuestLog.GetLogIndexForQuestID and C_QuestLog.GetLogIndexForQuestID(questID)) then
        found.part = true
    end
    return found
end

-- Quests the server gave nothing for, kept until the list changes: asking again would only wait out the timeout.
local function Unanswered()
    local version = ns.data and ns.data.version
    if ns.db.unanswered.version ~= version then ns.db.unanswered = { version = version } end
    return ns.db.unanswered
end

local function Answered(questID, loaded)
    if questID ~= waitingFor then return end
    waitingFor = nil
    local found = loaded and ServerRewards(questID)
    if not found then Unanswered()[questID] = true end
    if found then
        local saved = ns.db.rewards[questID]
        if not saved then
            ns.db.rewards[questID] = found
            ns.shareStale = true
        elseif not saved.xp then
            saved.xp = found.xp -- a quest window's: only the experience is new
        end
    end
    C_Timer.After(0.1, AskNext) -- before the page redraws, so an error there can't stop the queue
    local done = onAnswer[questID]
    onAnswer[questID] = nil
    if done then done() end
end

function AskNext()
    if waitingFor then return end
    if InCombatLockdown() then
        ns.events:RegisterEvent("PLAYER_REGEN_ENABLED") -- carried on after the fight
        return
    end
    local questID = table.remove(queue, 1)
    if not questID then
        ns.events:UnregisterEvent("QUEST_DATA_LOAD_RESULT")
        return
    end
    waitingFor = questID
    ns.events:RegisterEvent("QUEST_DATA_LOAD_RESULT")
    -- The answer can come before the call returns: waitingFor is set first.
    if not pcall(C_QuestLog.RequestLoadQuestByID, questID) then return Answered(questID, false) end
    C_Timer.After(3, function() -- a quest the server never answers for
        if waitingFor == questID then Answered(questID, false) end
    end)
end

local function Unknown(id)
    return type(id) == "number" and ns.Lore.LacksRewards(id) and not ns.db.rewards[id] and not Unanswered()[id]
end

-- Queues the quests whose rewards aren't known (the zone shown), in place of the zone shown before's.
function ns.AskRewards(ids)
    if not (C_QuestLog and C_QuestLog.RequestLoadQuestByID) then return end
    for i = #queue, 1, -1 do
        local id = queue[i]
        if not onAnswer[id] then -- not asked yet: free to be queued again
            table.remove(queue, i)
            asked[id] = nil
        end
    end
    for _, id in ipairs(ids) do
        if Unknown(id) and not asked[id] then
            asked[id] = true
            queue[#queue + 1] = id
        end
    end
    AskNext()
end

-- Asks for one quest's rewards ahead of the rest, then runs done (the quest page shown).
function ns.AskRewardsNow(id, done)
    if not (C_QuestLog and C_QuestLog.RequestLoadQuestByID) or not Unknown(id) then return end
    if id == waitingFor then
        onAnswer[id] = done
        return
    end
    local queued = false
    for i = #queue, 1, -1 do
        local other = queue[i]
        if other == id then
            table.remove(queue, i)
            queued = true
        elseif onAnswer[other] then -- the page shown before's, not asked yet: that page is gone
            table.remove(queue, i)
            onAnswer[other], asked[other] = nil, nil
        end
    end
    if asked[id] and not queued then return end -- answered already this session, with nothing to keep
    asked[id] = true
    onAnswer[id] = done
    table.insert(queue, 1, id)
    AskNext()
end

local function QuestWindow(kind)
    local questID = GetQuestID and GetQuestID()
    if not questID or questID == 0 then return end
    local saved = ns.db.text[questID] or {}
    if kind == "detail" then
        Keep(questID, saved, 1, GetQuestText())
        Keep(questID, saved, 2, GetObjectiveText())
    elseif kind == "progress" then
        Keep(questID, saved, 4, GetProgressText())
    else
        Keep(questID, saved, 3, GetRewardText())
    end
    if next(saved) then ns.db.text[questID] = saved end
    if kind ~= "progress" then
        local ok, found = pcall(WindowRewards)
        if ok and found then
            local before = ns.db.rewards[questID]
            if before then -- what the window doesn't tell, kept: the experience, and money read below the cap
                found.xp = before.xp
                if found.cap and not before.cap then found.m, found.cap = before.m, nil end
            end
            ns.db.rewards[questID] = found
        end
    end
    ns.shareStale = true
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
    ns.shareStale = true
    local info, zone = LogInfo(questID)
    if not info or info.isHidden or info.isTask or (info.frequency and info.frequency ~= 0) then return end
    if C_QuestLog.IsRepeatableQuest and C_QuestLog.IsRepeatableQuest(questID) then return end
    Learn(questID, info.title, zone, info.level)
end

local function TurnedIn(questID)
    if type(questID) ~= "number" or questID <= 0 then return end
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
for _, event in ipairs({ "ADDON_LOADED", "QUEST_DETAIL", "QUEST_PROGRESS", "QUEST_ACCEPTED", "QUEST_COMPLETE",
    "QUEST_TURNED_IN" }) do
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
    elseif event == "QUEST_PROGRESS" then
        QuestWindow("progress")
    elseif event == "QUEST_COMPLETE" then
        QuestWindow("reward")
    elseif event == "QUEST_ACCEPTED" then
        Accepted(arg2 or arg1) -- (questID), or (logIndex, questID) on older clients
    elseif event == "QUEST_TURNED_IN" then
        TurnedIn(arg1)
    elseif event == "QUEST_DATA_LOAD_RESULT" then
        Answered(arg1, arg2 ~= false)
    elseif event == "PLAYER_REGEN_ENABLED" then
        events:UnregisterEvent("PLAYER_REGEN_ENABLED")
        local lines = waiting
        waiting = {}
        for _, text in ipairs(lines) do ns.Say(text) end
        AskNext()
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
