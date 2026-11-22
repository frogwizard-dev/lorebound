local _, ns = ...

-- Sharing quests Lorebound's list hasn't got. Addons can't send anything themselves, so the journal
-- offers a code to copy (every quest learned in game that hasn't been shared yet: what Core noted when it
-- was offered, accepted and turned in) and where to paste it; _tools/make_lore.py reads pasted codes
-- (_tools/lore_reports/*.txt) into the next list. Reports are made of plain fields, one quest a line:
--
--   LM1^id^name^zone^level^sides^giverID^giverName^mapID^x^y^enderID^enderName^before^classID
--
-- sides: 1 Alliance, 2 Horde, 3 both have met it; giver/ender IDs are NPC (or object, as "o123") IDs;
-- x, y in percent on mapID where the quest was offered; before: the quest last turned in at the same
-- giver just before (likely the one it follows). Empty fields stay empty.

local Share = {}
ns.Share = Share

-- Where codes go (_tools/loremaster-report): the report page files each report as a GitHub issue, no
-- sign-in (Warscribe's way); the progress page shows a character's export (Export.lua).
ns.REPORT_URL = "lb.frogwizard.net/report"
ns.PROGRESS_URL = "lb.frogwizard.net/me"

local panel

-- Learned quests not shared yet, in ID order.
function Share.Pending()
    local list = {}
    for id, entry in pairs(ns.db.learned) do
        if not ns.db.shared[id] and not (ns.Lore.IsLeftOut and ns.Lore.IsLeftOut(id)) then list[#list + 1] = id end
    end
    table.sort(list)
    return list
end

local function Field(value)
    if value == nil then return "" end
    return (tostring(value):gsub("[%^\n|]", " "))
end

function Share.Code()
    local lines = {}
    local version, build = GetBuildInfo()
    lines[1] = ("Lorebound quests (client %s.%s), %d:"):format(Field(version), Field(build), #Share.Pending())
    for _, id in ipairs(Share.Pending()) do
        local e = ns.db.learned[id]
        local i = e.i or {}
        lines[#lines + 1] = table.concat({ "LM1", id, Field(e[1]), Field(e[2]), Field(e[3]), Field(e[4]),
            Field(i.giver), Field(i.giverName), Field(i.map), Field(i.x), Field(i.y), Field(i.ender),
            Field(i.enderName), Field(i.before), Field(i.class) }, "^")
    end
    return table.concat(lines, "\n")
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
    local pending = Share.Pending()
    Share.ShowCode({
        title = "Share new quests",
        about = ("Lorebound's list hasn't got these %d quest%s you've met. Copy the code (Ctrl+C), paste it at the address below, then mark them shared.")
            :format(#pending, #pending == 1 and "" or "s"),
        code = Share.Code(), url = ns.REPORT_URL, done = "Mark as shared",
        onDone = function()
            for _, id in ipairs(pending) do ns.db.shared[id] = true end -- what the code held, no more
            ns.Journal:Refresh()
        end,
    })
end
