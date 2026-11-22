local _, ns = ...

-- A ring that fills clockwise from twelve o'clock. The track is the ring drawn dark; the fill is two
-- half-rings, each masked to one side of the ring and rotated by exactly the share to show (the right
-- one sweeps the first half, the left one the second), so the direction never depends on anything but
-- this arithmetic. Round caps at both ends, the leading end lighter (a fading highlight rotated to it)
-- with a soft shadow under its cap, and on the big rings a small glyph in the start cap. Animated only
-- while it moves: the OnUpdate is cleared after.

local MEDIA = "Interface\\AddOns\\Lorebound\\Media\\"
ns.MEDIA = MEDIA

-- Each ring texture's band, as a share of the texture's width (make_lore_art.py: 11%, 15% and 23% of
-- a 254-texel diameter in 256).
local BAND = { [1] = 0.11 * 254 / 256, [2] = 0.149 * 254 / 256, [3] = 0.229 * 254 / 256 }
local DURATION = 0.9 -- seconds a ring takes to move
local TAU = 2 * math.pi

-- Each colour, and the lighter one its fill runs to at the leading end.
ns.COLORS = {
    zone = { 1.00, 0.33, 0.24, lift = { 1.00, 0.66, 0.40 } },   -- ember: the zone
    group = { 0.64, 0.40, 1.00, lift = { 0.86, 0.70, 1.00 } },  -- arcane: the continent or group
    total = { 0.12, 0.86, 0.62, lift = { 0.60, 1.00, 0.82 } },  -- jade: the whole Lorebound count
    gold = { 1.00, 0.76, 0.20, lift = { 1.00, 0.92, 0.55 } },   -- a closed ring
}

local Ring = {}

local function Animate(self, elapsed)
    self.spent = self.spent + elapsed
    local progress = math.min(1, self.spent / DURATION)
    local eased = 1 - (1 - progress) ^ 3
    self:Draw(self.from + (self.to - self.from) * eased)
    if progress >= 1 then
        self:SetScript("OnUpdate", nil)
        local done = self.onDone
        self.onDone = nil
        if done then done(self) end
    end
end

-- Shows the share (0 to 1). Animated from where it is when asked; onDone runs when it gets there.
function Ring:SetProgress(share, animate, onDone)
    share = math.max(0, math.min(1, share or 0))
    if animate and self:IsVisible() and math.abs(share - (self.shown or 0)) > 0.0005 then
        self.from, self.to, self.spent, self.onDone = self.shown or 0, share, 0, onDone
        self:SetScript("OnUpdate", Animate)
    else
        self:SetScript("OnUpdate", nil)
        self:Draw(share)
        if onDone then onDone(self) end
    end
end

-- A point on the band's middle at a share of the way round, clockwise from twelve o'clock.
local function Place(region, ring, share, ahead)
    local angle = share * TAU + (ahead or 0)
    region:ClearAllPoints()
    region:SetPoint("CENTER", ring, "CENTER", ring.radius * math.sin(angle), ring.radius * math.cos(angle))
end

function Ring:Draw(share)
    self.shown = share
    local right, left = self.right, self.left
    if share <= 0.0005 then
        right:Hide()
        left:Hide()
        self.head:Hide()
        self.startCap:Hide()
        self.endCap:Hide()
        self.shadow:Hide()
        if self.glyph then self.glyph:Hide() end
        return
    end
    -- Each half-ring starts on the right side and is turned clockwise by (share x a turn - half a turn):
    -- shown through its mask, that leaves exactly 0..share of the ring. (Positive rotation is
    -- counter-clockwise in the game, hence the minus.)
    local turn = share * TAU - math.pi
    right:SetRotation(-math.min(turn, 0))
    right:Show()
    if share > 0.5 then
        left:SetRotation(-turn)
        left:Show()
    else
        left:Hide()
    end
    -- The lighter leading end: a quarter-ring highlight ending at the fill's end, faded in over the
    -- first quarter so it never shows on the track behind the start.
    self.head:SetRotation(-share * TAU)
    self.head:SetAlpha(math.min(1, share / 0.25) ^ 2 * 0.85)
    self.head:Show()
    self.startCap:Show()
    if self.glyph then self.glyph:Show() end
    Place(self.endCap, self, share)
    Place(self.shadow, self, share, 0.05)
    self.endCap:Show()
    self.shadow:Show()
end

function Ring:SetColor(r, g, b, trackAlpha, lift)
    self.color = { r, g, b }
    lift = lift or { r, g, b }
    self.track:SetVertexColor(r, g, b, trackAlpha or 0.22)
    self.right:SetVertexColor(r, g, b, 1)
    self.left:SetVertexColor(r, g, b, 1)
    self.startCap:SetVertexColor(r, g, b, 1)
    self.head:SetVertexColor(lift[1] * 0.7, lift[2] * 0.7, lift[3] * 0.7)
    self.endCap:SetVertexColor(lift[1], lift[2], lift[3], 1)
    self.glow:SetVertexColor(r, g, b, 1)
end

-- color: one of ns.COLORS (with its lift).
function Ring:Paint(color, trackAlpha)
    self:SetColor(color[1], color[2], color[3], trackAlpha, color.lift)
end

-- A soft halo around a closed ring.
function Ring:SetGlow(on)
    self.glow:SetShown(on and true or false)
end

local GLYPHS = { zone = "Pin", group = "Spark", total = "Book" }

-- art: "Ring1", "Ring2" or "Ring3" (thin to thick); color: one of ns.COLORS; glyph: "zone", "group" or
-- "total" for the start cap's glyph (big rings only).
function ns.NewRing(parent, size, art, color, glyph)
    local ring = CreateFrame("Frame", nil, parent)
    ring:SetSize(size, size)
    for key, method in pairs(Ring) do ring[key] = method end
    local number = tonumber(art:match("%d")) or 2
    local band = BAND[number] * size
    local small = size <= 64 and "s" or "" -- small rings sample small textures

    ring.glow = ring:CreateTexture(nil, "BACKGROUND", nil, -1)
    ring.glow:SetTexture(MEDIA .. "Glow")
    ring.glow:SetPoint("CENTER")
    ring.glow:SetSize(size * 1.35, size * 1.35)
    ring.glow:SetBlendMode("ADD")
    ring.glow:Hide()

    ring.track = ring:CreateTexture(nil, "BACKGROUND")
    ring.track:SetAllPoints()
    ring.track:SetTexture(MEDIA .. "Ring" .. number .. small)

    local function Half(mask)
        local half = ring:CreateTexture(nil, "ARTWORK")
        half:SetAllPoints()
        -- Clamped to clear: turned, the texture's corners sample outside it.
        half:SetTexture(MEDIA .. "RingHalf" .. number .. small, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        local side = ring:CreateMaskTexture()
        side:SetTexture(MEDIA .. mask, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        side:SetAllPoints(ring)
        half:AddMaskTexture(side)
        half:Hide()
        return half
    end
    ring.right = Half("MaskRight")
    ring.left = Half("MaskLeft")

    ring.head = ring:CreateTexture(nil, "ARTWORK", nil, 2)
    ring.head:SetAllPoints()
    ring.head:SetTexture(MEDIA .. "RingHead" .. number .. small, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    ring.head:SetBlendMode("ADD")
    ring.head:Hide()

    local caps = CreateFrame("Frame", nil, ring)
    caps:SetAllPoints()
    caps:SetFrameLevel(ring:GetFrameLevel() + 2)
    ring.caps = caps
    ring.radius = size * 127 / 256 - band / 2
    local function Dot(sub, scale)
        local dot = caps:CreateTexture(nil, "OVERLAY", nil, sub)
        dot:SetTexture(MEDIA .. "Dot")
        dot:SetSize(band * scale, band * scale)
        dot:Hide()
        return dot
    end
    ring.startCap = Dot(1, 1)
    Place(ring.startCap, ring, 0)
    ring.shadow = Dot(2, 1.12)
    ring.shadow:SetVertexColor(0, 0, 0, 0.5)
    ring.endCap = Dot(3, 1)
    if glyph and size >= 90 then
        ring.glyph = caps:CreateTexture(nil, "OVERLAY", nil, 4)
        ring.glyph:SetTexture(MEDIA .. GLYPHS[glyph])
        ring.glyph:SetSize(band * 0.62, band * 0.62)
        ring.glyph:SetPoint("CENTER", ring.startCap, "CENTER")
        ring.glyph:SetVertexColor(0.08, 0.06, 0.05, 0.85)
        ring.glyph:Hide()
    end

    -- Text in the middle (a share, a count), for whoever wants it.
    ring.label = caps:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ring.label:SetPoint("CENTER")

    ring:Paint(color or ns.COLORS.zone)
    ring.shown = 0
    return ring
end
