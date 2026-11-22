local _, ns = ...

-- Badges, one per zone, like a gym leader's: the zone's own map art in a gold frame shaped by its kind
-- (a medal for a zone, a shield for a dungeon or battleground, a crest for a raid, a sigil for class and
-- profession quests, which show their icon instead). Each continent closed earns its crest, and the lot
-- the Lorebound Seal. Earned when the ring closes, and kept: LoreboundCharDB.badges notes the day.
-- Not earned yet: greyed out. Also here: laying a zone's map art out in a frame (DrawArt), which the
-- journal's header, its rows and the badges share.

local Badge = {}
ns.Badge = Badge

local MEDIA = ns.MEDIA
local ICONS = "Interface\\Icons\\"

-- By group (make_lore.py's GROUPS): the badge's shape, and its word.
local SHAPES = { "Medal", "Medal", "Shield", "Crest", "Hex", "Hex", "Shield", "Medal" }
local WORDS = { Medal = "Badge", Shield = "Shield", Crest = "Crest", Hex = "Sigil" }
local WINDOW = { Medal = 0.74, Shield = 0.76, Crest = 0.62, Hex = 0.76 } -- the window's share of the badge
-- Continents' maps, for their crests and their headings in the zone list.
Badge.GROUP_MAPS = { 1415, 1414, nil, nil, nil, nil, nil, 2521 }
-- The other groups' headings show the game's own art: { file ID, width, height, top row, rows } (Classic's
-- loading screens are 512 x 512 files shown stretched to 4:3); Class shows your class's talent painting.
local GROUP_PAINTINGS = {
    [3] = { 131833, 683, 512, 0, 512 }, -- glues/loadingscreens/loadscreendeadmines
    [4] = { 131851, 683, 512, 0, 512 }, -- glues/loadingscreens/loadscreenmoltencore
    [6] = { 374159, 512, 128, 0, 128 }, -- tradeskillframe/ui-tradeskill-blacksmithbg-top
    [7] = { 131861, 683, 512, 0, 512 }, -- glues/loadingscreens/loadscreenpvpbattleground
}
local CLASS_ART = { WARRIOR = 136983, PALADIN = 136918, HUNTER = 136890, ROGUE = 136942, PRIEST = 136930,
    SHAMAN = 136950, MAGE = 136902, WARLOCK = 136967, DRUID = 136878 } -- talentframe/<tree>-topleft

function Badge.GroupPainting(group)
    if group == 5 then
        local _, class = UnitClass("player")
        return CLASS_ART[class] and { CLASS_ART[class], 256, 256, 0, 256 }
    end
    return GROUP_PAINTINGS[group]
end

local ZONE_ICONS = {
    Warrior = "ClassIcon_Warrior", Paladin = "ClassIcon_Paladin", Hunter = "ClassIcon_Hunter",
    Rogue = "ClassIcon_Rogue", Priest = "ClassIcon_Priest", Shaman = "ClassIcon_Shaman",
    Mage = "ClassIcon_Mage", Warlock = "ClassIcon_Warlock", Druid = "ClassIcon_Druid",
    Alchemy = "Trade_Alchemy", Herbalism = "Trade_Herbalism", Blacksmithing = "Trade_BlackSmithing",
    Cooking = "INV_Misc_Food_15", ["First Aid"] = "Spell_Holy_SealOfSacrifice", Fishing = "Trade_Fishing",
    Leatherworking = "INV_Misc_ArmorKit_17", Engineering = "Trade_Engineering", Tailoring = "Trade_Tailoring",
    Camping = "Spell_Fire_Fire", ["Craftsman's Writs"] = "INV_Scroll_03",
    ["Night Elf"] = "Achievement_Character_Nightelf_Male", ["Deeprun Tram"] = "INV_Misc_Gear_08",
    Special = "INV_Misc_Note_01", Epic = "INV_Misc_Head_Dragon_01", Legendary = "INV_Hammer_Unique_Sulfuras",
}

------------------------------------------------------------------------------
-- Map art in a frame
------------------------------------------------------------------------------

local function Pow2(px) -- an overlay's last tile is stored at the next power of two, 16 at least
    local size = 16
    while size < px do size = size * 2 end
    return size
end

local function Tile(holder, list, index, sublevel)
    local tile = holder[list][index]
    if not tile then
        tile = holder:CreateTexture(nil, "BACKGROUND", nil, sublevel)
        if holder.mask then tile:AddMaskTexture(holder.mask) end
        holder[list][index] = tile
    end
    return tile
end

-- The dungeon journal's paintings fill 394 x 425 texels of their 512 x 512 file.
local JOURNAL_W, JOURNAL_H, JOURNAL_FILE = 394, 425, 512

-- A painting filling holder (w x h), cropped to fit: a journal file ID, or a Forever dungeon's loading
-- screen packaged with Lorebound_Data: { texture, file width and height, the painting's top row and height }
-- (make_lore.py's packaged_screen).
local function DrawJournal(holder, painting, w, h)
    local file, usedW, usedH, fileW, fileH, top = painting, JOURNAL_W, JOURNAL_H, JOURNAL_FILE, JOURNAL_FILE, 0
    if type(painting) == "table" then
        file, fileW, fileH, top, usedH = painting[1], painting[2], painting[3], painting[4], painting[5]
        usedW = fileW
    end
    local art = holder.journal
    if not art then
        art = holder:CreateTexture(nil, "BACKGROUND", nil, -6)
        art:SetAllPoints()
        if holder.mask then art:AddMaskTexture(holder.mask) end
        holder.journal = art
    end
    local u0, u1, v0, v1 = 0, usedW, 0, usedH
    if w / h > usedW / usedH then
        local shown = usedW * h / w -- wider than the painting: a band across its middle
        v0 = (usedH - shown) / 2
        v1 = v0 + shown
    else
        local shown = usedH * w / h
        u0 = (usedW - shown) / 2
        u1 = u0 + shown
    end
    art:SetTexture(file, nil, nil, "TRILINEAR")
    art:SetTexCoord(u0 / fileW, u1 / fileW, (top + v0) / fileH, (top + v1) / fileH)
    art:Show()
end

-- A zone's map art laid out in holder (w x h): "cover" fills it (cropped), else it fits inside. Fully
-- revealed: every sub-zone's overlay is painted over the base art (the game itself paints only the parts
-- you've explored; Lorebound_Data's reveal table has them all). Tiles take holder.mask if it has one.
-- Returns the map's drawn size and offset, for pins; nil when the zone has no map art. journal: a
-- dungeon's or raid's painting to show instead of its map. Drawn again only when something changes.
function ns.DrawArt(holder, uiMap, w, h, cover, journal)
    local key = ("%s:%d:%d:%s:%s"):format(tostring(uiMap), math.floor(w), math.floor(h), tostring(cover),
        tostring(journal))
    if holder.key == key then return unpack(holder.drawn) end
    holder.key, holder.drawn = key, {}
    holder.tiles = holder.tiles or {}
    holder.overlays = holder.overlays or {}
    for _, tile in ipairs(holder.tiles) do tile:Hide() end
    for _, tile in ipairs(holder.overlays) do tile:Hide() end
    if holder.journal then holder.journal:Hide() end
    if journal then
        DrawJournal(holder, journal, w, h)
        return nil
    end
    if not uiMap then return nil end
    local layers = C_Map.GetMapArtLayers(uiMap)
    local layer = layers and layers[1]
    local files = layer and C_Map.GetMapArtLayerTextures(uiMap, 1)
    if not files or #files == 0 or not layer.layerWidth or layer.layerWidth == 0 then return nil end
    local lw, lh, tw, th = layer.layerWidth, layer.layerHeight, layer.tileWidth, layer.tileHeight
    local scale = cover and math.max(w / lw, h / lh) or math.min(w / lw, h / lh)
    local mw, mh = lw * scale, lh * scale
    local ox, oy = (w - mw) / 2, (h - mh) / 2
    local cols = math.ceil(lw / tw)
    for i, file in ipairs(files) do
        local tile = Tile(holder, "tiles", i, -6)
        local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
        -- The last column and row hang past the map's edge (1002 x 668 drawn on 1024 x 768): cropped.
        local u = math.min(1, (lw - col * tw) / tw)
        local v = math.min(1, (lh - row * th) / th)
        local left, top = ox + col * tw * scale, oy + row * th * scale
        -- Only tiles that land in the frame (a strip of a map uses a few of its twelve).
        if u > 0 and v > 0 and left < w and top < h and left + tw * u * scale > 0 and top + th * v * scale > 0 then
            tile:SetTexture(file, nil, nil, "TRILINEAR")
            tile:SetTexCoord(0, u, 0, v)
            tile:SetSize(tw * u * scale, th * v * scale)
            tile:ClearAllPoints()
            tile:SetPoint("TOPLEFT", holder, "TOPLEFT", left, -top)
            tile:Show()
        end
    end
    -- Every explorable sub-zone, painted over the base art.
    local reveal = ns.data and ns.data.reveal
    local art = reveal and C_Map.GetMapArtID and C_Map.GetMapArtID(uiMap)
    local used = 0
    for _, overlay in ipairs(art and reveal[art] or {}) do
        local ow, oh, x, y = overlay[1], overlay[2], overlay[3], overlay[4]
        local cols, rows = math.ceil(ow / tw), math.ceil(oh / th)
        for r = 1, rows do
            local ph = r < rows and th or oh - th * (rows - 1)
            local fh = r < rows and th or Pow2(ph)
            for c = 1, cols do
                local pw = c < cols and tw or ow - tw * (cols - 1)
                local fw = c < cols and tw or Pow2(pw)
                local left, top = ox + (x + tw * (c - 1)) * scale, oy + (y + th * (r - 1)) * scale
                local file = overlay[4 + (r - 1) * cols + c]
                if file and left < w and top < h and left + pw * scale > 0 and top + ph * scale > 0 then
                    used = used + 1
                    local tile = Tile(holder, "overlays", used, -5)
                    tile:SetTexture(file, nil, nil, "TRILINEAR")
                    tile:SetTexCoord(0, pw / fw, 0, ph / fh)
                    tile:SetSize(pw * scale, ph * scale)
                    tile:ClearAllPoints()
                    tile:SetPoint("TOPLEFT", holder, "TOPLEFT", left, -top)
                    tile:Show()
                end
            end
        end
    end
    holder.drawn = { mw, mh, ox, oy }
    return mw, mh, ox, oy
end

------------------------------------------------------------------------------
-- What's earned
------------------------------------------------------------------------------

-- The key a badge is kept under: a zone's name, "group:N" for a continent, "seal" for everything.
local function KeyOf(kind, value)
    if kind == "zone" then return ns.Lore.Zone(value) end
    if kind == "group" then return "group:" .. value end
    return "seal"
end

local function Closed(kind, value)
    local done, total
    if kind == "zone" then
        done, total = ns.Lore.Count(value)
    elseif kind == "group" then
        done, total = ns.Lore.GroupCount(value)
    else
        done, total = ns.Lore.TotalCount()
    end
    return total > 0 and done >= total, done, total
end

-- Notes every badge whose ring is closed now (after a recount). Returns the keys newly earned.
function Badge.Record()
    local badges, now, new = ns.charDB.badges, time(), nil
    local function Check(kind, value)
        local key = KeyOf(kind, value)
        if key and not badges[key] and Closed(kind, value) then
            badges[key] = now
            new = new or {}
            new[#new + 1] = key
        end
    end
    for zone in ipairs(ns.Lore.Zones()) do Check("zone", zone) end
    Check("group", 1)
    Check("group", 2)
    Check("seal")
    return new
end

-- When a badge was earned (a time), or nil.
function Badge.Earned(kind, value)
    local key = KeyOf(kind, value)
    return key and ns.charDB.badges[key]
end

function Badge.Name(kind, value)
    if kind == "seal" then return "the Lorebound Seal" end
    if kind == "group" then return ("the %s Crest"):format(ns.Lore.Groups()[value] or "?") end
    local name, group = ns.Lore.Zone(value)
    return ("the %s %s"):format(name or "?", WORDS[SHAPES[group] or "Medal"])
end

-- For the inspector: done, total and locked out, and the first and latest turn-ins (noted since
-- Lorebound was installed) among the quests the badge covers.
function Badge.Stats(kind, value)
    local Lore, turned = ns.Lore, ns.charDB.turned
    local zones = {}
    if kind == "zone" then
        zones[1] = value
    else
        for zone, z in ipairs(Lore.Zones()) do
            if (kind == "group" and z[2] == value) or (kind == "seal" and Lore.IN_TOTAL[z[2]]) then
                zones[#zones + 1] = zone
            end
        end
    end
    local done, total, locked, first, last = 0, 0, 0, nil, nil
    for _, zone in ipairs(zones) do
        local d, t, l = Lore.Count(zone)
        done, total, locked = done + d, total + t, locked + l
        for _, id in ipairs(Lore.ZoneQuests(zone)) do
            local at = turned[id]
            if at then
                first = math.min(first or at, at)
                last = math.max(last or at, at)
            end
        end
    end
    return done, total, locked, first, last
end

function Badge.Count()
    local earned, all = 0, 0
    for zone in ipairs(ns.Lore.Zones()) do
        local _, total = ns.Lore.Count(zone)
        if total > 0 then
            all = all + 1
            if Badge.Earned("zone", zone) then earned = earned + 1 end
        end
    end
    return earned, all
end

------------------------------------------------------------------------------
-- The widget
------------------------------------------------------------------------------

local Widget = {}

local function SetShape(badge, shape)
    if badge.shape == shape then return end
    badge.shape = shape
    badge.rim:SetTexture(MEDIA .. "Badge" .. shape)
    badge.mask:SetTexture(MEDIA .. "Badge" .. shape .. "Mask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
end

local function Paint(badge, earned)
    local grey = not earned
    local shade = grey and 0.4 or 1
    for _, list in ipairs({ badge.window.tiles or {}, badge.window.overlays or {}, { badge.window.journal } }) do
        for _, tile in ipairs(list) do
            tile:SetDesaturated(grey)
            tile:SetVertexColor(shade, shade, shade)
        end
    end
    badge.icon:SetDesaturated(grey)
    badge.icon:SetVertexColor(grey and 0.45 or 1, grey and 0.45 or 1, grey and 0.45 or 1)
    badge.rim:SetDesaturated(grey)
    badge.rim:SetVertexColor(grey and 0.55 or 1, grey and 0.55 or 1, grey and 0.55 or 1)
    badge.glow:SetShown(earned and true or false)
end

-- kind: "zone" (value = zone), "group" (value = 1 or 2: a continent's crest) or "seal".
function Widget:Set(kind, value)
    local size = self:GetWidth()
    local shape, uiMap, icon, journal = "Crest", nil, nil, nil
    if kind == "zone" then
        local name, group, map, painting = ns.Lore.Zone(value)
        shape = SHAPES[group] or "Medal"
        uiMap, journal = map, painting
        icon = ZONE_ICONS[name]
    elseif kind == "group" then
        uiMap = Badge.GROUP_MAPS[value]
    else
        icon = "INV_Misc_Book_09"
    end
    SetShape(self, shape)
    if icon or not (uiMap or journal) then
        self.window:SetSize(size, size)
        ns.DrawArt(self.window, nil, size, size)
        self.icon:SetTexture(ICONS .. (icon or "INV_Misc_Book_09"))
        self.icon:Show()
    else
        self.icon:Hide()
        -- The art fills a square the size of the opening, centred on the badge (as the mask's opening is);
        -- the inspector's a little larger, so it can slide behind the rim as the badge turns.
        local inner = size * WINDOW[shape] * (self.leanArea and 1.3 or 1)
        self.window:SetSize(inner, inner)
        ns.DrawArt(self.window, uiMap, inner, inner, true, journal)
    end
    local closed, done, total = Closed(kind, value)
    local earned = closed or Badge.Earned(kind, value) ~= nil
    Paint(self, earned)
    self.earned = earned
    self.label:SetText(earned and "" or ("%d%%"):format(total > 0 and math.floor(done / total * 100) or 0))
    if self.leanArea then self:RefreshTilt() end
    return earned
end

function ns.NewBadge(parent, size)
    local badge = CreateFrame("Frame", nil, parent)
    badge:SetSize(size, size)
    for key, method in pairs(Widget) do badge[key] = method end

    badge.glow = badge:CreateTexture(nil, "BACKGROUND", nil, -1)
    badge.glow:SetTexture(MEDIA .. "Glow")
    badge.glow:SetBlendMode("ADD")
    badge.glow:SetPoint("CENTER")
    badge.glow:SetSize(size * 1.5, size * 1.5)
    badge.glow:SetVertexColor(1, 0.8, 0.3, 0.8)
    badge.glow:Hide()

    -- The window: map art (or an icon) seen through the badge's shape.
    local window = CreateFrame("Frame", nil, badge)
    window:SetPoint("CENTER")
    window:SetSize(size, size)
    badge.window = window
    badge.mask = window:CreateMaskTexture()
    badge.mask:SetAllPoints(badge)
    window.mask = badge.mask
    badge.icon = window:CreateTexture(nil, "ARTWORK")
    badge.icon:SetPoint("CENTER")
    badge.icon:SetSize(size * 0.8, size * 0.8)
    badge.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    badge.icon:AddMaskTexture(badge.mask)

    local over = CreateFrame("Frame", nil, badge)
    over:SetAllPoints()
    over:SetFrameLevel(window:GetFrameLevel() + 2)
    badge.over = over
    badge.rim = over:CreateTexture(nil, "OVERLAY")
    badge.rim:SetAllPoints()
    badge.label = over:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    badge.label:SetPoint("CENTER")
    badge.label:SetShadowOffset(1, -1)
    SetShape(badge, "Medal")
    return badge
end

-- A slow band of light across the badge (the inspector's), every few seconds while it's shown.
function Widget:EnableShine()
    if self.shine then return end
    local size = self:GetWidth()
    local shine = self.window:CreateTexture(nil, "OVERLAY", nil, 2)
    shine:SetTexture(ns.MEDIA .. "Shine")
    shine:SetBlendMode("ADD")
    shine:SetSize(size, size)
    shine:SetPoint("CENTER", self, "CENTER", -size, 0)
    shine:AddMaskTexture(self.mask)
    local sweep = shine:CreateAnimationGroup()
    sweep:SetLooping("REPEAT")
    local move = sweep:CreateAnimation("Translation")
    move:SetOffset(size * 2, 0)
    move:SetDuration(1.6)
    move:SetSmoothing("IN_OUT")
    move:SetStartDelay(2.4)
    self.shine, self.sweep = shine, sweep
    self:HookScript("OnShow", function() sweep:Play() end)
    self:HookScript("OnHide", function() sweep:Stop() end)
    if self:IsVisible() then sweep:Play() end
end

------------------------------------------------------------------------------
-- Leaning and spinning (the inspector's)
------------------------------------------------------------------------------

-- The inspector's badge as a thing in the hand: with the cursor near it, it leans to face it, and eases back
-- flat when the cursor goes; dragged sideways it spins, coasts when let go, slows and settles facing you; a
-- click gives it one whole turn. Drawn in perspective by moving each texture's corners (SetVertexOffset); the
-- map sits a little behind the rim (drawn larger, it slides against the lean), and the art's cut-out (the
-- mask) is moved and sized to where the rim's edges now fall. Still when nothing moves.
local LEAN = 0.38            -- radians at most, either way, leaning toward the cursor
local NEAR = 1.6             -- the cursor leans it within this many half-widths of its middle
local DEPTH = 520            -- the eye's distance in points: smaller is a stronger perspective
local BEHIND = 0.16          -- how far the map slides against the turn, as a share of the half-width
local FOLLOW = 8             -- how fast it turns to a new lean
local SPIN_PER_POINT = 0.014 -- radians a point dragged turns it
local FRICTION = 2.4         -- how fast a spin let go slows down
local KEEP = 1.2             -- under this speed (radians a second) it settles facing you
local SETTLE = 6             -- how fast it settles
local CLICK = 4              -- points moved at most for a click
local TAU = 2 * math.pi

-- Where a point (x, y) of the badge, from its middle, is seen once turned by yaw (its right side away from
-- you) and pitch (its top away from you).
local function Project(x, y, cosYaw, sinYaw, cosPitch, sinPitch)
    local z = x * sinYaw
    local y2 = y * cosPitch - z * sinPitch
    local z2 = y * sinPitch + z * cosPitch
    local seen = DEPTH / (DEPTH + z2)
    return x * cosYaw * seen, y2 * seen
end

-- The shown textures: the art's (they slide behind) and the rim's.
local function Tilted(badge)
    local art, rim = {}, {}
    for _, holder in ipairs({ badge.window, badge.over }) do
        for _, region in ipairs({ holder:GetRegions() }) do
            if region:GetObjectType() == "Texture" and region:IsShown() and region ~= badge.shine then
                local list = holder == badge.window and art or rim
                list[#list + 1] = region
            end
        end
    end
    return art, rim
end

local function Clamp(v) return math.max(-1, math.min(1, v)) end

-- The spin: dragged, coasting, or settling on facing you (or on a click's whole turn).
local function Spin(badge, elapsed, cursorX)
    if badge.dragging then
        local step = cursorX - badge.lastX
        badge.lastX = cursorX
        badge.moved = badge.moved + math.abs(step)
        badge.spin = badge.spin + step * SPIN_PER_POINT
        badge.speed = badge.speed + (step * SPIN_PER_POINT / math.max(elapsed, 0.001) - badge.speed) * math.min(1, elapsed * 12)
    elseif math.abs(badge.speed) > KEEP then
        badge.spin = badge.spin + badge.speed * elapsed
        badge.speed = badge.speed * math.max(0, 1 - FRICTION * elapsed)
    else
        badge.speed = 0
        local target = badge.spinTo or math.floor(badge.spin / TAU + 0.5) * TAU
        badge.spin = badge.spin + (target - badge.spin) * math.min(1, elapsed * SETTLE)
        if math.abs(target - badge.spin) < 0.002 then
            badge.spin, badge.spinTo = 0, nil
        end
    end
end

-- Each texture's corners where the turned badge shows them, slid by (dx, dy).
local function Place(list, cx, cy, dx, dy, cosYaw, sinYaw, cosPitch, sinPitch)
    for _, region in ipairs(list) do
        local left, right, top, bottom = region:GetLeft(), region:GetRight(), region:GetTop(), region:GetBottom()
        if left then
            left, right, top, bottom = left - cx, right - cx, top - cy, bottom - cy
            local x1, y1 = Project(left, top, cosYaw, sinYaw, cosPitch, sinPitch)
            local x2, y2 = Project(left, bottom, cosYaw, sinYaw, cosPitch, sinPitch)
            local x3, y3 = Project(right, top, cosYaw, sinYaw, cosPitch, sinPitch)
            local x4, y4 = Project(right, bottom, cosYaw, sinYaw, cosPitch, sinPitch)
            region:SetVertexOffset(1, x1 - left + dx, y1 - top + dy)
            region:SetVertexOffset(2, x2 - left + dx, y2 - bottom + dy)
            region:SetVertexOffset(3, x3 - right + dx, y3 - top + dy)
            region:SetVertexOffset(4, x4 - right + dx, y4 - bottom + dy)
        end
    end
end

local function Lean(badge, elapsed)
    local cx, cy = badge:GetCenter()
    if not cx then return end
    local half = badge:GetWidth() / 2
    local scale = badge:GetEffectiveScale()
    local mx, my = GetCursorPosition()
    mx, my = mx / scale - cx, my / scale - cy
    Spin(badge, elapsed, mx)
    local wantX, wantY = 0, 0
    local near = not ns.GamepadUI() and badge.leanArea:IsMouseOver() and (mx * mx + my * my) < (half * NEAR) ^ 2
    if near and not badge.dragging then wantX, wantY = Clamp(mx / half), Clamp(my / half) end
    local k = math.min(1, elapsed * FOLLOW)
    badge.leanX = badge.leanX + (wantX - badge.leanX) * k
    badge.leanY = badge.leanY + (wantY - badge.leanY) * k

    -- Still: nothing to draw again once it has been drawn flat.
    local resting = badge.spin == 0 and not badge.dragging and math.abs(badge.leanX) < 0.002 and math.abs(badge.leanY) < 0.002
    if resting and badge.drawnFlat then return end
    if resting then badge.leanX, badge.leanY = 0, 0 end
    badge.drawnFlat = resting

    local yaw, pitch = badge.leanX * LEAN + badge.spin, badge.leanY * LEAN
    local cosYaw, sinYaw, cosPitch, sinPitch = math.cos(yaw), math.sin(yaw), math.cos(pitch), math.sin(pitch)
    Place(badge.tiltRim, cx, cy, 0, 0, cosYaw, sinYaw, cosPitch, sinPitch)
    Place(badge.tiltArt, cx, cy, -sinYaw * half * BEHIND, -sinPitch * half * BEHIND, cosYaw, sinYaw, cosPitch, sinPitch)
    -- The cut-out where the rim's edges now fall: between its projected left and right, top and bottom.
    local left = Project(-half, 0, cosYaw, sinYaw, cosPitch, sinPitch)
    local right = Project(half, 0, cosYaw, sinYaw, cosPitch, sinPitch)
    local _, top = Project(0, half, cosYaw, sinYaw, cosPitch, sinPitch)
    local _, bottom = Project(0, -half, cosYaw, sinYaw, cosPitch, sinPitch)
    badge.mask:ClearAllPoints()
    badge.mask:SetPoint("CENTER", badge, "CENTER", (left + right) / 2, (top + bottom) / 2)
    badge.mask:SetSize(math.max(1, math.abs(right - left)), math.max(1, math.abs(top - bottom)))
end

-- area: the frame the cursor leans it from (the inspector's page).
function Widget:EnableTilt(area)
    if self.leanArea then return end
    self.leanArea, self.leanX, self.leanY = area, 0, 0
    self.spin, self.speed, self.moved = 0, 0, 0
    self:EnableMouse(true)
    self:SetScript("OnMouseDown", function(badge, button)
        if button ~= "LeftButton" then return end
        badge.dragging, badge.moved, badge.speed, badge.spinTo = true, 0, 0, nil
        badge.lastX = GetCursorPosition() / badge:GetEffectiveScale() - badge:GetCenter()
    end)
    self:SetScript("OnMouseUp", function(badge, button)
        if button ~= "LeftButton" or not badge.dragging then return end
        badge.dragging = false
        if badge.moved <= CLICK then -- a click: one whole turn
            badge.speed = 0
            badge.spinTo = math.floor(badge.spin / TAU + 0.5) * TAU + TAU
        end
    end)
    self:HookScript("OnHide", function(badge)
        badge.dragging, badge.speed, badge.spin, badge.spinTo = false, 0, 0, nil
        badge.leanX, badge.leanY, badge.drawnFlat = 0, 0, false
    end)
    self:RefreshTilt()
    self:SetScript("OnUpdate", Lean)
end

-- What turns: every texture of the art and the rim (Set may have made new tiles); drawn again next frame.
function Widget:RefreshTilt()
    if self.rim.SetVertexOffset then
        self.tiltArt, self.tiltRim = Tilted(self)
    else
        self.tiltArt, self.tiltRim = {}, {}
    end
    self.drawnFlat = false
end
