local _, ns = ...

-- Lorebound with a controller, in Forever's gamepad UI.
--
-- Opening it: hold LT and press L3 (L3 is ours only while LT is held, so auto-run is untouched; LT+L3 is
-- free in Forever's layout and GamepadQoL's). The Key Bindings menu's entry (Bindings.xml) works too.
--
-- While the journal is open and no Blizzard gamepad window, radial or popup has the controller, the
-- D-pad, A, B, X, Y, the shoulders and the triggers are ours: priority override bindings to hidden
-- buttons of our own (SetOverrideBindingClick), the way GamepadQoL's windows do it, so Blizzard's
-- binding stack and frame manager are never touched (they taint the gamepad UI); the binding manager
-- and the frame manager are only read. Bindings change only out of combat, never while one of those
-- buttons is held (its release would be lost), and are let go a frame after the journal closes (not
-- inside Blizzard's window code) and the moment a fight starts, when the journal closes too.
--
--   D-pad up/down     zones (the page follows), quests, or rows of the overview
--   D-pad right / A   into the zone's quests (or the overview's badges); A opens what's chosen, and A on
--                     an opened quest its page (Quest.lua takes the keys while that's up)
--   D-pad left / B    back; B closes a badge, the giver map or the settings, then the journal
--   X                 show the quest giver (on a zone or a badge: pin or unpin it)
--   Y                 locked-out quests on/off (on the overview: the settings)
--   LB / RB           To do, Done, All (a zone's quests)
--   LT / RT           a page up or down

local Pad = {}
ns.Pad = Pad

local FILTERS = { "todo", "done", "all" }
local PAGE = 8                -- rows a trigger moves
local owner = CreateFrame("Frame")
local watcher = CreateFrame("Frame")
local frame                   -- the journal
local bound = false
local focus = "nav"           -- "nav", "list" (a zone's quests), "wall" (the overview) or "settings"
local navIndex, navData = 0, nil  -- 0 is the overview button, then the zone list's rows
local listIndex, listId = 1, nil
local wallIndex, wallCol, wallKey = 1, 1, nil  -- wallKey: the medal's zone, or its special's kind..value
local comboAt = 0             -- when LT + L3 last fired: that LT press isn't a page up
local settingsIndex = 1
local marker, hintBar, buttons, tipOwner

-- A Blizzard gamepad window, the Start radial or a popup has the controller (only read, never driven).
local function Busy()
    local manager = GamepadMode and GamepadMode.FrameControlsManager
    if manager and manager.isUIFocused then return true end
    local inputs = GamepadSharedUtility and GamepadSharedUtility.InputBindingManager
    if inputs and inputs.IsOnlyCoreBindingSetActive then
        local ok, onlyCore = pcall(inputs.IsOnlyCoreBindingSetActive, inputs)
        if ok and not onlyCore then return true end
    end
    if GamepadMode and GamepadMode.GetOverrideAllowLeftRightModifiers then
        local ok, edit = pcall(GamepadMode.GetOverrideAllowLeftRightModifiers)
        if ok and edit then return true end
    end
    local radial = _G.GamepadRadial
    if radial and radial.IsShown then
        local ok, shown = pcall(radial.IsShown, radial)
        if ok and shown then return true end
    end
    return false
end

------------------------------------------------------------------------------
-- Where the controller is
------------------------------------------------------------------------------

local function Size(list)
    local provider = list:GetDataProvider()
    return provider and provider:GetSize() or 0
end

local function Data(list, index)
    local provider = list:GetDataProvider()
    return provider and index >= 1 and provider:Find(index) or nil
end

local function ScrollTo(list, index)
    if index >= 1 and index <= Size(list) then
        list:ScrollToElementDataIndex(index, ScrollBoxConstants.AlignNearest)
    end
end

local function Same(a, b)
    return a.zone == b.zone and a.group == b.group and a.pinned == b.pinned
end

-- The zone list's row the pad was on, found again (pinning or folding a group moves rows).
local function RefindNav()
    if navIndex == 0 or not navData then return end
    local list = frame.navList
    local current = Data(list, navIndex)
    if current and Same(current, navData) then return end
    local size = Size(list)
    for i = 1, size do
        if Same(Data(list, i), navData) then
            navIndex = i
            return
        end
    end
    for i = 1, size do -- gone (an unpinned zone's copy): the zone's own row
        local data = Data(list, i)
        if navData.zone and data.zone == navData.zone then
            navIndex, navData = i, data
            return
        end
    end
    navIndex = math.min(navIndex, size)
    navData = Data(list, navIndex)
end

-- The next quest row (not a heading) from index in direction step, or nil.
local function NextQuest(index, step)
    local size = Size(frame.questList)
    index = index + step
    while index >= 1 and index <= size do
        local data = Data(frame.questList, index)
        if data and data.id then return index end
        index = index + step
    end
    return nil
end

-- The quest the pad was on, found again after the list was redrawn (else the nearest quest).
local function RefindList()
    local current = Data(frame.questList, listIndex)
    if current and current.id and current.id == listId then return end
    for i = 1, Size(frame.questList) do
        local data = Data(frame.questList, i)
        if data.id and data.id == listId then
            listIndex = i
            return
        end
    end
    listIndex = math.min(listIndex, Size(frame.questList))
    listIndex = NextQuest(listIndex - 1, 1) or NextQuest(listIndex + 1, -1) or 1
    local data = Data(frame.questList, listIndex)
    listId = data and data.id
end

local function WallEntries(index)
    local data = Data(frame.wallList, index)
    return data and (data.zones or data.specials)
end

local function KeyOf(entry)
    if type(entry) == "table" then return tostring(entry[1]) .. tostring(entry[2]) end
    return entry
end

local function NextWallRow(index, step)
    local size = Size(frame.wallList)
    index = index + step
    while index >= 1 and index <= size do
        if WallEntries(index) then return index end
        index = index + step
    end
    return nil
end

-- The medal the pad was on, found again after the wall was redrawn (pins move rows).
local function RefindWall()
    local entries = WallEntries(wallIndex)
    if entries and entries[wallCol] and KeyOf(entries[wallCol]) == wallKey then return end
    for i = 1, Size(frame.wallList) do
        local list = WallEntries(i)
        for col, entry in ipairs(list or {}) do
            if KeyOf(entry) == wallKey then
                wallIndex, wallCol = i, col
                return
            end
        end
    end
    wallIndex = NextWallRow(0, 1) or 1
    wallCol = 1
    entries = WallEntries(wallIndex)
    wallKey = entries and KeyOf(entries[1])
end

-- The frame the controller is on, if it's on screen.
local function Target()
    if focus == "nav" then
        if navIndex == 0 then return frame.overview end
        local data = Data(frame.navList, navIndex)
        return data and frame.navList:FindFrame(data)
    elseif focus == "list" then
        local data = Data(frame.questList, listIndex)
        return data and frame.questList:FindFrame(data)
    elseif focus == "wall" then
        local entries = WallEntries(wallIndex)
        if not entries or wallCol > #entries then return nil end
        local row = frame.wallList:FindFrame(Data(frame.wallList, wallIndex))
        local medal = row and row.medals and row.medals[wallCol]
        return medal and medal:IsShown() and medal or nil
    elseif focus == "settings" then
        return frame.settings and frame.settings:IsShown() and frame.settings.items[settingsIndex]
    end
end

local function TipOff()
    if tipOwner and GameTooltip:GetOwner() == tipOwner then GameTooltip:Hide() end
    tipOwner = nil
end

function Pad.Mark()
    if not marker then return end
    if focus == "settings" and not (frame.settings and frame.settings:IsShown()) then focus = "nav" end
    if focus == "nav" then RefindNav() elseif focus == "list" then RefindList() elseif focus == "wall" then RefindWall() end
    local target = bound and Target()
    if bound and not target then -- scrolled away (a redraw keeps the scroll): bring it back
        if focus == "nav" then ScrollTo(frame.navList, navIndex) end
        if focus == "list" then ScrollTo(frame.questList, listIndex) end
        if focus == "wall" then ScrollTo(frame.wallList, wallIndex) end
        target = Target()
    end
    TipOff()
    marker:ClearAllPoints()
    if target and not frame.map:IsShown() and not ns.Journal:Inspecting() and not ns.QuestPage.IsShown() then
        marker:SetPoint("TOPLEFT", target, "TOPLEFT", -2, 2)
        marker:SetPoint("BOTTOMRIGHT", target, "BOTTOMRIGHT", 2, -2)
        marker:Show()
        -- On the overview, what a mouse would see on hovering (our own frame's tooltip).
        if focus == "wall" then
            local enter = target:GetScript("OnEnter")
            if enter then
                enter(target)
                tipOwner = target
            end
        end
    else
        marker:Hide()
    end
end

-- The page was chosen some other way (the mouse, opening on your zone): the zone list follows.
function Pad.Follow()
    if not frame then return end
    local page = ns.Journal:Page()
    if focus ~= "settings" then focus = "nav" end
    if page == "overview" or page == "search" then
        navIndex, navData = 0, nil
    elseif type(page) == "number" and not (navData and navData.zone == page) then
        local _, group = ns.Lore.Zone(page)
        local own, copy, heading
        for i = 1, Size(frame.navList) do
            local data = Data(frame.navList, i)
            if data.zone == page and not data.pinned then own = own or i end
            if data.zone == page and data.pinned then copy = copy or i end
            if data.group == group then heading = heading or i end
        end
        navIndex = own or copy or heading or navIndex
        navData = Data(frame.navList, navIndex)
    end
    ScrollTo(frame.navList, navIndex)
    Pad.Mark()
end

-- Called by the journal before it draws a new page.
function Pad.PageChanging()
    if focus == "list" or focus == "wall" then focus = "nav" end
end

local function OpenNav()
    if navIndex == 0 then
        ns.Journal:ShowPage("overview")
        return
    end
    local data = Data(frame.navList, navIndex)
    if data and data.zone then ns.Journal:ShowPage(data.zone) end
end

local function MoveNav(step)
    navIndex = math.max(0, math.min(Size(frame.navList), navIndex + step))
    navData = Data(frame.navList, navIndex)
    ScrollTo(frame.navList, navIndex)
    OpenNav()
    Pad.Mark()
end

local function EnterList()
    local page = ns.Journal:Page()
    if focus == "nav" and navIndex > 0 then -- on a heading, or a zone that isn't the page shown: not in
        local data = Data(frame.navList, navIndex)
        if not (data and data.zone == page) then return end
    end
    if page == "overview" then
        local first = NextWallRow(0, 1)
        if not first then return end
        focus, wallIndex, wallCol = "wall", first, 1
        wallKey = KeyOf(WallEntries(first)[1])
        ScrollTo(frame.wallList, wallIndex)
        Pad.Mark()
        return
    end
    if type(page) ~= "number" and page ~= "search" then return end
    local first = NextQuest(0, 1)
    if not first then return end
    focus, listIndex = "list", first
    listId = Data(frame.questList, first).id
    ScrollTo(frame.questList, listIndex)
    Pad.Mark()
end

local function MoveList(step)
    local index = listIndex
    for _ = 1, math.abs(step) do index = NextQuest(index, step > 0 and 1 or -1) or index end
    if index == listIndex then return end
    listIndex = index
    listId = Data(frame.questList, index).id
    ScrollTo(frame.questList, listIndex)
    Pad.Mark()
end

local function MoveWallRow(step)
    local index = wallIndex
    for _ = 1, math.abs(step) do index = NextWallRow(index, step > 0 and 1 or -1) or index end
    if index == wallIndex then return end
    wallIndex = index
    wallCol = math.min(wallCol, #WallEntries(index))
    wallKey = KeyOf(WallEntries(index)[wallCol])
    ScrollTo(frame.wallList, wallIndex)
    Pad.Mark()
end

local function MoveWallCol(step)
    local entries = WallEntries(wallIndex)
    local col = wallCol + step
    if col < 1 then
        focus = "nav"
    elseif entries and col <= #entries then
        wallCol = col
        wallKey = KeyOf(entries[col])
    end
    Pad.Mark()
end

local function Medal()
    return focus == "wall" and Target() or nil
end

local function Back()
    focus = "nav"
    Pad.Mark()
end

local function OpenSettings()
    ns.Journal:Settings(true)
    focus, settingsIndex = "settings", 1
    Pad.Mark()
end

local function CloseSettings()
    ns.Journal:Settings(false)
    focus = "nav"
    Pad.Mark()
end

-- LB/RB: a zone's To do, Done or All.
local function Shoulder(step)
    if type(ns.Journal:Page()) ~= "number" then return end -- only a zone's list has filters
    for i, key in ipairs(FILTERS) do
        if key == ns.db.filter then
            ns.Journal:SetFilter(FILTERS[(i - 1 + step) % #FILTERS + 1])
            break
        end
    end
    if focus == "list" then EnterList() end
end

local function Quest()
    local data = focus == "list" and Data(frame.questList, listIndex)
    return data and data.id
end

local function Move(step)
    if focus == "nav" then MoveNav(step)
    elseif focus == "list" then MoveList(step)
    elseif focus == "wall" then MoveWallRow(step > 0 and math.max(1, math.floor(step / 4)) or math.min(-1, math.ceil(step / 4)))
    elseif focus == "settings" then
        local count = #frame.settings.items
        settingsIndex = math.max(1, math.min(count, settingsIndex + (step > 0 and 1 or -1)))
        Pad.Mark()
    end
end

local PRESS = {
    PADDUP = function() Move(-1) end,
    PADDDOWN = function() Move(1) end,
    PADLTRIGGER = function()
        if GetTime() - comboAt > 1 then Move(-PAGE) end -- LT held for LT + L3 isn't a page up
    end,
    PADRTRIGGER = function() Move(PAGE) end,
    PADDRIGHT = function()
        if ns.Journal:Inspecting() then return ns.Journal:InspectStep(1) end
        if focus == "nav" then EnterList() elseif focus == "wall" then MoveWallCol(1) end
    end,
    PADDLEFT = function()
        if ns.Journal:Inspecting() then return ns.Journal:InspectStep(-1) end
        if focus == "list" then Back() elseif focus == "wall" then MoveWallCol(-1) end
    end,
    PAD1 = function() -- A
        local inspecting = ns.Journal:Inspecting()
        if inspecting then
            if inspecting[1] == "zone" then ns.Journal:ShowPage(inspecting[2]) end
            return
        end
        if focus == "settings" then
            local item = frame.settings.items[settingsIndex]
            if item then item:Click() end
        elseif focus == "list" then
            local id = Quest()
            if id and ns.Journal:IsExpanded(id) then
                ns.QuestPage.Show(id) -- A again on an opened quest: its page
            elseif id then
                ns.Journal:ToggleQuest(id)
            end
        elseif focus == "wall" then
            local medal = Medal()
            if medal then ns.Journal:Inspect(medal.special or { "zone", medal.zone }) end
        else
            local data = navIndex > 0 and Data(frame.navList, navIndex)
            if data and data.group then
                ns.Journal:ToggleGroup(data.group)
            else
                EnterList()
            end
        end
    end,
    PAD2 = function() -- B
        if ns.Journal:Inspecting() then
            frame.inspect:Hide()
        elseif frame.map:IsShown() then
            frame.map:Hide()
            Pad.Mark()
        elseif frame.settings and frame.settings:IsShown() then
            CloseSettings()
        elseif focus == "list" or focus == "wall" then
            Back()
        else
            frame:Hide()
        end
    end,
    PAD3 = function() -- X
        if focus == "nav" then
            local data = navIndex > 0 and Data(frame.navList, navIndex)
            if data and data.zone then ns.Journal:TogglePin(data.zone) end
        elseif focus == "wall" then
            local medal = Medal()
            if medal and medal.zone then ns.Journal:TogglePin(medal.zone) end
        elseif focus == "list" then
            local id = Quest()
            if id then
                ns.Journal:ShowMap(id)
                Pad.Mark()
            end
        end
    end,
    PAD4 = function() -- Y
        if focus == "settings" then
            CloseSettings()
        elseif ns.Journal:Page() == "overview" then
            OpenSettings()
        elseif type(ns.Journal:Page()) == "number" then
            ns.Journal:SetLocked(not ns.db.showLocked)
            if focus == "list" then Pad.Mark() end
        end
    end,
    PADLSHOULDER = function() Shoulder(-1) end,
    PADRSHOULDER = function() Shoulder(1) end,
}

------------------------------------------------------------------------------
-- The journal's bindings
------------------------------------------------------------------------------

local function AnyHeld()
    for key in pairs(PRESS) do
        if IsKeyDown(key) then return true end
    end
    return false
end

local function Bind(on)
    if on == bound then return end
    if on then
        if AnyHeld() then return end -- once it's let go; its release would never reach the game
        for key in pairs(PRESS) do
            SetOverrideBindingClick(owner, true, key, buttons[key]:GetName(), "LeftButton")
        end
    else
        ClearOverrideBindings(owner)
    end
    bound = on
    hintBar:SetShown(on)
    local bottom = on and 30 or 6 -- above the hint bar while it shows
    frame.questList:SetPoint("BOTTOMRIGHT", -22, bottom)
    frame.wallList:SetPoint("BOTTOMRIGHT", -22, bottom)
    Pad.Mark()
end

local function Update()
    if InCombatLockdown() or not frame then return end
    Bind(frame:IsShown() and ns.GamepadUI() and not Busy())
end

-- Ten times a second while the journal is open: a Blizzard gamepad window, the radial or a popup can
-- take the controller at any time (and give it back), and the gamepad UI can be switched on or off.
local elapsed = 0
local function Watch(_, sinceLast)
    elapsed = elapsed + sinceLast
    if elapsed > 0.1 then
        elapsed = 0
        Update()
    end
end

watcher:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_REGEN_DISABLED" then
        Bind(false) -- still allowed: the lockdown starts after this event
        if ns.GamepadUI() and frame and frame:IsShown() then frame:Hide() end -- out of the way of the fight
    else
        Update()
        if frame and not frame:IsShown() and not InCombatLockdown() then watcher:UnregisterAllEvents() end
    end
end)

-- Called once the journal is built.
function Pad.Attach(journal)
    frame = journal
    buttons = {}
    for key, press in pairs(PRESS) do
        local button = CreateFrame("Button", "LoreboundPad" .. key, UIParent)
        button:Hide()
        button:RegisterForClicks("AnyDown")
        if key == "PADLTRIGGER" or key == "PADRTRIGGER" then button:RegisterForClicks("AnyUp") end
        local always = key == "PAD2" or key == "PAD3"
        local inspector = key == "PAD1" or key == "PAD2" or key == "PADDLEFT" or key == "PADDRIGHT"
        button:SetScript("OnClick", function()
            if not frame:IsShown() then return end -- a press after closing does nothing
            if ns.QuestPage.IsShown() then -- a quest's page: its keys (with its giver map over it: B closes the map)
                if not frame.map:IsShown() then return ns.QuestPage.Press(key) end
                if key == "PAD2" then frame.map:Hide() end
                return
            end
            if frame.map:IsShown() and not always then return end -- the giver map is up: B closes it
            if ns.Journal:Inspecting() and not inspector then return end -- a badge is open: its buttons only
            press()
        end)
        buttons[key] = button
    end

    marker = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    marker:SetFrameLevel(frame:GetFrameLevel() + 60)
    marker:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 2 })
    marker:SetBackdropBorderColor(1, 0.82, 0.25, 0.95)
    marker:EnableMouse(false)
    marker:Hide()

    -- The buttons, along the bottom of the window.
    hintBar = CreateFrame("Frame", nil, frame)
    hintBar:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 272, 8)
    hintBar:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -12, 8)
    hintBar:SetHeight(20)
    hintBar:SetFrameLevel(frame:GetFrameLevel() + 55)
    local back = hintBar:CreateTexture(nil, "BACKGROUND")
    back:SetAllPoints()
    back:SetColorTexture(0, 0, 0, 0.85)
    local hint = hintBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("LEFT", 6, 0)
    hint:SetPoint("RIGHT", -6, 0)
    hint:SetWordWrap(false)
    hint:SetText("D-pad move  A open  B back  X giver/pin  Y locked out (overview: settings)  LB RB filter  LT RT page")
    hintBar:Hide()

    frame:HookScript("OnShow", function()
        focus = "nav"
        watcher:RegisterEvent("PLAYER_REGEN_DISABLED")
        watcher:RegisterEvent("PLAYER_REGEN_ENABLED")
        watcher:SetScript("OnUpdate", Watch)
        Update()
    end)
    frame:HookScript("OnHide", function()
        watcher:SetScript("OnUpdate", nil)
        TipOff()
        -- A frame later: Escape and a Blizzard window opening close the journal from inside Blizzard's
        -- panel code, which shouldn't run our binding changes.
        C_Timer.After(0, function()
            if frame:IsShown() then return end
            if InCombatLockdown() then
                watcher:RegisterEvent("PLAYER_REGEN_ENABLED") -- let go after the fight
            else
                watcher:UnregisterAllEvents()
                Bind(false)
            end
        end)
    end)
end

------------------------------------------------------------------------------
-- LT + L3 opens or closes the journal
------------------------------------------------------------------------------

-- While the gamepad UI is on and there's no fight: twenty times a second, whether LT is held. While it
-- is, L3 is bound to our button (and kept while L3 is down, so its release reaches us too).
local combo = CreateFrame("Frame")
local comboOwner = CreateFrame("Frame")
local comboBound = false
local opener = CreateFrame("Button", "LoreboundPadOpen", UIParent)
opener:Hide()
opener:RegisterForClicks("AnyDown")
opener:SetScript("OnClick", function()
    comboAt = GetTime()
    ns.Journal:Toggle()
end)

local function ComboBind(on)
    if on == comboBound then return end
    if on then
        SetOverrideBindingClick(comboOwner, true, "PADLSTICK", "LoreboundPadOpen", "LeftButton")
    else
        ClearOverrideBindings(comboOwner)
    end
    comboBound = on
end

local comboElapsed = 0
local function ComboWatch(_, sinceLast)
    comboElapsed = comboElapsed + sinceLast
    if comboElapsed < 0.05 then return end
    comboElapsed = 0
    if InCombatLockdown() then return end
    local want = IsKeyDown("PADLTRIGGER") and not Busy()
    if comboBound and IsKeyDown("PADLSTICK") then want = true end
    if not comboBound and want and IsKeyDown("PADLSTICK") then return end -- L3 first, then LT: not ours
    ComboBind(want and true or false)
end

local function ComboApply()
    if InCombatLockdown() then return end
    local on = ns.GamepadUI()
    combo:SetScript("OnUpdate", on and ComboWatch or nil)
    if not on then ComboBind(false) end
end

combo:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_REGEN_DISABLED" then
        combo:SetScript("OnUpdate", nil)
        ComboBind(false) -- still allowed: the lockdown starts after this event
    else
        ComboApply()
    end
end)
for _, event in ipairs({ "PLAYER_LOGIN", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED",
    "INPUT_DEVICE_INTERFACE_TRANSITION" }) do
    pcall(combo.RegisterEvent, combo, event)
end
