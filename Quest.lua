local _, ns = ...

-- A quest's own page in the journal, laid out like the website's: the quest window's parchment with the
-- objectives, story, rewards (the game's item slots, with their tooltips) and what the quest giver says when
-- you come back and when you hand it in; beside it who gives and takes it and where, its level and side, and
-- its chain. Opened by clicking a quest in the journal (or A on a controller); the cross or B closes it. The text is from the Lorebound_Text part for its group (ns.QuestText), and what the game showed you
-- comes first.

local F, Lore = ns.F, ns.Lore
local QuestPage = {}
ns.QuestPage = QuestPage

local SIDE_W = 236
local PAPER = "Interface\\QuestFrame\\QuestBG"   -- the page fills 300 x 338 of its 512 x 512 (GossipFrame.xml)
local PAPER_U, PAPER_V = 300 / 512, 338 / 512
local PLATE = "Interface\\QuestFrame\\UI-QuestItemNameFrame"
local SLOT_W, SLOT_H = 150, 42                     -- ItemButtonTemplate's quest reward slot
local MAX_CHAIN = 14
local SCROLL_STEP = 40

local view
local current    -- the quest shown
local pool = { text = {}, slot = {}, chain = {} }
local used = { text = 0, slot = 0 }

local function Words(text)
    if not text then return nil end
    local name = UnitName("player") or "you"
    local class = UnitClass("player") or ""
    local race = UnitRace("player") or ""
    return (text:gsub("<name>", name):gsub("<class>", class:lower()):gsub("<race>", race))
end

-- 12345 as "12,345".
local function Thousands(number)
    local text = tostring(math.floor(number))
    while true do
        local grouped, count = text:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
        text = grouped
        if count == 0 then return text end
    end
end

-- The rewards you've seen for a quest yourself (Core.lua keeps them from its window or your log), in the list's
-- shape, for a quest the list has none for.
local function Seen(id)
    local found = ns.db.rewards and ns.db.rewards[id]
    if not found then return nil end
    return { ch = #found.ch > 0 and found.ch or nil, it = #found.it > 0 and found.it or nil, m = found.m,
             xp = found.xp, part = found.part, cap = found.cap }
end

local function FactionName(id)
    local ok, name = pcall(function()
        if C_Reputation and C_Reputation.GetFactionDataByID then
            local data = C_Reputation.GetFactionDataByID(id)
            return data and data.name
        end
        return GetFactionInfoByID and (select(1, GetFactionInfoByID(id)))
    end)
    return ok and name or "a faction"
end

------------------------------------------------------------------------------
-- The parchment's contents, laid out top to bottom
------------------------------------------------------------------------------

local function Text(font)
    used.text = used.text + 1
    local text = pool.text[used.text]
    if not text then
        text = view.child:CreateFontString(nil, "OVERLAY")
        text:SetJustifyH("LEFT")
        text:SetSpacing(3)
        pool.text[used.text] = text
    end
    text:SetFontObject(font)
    text:SetTextColor(0.18, 0.11, 0.05) -- the quest window's ink
    text:Show()
    return text
end

local function SlotEnter(slot)
    GameTooltip:SetOwner(slot, "ANCHOR_RIGHT")
    GameTooltip:SetItemByID(slot.item)
    GameTooltip:Show()
end

local function Slot()
    used.slot = used.slot + 1
    local slot = pool.slot[used.slot]
    if not slot then
        slot = CreateFrame("Button", nil, view.child)
        slot:SetSize(SLOT_W, SLOT_H)
        slot.icon = slot:CreateTexture(nil, "ARTWORK")
        slot.icon:SetSize(39, 39)
        slot.icon:SetPoint("TOPLEFT")
        slot.plate = slot:CreateTexture(nil, "BACKGROUND")
        slot.plate:SetTexture(PLATE)
        slot.plate:SetSize(128, 64)
        slot.plate:SetPoint("LEFT", slot.icon, "RIGHT", -10, 0)
        slot.name = slot:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        slot.name:SetSize(92, 36)
        slot.name:SetPoint("LEFT", slot.plate, "LEFT", 15, 0)
        slot.name:SetJustifyH("LEFT")
        slot.count = slot:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
        slot.count:SetPoint("BOTTOMRIGHT", slot.icon, "BOTTOMRIGHT", -1, 1)
        slot:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
        slot:GetHighlightTexture():SetAllPoints(slot.icon)
        slot:SetScript("OnEnter", SlotEnter)
        slot:SetScript("OnLeave", GameTooltip_Hide)
        pool.slot[used.slot] = slot
    end
    slot:Show()
    return slot
end

-- Lays out one quest's page: a cursor runs down the parchment.
local function Layout(id, keepScroll)
    for _, list in ipairs({ pool.text, pool.slot }) do
        for _, region in ipairs(list) do region:Hide() end
    end
    used.text, used.slot = 0, 0
    local width = view.child:GetWidth()
    local y = 0
    local function Add(region, height, gap)
        region:ClearAllPoints()
        region:SetPoint("TOPLEFT", view.child, "TOPLEFT", 0, -y)
        y = y + height + (gap or 10)
    end
    local function Heading(label)
        local text = Text(QuestTitleFont and "QuestTitleFont" or "GameFontNormalLarge")
        text:SetWidth(width)
        text:SetText(label)
        Add(text, text:GetStringHeight(), 6)
    end
    local function Paragraphs(words, font)
        local text = Text(font or (QuestFont and "QuestFont" or "GameFontHighlight"))
        text:SetWidth(width)
        text:SetText(words)
        Add(text, text:GetStringHeight(), 12)
    end

    local row = Lore.Row(id)
    local details = not Lore.IsLearned(id) and ns.QuestText(id, select(2, Lore.Zone(row[F.zone]))) or {}
    local saved = ns.db.text[id]

    Heading("Objectives")
    Paragraphs(Words((saved and saved[2]) or details.o or ns.Journal.Fill(row[F.objective]))
        or "Its objective isn't known yet.")
    local lines = {}
    local active = C_QuestLog.GetQuestObjectives and C_QuestLog.GetQuestObjectives(id)
    if active and #active > 0 then -- in your quest log: the game's own lines, with your progress
        for _, objective in ipairs(active) do
            lines[#lines + 1] = (objective.finished and "|cff4c7a3a%s|r" or "%s"):format(objective.text or "")
        end
    else
        for _, need in ipairs(details.n or {}) do lines[#lines + 1] = ("%s: %d"):format(need[1], need[2]) end
    end
    if #lines > 0 then Paragraphs(table.concat(lines, "\n")) end

    local description = (saved and saved[1]) or details.d
    if description then
        Heading("Description")
        Paragraphs(Words(description))
    end

    local rewards, listed = Seen(id), details.r -- the game's own over the list's (which may be part of them)
    if rewards and listed then
        rewards.xp, rewards.rep, rewards.sp = listed.xp or rewards.xp, listed.rep, listed.sp -- the game's is this
        -- character's (less for a quest well below it)
        if rewards.cap then rewards.m = listed.m end -- read at the level cap, where the money isn't known
        if rewards.part and not rewards.ch then -- the server's answer for a quest not in your log: no choices in it
            rewards.ch = listed.ch
            local given, some = {}, {}
            for _, item in ipairs(rewards.it or {}) do given[item[1]] = true end
            for _, item in ipairs(listed.so or {}) do
                if not given[item[1]] then some[#some + 1] = item end
            end
            rewards.so = #some > 0 and some or nil
        end
    end
    rewards = rewards or listed
    if rewards then
        Heading("Rewards")
        for _, part in ipairs({ { rewards.ch, "You will be able to choose one of these rewards:" },
                                { rewards.it, "You will receive:" },
                                { rewards.so, "Rewards include:" } }) do
            local items, label = part[1], part[2]
            if items then
                Paragraphs(label)
                local columns = math.max(1, math.floor((width + 8) / (SLOT_W + 8)))
                for i, item in ipairs(items) do
                    local slot = Slot()
                    slot.item = item[1]
                    slot.icon:SetTexture(item[5] and ("Interface\\Icons\\" .. item[5])
                        or (C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(item[1])) or 134400)
                    slot.name:SetText(item[3] or (GetItemInfo(item[1])) or ("Item " .. item[1]))
                    slot.count:SetText(item[2] > 1 and item[2] or "")
                    local col = (i - 1) % columns
                    slot:ClearAllPoints()
                    slot:SetPoint("TOPLEFT", view.child, "TOPLEFT", col * (SLOT_W + 8), -y)
                    if col == columns - 1 or i == #items then y = y + SLOT_H + 6 end
                end
                y = y + 6
            end
        end
        local coins = (C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString) or GetCoinTextureString
        if rewards.m and rewards.m > 0 then Paragraphs(coins and coins(rewards.m) or ("%d copper"):format(rewards.m)) end
        if rewards.xp then Paragraphs(("%s experience"):format(Thousands(rewards.xp))) end
        for _, rep in ipairs(rewards.rep or {}) do
            local faction = type(rep[1]) == "string" and rep[1] or FactionName(rep[1])
            Paragraphs(("%s%d reputation with %s"):format(rep[2] > 0 and "+" or "", rep[2], faction))
        end
        if rewards.sp then Paragraphs("A spell is cast on you when you hand it in.") end
    end

    local progress = (saved and saved[4]) or details.p
    if progress then
        Heading("When you come back")
        Paragraphs(Words(progress))
    end
    local completion = (saved and saved[3]) or details.c
    if completion then
        Heading("On completion")
        Paragraphs(Words(completion))
    end

    if details.nt then
        Heading("Notes")
        Paragraphs(details.nt)
    end

    local note
    if not (description or completion) then
        note = "This quest's story isn't known yet. Read it at the quest giver and Lorebound keeps it here: share it"
            .. " from the overview and it's here for everyone."
    elseif not (saved and saved[1]) then
        if details.s then
            note = "Forever's own text, as players saw it in game."
        else
            note = details.k and "Classic's text: Forever's objective matches it word for word."
                or "Classic's text, not yet checked against Forever."
        end
    end
    if note then Paragraphs(note, "GameFontDisableSmall") end
    view.child:SetHeight(math.max(1, y))
    if keepScroll then QuestPage.Scroll(0) else view.scroll:SetVerticalScroll(0) end
end

------------------------------------------------------------------------------
-- The column beside it
------------------------------------------------------------------------------

local function Place(map, x, y)
    if not map then return "" end
    local info = C_Map.GetMapInfo(map)
    return ("\n|cff9a9a9a%s %s, %s|r"):format(info and info.name or "", x or "?", y or "?")
end

-- A chain's steps as this character sees them (Lore.ChainFor); a quest it can't have, looked at anyway, gets the
-- whole chain it's in.
local function ChainFor(first, shown)
    local steps = Lore.ChainFor(first)
    for _, id in ipairs(steps) do
        if id == shown then return steps end
    end
    return Lore.ChainSteps(first)
end

local function ChainRow(i)
    local row = pool.chain[i]
    if not row then
        row = CreateFrame("Button", nil, view.side)
        row:SetSize(SIDE_W, 20)
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(14, 14)
        row.icon:SetPoint("LEFT", 2, 0)
        row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
        row.name:SetPoint("RIGHT", -2, 0)
        row.name:SetJustifyH("LEFT")
        row.name:SetWordWrap(false)
        row:SetScript("OnClick", function(self) QuestPage.Show(self.quest) end)
        pool.chain[i] = row
    end
    row:Show()
    return row
end

local function Side(id)
    local row = Lore.Row(id)
    local facts = {}
    local function Fact(label, value)
        if value and value ~= "" then facts[#facts + 1] = ("|cffffd100%s|r\n%s"):format(label, value) end
    end
    local details = not Lore.IsLearned(id) and ns.QuestText(id, select(2, Lore.Zone(row[F.zone]))) or {}
    Fact("Start", details.ws or row[F.starter] and (row[F.starter] .. Place(row[F.map], row[F.x], row[F.y])))
    Fact("End", details.we or row[F.finisher])
    local level, minLevel = row[F.level], row[F.minLevel]
    Fact("Level", level and level > 0 and (minLevel and ("%d, from level %d"):format(level, minLevel) or tostring(level)))
    Fact("Zone", (Lore.Zone(row[F.zone])))
    local needs, named = {}, {}
    for _, field in ipairs({ F.needsAll, F.needsAny }) do
        for _, need in ipairs(row[field] or {}) do
            need = math.abs(need)
            local name = Lore.Name(need)
            if Lore.StatusOf(need) ~= Lore.HIDDEN and not named[name] then
                named[name] = true
                needs[#needs + 1] = need
            end
        end
    end
    if #needs > 0 then Fact("Needs first", ns.Journal.NamesWithTicks(needs)) end
    if row[F.breadcrumbFor] then Fact("Leads to", ns.Journal.NamesWithTicks({ row[F.breadcrumbFor] })) end
    if Lore.IsLearned(id) then Fact("Learned in game", "Not in Lorebound's list yet: share it from the overview.") end
    Fact("Quest ID", tostring(id))
    view.facts:SetText(table.concat(facts, "\n\n"))
    view.giver:SetEnabled(row[F.map] ~= nil)

    for _, line in ipairs(pool.chain) do line:Hide() end
    local chainFirst = Lore.ChainOf(id)
    view.chainHead:SetShown(chainFirst ~= nil)
    if not chainFirst then return end
    local steps = ChainFor(chainFirst, id)
    view.chainHead:SetText(("Quest chain  |cff9a9a9a%d quests|r"):format(#steps))
    -- As many rows as fit the column under the facts, around the quest shown.
    local room = view.side:GetHeight() - view.facts:GetStringHeight() - 14 - 22 - 18 - 18 - 36
    local rows = math.max(3, math.min(MAX_CHAIN, math.floor(room / 20)))
    local at = 1
    for i, step in ipairs(steps) do
        if step == id then at = i end
    end
    local first = math.max(1, math.min(at - math.floor(rows / 2), #steps - rows + 1))
    for i = first, math.min(#steps, first + rows - 1) do
        local step = steps[i]
        local line = ChainRow(i - first + 1)
        line.quest = step
        line:ClearAllPoints()
        line:SetPoint("TOPLEFT", view.chainHead, "BOTTOMLEFT", 0, -6 - (i - first) * 20)
        ns.Journal.SetStatusIcon(line.icon, (Lore.StatusOf(step)))
        local here = step == id
        line.name:SetText(("%s%d. %s|r"):format(here and "|cffffd100" or "|cffffffff", i, Lore.Name(step) or "?"))
        line:EnableMouse(not here)
    end
end

------------------------------------------------------------------------------
-- The page
------------------------------------------------------------------------------

local function Build()
    local frame = ns.Journal.frame
    local content = frame.map:GetParent()
    view = CreateFrame("Frame", nil, content)
    view:SetPoint("TOPLEFT", 4, -4)
    view:SetPoint("BOTTOMRIGHT", -4, 4)
    view:SetFrameLevel(content:GetFrameLevel() + 30) -- with its children (up to +34), under the giver map (40)
    view:EnableMouse(true)
    view:Hide()
    local back = view:CreateTexture(nil, "BACKGROUND", nil, -8)
    back:SetAllPoints()
    back:SetColorTexture(0.02, 0.02, 0.03, 0.97)

    view.title = view:CreateFontString(nil, "OVERLAY", ns.Journal.TITLE_FONT)
    view.title:SetPoint("TOPLEFT", 16, -12)
    view.title:SetPoint("RIGHT", -44, 0)
    view.title:SetJustifyH("LEFT")
    view.title:SetWordWrap(false)
    view.title:SetTextColor(1, 0.82, 0.25)
    view.icon = view:CreateTexture(nil, "OVERLAY")
    view.icon:SetSize(16, 16)
    view.icon:SetPoint("TOPLEFT", view.title, "BOTTOMLEFT", 0, -8)
    view.status = view:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    view.status:SetPoint("LEFT", view.icon, "RIGHT", 6, 0)
    view.status:SetPoint("RIGHT", view, "RIGHT", -16, 0)
    view.status:SetJustifyH("LEFT")
    view.status:SetWordWrap(false)
    local close = CreateFrame("Button", nil, view, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)
    close:SetScript("OnClick", function() QuestPage.Hide() end)

    -- The column: who and where, the giver's map, the chain.
    view.side = CreateFrame("Frame", nil, view)
    view.side:SetPoint("TOPRIGHT", -14, -74)
    view.side:SetPoint("BOTTOMRIGHT", -14, 14)
    view.side:SetWidth(SIDE_W)
    view.side:SetClipsChildren(true)
    view.facts = view.side:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    view.facts:SetPoint("TOPLEFT")
    view.facts:SetWidth(SIDE_W)
    view.facts:SetJustifyH("LEFT")
    view.facts:SetSpacing(2)
    view.giver = CreateFrame("Button", nil, view.side, "UIPanelButtonTemplate")
    view.giver:SetSize(170, 22)
    view.giver:SetText("Show quest giver")
    view.giver:SetPoint("TOPLEFT", view.facts, "BOTTOMLEFT", 0, -14)
    view.giver:SetScript("OnClick", function() if current then ns.Journal:ShowMap(current) end end)
    view.chainHead = view.side:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    view.chainHead:SetPoint("TOPLEFT", view.giver, "BOTTOMLEFT", 0, -18)
    view.hint = view.side:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    view.hint:SetPoint("BOTTOMLEFT")
    view.hint:SetWidth(SIDE_W)
    view.hint:SetJustifyH("LEFT")

    -- The parchment, with its contents scrolling inside.
    local paper = CreateFrame("Frame", nil, view)
    paper:SetPoint("TOPLEFT", 14, -74)
    paper:SetPoint("BOTTOMRIGHT", view.side, "BOTTOMLEFT", -16, 0)
    local texture = paper:CreateTexture(nil, "BACKGROUND")
    texture:SetAllPoints()
    texture:SetTexture(PAPER)
    texture:SetTexCoord(0, PAPER_U, 0, PAPER_V)
    view.scroll = CreateFrame("ScrollFrame", nil, paper)
    view.scroll:SetPoint("TOPLEFT", 22, -20)
    view.scroll:SetPoint("BOTTOMRIGHT", -22, 20)
    view.child = CreateFrame("Frame", nil, view.scroll)
    view.child:SetSize(1, 1)
    view.scroll:SetScrollChild(view.child)
    view.scroll:SetScript("OnSizeChanged", function(scroll, width)
        view.child:SetWidth(width)
        if current and view:IsShown() then
            Layout(current, true)
            Side(current)
        end
    end)
    view:EnableMouseWheel(true)
    view:SetScript("OnMouseWheel", function(_, delta) QuestPage.Scroll(-delta * SCROLL_STEP) end)
    view:SetScript("OnHide", function() ns.Pad.Mark() end)
end

function QuestPage.Show(id)
    if not id or not Lore.Row(id) then return end
    if not view then Build() end
    current = id
    view.title:SetText(Lore.Name(id) or ("Quest " .. id))
    local state, why = Lore.StatusOf(id)
    ns.Journal.SetStatusIcon(view.icon, state)
    view.status:SetText(ns.Journal.Summary(id, state, why))
    view.side:SetPoint("BOTTOMRIGHT", -14, ns.GamepadUI() and 36 or 14) -- clear of the controller's hint bar
    view.child:SetWidth(math.max(1, view.scroll:GetWidth()))
    view:Show()
    Layout(id)
    Side(id)
    ns.AskRewardsNow(id, function() -- not known: the game's answer redraws the page
        if current == id and QuestPage.IsShown() then Layout(id, true) end
    end)
    view.hint:SetText(ns.GamepadUI() and "D-pad up/down: scroll   left/right: the chain\nX: the quest giver   B: back" or "")
    ns.Pad.Mark()
end

function QuestPage.Hide()
    if view then view:Hide() end
end

function QuestPage.IsShown()
    return view ~= nil and view:IsVisible()
end

function QuestPage.Scroll(step)
    local scroll = view.scroll
    local most = math.max(0, view.child:GetHeight() - scroll:GetHeight())
    scroll:SetVerticalScroll(math.max(0, math.min(most, scroll:GetVerticalScroll() + step)))
end

-- The chain's step before (direction -1) or after (1) the one shown, as the chain list shows them.
function QuestPage.Step(direction)
    local chainFirst = current and Lore.ChainOf(current)
    if not chainFirst then return end
    local steps = ChainFor(chainFirst, current)
    for i, id in ipairs(steps) do
        if id == current then
            local target = steps[i + direction]
            if target then QuestPage.Show(target) end
            return
        end
    end
end

-- Shown again with fresh statuses and quest log progress (the journal's refresh after quest events).
function QuestPage.Refresh()
    if current and QuestPage.IsShown() then QuestPage.Show(current) end
end

-- A controller's press while the page is up (Pad.lua).
function QuestPage.Press(key)
    if key == "PAD2" then QuestPage.Hide()
    elseif key == "PAD3" then ns.Journal:ShowMap(current)
    elseif key == "PADDUP" then QuestPage.Scroll(-SCROLL_STEP)
    elseif key == "PADDDOWN" then QuestPage.Scroll(SCROLL_STEP)
    elseif key == "PADLTRIGGER" then QuestPage.Scroll(-view.scroll:GetHeight())
    elseif key == "PADRTRIGGER" then QuestPage.Scroll(view.scroll:GetHeight())
    elseif key == "PADDLEFT" then QuestPage.Step(-1)
    elseif key == "PADDRIGHT" then QuestPage.Step(1)
    end
end
