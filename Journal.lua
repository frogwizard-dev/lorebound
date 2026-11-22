local _, ns = ...

-- The journal (/lore): zones down the left, each with its own small ring, and on the right the page you
-- pick. A zone's page has three nested rings over the zone's own map art (the zone, its continent or
-- group, the whole Lorebound count) and its quests below: in your log, available now, coming up (and
-- what for), done, and the ones you're locked out of with the reason (hidden until asked for). Opening
-- a quest shows its objective, the story text from when you last read it, and who gives it, with a
-- button that shows the quest giver on a map of the zone and puts a map pin link in chat. The overview
-- is the badge case: every zone's badge, under the continents' crests.
--
-- All of it is our own frames: nothing is put on Blizzard's world map, and the map pin is set by
-- Blizzard's own link handler when the link is clicked. Built on first open; listens for quest events
-- only while shown.

local F = ns.F
local Lore = ns.Lore
local COLORS = ns.COLORS
local MEDIA = ns.MEDIA

local Journal = {}
ns.Journal = Journal

local NAV_W = 262
local MIN_W, MIN_H, MAX_W, MAX_H = 820, 560, 2000, 1400 -- the window's size, by its grip
local MIN_SCALE, MAX_SCALE, SCALE_STEP = 0.6, 1.8, 0.1   -- its scale, by the grip with Shift or the settings
local HEADER_H = 236
local NAV_ZONE_H, NAV_GROUP_H = 30, 26
local QUEST_H, SECTION_H, CHAIN_H = 44, 28, 24
local WALL_ROW_H, WALL_HEAD_H, MEDAL_W = 104, 30, 110
local TITLE_FONT = _G.Game30Font and "Game30Font" or "GameFontNormalHuge"

local frame
local page = "overview" -- "overview", "search" or a zone
local lastPage = "overview" -- the page before a search
local headerPage        -- the page the header's rings were last drawn for
local searchText = ""
local found = {}        -- the search's results
local bodies = {}       -- [questID] = an opened quest's text, until the next redraw
local searchTimer       -- the search waits for a pause in typing
local expanded = {}     -- [questID] = true: opened in the list
local events = CreateFrame("Frame")
local pending           -- a coalesced refresh

local SECTIONS = {
    { Lore.ACTIVE, "In your quest log" },
    { Lore.AVAILABLE, "Available now" },
    { Lore.LATER, "Coming up" },
    { Lore.DONE, "Done" },
    { Lore.LOCKED, "Locked out" },
}
local SHOWN_BY_FILTER = {
    todo = { [Lore.ACTIVE] = true, [Lore.AVAILABLE] = true, [Lore.LATER] = true },
    done = { [Lore.DONE] = true },
    all = { [Lore.ACTIVE] = true, [Lore.AVAILABLE] = true, [Lore.LATER] = true, [Lore.DONE] = true },
}

------------------------------------------------------------------------------
-- Small helpers
------------------------------------------------------------------------------

local function Share(done, total)
    if total <= 0 then return 0 end
    return done / total
end

local function Percent(done, total)
    return ("%d%%"):format(math.floor(Share(done, total) * 100))
end

local function Levels(zone)
    local low, high = Lore.ZoneLevels(zone)
    if not low then return "" end
    if low == high then return ("Level %d"):format(low) end
    return ("Levels %d-%d"):format(low, high)
end

-- The list's objective texts still hold the game's placeholders ($N for your name...).
local you -- { name, class, race }, read once
local function Fill(text)
    if not text or not text:find("$", 1, true) then return text end
    you = you or { UnitName("player") or "", (UnitClass("player")) or "", (UnitRace("player")) or "" }
    return (text:gsub("%$[Bb]", "\n"):gsub("%$[Nn]", you[1]):gsub("%$[Cc]", you[2]):gsub("%$[Rr]", you[3]))
end

local function QuestColor(id, s)
    if s == Lore.DONE then return 0.55, 0.78, 0.55 end
    if s == Lore.LOCKED then return 0.78, 0.36, 0.36 end
    if s == Lore.LATER then return 0.62, 0.62, 0.62 end
    if s == Lore.ACTIVE then return 1, 0.82, 0 end
    local row = Lore.Row(id)
    local level = row and row[F.level]
    if level and level > 0 and GetQuestDifficultyColor then
        local c = GetQuestDifficultyColor(level)
        if c then return c.r, c.g, c.b end
    end
    return 1, 0.82, 0
end

local function SetAtlasOr(icon, atlas, file)
    if C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(atlas) then
        icon:SetAtlas(atlas)
    else
        icon:SetTexture(file)
    end
end

local function SetStatusIcon(icon, s)
    icon:SetDesaturated(false)
    icon:SetAlpha(1)
    if s == Lore.DONE then
        icon:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready")
    elseif s == Lore.LOCKED then
        icon:SetTexture("Interface\\RaidFrame\\ReadyCheck-NotReady")
    elseif s == Lore.ACTIVE then
        SetAtlasOr(icon, "QuestTurnin", "Interface\\GossipFrame\\ActiveQuestIcon")
    else
        SetAtlasOr(icon, "QuestNormal", "Interface\\GossipFrame\\AvailableQuestIcon")
        if s == Lore.LATER then
            icon:SetDesaturated(true)
            icon:SetAlpha(0.6)
        end
    end
end

local DrawArt = ns.DrawArt

local function Gradient(texture, orientation, a1, a2)
    texture:SetColorTexture(1, 1, 1, 1)
    if CreateColor then
        texture:SetGradient(orientation, CreateColor(0, 0, 0, a1), CreateColor(0, 0, 0, a2))
    else
        texture:SetColorTexture(0, 0, 0, (a1 + a2) / 2)
    end
end

local function Triple(parent, sizes)
    local outer = ns.NewRing(parent, sizes[1], "Ring1", COLORS.zone, "zone")
    local middle = ns.NewRing(parent, sizes[2], "Ring2", COLORS.group, "group")
    local inner = ns.NewRing(parent, sizes[3], "Ring3", COLORS.total, "total")
    middle:SetPoint("CENTER", outer)
    inner:SetPoint("CENTER", outer)
    middle:SetFrameLevel(outer:GetFrameLevel() + 3)
    inner:SetFrameLevel(outer:GetFrameLevel() + 6)
    return { outer, middle, inner }
end

------------------------------------------------------------------------------
-- Pinned zones
------------------------------------------------------------------------------

local PINNED = "pinned" -- the zone list's group of pinned zones (kept by name in LoreboundDB.pinned)

function Journal:IsPinned(zone)
    local name = Lore.Zone(zone)
    return name and ns.db.pinned[name] or false
end

function Journal:TogglePin(zone)
    local name = Lore.Zone(zone)
    if not name then return end
    ns.db.pinned[name] = not ns.db.pinned[name] or nil
    self:FillNav()
    self:Draw(true)
end

local function PinnedZones()
    local list = {}
    for zone, z in ipairs(Lore.Zones()) do
        if ns.db.pinned[z[1]] then
            local _, total = Lore.Count(zone)
            if total > 0 then list[#list + 1] = zone end
        end
    end
    return list
end

local function GroupCount(group)
    if group ~= PINNED then return Lore.GroupCount(group) end
    local done, total = 0, 0
    for _, zone in ipairs(PinnedZones()) do
        local d, t = Lore.Count(zone)
        done, total = done + d, total + t
    end
    return done, total
end

local function GroupName(group)
    if group == PINNED then return "Pinned" end
    return Lore.Groups()[group] or "Other"
end

-- The zones of a group (or the pinned ones) that hold quests for this character.
local function ZonesOf(group)
    if group == PINNED then return PinnedZones() end
    local list = {}
    for zone, z in ipairs(Lore.Zones()) do
        if z[2] == group then
            local _, total = Lore.Count(zone)
            if total > 0 then list[#list + 1] = zone end
        end
    end
    return list
end

local function ZoneTooltip(owner, zone)
    local done, total, locked = Lore.Count(zone)
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:SetText((Lore.Zone(zone)))
    GameTooltip:AddLine(("%d / %d quests  ·  %s"):format(done, total, Percent(done, total)), 1, 1, 1)
    if locked > 0 then GameTooltip:AddLine(("%d locked out"):format(locked), 0.85, 0.45, 0.45) end
    local levels = Levels(zone)
    if levels ~= "" then GameTooltip:AddLine(levels, 0.7, 0.7, 0.7) end
    local earned = ns.Badge.Earned("zone", zone)
    if earned then
        GameTooltip:AddLine(("%s, earned %s"):format(ns.Badge.Name("zone", zone), date("%d %b %Y", earned)), 1, 0.82, 0.25)
    end
    GameTooltip:AddLine(Journal:IsPinned(zone) and "Right-click to unpin" or "Right-click to pin it to the top",
        0.55, 0.55, 0.55)
    GameTooltip:Show()
end

------------------------------------------------------------------------------
-- The zone list (left)
------------------------------------------------------------------------------

function Journal:ToggleGroup(group)
    ns.db.collapsed[group] = not ns.db.collapsed[group] or nil
    self:FillNav()
end

local function NavRowClick(row, button)
    local data = row.data
    if not data then return end
    if data.group then
        Journal:ToggleGroup(data.group)
    elseif button == "RightButton" then
        Journal:TogglePin(data.zone)
    else
        Journal:ShowPage(data.zone)
    end
end

local function NavRowEnter(row)
    row.hover:Show()
    if row.data and row.data.zone then ZoneTooltip(row, row.data.zone) end
end

local function NavRowLeave(row)
    row.hover:Hide()
    GameTooltip:Hide()
end

local function InitNavRow(row, data)
    local height = data.group and NAV_GROUP_H or NAV_ZONE_H
    if not row.built then
        row.built = true
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        -- The zone's map behind the row, darkened towards the text; the row's own parts on a layer above.
        row.art = CreateFrame("Frame", nil, row)
        row.art:SetAllPoints()
        row.art:SetClipsChildren(true)
        row.art:SetFrameLevel(row:GetFrameLevel() + 1)
        local shade = row.art:CreateTexture(nil, "BORDER")
        shade:SetAllPoints()
        Gradient(shade, "HORIZONTAL", 0.82, 0.4)
        row.content = CreateFrame("Frame", nil, row)
        row.content:SetAllPoints()
        row.content:SetFrameLevel(row:GetFrameLevel() + 3)
        local c = row.content
        row.selected = c:CreateTexture(nil, "BACKGROUND")
        row.selected:SetAllPoints()
        row.selected:SetColorTexture(1, 0.82, 0.25, 0.16)
        row.hover = c:CreateTexture(nil, "BACKGROUND", nil, 1)
        row.hover:SetAllPoints()
        row.hover:SetColorTexture(1, 1, 1, 0.07)
        row.hover:Hide()
        row.edge = c:CreateTexture(nil, "BORDER")
        row.edge:SetPoint("BOTTOMLEFT")
        row.edge:SetPoint("BOTTOMRIGHT")
        row.edge:SetHeight(1)
        row.edge:SetColorTexture(0, 0, 0, 0.8)
        row.ring = ns.NewRing(c, 22, "Ring2", COLORS.zone)
        row.ring:SetPoint("LEFT", 6, 0)
        row.ring:EnableMouse(false)
        row.arrow = c:CreateTexture(nil, "ARTWORK")
        row.arrow:SetSize(14, 14)
        row.arrow:SetPoint("LEFT", 6, 0)
        row.name = c:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row.name:SetJustifyH("LEFT")
        row.name:SetWordWrap(false)
        row.name:SetShadowOffset(1, -1)
        row.levels = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.levels:SetJustifyH("LEFT")
        row.count = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.count:SetPoint("RIGHT", -6, 0)
        row.count:SetShadowOffset(1, -1)
        row.pin = c:CreateTexture(nil, "OVERLAY")
        row.pin:SetTexture(MEDIA .. "Pin")
        row.pin:SetSize(12, 12)
        row.pin:SetPoint("RIGHT", row.count, "LEFT", -4, 0)
        row.pin:SetVertexColor(1, 0.82, 0.25)
        row:SetScript("OnClick", NavRowClick)
        row:SetScript("OnEnter", NavRowEnter)
        row:SetScript("OnLeave", NavRowLeave)
    end
    row.data = data
    local width = row:GetWidth()
    if not width or width < 50 then width = NAV_W - 26 end
    row.name:ClearAllPoints()
    if data.group then
        local group = data.group ~= PINNED and data.group or nil
        DrawArt(row.art, group and ns.Badge.GROUP_MAPS[group], width, height, true, group and ns.Badge.GroupPainting(group))
        row.ring:Hide()
        row.pin:SetShown(data.group == PINNED)
        row.arrow:Show()
        row.arrow:SetTexture(ns.db.collapsed[data.group] and "Interface\\Buttons\\UI-PlusButton-Up"
            or "Interface\\Buttons\\UI-MinusButton-Up")
        row.name:SetFontObject("GameFontNormal")
        row.name:SetPoint("LEFT", 26, 0)
        row.name:SetPoint("RIGHT", row.count, "LEFT", -20, 0)
        row.name:SetText(GroupName(data.group))
        row.levels:SetText("")
        row.count:SetText(("%d / %d"):format(GroupCount(data.group)))
        row.selected:Hide()
        return
    end
    local _, _, uiMap, journal = Lore.Zone(data.zone)
    DrawArt(row.art, uiMap, width, height, true, journal)
    row.arrow:Hide()
    row.ring:Show()
    local done, total = Lore.Count(data.zone)
    local closed = total > 0 and done >= total
    local color = closed and COLORS.gold or COLORS.zone
    row.ring:Paint(color, 0.35)
    row.ring:SetGlow(closed)
    row.ring:SetProgress(Share(done, total))
    row.pin:SetShown(Journal:IsPinned(data.zone) and not data.pinned)
    row.name:SetFontObject(closed and "GameFontNormal" or "GameFontHighlight")
    row.name:SetPoint("TOPLEFT", 36, -3)
    row.name:SetPoint("RIGHT", row.count, "LEFT", -20, 0)
    row.name:SetText((Lore.Zone(data.zone)))
    row.levels:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -1)
    row.levels:SetText(Levels(data.zone))
    row.count:SetText(("%d / %d"):format(done, total))
    row.selected:SetShown(page == data.zone)
end

function Journal:FillNav()
    local provider = CreateDataProvider()
    local pinned = PinnedZones()
    if #pinned > 0 then
        provider:Insert({ group = PINNED })
        if not ns.db.collapsed[PINNED] then
            for _, zone in ipairs(pinned) do provider:Insert({ zone = zone, pinned = true }) end
        end
    end
    for group in ipairs(Lore.Groups()) do
        local list = ZonesOf(group)
        if #list > 0 then
            provider:Insert({ group = group })
            if not ns.db.collapsed[group] then
                for _, zone in ipairs(list) do provider:Insert({ zone = zone }) end
            end
        end
    end
    frame.navList:SetDataProvider(provider, ScrollBoxConstants.RetainScrollPosition)
    ns.Pad.Mark()
    local done, total = Lore.TotalCount()
    frame.overview.count:SetText(("%d / %d  ·  %s"):format(done, total, Percent(done, total)))
    frame.overview.selected:SetShown(page == "overview")
    local rings = frame.overview.rings
    rings[1]:SetProgress(Share(Lore.GroupCount(1)))
    rings[2]:SetProgress(Share(Lore.GroupCount(2)))
    rings[3]:SetProgress(Share(done, total))
end

local function MarkSelected()
    frame.navList:ForEachFrame(function(row, data)
        if row.selected and data.zone then row.selected:SetShown(page == data.zone) end
    end)
    frame.overview.selected:SetShown(page == "overview")
end

------------------------------------------------------------------------------
-- The header: rings over the map art
------------------------------------------------------------------------------

local function Legend(index, color, text)
    local line = frame.legend[index]
    line.dot:SetVertexColor(color[1], color[2], color[3])
    line.text:SetText(text)
    line:Show()
end

local function SetHeader(title, subtitle, uiMap, rings, summary, journal)
    local header = frame.header
    header.title:SetText(title)
    header.subtitle:SetText(subtitle or "")
    local w = header:GetWidth()
    DrawArt(header.art, uiMap or 947, w > 0 and w or (ns.db.size[1] - NAV_W - 20), HEADER_H, true, journal) -- 947: Azeroth
    local key = type(page) == "number" and page or "overview" -- the search shows the overview's rings
    local fresh = headerPage ~= key
    headerPage = key
    for i, ring in ipairs(frame.rings) do
        local r = rings[i]
        if fresh then ring:Draw(0) end
        ring:SetProgress(Share(r[1], r[2]), true)
    end
    local inner = rings[3]
    frame.rings[3].label:SetText(Percent(inner[1], inner[2]))
    header.summary:SetText(summary or "")
    local today, week = ns.TurnInCounts()
    header.days:SetText(("Today %d  ·  this week %d"):format(today, week))
end

------------------------------------------------------------------------------
-- The quest list
------------------------------------------------------------------------------

local function PeopleLine(row)
    local starter, finisher = row[F.starter], row[F.finisher]
    local parts = {}
    if starter then
        local kind = row[F.starterKind]
        parts[#parts + 1] = (kind == 3 and "Starts from %s" or kind == 2 and "Starts at %s" or "Given by %s"):format(starter)
    end
    if finisher and finisher ~= starter then parts[#parts + 1] = ("turn in to %s"):format(finisher) end
    return table.concat(parts, ", ")
end

local function NamesWithTicks(list)
    local parts = {}
    for _, id in ipairs(list) do
        local s = Lore.StatusOf(id)
        local done = s == Lore.DONE and (Lore.IsPassed(id) and "|cff9a9a9a%s (skipped)|r" or "|cff8cc78c%s (done)|r")
        parts[#parts + 1] = (done or "%s"):format(Lore.Name(id) or "?")
    end
    return table.concat(parts, ", ")
end

-- The opened quest's text: objective, story, turn-in text, people and chain.
local function Body(id)
    if bodies[id] then return bodies[id] end
    local row = Lore.Row(id)
    local saved = ns.db.text[id]
    local lines = {}
    local objective = (saved and saved[2]) or Fill(row[F.objective])
    if objective then lines[#lines + 1] = "|cffffd100Objective|r  " .. objective end
    if saved and saved[1] then
        lines[#lines + 1] = "|cffe8dcc0" .. saved[1] .. "|r"
    else
        lines[#lines + 1] = "|cff8a8a8aYou haven't read this one yet. Its story is kept here once you open it at the quest giver.|r"
    end
    if saved and saved[3] then lines[#lines + 1] = "|cffffd100On turning in|r  |cffe8dcc0" .. saved[3] .. "|r" end
    local people = PeopleLine(row)
    if people ~= "" then lines[#lines + 1] = people .. "." end
    local needs = {}
    for _, field in ipairs({ F.needsAll, F.needsAny }) do
        for _, need in ipairs(row[field] or {}) do needs[#needs + 1] = need end
    end
    if #needs > 0 then lines[#lines + 1] = "|cffffd100Needs first|r  " .. NamesWithTicks(needs) end
    if row[F.breadcrumbFor] then lines[#lines + 1] = "|cffffd100Leads to|r  " .. NamesWithTicks({ row[F.breadcrumbFor] }) end
    if Lore.IsLearned(id) then lines[#lines + 1] = "|cff8a8a8aLearned in game: not in Lorebound's list.|r" end
    bodies[id] = table.concat(lines, "\n\n")
    return bodies[id]
end

local function Summary(id, s, why)
    if why then return why end
    local row = Lore.Row(id)
    local objective = Fill(row[F.objective])
    if objective then return objective end
    local people = PeopleLine(row)
    return people ~= "" and people or ""
end

-- Shared with the quest page (Quest.lua).
Journal.SetStatusIcon, Journal.Summary, Journal.Fill, Journal.TITLE_FONT = SetStatusIcon, Summary, Fill, TITLE_FONT

local function BodyWidth()
    return math.max(240, frame.questList:GetWidth() - 52)
end

-- Height of an opened quest, from a hidden string set to the same width and text.
local function ExpandedHeight(id)
    local measure = frame.measure
    measure:SetWidth(BodyWidth())
    measure:SetText(Body(id))
    return QUEST_H + measure:GetStringHeight() + 14 + 30 -- and its buttons: the quest page, the giver
end

function Journal:ToggleQuest(id)
    expanded[id] = not expanded[id] or nil
    self:FillQuests(true)
end

function Journal:IsExpanded(id)
    return expanded[id] == true
end

local function QuestRowClick(row)
    local id = row.data and row.data.id
    if id then Journal:ToggleQuest(id) end
end

local function ShowGiverClick(button)
    local id = button:GetParent().data.id
    Journal:ShowMap(id)
end

local function QuestPageClick(button)
    ns.QuestPage.Show(button:GetParent().data.id)
end

local function InitQuestRow(row, data)
    if not row.built then
        row.built = true
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        row.head = row:CreateFontString(nil, "OVERLAY", "GameFontNormalMed3")
        row.head:SetPoint("LEFT", 10, -2)
        row.head:SetJustifyH("LEFT")
        row.rule = row:CreateTexture(nil, "ARTWORK")
        row.rule:SetHeight(1)
        row.rule:SetPoint("LEFT", row.head, "RIGHT", 8, 0)
        row.rule:SetPoint("RIGHT", -10, -2)
        row.rule:SetColorTexture(1, 0.82, 0.25, 0.25)
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(16, 16)
        row.icon:SetPoint("TOPLEFT", 10, -6)
        row.level = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.level:SetPoint("TOPLEFT", 32, -8)
        row.level:SetWidth(28)
        row.level:SetJustifyH("LEFT")
        row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        row.name:SetPoint("TOPLEFT", 60, -7)
        row.name:SetJustifyH("LEFT")
        row.name:SetWordWrap(false)
        row.where = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.where:SetPoint("TOPRIGHT", -10, -8)
        row.where:SetJustifyH("RIGHT")
        row.name:SetPoint("RIGHT", row.where, "LEFT", -8, 0)
        row.line = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.line:SetPoint("TOPLEFT", 60, -25)
        row.line:SetPoint("TOPRIGHT", -10, -25)
        row.line:SetJustifyH("LEFT")
        row.line:SetWordWrap(false)
        row.body = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.body:SetPoint("TOPLEFT", 40, -QUEST_H)
        row.body:SetJustifyH("LEFT")
        row.body:SetJustifyV("TOP")
        row.body:SetSpacing(2)
        row.giver = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        row.giver:SetSize(150, 22)
        row.giver:SetText("Show quest giver")
        row.giver:SetPoint("BOTTOMLEFT", 196, 6)
        row.page = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        row.page:SetSize(150, 22)
        row.page:SetText("Quest page")
        row.page:SetPoint("BOTTOMLEFT", 38, 6)
        row.page:SetScript("OnClick", QuestPageClick)
        row.giver:SetScript("OnClick", ShowGiverClick)
        row.back = row:CreateTexture(nil, "BACKGROUND")
        row.back:SetAllPoints()
        row.back:SetColorTexture(1, 1, 1, 0.04)
        row.parts = { row.icon, row.level, row.name, row.where, row.line }
        row:SetScript("OnClick", QuestRowClick)
    end
    row.data = data
    local isHead = data.section ~= nil or data.chain ~= nil
    row.head:SetShown(isHead)
    row.rule:SetShown(data.section ~= nil)
    for _, part in ipairs(row.parts) do part:SetShown(not isHead) end
    row:EnableMouse(not isHead)
    if data.chain then -- a chain's heading: its first quest's name, then its steps below
        row.head:SetFontObject("GameFontHighlight")
        row.head:SetText(("%s  |cff9a9a9aa chain of %d quests%s|r"):format(data.label, data.of,
            data.here < data.of and (", %d here"):format(data.here) or ""))
        row.body:Hide()
        row.giver:Hide()
        row.page:Hide()
        row.back:Hide()
        return
    end
    if isHead then
        row.head:SetFontObject("GameFontNormalMed3")
        row.head:SetText(data.count > 0 and ("%s  |cff9a9a9a%d|r"):format(data.label, data.count) or data.label)
        row.body:Hide()
        row.giver:Hide()
        row.page:Hide()
        row.back:Hide()
        return
    end
    local id = data.id
    local quest = Lore.Row(id)
    local s, why = Lore.StatusOf(id)
    SetStatusIcon(row.icon, s)
    local passed = s == Lore.DONE and Lore.IsPassed(id) -- skipped on the way to a later quest: counted done
    if passed then row.icon:SetAlpha(0.55) end
    local level = quest[F.level]
    row.level:SetText(level and level > 0 and ("[%d]"):format(level) or "")
    row.name:SetText((data.step and ("|cff9a9a9aPart %d|r  "):format(data.step) or "") .. (quest[F.name] or ("Quest " .. id)))
    row.name:SetTextColor(QuestColor(id, s))
    if data.showZone then
        row.where:SetText((Lore.Zone(quest[F.zone])))
    else
        row.where:SetText(quest[F.starter] or "")
    end
    row.line:SetText(Summary(id, s, why))
    if s == Lore.LOCKED then
        row.line:SetTextColor(0.85, 0.45, 0.45)
    elseif s == Lore.LATER or passed then
        row.line:SetTextColor(0.62, 0.62, 0.62)
    else
        row.line:SetTextColor(0.85, 0.85, 0.85)
    end
    local open = expanded[id]
    row.back:SetShown(open and true or false)
    row.body:SetShown(open and true or false)
    row.line:SetShown(not open or why ~= nil)
    if open then
        row.body:SetWidth(BodyWidth())
        row.body:SetText(Body(id))
    end
    row.giver:SetShown(open and quest[F.map] ~= nil)
    row.page:SetShown(open and true or false)
end

local function SortQuests(list)
    table.sort(list, function(a, b)
        local ra, rb = Lore.Row(a), Lore.Row(b)
        local la, lb = ra[F.level] or 0, rb[F.level] or 0
        if la ~= lb then return la < lb end
        local na, nb = ra[F.name] or "", rb[F.name] or ""
        if na ~= nb then return na < nb end
        return a < b
    end)
    return list
end

-- A section's quests, each chain's steps gathered under a heading at its first one (two or more of them here).
local function InsertQuests(provider, list)
    local members = {}
    for _, id in ipairs(list) do
        local chain = Lore.Row(id)[F.chain]
        if chain then
            members[chain[1]] = members[chain[1]] or {}
            table.insert(members[chain[1]], id)
        end
    end
    local placed = {}
    for _, id in ipairs(list) do
        local chain = Lore.Row(id)[F.chain]
        local steps = chain and members[chain[1]]
        if steps and #steps > 1 then
            if not placed[chain[1]] then
                placed[chain[1]] = true
                table.sort(steps, function(a, b) return Lore.Row(a)[F.chain][2] < Lore.Row(b)[F.chain][2] end)
                provider:Insert({ chain = chain[1], label = Lore.Row(steps[1])[F.name] or "", of = chain[3], here = #steps })
                for _, step in ipairs(steps) do provider:Insert({ id = step, step = Lore.Row(step)[F.chain][2] }) end
            end
        else
            provider:Insert({ id = id })
        end
    end
end

-- The list for the page shown: a zone's quests in sections, or the search's results.
function Journal:FillQuests(keepScroll)
    local provider = CreateDataProvider()
    if page == "search" then
        for i = 1, math.min(#found, 200) do provider:Insert({ id = found[i], showZone = true }) end
    elseif type(page) == "number" then
        local byStatus = {}
        for _, id in ipairs(Lore.ZoneQuests(page)) do
            local s = Lore.StatusOf(id)
            if s ~= Lore.HIDDEN then
                byStatus[s] = byStatus[s] or {}
                table.insert(byStatus[s], id)
            end
        end
        local shown = SHOWN_BY_FILTER[ns.db.filter] or SHOWN_BY_FILTER.todo
        for _, section in ipairs(SECTIONS) do
            local s, label = section[1], section[2]
            local list = byStatus[s]
            local wanted = shown[s] or (s == Lore.LOCKED and ns.db.showLocked)
            if list and wanted then
                provider:Insert({ section = s, label = label, count = #list })
                InsertQuests(provider, SortQuests(list))
            end
        end
        if provider:GetSize() == 0 then
            provider:Insert({ section = 0, label = ns.db.filter == "done" and "Nothing done here yet" or "Nothing left to do here", count = 0 })
        end
        self:UpdateFilters(byStatus)
    end
    frame.questList:SetDataProvider(provider, keepScroll and ScrollBoxConstants.RetainScrollPosition or nil)
    ns.Pad.Mark()
end

function Journal:SetFilter(key)
    ns.db.filter = key
    self:FillQuests()
end

function Journal:SetLocked(on)
    ns.db.showLocked = on
    self:FillQuests()
end

function Journal:Page()
    return page
end

function Journal:UpdateFilters(byStatus)
    local function Count(...)
        local n = 0
        for i = 1, select("#", ...) do
            local list = byStatus[select(i, ...)]
            n = n + (list and #list or 0)
        end
        return n
    end
    local todo = Count(Lore.ACTIVE, Lore.AVAILABLE, Lore.LATER)
    local done = Count(Lore.DONE)
    local counts = { todo = todo, done = done, all = todo + done }
    for key, button in pairs(frame.filters) do
        button.text:SetText(("%s  |cff9a9a9a%d|r"):format(button.label, counts[key]))
        local on = ns.db.filter == key
        button.text:SetTextColor(on and 1 or 0.75, on and 0.82 or 0.75, on and 0 or 0.75)
        button.line:SetShown(on)
    end
    local locked = Count(Lore.LOCKED)
    frame.locked.text:SetText(("Locked out  |cff9a9a9a%d|r"):format(locked))
    frame.locked:SetChecked(ns.db.showLocked)
end

------------------------------------------------------------------------------
-- The overview: the badge case
------------------------------------------------------------------------------

local SPECIALS = { { "group", 1 }, { "group", 2 }, { "seal" } } -- the crests and the seal, atop the badges

local function MedalClick(medal, button)
    if button == "RightButton" then
        if medal.zone then Journal:TogglePin(medal.zone) end
    else
        Journal:Inspect(medal.special or { "zone", medal.zone })
    end
end

local function MedalEnter(medal)
    if medal.zone then
        ZoneTooltip(medal, medal.zone)
        return
    end
    if not medal.special then return end
    local kind, value = medal.special[1], medal.special[2]
    GameTooltip:SetOwner(medal, "ANCHOR_RIGHT")
    local name = ns.Badge.Name(kind, value)
    GameTooltip:SetText(name:sub(1, 1):upper() .. name:sub(2))
    local earned = ns.Badge.Earned(kind, value)
    if earned then
        GameTooltip:AddLine(("Earned %s"):format(date("%d %b %Y", earned)), 1, 0.82, 0.25)
    else
        local done, total
        if kind == "group" then done, total = Lore.GroupCount(value) else done, total = Lore.TotalCount() end
        GameTooltip:AddLine(("%d / %d quests: every one for this %s."):format(done, total,
            kind == "group" and "continent" or "journal"), 1, 1, 1)
    end
    GameTooltip:Show()
end

local function Medal(row, i)
    local medal = row.medals[i]
    if medal then return medal end
    medal = CreateFrame("Button", nil, row)
    medal:SetSize(MEDAL_W - 6, WALL_ROW_H - 6)
    medal:SetPoint("TOPLEFT", 8 + (i - 1) * MEDAL_W, -2)
    medal:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    medal:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    medal.badge = ns.NewBadge(medal, 62)
    medal.badge:SetPoint("TOP", 0, -2)
    medal.badge:EnableMouse(false)
    medal.name = medal:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    medal.name:SetPoint("TOP", medal.badge, "BOTTOM", 0, -4)
    medal.name:SetWidth(MEDAL_W - 8)
    medal.name:SetMaxLines(2)
    medal:SetScript("OnClick", MedalClick)
    medal:SetScript("OnEnter", MedalEnter)
    medal:SetScript("OnLeave", GameTooltip_Hide)
    row.medals[i] = medal
    return medal
end

local function InitWallRow(row, data)
    if not row.built then
        row.built = true
        row.medals = {}
        row.head = row:CreateFontString(nil, "OVERLAY", "GameFontNormalMed3")
        row.head:SetPoint("BOTTOMLEFT", 10, 6)
        row.count = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.count:SetPoint("LEFT", row.head, "RIGHT", 10, 0)
        row.rule = row:CreateTexture(nil, "ARTWORK")
        row.rule:SetHeight(1)
        row.rule:SetPoint("LEFT", row.count, "RIGHT", 8, 0)
        row.rule:SetPoint("RIGHT", -10, 0)
        row.rule:SetColorTexture(1, 0.82, 0.25, 0.25)
    end
    local isHead = data.group ~= nil or data.title ~= nil
    row.head:SetShown(isHead)
    row.count:SetShown(isHead)
    row.rule:SetShown(isHead)
    for _, medal in ipairs(row.medals) do
        medal:Hide()
        medal.zone, medal.special = nil, nil
    end
    if isHead then
        if data.title then
            row.head:SetText(data.title)
            row.count:SetText(data.count or "")
        else
            row.head:SetText(GroupName(data.group))
            local done, total = GroupCount(data.group)
            row.count:SetText(("%d / %d  ·  %s"):format(done, total, Percent(done, total)))
        end
        return
    end
    for i, entry in ipairs(data.zones or data.specials) do
        local medal = Medal(row, i)
        local name, lit
        if data.specials then
            medal.special = entry
            lit = medal.badge:Set(entry[1], entry[2])
            name = ns.Badge.Name(entry[1], entry[2]):gsub("^the ", "")
        else
            medal.zone = entry
            lit = medal.badge:Set("zone", entry)
            name = (Lore.Zone(entry))
        end
        medal.name:SetText(name)
        medal.name:SetTextColor(lit and 1 or 0.9, lit and 0.82 or 0.9, lit and 0.25 or 0.9)
        medal:Show()
    end
end

function Journal:FillWall(keepScroll)
    local provider = CreateDataProvider()
    local width = frame.wallList:GetWidth()
    if not width or width < MEDAL_W then width = ns.db.size[1] - NAV_W - 50 end -- not laid out yet (first open)
    local perRow = math.max(1, math.floor((width - 8) / MEDAL_W))
    local order = {} -- the badge case in order, for the inspector's arrows
    local earned, all = ns.Badge.Count()
    provider:Insert({ title = "Crests", count = ("%d of %d zone badges"):format(earned, all) })
    provider:Insert({ specials = SPECIALS })
    for _, special in ipairs(SPECIALS) do order[#order + 1] = special end
    local function Add(group)
        local list = ZonesOf(group)
        if #list == 0 then return end
        if group ~= PINNED then
            for _, zone in ipairs(list) do order[#order + 1] = { "zone", zone } end
        end
        provider:Insert({ group = group })
        for first = 1, #list, perRow do
            provider:Insert({ zones = { unpack(list, first, math.min(#list, first + perRow - 1)) } })
        end
    end
    Add(PINNED)
    for group in ipairs(Lore.Groups()) do Add(group) end
    frame.badgeOrder = order
    frame.wallList:SetDataProvider(provider, keepScroll and ScrollBoxConstants.RetainScrollPosition or nil)
    if frame.inspect and frame.inspect:IsShown() then Journal:Inspect(frame.inspect.entry, true) end -- fresh numbers
    ns.Pad.Mark()
end

------------------------------------------------------------------------------
-- Pages
------------------------------------------------------------------------------

-- keepSearch: the search box itself asked (leaving the search as you delete letters keeps your text).
function Journal:ShowPage(target, keepSearch)
    if target ~= "search" and not keepSearch and frame.search:GetText() ~= "" then
        searchText = ""
        frame.search:SetText("")
    end
    if target and target ~= "search" then lastPage = target end
    ns.Pad.PageChanging()
    page = target or page
    frame.map:Hide()
    ns.QuestPage.Hide()
    if frame.inspect then frame.inspect:Hide() end
    MarkSelected()
    self:Draw(false)
    ns.Pad.Follow()
end

-- The page shown, drawn again: from the top when it's just been opened, else where it was scrolled to.
function Journal:Draw(keepScroll)
    wipe(bodies)
    local listing = type(page) == "number" or page == "search"
    frame.questList:SetShown(listing)
    frame.questBar:SetShown(listing)
    frame.wallList:SetShown(not listing)
    frame.wallBar:SetShown(not listing)
    frame.filterBar:SetShown(type(page) == "number")
    frame.pinButton:SetShown(type(page) == "number")
    frame.exportButton:SetShown(page == "overview")
    local pending = page == "overview" and #ns.Share.Pending() or 0
    frame.shareButton:SetShown(pending > 0)
    if pending > 0 then
        frame.shareButton:SetText(("Share %d new quest%s"):format(pending, pending == 1 and "" or "s"))
    end
    if type(page) == "number" then
        local pinned = Journal:IsPinned(page)
        frame.pinButton.icon:SetVertexColor(pinned and 1 or 0.6, pinned and 0.82 or 0.6, pinned and 0.25 or 0.6)
    end
    frame.questList:SetPoint("TOPLEFT", frame.header, "BOTTOMLEFT", 0, type(page) == "number" and -34 or -6)

    local allDone, allTotal = Lore.TotalCount()
    if type(page) == "number" then
        local zone = page
        local name, group, uiMap, journal = Lore.Zone(zone)
        local done, total, locked = Lore.Count(zone)
        local groupDone, groupTotal = Lore.GroupCount(group)
        local groupName = Lore.Groups()[group] or "Other"
        Legend(1, COLORS.zone, ("%s  |cffffffff%d / %d|r"):format(name, done, total))
        Legend(2, COLORS.group, ("%s  |cffffffff%d / %d|r"):format(groupName, groupDone, groupTotal))
        Legend(3, COLORS.total, ("Lorebound  |cffffffff%d / %d|r"):format(allDone, allTotal))
        local summary
        if total > 0 and done >= total then
            summary = "|cffffd040Complete!|r"
        else
            summary = ("%d to go"):format(total - done)
        end
        if locked > 0 then summary = summary .. ("  ·  |cffd97373%d locked out|r"):format(locked) end
        local levels = Levels(zone)
        SetHeader(name, groupName .. (levels ~= "" and ("  ·  " .. levels) or ""), uiMap,
            { { done, total }, { groupDone, groupTotal }, { allDone, allTotal } }, summary, journal)
        self:FillQuests(keepScroll)
    else
        local ekDone, ekTotal = Lore.GroupCount(1)
        local kalDone, kalTotal = Lore.GroupCount(2)
        Legend(1, COLORS.zone, ("Eastern Kingdoms  |cffffffff%d / %d|r"):format(ekDone, ekTotal))
        Legend(2, COLORS.group, ("Kalimdor  |cffffffff%d / %d|r"):format(kalDone, kalTotal))
        Legend(3, COLORS.total, ("Lorebound  |cffffffff%d / %d|r"):format(allDone, allTotal))
        local title, subtitle = "Lorebound", "Every zone's quests: close the rings."
        if page == "search" then
            SortQuests(Lore.Search(searchText, found))
            local shown = #found > 200 and ("%d (the first 200 shown)"):format(#found) or tostring(#found)
            title, subtitle = "Search", ('"%s": %s quest%s'):format(searchText, shown, #found == 1 and "" or "s")
        end
        SetHeader(title, subtitle, nil, { { ekDone, ekTotal }, { kalDone, kalTotal }, { allDone, allTotal } },
            ("%d to go"):format(allTotal - allDone))
        if page == "search" then self:FillQuests(keepScroll) else self:FillWall(keepScroll) end
    end
end

------------------------------------------------------------------------------
-- Inspecting a badge (the badge case's): large, with a band of light, and what it stands for
------------------------------------------------------------------------------

local INSPECT_SIZE = 230

local function BuildInspect()
    local content = frame.map:GetParent()
    local view = CreateFrame("Frame", nil, content)
    view:SetPoint("TOPLEFT", 4, -4)
    view:SetPoint("BOTTOMRIGHT", -4, 4)
    view:SetFrameLevel(content:GetFrameLevel() + 45)
    view:EnableMouse(true)
    view:EnableMouseWheel(true)
    view:SetScript("OnMouseWheel", function() end) -- not the wall underneath
    view:Hide()
    local back = view:CreateTexture(nil, "BACKGROUND", nil, -8)
    back:SetAllPoints()
    back:SetColorTexture(0.02, 0.02, 0.03, 0.97)
    local halo = view:CreateTexture(nil, "BACKGROUND", nil, -7)
    halo:SetTexture(MEDIA .. "Halo") -- a soft light fading from the middle (Glow is a ring's halo)
    halo:SetBlendMode("ADD")
    halo:SetSize(INSPECT_SIZE * 2, INSPECT_SIZE * 2)
    halo:SetVertexColor(1, 0.78, 0.32)
    local breathe = halo:CreateAnimationGroup()
    breathe:SetLooping("BOUNCE")
    local pulse = breathe:CreateAnimation("Alpha")
    pulse:SetFromAlpha(0.35)
    pulse:SetToAlpha(0.6)
    pulse:SetDuration(2.2)
    pulse:SetSmoothing("IN_OUT")
    view.halo, view.breathe = halo, breathe

    view.badge = ns.NewBadge(view, INSPECT_SIZE)
    view.badge:SetPoint("LEFT", 60, 10)
    view.badge:SetFrameLevel(view:GetFrameLevel() + 2)
    view.badge:EnableShine()
    view.badge:EnableTilt(view)
    halo:SetPoint("CENTER", view.badge, "CENTER")

    -- The opening: a ring fills to the badge's share, swells and fades, and the badge springs out of it.
    local ring = ns.NewRing(view, INSPECT_SIZE, "Ring3", COLORS.zone)
    ring:SetPoint("CENTER", view.badge, "CENTER")
    ring:SetFrameLevel(view.badge:GetFrameLevel() + 6)
    ring:EnableMouse(false)
    ring:Hide()
    local pop = ring:CreateAnimationGroup()
    local swell = pop:CreateAnimation("Scale")
    swell:SetScaleFrom(1, 1)
    swell:SetScaleTo(1.35, 1.35)
    swell:SetDuration(0.3)
    swell:SetSmoothing("OUT")
    local vanish = pop:CreateAnimation("Alpha")
    vanish:SetFromAlpha(1)
    vanish:SetToAlpha(0)
    vanish:SetDuration(0.3)
    pop:SetScript("OnFinished", function() ring:Hide() end)
    local spring = view.badge:CreateAnimationGroup()
    local grow = spring:CreateAnimation("Scale")
    grow:SetScaleFrom(0.45, 0.45)
    grow:SetScaleTo(1, 1)
    grow:SetDuration(0.5)
    grow:SetSmoothing("OUT")
    local appear = spring:CreateAnimation("Alpha")
    appear:SetFromAlpha(0)
    appear:SetToAlpha(1)
    appear:SetDuration(0.25)
    local flash = view:CreateTexture(nil, "OVERLAY", nil, 7)
    flash:SetTexture(MEDIA .. "Halo")
    flash:SetBlendMode("ADD")
    flash:SetSize(INSPECT_SIZE * 1.8, INSPECT_SIZE * 1.8)
    flash:SetPoint("CENTER", view.badge, "CENTER")
    flash:SetVertexColor(1, 0.85, 0.4)
    flash:SetAlpha(0)
    local burst = flash:CreateAnimationGroup()
    local bloom = burst:CreateAnimation("Scale")
    bloom:SetScaleFrom(0.5, 0.5)
    bloom:SetScaleTo(1.3, 1.3)
    bloom:SetDuration(0.7)
    bloom:SetSmoothing("OUT")
    local fade = burst:CreateAnimation("Alpha")
    fade:SetFromAlpha(0.8)
    fade:SetToAlpha(0)
    fade:SetDuration(0.7)
    view.ring, view.pop, view.spring, view.burst = ring, pop, spring, burst

    view.title = view:CreateFontString(nil, "OVERLAY", TITLE_FONT)
    view.title:SetPoint("TOPLEFT", view.badge, "TOPRIGHT", 40, -10)
    view.title:SetPoint("RIGHT", view, "RIGHT", -24, 0) -- its width follows the window's
    view.title:SetJustifyH("LEFT")
    view.title:SetTextColor(1, 0.82, 0.25)
    view.when = view:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    view.when:SetPoint("TOPLEFT", view.title, "BOTTOMLEFT", 0, -10)
    view.what = view:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    view.what:SetPoint("TOPLEFT", view.when, "BOTTOMLEFT", 0, -16)
    view.what:SetPoint("RIGHT", view, "RIGHT", -24, 0)
    view.what:SetJustifyH("LEFT")
    view.what:SetSpacing(4)

    local function Button(label, width)
        local button = CreateFrame("Button", nil, view, "UIPanelButtonTemplate")
        button:SetSize(width, 24)
        button:SetText(label)
        return button
    end
    view.prev = Button("<", 40)
    view.prev:SetPoint("BOTTOMLEFT", 16, 40)
    view.prev:SetScript("OnClick", function() Journal:InspectStep(-1) end)
    view.next = Button(">", 40)
    view.next:SetPoint("LEFT", view.prev, "RIGHT", 6, 0)
    view.next:SetScript("OnClick", function() Journal:InspectStep(1) end)
    view.open = Button("Open zone", 120)
    view.open:SetPoint("BOTTOMRIGHT", -16, 40)
    view.open:SetScript("OnClick", function()
        local entry = view.entry
        if entry and entry[1] == "zone" then Journal:ShowPage(entry[2]) end
    end)
    view.close = CreateFrame("Button", nil, view, "UIPanelCloseButton")
    view.close:SetPoint("TOPRIGHT", -4, -4)
    view.close:SetScript("OnClick", function() view:Hide() end)
    view.hint = view:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    view.hint:SetPoint("LEFT", view.next, "RIGHT", 12, 0)
    view.hint:SetPoint("RIGHT", view.open, "LEFT", -12, 0)
    view.hint:SetWordWrap(true)
    view:SetScript("OnHide", function()
        breathe:Stop()
        ring:SetScript("OnUpdate", nil)
        ring.onDone = nil
        ns.Pad.Mark()
    end)
    return view
end

local RING_COLORS = { zone = COLORS.zone, group = COLORS.group, seal = COLORS.total }

-- The opening, from an empty ring: it fills to the badge's share (all the way, gold, for one earned),
-- then pops and the badge springs out of it.
local function PlayOpening(view, kind, share, earned)
    local ring, badge = view.ring, view.badge
    view.pop:Stop()
    view.spring:Stop()
    view.burst:Stop()
    badge:SetAlpha(0)
    ring:Paint(earned and COLORS.gold or RING_COLORS[kind], 0.3)
    ring:SetGlow(false)
    ring:SetProgress(0)
    ring:SetAlpha(1)
    ring:Show()
    ring:SetProgress(earned and 1 or share, true, function()
        if earned then
            ring:SetGlow(true)
            view.burst:Play()
            if ns.db.sound then -- the turn-in's fanfare (Toast.lua): a zone's, or the bigger one for a crest or the Seal
                PlaySound(kind == "zone" and SOUNDKIT.UI_WORLDQUEST_COMPLETE or SOUNDKIT.UI_LEGENDARY_LOOT_TOAST)
            end
        end
        view.pop:Play()
        badge:SetAlpha(1)
        view.spring:Play()
    end)
end

local function DateText(at)
    return at and date("%d %b %Y", at) or nil
end

-- entry: { "zone", zone }, { "group", 1 or 2 } or { "seal" }. quiet: fresh numbers for the badge already
-- shown, without its opening again.
function Journal:Inspect(entry, quiet)
    if not entry then return end
    frame.inspect = frame.inspect or BuildInspect()
    local view = frame.inspect
    view.entry = entry
    view.index = nil
    for i, e in ipairs(frame.badgeOrder or {}) do
        if e[1] == entry[1] and e[2] == entry[2] then view.index = i end
    end
    local kind, value = entry[1], entry[2]
    local earnedNow = view.badge:Set(kind, value)
    view.badge.label:SetText("") -- the text beside it says how far along
    local earnedAt = ns.Badge.Earned(kind, value)
    local done, total, locked, first, last = ns.Badge.Stats(kind, value)
    local name = ns.Badge.Name(kind, value):gsub("^the ", "")
    view.title:SetText(name)
    if earnedNow or earnedAt then
        view.when:SetText(earnedAt and ("Earned " .. DateText(earnedAt)) or "Earned")
        view.when:SetTextColor(1, 0.82, 0.25)
        view.breathe:Play()
        view.halo:Show()
        view.badge.shine:Show()
    else
        view.badge.shine:Hide()
        view.when:SetText(("Not earned yet: %d to go"):format(math.max(0, total - done)))
        view.when:SetTextColor(0.8, 0.8, 0.8)
        view.breathe:Stop()
        view.halo:Hide()
    end
    local lines = {}
    if kind == "zone" then
        local zoneName, group = Lore.Zone(value)
        local levels = Levels(value)
        lines[#lines + 1] = ("%s, %s%s"):format(zoneName, Lore.Groups()[group] or "Other", levels ~= "" and (", " .. levels:lower()) or "")
    elseif kind == "group" then
        lines[#lines + 1] = ("Every quest in %s's zones"):format(Lore.Groups()[value] or "?")
    else
        lines[#lines + 1] = "Every quest Lorebound counts"
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = ("|cffffd100Quests|r  %d / %d  (%s)"):format(done, total, Percent(done, total))
    if locked > 0 then lines[#lines + 1] = ("|cffd97373Locked out|r  %d"):format(locked) end
    if first then lines[#lines + 1] = ("|cffffd100First quest here|r  %s"):format(DateText(first)) end
    if last and last ~= first then lines[#lines + 1] = ("|cffffd100Latest|r  %s"):format(DateText(last)) end
    view.what:SetText(table.concat(lines, "\n"))
    view.open:SetShown(kind == "zone")
    local count = #(frame.badgeOrder or {})
    view.prev:SetEnabled(count > 1)
    view.next:SetEnabled(count > 1)
    view.hint:SetText(ns.GamepadUI() and ("D-pad left/right: the next badge   %sB: close"):format(kind == "zone" and "A: open the zone   " or "") or "")
    view:Show()
    if not quiet then PlayOpening(view, kind, total > 0 and done / total or 0, earnedNow or earnedAt ~= nil) end
    ns.Pad.Mark()
end

function Journal:InspectStep(step)
    local view, order = frame.inspect, frame.badgeOrder
    if not (view and view:IsShown() and order and #order > 0) then return end
    local at -- where the shown badge is in the case now (it may have been redrawn)
    for i, e in ipairs(order) do
        if e[1] == view.entry[1] and e[2] == view.entry[2] then at = i end
    end
    local index = at and ((at - 1 + step) % #order + 1) or (step > 0 and 1 or #order)
    self:Inspect(order[index])
end

function Journal:Inspecting()
    return frame and frame.inspect and frame.inspect:IsShown() and frame.inspect.entry or nil
end

------------------------------------------------------------------------------
-- The quest giver on a map of the zone
------------------------------------------------------------------------------

function Journal:ShowMap(id)
    local row = Lore.Row(id)
    local uiMap, x, y = row and row[F.map], row and row[F.x], row and row[F.y]
    if not uiMap then return end
    local map = frame.map
    map.id = id
    map:Show()
    local w, h = map.art:GetWidth(), map.art:GetHeight()
    if not w or w <= 0 then w, h = map:GetWidth() - 20, map:GetHeight() - 66 end
    local mw, mh, ox, oy = DrawArt(map.art, uiMap, w, h, false)
    local info = C_Map.GetMapInfo(uiMap)
    local who = row[F.starter] or "Quest giver"
    map.title:SetText(("%s  |cff9a9a9a%s  %.1f, %.1f|r"):format(who, info and info.name or "", x, y))
    map.pin:ClearAllPoints()
    if mw then
        map.pin:SetPoint("CENTER", map.art, "TOPLEFT", ox + mw * x / 100, -(oy + mh * y / 100))
        map.pin:Show()
        map.pulse:Play()
    else
        map.pin:Hide()
    end
    -- You, if you're on this map (a read of where you are; nothing set).
    local here = mw and C_Map.GetPlayerMapPosition and C_Map.GetPlayerMapPosition(uiMap, "player")
    local px, py
    if here then
        -- A vector, or (as Forever hands some positions back) a plain { x, y }.
        local ok, a, b = pcall(function()
            if here.GetXY then return here:GetXY() end
            return here.x, here.y
        end)
        local secret = issecretvalue and ok and (issecretvalue(a) or issecretvalue(b))
        if ok and not secret and type(a) == "number" and type(b) == "number" and a > 0 and b > 0 then
            px, py = a, b
        end
    end
    map.you:SetShown(px ~= nil)
    map.youLabel:SetShown(px ~= nil)
    if px then
        map.you:ClearAllPoints()
        map.you:SetPoint("CENTER", map.art, "TOPLEFT", ox + mw * px, -(oy + mh * py))
    end
    if ns.GamepadUI() then
        -- A chat link can't be clicked with a controller: the map here is the way.
        map.hint:SetText(px and "The blue dot is you.  B closes." or "B closes.")
    else
        map.hint:SetText("A map pin link for it is in chat: click it to set the waypoint. Click here to close.")
        ns.ShowGiver(who, uiMap, x, y)
    end
end

------------------------------------------------------------------------------
-- Building the window
------------------------------------------------------------------------------

local function SavePoint()
    local point, _, relative, x, y = frame:GetPoint(1)
    ns.db.point = { point, relative, x, y }
end

-- Size, scale and place back to how they started.
function Journal:ResetWindow()
    ns.db.point = { unpack(ns.defaults.point) }
    ns.db.size = { unpack(ns.defaults.size) }
    ns.db.scale = ns.defaults.scale
    self:Place()
end

-- The largest scale the window fits the screen at, and the largest size at its scale.
local function FitScale()
    return math.min(MAX_SCALE, UIParent:GetWidth() / frame:GetWidth(), UIParent:GetHeight() / frame:GetHeight())
end

local function FitBounds()
    local scale = frame:GetScale()
    local maxW = math.max(MIN_W, math.min(MAX_W, UIParent:GetWidth() / scale))
    local maxH = math.max(MIN_H, math.min(MAX_H, UIParent:GetHeight() / scale))
    if frame.SetResizeBounds then
        frame:SetResizeBounds(MIN_W, MIN_H, maxW, maxH)
    else
        frame:SetMinResize(MIN_W, MIN_H)
        frame:SetMaxResize(maxW, maxH)
    end
end

-- The window's top left corner pinned where it is now, so it grows to the right and down.
local function PinTopLeft()
    local left, top = frame:GetLeft(), frame:GetTop()
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
end

-- The saved size, scale and place (a screen smaller than when they were saved shrinks them to fit).
function Journal:Place()
    if not frame then return end
    local p, size = ns.db.point, ns.db.size
    frame:SetScale(1)
    frame:SetSize(math.max(MIN_W, math.min(MAX_W, UIParent:GetWidth(), size[1] or 0)),
        math.max(MIN_H, math.min(MAX_H, UIParent:GetHeight(), size[2] or 0)))
    frame:SetScale(math.max(MIN_SCALE, math.min(FitScale(), ns.db.scale or 1)))
    FitBounds()
    frame:ClearAllPoints()
    frame:SetPoint(p[1] or "CENTER", UIParent, p[2] or "CENTER", p[3] or 0, p[4] or 0)
end

-- A new scale (never more than fits the screen), the window's top left corner staying where it is.
function Journal:SetScale(scale)
    scale = math.max(MIN_SCALE, math.min(FitScale(), scale))
    local old = frame:GetScale()
    if math.abs(scale - old) < 0.001 then return end
    local left, top = frame:GetLeft() * old, frame:GetTop() * old -- in UIParent's points
    frame:SetScale(scale)
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left / scale, top / scale)
    ns.db.scale = scale
    FitBounds()
    SavePoint()
end

-- The grip at the bottom right: dragged, the window grows and shows more (zones, quests, badges);
-- dragged with Shift held, everything in it grows instead.
local function ScaleToCursor(grip)
    local x, y = GetCursorPosition()
    local ui = UIParent:GetEffectiveScale()
    local scale = frame:GetScale()
    local left, top = frame:GetLeft() * scale, frame:GetTop() * scale
    local wide = (x / ui - left) / frame:GetWidth()
    local tall = (top - y / ui) / frame:GetHeight()
    local want = math.max(MIN_SCALE, math.min(FitScale(), math.max(wide, tall)))
    if math.abs(want - scale) > 0.005 then Journal:SetScale(want) end
end

local function StopGrip(grip, button)
    if not grip.held or (button and button ~= "LeftButton") then return end
    grip.held = false
    grip:SetScript("OnUpdate", nil)
    frame:StopMovingOrSizing()
    ns.db.size = { math.floor(frame:GetWidth() + 0.5), math.floor(frame:GetHeight() + 0.5) }
    SavePoint()
end

local function BuildGrip()
    local grip = CreateFrame("Button", nil, frame)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -3, 3)
    grip:SetFrameLevel(frame:GetFrameLevel() + 60)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" then return end
        self.held = true
        if IsShiftKeyDown() then
            self:SetScript("OnUpdate", ScaleToCursor)
        else
            PinTopLeft()
            FitBounds()
            frame:StartSizing("BOTTOMRIGHT")
        end
    end)
    grip:SetScript("OnMouseUp", StopGrip)
    grip:SetScript("OnHide", StopGrip)
    grip:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Resize")
        GameTooltip:AddLine("Drag: a bigger window, with more in view.", 1, 1, 1)
        GameTooltip:AddLine("Shift-drag: everything bigger.", 1, 1, 1)
        GameTooltip:Show()
    end)
    grip:SetScript("OnLeave", GameTooltip_Hide)
    return grip
end

local function MakeScrollList(parent)
    local list = CreateFrame("Frame", nil, parent, "WowScrollBoxList")
    local bar = CreateFrame("EventFrame", nil, parent, "MinimalScrollBar")
    bar:SetPoint("TOPLEFT", list, "TOPRIGHT", 6, 0)
    bar:SetPoint("BOTTOMLEFT", list, "BOTTOMRIGHT", 6, 0)
    local view = CreateScrollBoxListLinearView()
    return list, bar, view
end

local function Checkbox(parent, label, get, set)
    local box = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    box:SetSize(24, 24)
    box.text = box.text or box.Text or box:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    box.text:ClearAllPoints()
    box.text:SetPoint("LEFT", box, "RIGHT", 2, 0)
    box.text:SetFontObject("GameFontHighlightSmall")
    box.text:SetText(label)
    box:SetScript("OnShow", function(self) self:SetChecked(get()) end)
    box:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
    return box
end

local function BuildSettings()
    local panel = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    panel:SetSize(270, 176)
    panel:SetPoint("TOPRIGHT", frame.header, "TOPRIGHT", -8, -36)
    panel:SetFrameLevel(frame.header:GetFrameLevel() + 20)
    panel:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    panel:SetBackdropColor(0.04, 0.04, 0.06, 0.96)
    panel:SetBackdropBorderColor(0.4, 0.4, 0.45, 1)
    panel:EnableMouse(true)
    panel:Hide()
    local toasts = Checkbox(panel, "A toast for each quest turned in",
        function() return ns.db.toasts end, function(on) ns.db.toasts = on end)
    toasts:SetPoint("TOPLEFT", 10, -10)
    local sound = Checkbox(panel, "A fanfare when a ring closes",
        function() return ns.db.sound end, function(on) ns.db.sound = on end)
    sound:SetPoint("TOPLEFT", toasts, "BOTTOMLEFT", 0, -2)
    -- Pretend turn-ins, to see and hear them.
    local testToast = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    testToast:SetSize(98, 22)
    testToast:SetText("Test toast")
    testToast:SetPoint("TOPLEFT", sound, "BOTTOMLEFT", 4, -8)
    testToast:SetScript("OnClick", function() ns.Toast.Test(false) end)
    local testFanfare = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    testFanfare:SetSize(98, 22)
    testFanfare:SetText("Test fanfare")
    testFanfare:SetPoint("LEFT", testToast, "RIGHT", 4, 0)
    testFanfare:SetScript("OnClick", function() ns.Toast.Test(true) end)
    -- The scale here too, for a controller (the grip needs a mouse).
    local smaller = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    smaller:SetSize(98, 22)
    smaller:SetText("Smaller")
    smaller:SetPoint("TOPLEFT", testToast, "BOTTOMLEFT", 0, -6)
    smaller:SetScript("OnClick", function() Journal:SetScale(frame:GetScale() - SCALE_STEP) end)
    local bigger = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    bigger:SetSize(98, 22)
    bigger:SetText("Bigger")
    bigger:SetPoint("LEFT", smaller, "RIGHT", 4, 0)
    bigger:SetScript("OnClick", function() Journal:SetScale(frame:GetScale() + SCALE_STEP) end)
    local reset = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    reset:SetSize(200, 22)
    reset:SetText("Window back to normal")
    reset:SetPoint("TOPLEFT", smaller, "BOTTOMLEFT", 0, -6)
    reset:SetScript("OnClick", function() Journal:ResetWindow() end)
    panel.items = { toasts, sound, testToast, testFanfare, smaller, bigger, reset } -- in order, for the controller (Pad.lua)
    return panel
end

-- The settings panel, built on first use, shown or hidden (or flipped when on is nil).
function Journal:Settings(on)
    frame.settings = frame.settings or BuildSettings()
    if on == nil then on = not frame.settings:IsShown() end
    frame.settings:SetShown(on)
    return frame.settings
end

local function BuildHeader(content)
    local header = CreateFrame("Frame", nil, content)
    header:SetPoint("TOPLEFT", 4, -4)
    header:SetPoint("TOPRIGHT", -4, -4)
    header:SetHeight(HEADER_H)
    header:SetClipsChildren(true)
    local back = header:CreateTexture(nil, "BACKGROUND", nil, -8)
    back:SetAllPoints()
    back:SetColorTexture(0.05, 0.05, 0.07, 1)
    header.art = CreateFrame("Frame", nil, header)
    header.art:SetAllPoints()
    local shade = header.art:CreateTexture(nil, "BORDER")
    shade:SetAllPoints()
    Gradient(shade, "HORIZONTAL", 0.88, 0.45)
    local fadeOut = header.art:CreateTexture(nil, "BORDER", nil, 1)
    fadeOut:SetPoint("BOTTOMLEFT")
    fadeOut:SetPoint("BOTTOMRIGHT")
    fadeOut:SetHeight(70)
    Gradient(fadeOut, "VERTICAL", 0.9, 0)

    local rings = Triple(header, { 204, 150, 96 })
    rings[1]:SetPoint("LEFT", 20, 0)
    rings[1]:SetFrameLevel(header.art:GetFrameLevel() + 4)
    rings[2]:SetFrameLevel(rings[1]:GetFrameLevel() + 3)
    rings[3]:SetFrameLevel(rings[1]:GetFrameLevel() + 6)
    rings[3].label:SetFontObject("GameFontNormalLarge")
    rings[3].label:SetTextColor(1, 1, 1)
    frame.rings = rings

    local text = CreateFrame("Frame", nil, header)
    text:SetAllPoints()
    text:SetFrameLevel(rings[3]:GetFrameLevel() + 4)
    header.title = text:CreateFontString(nil, "OVERLAY", TITLE_FONT)
    header.title:SetPoint("TOPLEFT", 252, -26)
    header.title:SetPoint("TOPRIGHT", -50, -26)
    header.title:SetJustifyH("LEFT")
    header.title:SetWordWrap(false)
    header.title:SetTextColor(1, 0.82, 0.25)
    header.subtitle = text:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    header.subtitle:SetPoint("TOPLEFT", header.title, "BOTTOMLEFT", 0, -4)
    header.subtitle:SetTextColor(0.8, 0.8, 0.8)
    frame.legend = {}
    for i = 1, 3 do
        local line = CreateFrame("Frame", nil, text)
        line:SetSize(360, 20)
        line:SetPoint("TOPLEFT", header.subtitle, "BOTTOMLEFT", 0, -14 - (i - 1) * 22)
        line.dot = line:CreateTexture(nil, "OVERLAY")
        line.dot:SetTexture(MEDIA .. "Dot")
        line.dot:SetSize(11, 11)
        line.dot:SetPoint("LEFT")
        line.text = line:CreateFontString(nil, "OVERLAY", "GameFontNormalMed3")
        line.text:SetPoint("LEFT", line.dot, "RIGHT", 8, 0)
        line.text:SetTextColor(0.92, 0.92, 0.92)
        frame.legend[i] = line
    end
    header.summary = text:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    header.summary:SetPoint("TOPLEFT", frame.legend[3], "BOTTOMLEFT", 0, -12)
    header.summary:SetTextColor(0.95, 0.95, 0.95)
    header.days = text:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    header.days:SetPoint("BOTTOMRIGHT", -12, 10)

    local gear = CreateFrame("Button", nil, text)
    gear:SetSize(24, 24)
    gear:SetPoint("TOPRIGHT", -10, -10)
    gear:SetNormalTexture("Interface\\Buttons\\UI-OptionsButton")
    gear:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    gear:SetScript("OnClick", function() Journal:Settings() end)
    gear:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("Lorebound settings")
        GameTooltip:Show()
    end)
    gear:SetScript("OnLeave", GameTooltip_Hide)
    local pin = CreateFrame("Button", nil, text)
    pin:SetSize(22, 22)
    pin:SetPoint("RIGHT", gear, "LEFT", -8, 0)
    pin.icon = pin:CreateTexture(nil, "ARTWORK")
    pin.icon:SetTexture(MEDIA .. "Pin")
    pin.icon:SetAllPoints()
    pin:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    pin:SetScript("OnClick", function()
        if type(page) == "number" then Journal:TogglePin(page) end
    end)
    pin:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText(Journal:IsPinned(page) and "Unpin this zone" or "Pin this zone to the top of the list")
        GameTooltip:Show()
    end)
    pin:SetScript("OnLeave", GameTooltip_Hide)
    frame.pinButton = pin
    -- Quests Lorebound's list hasn't got, waiting to be shared (Share.lua): on the overview.
    local share = CreateFrame("Button", nil, text, "UIPanelButtonTemplate")
    share:SetSize(190, 22)
    share:SetPoint("BOTTOMRIGHT", -10, 28)
    share:SetScript("OnClick", function() ns.Share.Open() end)
    share:Hide()
    frame.shareButton = share
    -- This character's progress, for lb.frogwizard.net (Export.lua): on the overview.
    local export = CreateFrame("Button", nil, text, "UIPanelButtonTemplate")
    export:SetSize(190, 22)
    export:SetPoint("BOTTOMRIGHT", -10, 54)
    export:SetText("Export to website")
    export:SetScript("OnClick", function() ns.Export.Open() end)
    export:Hide()
    frame.exportButton = export
    frame.header = header
end

local function FilterButton(bar, key, label, click)
    local button = CreateFrame("Button", nil, bar)
    button:SetSize(100, 26)
    button.label = label
    button.text = button:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    button.text:SetPoint("CENTER", 0, 1)
    button.line = button:CreateTexture(nil, "ARTWORK")
    button.line:SetHeight(2)
    button.line:SetPoint("BOTTOMLEFT", 10, 2)
    button.line:SetPoint("BOTTOMRIGHT", -10, 2)
    button.line:SetColorTexture(1, 0.82, 0.25, 0.9)
    button:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    button:SetScript("OnClick", click or function() Journal:SetFilter(key) end)
    return button
end

local function BuildMap(content)
    local map = CreateFrame("Frame", nil, content)
    map:SetPoint("TOPLEFT", 4, -4)
    map:SetPoint("BOTTOMRIGHT", -4, 4)
    map:SetFrameLevel(content:GetFrameLevel() + 40)
    map:EnableMouse(true)
    map:SetScript("OnMouseUp", function(self) self:Hide() end)
    local back = map:CreateTexture(nil, "BACKGROUND", nil, -8)
    back:SetAllPoints()
    back:SetColorTexture(0.02, 0.02, 0.03, 0.97)
    map.title = map:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    map.title:SetPoint("TOPLEFT", 14, -12)
    local hint = map:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("BOTTOM", 0, 10)
    map.hint = hint
    map.art = CreateFrame("Frame", nil, map)
    map.art:SetPoint("TOPLEFT", 10, -38)
    map.art:SetPoint("BOTTOMRIGHT", -10, 28)
    map.art:SetClipsChildren(true)
    local pin = CreateFrame("Frame", nil, map.art)
    pin:SetSize(18, 18)
    pin:SetFrameLevel(map.art:GetFrameLevel() + 5)
    local dot = pin:CreateTexture(nil, "OVERLAY", nil, 2)
    dot:SetTexture(MEDIA .. "Dot")
    dot:SetAllPoints()
    dot:SetVertexColor(1, 0.82, 0.2)
    local ring = pin:CreateTexture(nil, "OVERLAY", nil, 1)
    ring:SetTexture(MEDIA .. "Ring2")
    ring:SetPoint("CENTER")
    ring:SetSize(44, 44)
    ring:SetVertexColor(1, 0.82, 0.2)
    local pulse = ring:CreateAnimationGroup()
    pulse:SetLooping("REPEAT")
    local grow = pulse:CreateAnimation("Scale")
    grow:SetScaleFrom(0.4, 0.4)
    grow:SetScaleTo(1.3, 1.3)
    grow:SetDuration(1.2)
    local fade = pulse:CreateAnimation("Alpha")
    fade:SetFromAlpha(1)
    fade:SetToAlpha(0)
    fade:SetDuration(1.2)
    map.pin, map.pulse = pin, pulse
    -- You, when you're on the same map.
    local you = map.art:CreateTexture(nil, "OVERLAY", nil, 3)
    you:SetTexture(MEDIA .. "Dot")
    you:SetSize(12, 12)
    you:SetVertexColor(0.3, 0.8, 1)
    map.you = you
    local youLabel = map.art:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    youLabel:SetPoint("LEFT", you, "RIGHT", 4, 0)
    youLabel:SetText("You")
    map.youLabel = youLabel
    map:SetScript("OnHide", function()
        pulse:Stop()
        ns.Pad.Mark()
    end)
    map:Hide()
    return map
end

local function Build()
    frame = CreateFrame("Frame", "LoreboundFrame", UIParent, "PortraitFrameTemplate")
    Journal.frame = frame
    frame:SetFrameStrata("HIGH")
    frame:SetToplevel(true)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:SetResizable(true)
    if frame.SetDontSavePosition then frame:SetDontSavePosition(true) end -- ns.db keeps it (Place)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePoint()
    end)
    frame:Hide()
    tinsert(UISpecialFrames, "LoreboundFrame") -- Escape closes it
    if frame.SetTitle then frame:SetTitle("Lorebound") end
    if frame.SetPortraitToAsset then frame:SetPortraitToAsset("Interface\\Icons\\INV_Misc_Book_09") end
    if frame.CloseButton then frame.CloseButton:SetScript("OnClick", function() frame:Hide() end) end
    Journal:Place()

    -- Left: the overview button, the search and the zones.
    local nav = CreateFrame("Frame", nil, frame, "InsetFrameTemplate")
    nav:SetPoint("TOPLEFT", 4, -60)
    nav:SetPoint("BOTTOMLEFT", 4, 4)
    nav:SetWidth(NAV_W)

    local overview = CreateFrame("Button", nil, nav)
    overview:SetPoint("TOPLEFT", 4, -4)
    overview:SetPoint("TOPRIGHT", -4, -4)
    overview:SetHeight(56)
    overview:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    overview.selected = overview:CreateTexture(nil, "BACKGROUND")
    overview.selected:SetAllPoints()
    overview.selected:SetColorTexture(1, 0.82, 0.25, 0.14)
    overview.rings = Triple(overview, { 46, 34, 22 })
    overview.rings[1]:SetPoint("LEFT", 6, 0)
    local name = overview:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    name:SetPoint("TOPLEFT", 62, -10)
    name:SetText("Lorebound")
    overview.count = overview:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    overview.count:SetPoint("TOPLEFT", name, "BOTTOMLEFT", 0, -4)
    overview:SetScript("OnClick", function() Journal:ShowPage("overview") end)
    frame.overview = overview

    local search = CreateFrame("EditBox", nil, nav, "SearchBoxTemplate")
    search:SetSize(NAV_W - 26, 20)
    search:SetPoint("TOPLEFT", overview, "BOTTOMLEFT", 10, -6)
    search:SetAutoFocus(false)
    search:HookScript("OnTextChanged", function(self)
        local text = strtrim(self:GetText() or "")
        if text == searchText then return end
        searchText = text
        if searchTimer then searchTimer:Cancel() end
        searchTimer = C_Timer.NewTimer(0.15, function()
            searchTimer = nil
            if #searchText >= 3 then
                Journal:ShowPage("search")
            elseif page == "search" then
                Journal:ShowPage(lastPage, true)
            end
        end)
    end)
    frame.search = search

    local navList, navBar, navView = MakeScrollList(nav)
    navList:SetPoint("TOPLEFT", search, "BOTTOMLEFT", -10, -6)
    navList:SetPoint("BOTTOMRIGHT", -22, 4)
    navView:SetElementExtentCalculator(function(_, data) return data.group and NAV_GROUP_H or NAV_ZONE_H end)
    navView:SetElementInitializer("Button", InitNavRow)
    ScrollUtil.InitScrollBoxListWithScrollBar(navList, navBar, navView)
    frame.navList = navList

    -- Right: the header, the filters and the list (or the wall).
    local content = CreateFrame("Frame", nil, frame, "InsetFrameTemplate")
    content:SetPoint("TOPLEFT", nav, "TOPRIGHT", 4, 32)
    content:SetPoint("BOTTOMRIGHT", -6, 4)
    BuildHeader(content)

    local filterBar = CreateFrame("Frame", nil, content)
    filterBar:SetPoint("TOPLEFT", frame.header, "BOTTOMLEFT", 0, -2)
    filterBar:SetPoint("TOPRIGHT", frame.header, "BOTTOMRIGHT", 0, -2)
    filterBar:SetHeight(28)
    frame.filters = {
        todo = FilterButton(filterBar, "todo", "To do"),
        done = FilterButton(filterBar, "done", "Done"),
        all = FilterButton(filterBar, "all", "All"),
    }
    frame.filters.todo:SetPoint("LEFT", 6, 0)
    frame.filters.done:SetPoint("LEFT", frame.filters.todo, "RIGHT", 4, 0)
    frame.filters.all:SetPoint("LEFT", frame.filters.done, "RIGHT", 4, 0)
    frame.locked = Checkbox(filterBar, "Locked out",
        function() return ns.db.showLocked end,
        function(on) Journal:SetLocked(on) end)
    frame.locked:SetPoint("RIGHT", -120, 0)
    frame.filterBar = filterBar

    local questList, questBar, questView = MakeScrollList(content)
    questList:SetPoint("TOPLEFT", frame.header, "BOTTOMLEFT", 0, -34)
    questList:SetPoint("BOTTOMRIGHT", -22, 6)
    questView:SetElementExtentCalculator(function(_, data)
        if data.section then return SECTION_H end
        if data.chain then return CHAIN_H end
        if expanded[data.id] then return ExpandedHeight(data.id) end
        return QUEST_H
    end)
    questView:SetElementInitializer("Button", InitQuestRow)
    ScrollUtil.InitScrollBoxListWithScrollBar(questList, questBar, questView)
    frame.questList, frame.questBar = questList, questBar

    local wallList, wallBar, wallView = MakeScrollList(content)
    wallList:SetPoint("TOPLEFT", frame.header, "BOTTOMLEFT", 0, -6)
    wallList:SetPoint("BOTTOMRIGHT", -22, 6)
    wallView:SetElementExtentCalculator(function(_, data)
        return (data.group or data.title) and WALL_HEAD_H or WALL_ROW_H
    end)
    wallView:SetElementInitializer("Frame", InitWallRow)
    ScrollUtil.InitScrollBoxListWithScrollBar(wallList, wallBar, wallView)
    frame.wallList, frame.wallBar = wallList, wallBar

    frame.measure = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.measure:SetPoint("TOPLEFT")
    frame.measure:SetSpacing(2)
    frame.measure:SetJustifyH("LEFT")
    frame.measure:Hide()

    frame.map = BuildMap(content)
    frame.grip = BuildGrip()

    -- Resized: the page laid out again for its new width (badges per row, the header's art, quest text),
    -- once the size settles for a moment.
    local relayout
    frame:SetScript("OnSizeChanged", function()
        if not frame:IsShown() then return end
        if relayout then relayout:Cancel() end
        relayout = C_Timer.NewTimer(0.15, function()
            relayout = nil
            if not frame:IsShown() then return end
            Journal:Draw(true)
            if frame.map:IsShown() and frame.map.id then Journal:ShowMap(frame.map.id) end
        end)
    end)

    frame:SetScript("OnShow", function()
        for _, event in ipairs({ "QUEST_ACCEPTED", "QUEST_REMOVED", "PLAYER_LEVEL_UP" }) do
            events:RegisterEvent(event)
        end
        PlaySound(SOUNDKIT.IG_SPELLBOOK_OPEN or 829)
    end)
    frame:SetScript("OnHide", function()
        events:UnregisterAllEvents()
        if pending then
            pending:Cancel()
            pending = nil
        end
        if searchTimer then
            searchTimer:Cancel()
            searchTimer = nil
        end
        if frame.settings then frame.settings:Hide() end
        if frame.inspect then frame.inspect:Hide() end
        ns.QuestPage.Hide()
        PlaySound(SOUNDKIT.IG_SPELLBOOK_CLOSE or 830)
    end)
    ns.Pad.Attach(frame)
end

-- Quest log or level changes while the journal is up (and turn-ins, from Core): one recount and redraw
-- for a burst of them.
function Journal:Schedule(stale)
    if stale then Lore.fresh = false end
    if not frame or not frame:IsShown() or pending then return end
    pending = C_Timer.NewTimer(0.3, function()
        pending = nil
        Journal:Refresh()
    end)
end

events:SetScript("OnEvent", function() Journal:Schedule(true) end)

------------------------------------------------------------------------------
-- Opening and refreshing
------------------------------------------------------------------------------

function Journal:Refresh()
    if not frame or not frame:IsShown() then return end
    if not Lore.fresh then
        Lore.Refresh()
        ns.Badge.Record()
    end
    self:FillNav()
    self:Draw(true)
    ns.QuestPage.Refresh()
end

-- target: a zone index, a zone's name (or its start), or nil for where you are (else the overview).
function Journal:Open(target)
    if not ns.LoadData() then return end
    if not frame then Build() end
    Lore.Refresh()
    ns.Badge.Record()
    if type(target) == "string" then
        local zone = Lore.FindZone(target)
        if not zone then
            ns.Say(("no zone called %q."):format(target))
            return
        end
        target = zone
    elseif target == nil and not frame:IsShown() then
        local here = GetRealZoneText and GetRealZoneText()
        local zone = here and here ~= "" and Lore.FindZone(here)
        if zone and select(2, Lore.Count(zone)) > 0 then target = zone end
    end
    frame:Show()
    self:FillNav()
    self:ShowPage(target or page)
end

function Journal:Toggle()
    if frame and frame:IsShown() then
        frame:Hide()
    else
        self:Open()
    end
end
