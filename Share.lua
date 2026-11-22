local _, ns = ...

-- Sharing what Lorebound's list hasn't got: quests met in game, and the Forever text of quests it only has
-- Classic's text for, or none (changed or new in Forever). Addons can't send anything themselves, so the journal
-- offers a code to copy (what Core noted from the quest windows and hasn't been shared yet) and where to paste
-- it; tools/make_lore.py reads the reports you've approved (tools/lore_reports) into the next list. Reports are
-- made of plain fields, one a line:
--
--   LM1^id^name^zone^level^sides^giverID^giverName^mapID^x^y^enderID^enderName^before^classID
--   LT1^id^field^text
--
-- sides: 1 Alliance, 2 Horde, 3 both have met it; giver/ender IDs are NPC (or object, as "o123") IDs;
-- x, y in percent on mapID where the quest was offered; before: the quest last turned in at the same
-- giver just before (likely the one it follows). Empty fields stay empty. field: d description, o objective,
-- c completion, p progress; the text with line breaks as $B and your name as $N (the game's own markup).

local Share = {}
ns.Share = Share

-- Where codes go (site/): the report page files each report as a GitHub issue, no
-- sign-in (Warscribe's way); the progress page shows a character's export (Export.lua).
ns.REPORT_URL = "lb.frogwizard.net/report"
ns.PROGRESS_URL = "lb.frogwizard.net/me"

local MAX_CODE = 36000   -- characters in one code: the report page takes 40,000 (site/functions/api/report.js)
local MAX_LINES = 290    -- lines in one code: the page takes 300, and refuses a longer report whole
local MAX_TEXT = 3800    -- in one text line: the page takes 4,000; a longer text isn't offered
local MAX_FIELD = 80     -- characters in a met quest's name fields: its line stays under the page's 400
local ENGLISH = { enUS = true, enGB = true } -- the list's text is English: other clients share quests, not text
local TEXT_FIELDS = { { "d", 1 }, { "o", 2 }, { "c", 3 }, { "p", 4 } } -- the code's letter, ns.db.text's index

local panel

local function NewQuest(id)
    return ns.db.learned[id] and not ns.db.shared[id] and not ns.Lore.IsLeftOut(id)
end

-- A quest's text for the code: line breaks as $B (the name was made $N when it was kept, Core.lua), the code's
-- separator and what the report page refuses (`, control characters) turned into spaces.
local function TextField(text)
    return (text:gsub("\r", ""):gsub("\n", "$B"):gsub("[%^|`%c]", " "))
end

-- The text fields of a quest worth sharing and not shared yet, as letters ("dp"), or nil: only text kept without
-- the reader's name (Core.lua's textClean), on an English client, short enough for one line.
local function NewText(id)
    local saved = ns.db.text[id]
    if not saved or not ENGLISH[GetLocale()] or not ns.Lore.WantsText(id) then return nil end
    local sent, clean, fields = ns.db.textShared[id] or "", ns.db.textClean[id] or "", ""
    for _, field in ipairs(TEXT_FIELDS) do
        local text = saved[field[2]]
        if text and clean:find(tostring(field[2]), 1, true) and not sent:find(field[1], 1, true)
            and #text < MAX_TEXT - 20 then
            fields = fields .. field[1]
        end
    end
    return fields ~= "" and fields or nil
end

-- Quests with something to share (met in game, or their text), in ID order: worked out again only after a quest
-- window or a share (the journal asks on every draw).
local pending
function Share.Pending()
    if pending and not ns.shareStale then return pending end
    ns.shareStale = false
    local seen, list = {}, {}
    for id in pairs(ns.db.learned) do
        if NewQuest(id) then seen[id] = true end
    end
    for id in pairs(ns.db.text) do
        if NewText(id) then seen[id] = true end
    end
    for id in pairs(seen) do list[#list + 1] = id end
    table.sort(list)
    pending = list
    return list
end

-- Whether anything pending isn't in what the code held.
local function Leftover(held)
    local heldQuest = {}
    for _, id in ipairs(held.quests) do heldQuest[id] = true end
    for _, id in ipairs(Share.Pending()) do
        if NewQuest(id) and not heldQuest[id] then return true end
        local fields = NewText(id)
        if fields and #fields > #(held.text[id] or "") then return true end
    end
    return false
end

-- The code, as long as fits one report, and what it holds ({ quests = { id }, text = { [id] = fields }, count =
-- quests with anything in it }) for marking as shared; what didn't fit waits for the next one.
function Share.Code()
    local function Plain(value) return (ns.Plain(value):sub(1, MAX_FIELD)) end
    local lines, held, size = {}, { quests = {}, text = {}, count = 0 }, 0
    local function Add(line)
        if size + #line + 1 > MAX_CODE or #lines >= MAX_LINES then return false end
        lines[#lines + 1] = line
        size = size + #line + 1
        return true
    end
    local version, build = GetBuildInfo()
    Add(("Lorebound quests (client %s.%s):"):format(Plain(version), Plain(build)))
    for _, id in ipairs(Share.Pending()) do
        local before = #held.quests
        if NewQuest(id) then
            local entry = ns.db.learned[id]
            local met = entry.i or {}
            if not Add(table.concat({ "LM1", id, Plain(entry[1]), Plain(entry[2]), Plain(entry[3]),
                Plain(entry[4]), Plain(met.giver), Plain(met.giverName), Plain(met.map), Plain(met.x), Plain(met.y),
                Plain(met.ender), Plain(met.enderName), Plain(met.before), Plain(met.class) }, "^")) then break end
            held.quests[#held.quests + 1] = id
        end
        local fields, sent = NewText(id), ""
        for _, field in ipairs(TEXT_FIELDS) do
            if fields and fields:find(field[1], 1, true) then
                local line = ("LT1^%d^%s^%s"):format(id, field[1], TextField(ns.db.text[id][field[2]]))
                if #line <= MAX_TEXT and Add(line) then sent = sent .. field[1] end
            end
        end
        if sent ~= "" then held.text[id] = sent end
        if sent ~= "" or #held.quests > before then held.count = held.count + 1 end
        if size >= MAX_CODE - 200 or #lines >= MAX_LINES then break end
    end
    return table.concat(lines, "\n"), held
end

local function Build()
    panel = CreateFrame("Frame", "LoreboundShare", UIParent, "BackdropTemplate")
    panel:SetSize(560, 360)
    panel:SetPoint("CENTER", 0, 40)
    panel:SetFrameStrata("DIALOG")
    panel:SetToplevel(true)
    panel:EnableMouse(true)
    panel:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    panel:SetBackdropColor(0.04, 0.04, 0.06, 0.97)
    panel:SetBackdropBorderColor(0.45, 0.45, 0.5, 1)
    panel:Hide()

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -14)
    panel.title = title
    local about = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    about:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    about:SetWidth(528)
    about:SetJustifyH("LEFT")
    about:SetSpacing(2)
    panel.about = about

    -- The code, selected: Ctrl+C copies it.
    local scroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 16, -86)
    scroll:SetPoint("BOTTOMRIGHT", -36, 84)
    local back = panel:CreateTexture(nil, "BACKGROUND", nil, 1)
    back:SetPoint("TOPLEFT", scroll, -4, 4)
    back:SetPoint("BOTTOMRIGHT", scroll, 24, -4)
    back:SetColorTexture(0, 0, 0, 0.6)
    local box = CreateFrame("EditBox", nil, scroll)
    box:SetMultiLine(true)
    box:SetFontObject("GameFontHighlightSmall")
    box:SetWidth(500)
    box:SetAutoFocus(false)
    box:SetScript("OnEscapePressed", function() panel:Hide() end)
    box:SetScript("OnTextChanged", function(self, user)
        if user then -- read only: put the code back, selected again
            self:SetText(panel.code or "")
            self:HighlightText()
        end
    end)
    box:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    box:SetScript("OnMouseUp", function(self) self:HighlightText() end)
    if ScrollingEdit_OnCursorChanged then box:SetScript("OnCursorChanged", ScrollingEdit_OnCursorChanged) end
    scroll:SetScrollChild(box)
    panel.box = box

    -- Where to paste it (also selectable, to copy).
    local where = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    where:SetSize(500, 20)
    where:SetPoint("BOTTOMLEFT", 22, 52)
    where:SetAutoFocus(false)
    where:SetScript("OnTextChanged", function(self, user)
        if user then self:SetText(panel.url or "") end
    end)
    where:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    where:SetScript("OnEscapePressed", function() panel:Hide() end)
    panel.where = where

    local done = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    done:SetSize(150, 24)
    done:SetPoint("BOTTOMLEFT", 16, 16)
    done:SetText("Mark as shared")
    done:SetScript("OnClick", function()
        local onDone = panel.onDone
        panel:Hide()
        if onDone then onDone() end
    end)
    panel.done = done
    local close = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    close:SetSize(100, 24)
    close:SetPoint("BOTTOMRIGHT", -16, 16)
    close:SetText("Close")
    close:SetScript("OnClick", function() panel:Hide() end)
    panel:SetScript("OnHide", function()
        panel.box:ClearFocus()
        panel.where:ClearFocus()
    end)
    tinsert(UISpecialFrames, "LoreboundShare")
end

-- A code to copy, and where to paste it. options: title, about, code, url, done (the button's text, or nil
-- for none) and onDone.
function Share.ShowCode(options)
    if not panel then Build() end
    panel.title:SetText(options.title)
    panel.code, panel.url, panel.onDone = options.code, options.url, options.onDone
    panel.box:SetText(panel.code)
    panel.where:SetText(panel.url or "")
    panel.where:SetShown(panel.url ~= nil)
    panel.done:SetShown(options.done ~= nil)
    if options.done then panel.done:SetText(options.done) end
    local pad = ns.GamepadUI() and "\nCopying needs a keyboard: do this from a computer." or ""
    panel.about:SetText(options.about .. pad)
    panel:Show()
    if not ns.GamepadUI() then
        panel.box:SetFocus()
        panel.box:HighlightText()
    end
end

function Share.Open()
    local code, held = Share.Code()
    if held.count == 0 then
        ns.Say("nothing to share right now.")
        return
    end
    local texts = 0
    for _ in pairs(held.text) do texts = texts + 1 end
    local parts = {}
    if #held.quests > 0 then
        parts[#parts + 1] = ("%d quest%s you've met that Lorebound's list hasn't got"):format(#held.quests,
            #held.quests == 1 and "" or "s")
    end
    if texts > 0 then
        parts[#parts + 1] = ("the Forever text of %d quest%s it only has Classic's text for, or none"):format(texts,
            texts == 1 and "" or "s")
    end
    local more = Leftover(held) and " There's more after this: share again once it's marked." or ""
    Share.ShowCode({
        title = "Share quests",
        about = ("This code holds %s. Copy it (Ctrl+C), paste it at the address below, then mark it shared.%s")
            :format(table.concat(parts, ", and "), more),
        code = code, url = ns.REPORT_URL, done = "Mark as shared",
        onDone = function()
            for _, id in ipairs(held.quests) do ns.db.shared[id] = true end -- what the code held, no more
            for id, fields in pairs(held.text) do ns.db.textShared[id] = (ns.db.textShared[id] or "") .. fields end
            ns.shareStale = true
            ns.Journal:Refresh()
        end,
    })
end
