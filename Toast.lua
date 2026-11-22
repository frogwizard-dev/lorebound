local _, ns = ...

-- After each quest turned in: a toast near the top of the screen with the zone's ring ticking up. When a
-- turn-in closes a ring (the zone, its continent or group, or the whole Lorebound count) a bigger banner
-- instead: the ring sweeps shut, a halo bursts, sparks fly out, a fanfare plays and the badge it earns
-- (Badge.lua) takes the ring's place. Our own frame on UIParent, built the first time it's needed;
-- clicking it opens the journal on that zone.

local Toast = {}
ns.Toast = Toast

local HOLD, BIG_HOLD = 6, 10 -- seconds on screen before fading (held while the mouse is over it)
local BEAT = 0.45            -- the pause between the toast arriving and its ring moving
local MOVE, SWEEP = 1.4, 2.0 -- seconds the ring ticks up, and sweeps shut from empty when it closes
local SPARKS = 16
local TOP = -140             -- the toast's place: this far down from the top of the screen
local SLIDE = 44             -- how far above it it starts, sliding down into place
local BIG_TITLE = _G.Game24Font and "Game24Font" or "GameFontNormalHuge"
local frame, fadeTimer
local shown = 0              -- counts toasts, so a delayed step of one replaced meanwhile doesn't run
local celebrating = false -- a banner is up: plain toasts wait for it
local waiting             -- the latest plain toast held back meanwhile
local testing = false     -- a settings test button's pretend turn-in: shown and heard whatever the settings say

local function FadeOut()
    fadeTimer = nil
    if frame and frame:IsShown() then frame.fade:Play() end
end

local function Hold(seconds)
    if fadeTimer then fadeTimer:Cancel() end
    fadeTimer = C_Timer.NewTimer(seconds, FadeOut)
end

local function Build()
    frame = CreateFrame("Button", "LoreboundToast", UIParent, "BackdropTemplate")
    frame:SetFrameStrata("DIALOG") -- over the journal (HIGH), which it often sits on
    frame:SetPoint("TOP", UIParent, "TOP", 0, TOP)
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    frame:SetBackdropColor(0.03, 0.03, 0.05, 0.94)
    frame:SetBackdropBorderColor(0.32, 0.32, 0.38, 1)
    frame:RegisterForClicks("LeftButtonUp")
    frame:SetScript("OnClick", function(self)
        self:Hide()
        if self.zone then ns.Journal:Open(self.zone) end
    end)
    -- Held while the mouse is over it, then a moment more.
    frame:SetScript("OnEnter", function(self)
        if fadeTimer then fadeTimer:Cancel() fadeTimer = nil end
        self.fade:Stop()
        self:SetAlpha(1)
    end)
    frame:SetScript("OnLeave", function() Hold(2.5) end)
    frame:Hide()

    -- Arriving: fading in as it settles from a little smaller. Closing a ring: a jolt as it shuts.
    local enter = frame:CreateAnimationGroup()
    local settle = enter:CreateAnimation("Scale")
    settle:SetScaleFrom(0.86, 0.86)
    settle:SetScaleTo(1, 1)
    settle:SetDuration(0.35)
    settle:SetSmoothing("OUT")
    local arrive = enter:CreateAnimation("Alpha")
    arrive:SetFromAlpha(0)
    arrive:SetToAlpha(1)
    arrive:SetDuration(0.25)
    frame.enter = enter
    local jolt = frame:CreateAnimationGroup()
    local punch = jolt:CreateAnimation("Scale")
    punch:SetScaleFrom(1.07, 1.07)
    punch:SetScaleTo(1, 1)
    punch:SetDuration(0.4)
    punch:SetSmoothing("OUT")
    frame.jolt = jolt

    frame.small = ns.NewRing(frame, 52, "Ring2", ns.COLORS.zone)
    frame.small:SetPoint("LEFT", 12, 0)
    frame.big = ns.NewRing(frame, 92, "Ring2", ns.COLORS.zone)
    frame.big:SetPoint("LEFT", 16, 0)
    frame.badge = ns.NewBadge(frame, 96)
    frame.badge:SetPoint("CENTER", frame.big, "CENTER")
    frame.badge:SetFrameLevel(frame.big.caps:GetFrameLevel() + 2)
    frame.badge:Hide()
    local reveal = frame.badge:CreateAnimationGroup()
    local pop = reveal:CreateAnimation("Scale")
    pop:SetScaleFrom(0.3, 0.3)
    pop:SetScaleTo(1, 1)
    pop:SetDuration(0.7)
    pop:SetSmoothing("OUT")
    local appear = reveal:CreateAnimation("Alpha")
    appear:SetFromAlpha(0)
    appear:SetToAlpha(1)
    appear:SetDuration(0.4)
    frame.reveal = reveal

    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    frame.line1 = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    frame.line2 = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    for _, text in ipairs({ frame.title, frame.line1, frame.line2 }) do
        text:SetJustifyH("LEFT")
        text:SetWordWrap(false)
    end

    -- "+1" that rises out of the top of the ring (clear of the zone's name), on a layer above the ring.
    local over = CreateFrame("Frame", nil, frame)
    over:SetAllPoints()
    over:SetFrameLevel(frame.small.caps:GetFrameLevel() + 2)
    frame.plus = over:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    frame.plus:SetTextColor(1, 0.82, 0.25)
    frame.plus:SetText("+1")
    frame.plus:SetPoint("BOTTOM", frame.small, "TOP", 0, -4)
    frame.plus:SetAlpha(0)
    local up = frame.plus:CreateAnimationGroup()
    local popIn = up:CreateAnimation("Scale")
    popIn:SetScaleFrom(1.6, 1.6)
    popIn:SetScaleTo(1, 1)
    popIn:SetDuration(0.3)
    popIn:SetSmoothing("OUT")
    local rise = up:CreateAnimation("Translation")
    rise:SetOffset(0, 30)
    rise:SetDuration(1.4)
    rise:SetSmoothing("OUT")
    local show = up:CreateAnimation("Alpha")
    show:SetFromAlpha(1)
    show:SetToAlpha(0)
    show:SetDuration(1.4)
    show:SetSmoothing("IN")
    frame.plusAnim = up

    -- The small ring landing: a soft pulse of light behind it.
    local pulse = frame:CreateTexture(nil, "OVERLAY", nil, 4)
    pulse:SetTexture(ns.MEDIA .. "Glow")
    pulse:SetBlendMode("ADD")
    pulse:SetSize(90, 90)
    pulse:SetPoint("CENTER", frame.small, "CENTER")
    pulse:SetAlpha(0)
    local land = pulse:CreateAnimationGroup()
    local widen = land:CreateAnimation("Scale")
    widen:SetScaleFrom(0.8, 0.8)
    widen:SetScaleTo(1.35, 1.35)
    widen:SetDuration(0.8)
    widen:SetSmoothing("OUT")
    local dim = land:CreateAnimation("Alpha")
    dim:SetFromAlpha(0.7)
    dim:SetToAlpha(0)
    dim:SetDuration(0.8)
    frame.pulse, frame.land = pulse, land

    -- The burst: a halo that swells and fades, and sparks flying out from the ring.
    local burst = frame:CreateTexture(nil, "OVERLAY", nil, 5)
    burst:SetTexture(ns.MEDIA .. "Glow")
    burst:SetBlendMode("ADD")
    burst:SetSize(150, 150)
    burst:SetPoint("CENTER", frame.big, "CENTER")
    burst:SetAlpha(0)
    local swell = burst:CreateAnimationGroup()
    local grow = swell:CreateAnimation("Scale")
    grow:SetScaleFrom(0.6, 0.6)
    grow:SetScaleTo(2.4, 2.4)
    grow:SetDuration(1.5)
    grow:SetSmoothing("OUT")
    local fadeBurst = swell:CreateAnimation("Alpha")
    fadeBurst:SetFromAlpha(1)
    fadeBurst:SetToAlpha(0)
    fadeBurst:SetDuration(1.5)
    frame.burst, frame.swell = burst, swell
    local flash = frame:CreateTexture(nil, "OVERLAY", nil, 7)
    flash:SetTexture(ns.MEDIA .. "Halo")
    flash:SetBlendMode("ADD")
    flash:SetSize(240, 240)
    flash:SetPoint("CENTER", frame.big, "CENTER")
    flash:SetAlpha(0)
    local blaze = flash:CreateAnimationGroup()
    local bloom = blaze:CreateAnimation("Scale")
    bloom:SetScaleFrom(0.4, 0.4)
    bloom:SetScaleTo(1.2, 1.2)
    bloom:SetDuration(0.9)
    bloom:SetSmoothing("OUT")
    local fadeFlash = blaze:CreateAnimation("Alpha")
    fadeFlash:SetFromAlpha(0.9)
    fadeFlash:SetToAlpha(0)
    fadeFlash:SetDuration(0.9)
    frame.flash, frame.blaze = flash, blaze

    frame.sparks = {}
    for i = 1, SPARKS do
        local spark = frame:CreateTexture(nil, "OVERLAY", nil, 6)
        spark:SetTexture(ns.MEDIA .. "Spark")
        spark:SetBlendMode("ADD")
        spark:SetSize(22, 22)
        spark:SetPoint("CENTER", frame.big, "CENTER")
        spark:SetAlpha(0)
        local angle = (i - 1) / SPARKS * 2 * math.pi + 0.3
        local distance = 85 + (i % 3) * 24
        local fly = spark:CreateAnimationGroup()
        local move = fly:CreateAnimation("Translation")
        move:SetOffset(distance * math.sin(angle), distance * math.cos(angle))
        move:SetDuration(1.1 + (i % 4) * 0.12)
        move:SetSmoothing("OUT")
        local fadeSpark = fly:CreateAnimation("Alpha")
        fadeSpark:SetFromAlpha(1)
        fadeSpark:SetToAlpha(0)
        fadeSpark:SetDuration(1.2 + (i % 4) * 0.12)
        fadeSpark:SetSmoothing("IN")
        frame.sparks[i] = fly
    end

    local fade = frame:CreateAnimationGroup()
    local out = fade:CreateAnimation("Alpha")
    out:SetFromAlpha(1)
    out:SetToAlpha(0)
    out:SetDuration(1)
    out:SetSmoothing("IN")
    local shrink = fade:CreateAnimation("Scale")
    shrink:SetScaleFrom(1, 1)
    shrink:SetScaleTo(0.95, 0.95)
    shrink:SetDuration(1)
    fade:SetScript("OnFinished", function() frame:Hide() end)
    frame.fade = fade
    -- The slide: the anchor itself eased down, so nothing snaps back when it ends.
    frame.slideTo = function(self, elapsed)
        self.slid = math.min(1, (self.slid or 0) + elapsed / 0.45)
        local eased = 1 - (1 - self.slid) ^ 3
        self:ClearAllPoints()
        self:SetPoint("TOP", UIParent, "TOP", 0, TOP + SLIDE * (1 - eased))
        if self.slid >= 1 then self:SetScript("OnUpdate", nil) end
    end

    -- A band of light sweeping across the panel (clipped to it) when the ring lands or closes.
    local sheen = CreateFrame("Frame", nil, frame)
    sheen:SetPoint("TOPLEFT", 3, -3)
    sheen:SetPoint("BOTTOMRIGHT", -3, 3)
    sheen:SetClipsChildren(true)
    local band = sheen:CreateTexture(nil, "ARTWORK")
    band:SetTexture(ns.MEDIA .. "Shine")
    band:SetBlendMode("ADD")
    band:SetVertexColor(1, 0.9, 0.65)
    band:SetAlpha(0)
    local sweep = band:CreateAnimationGroup()
    local across = sweep:CreateAnimation("Translation")
    across:SetDuration(0.9)
    across:SetSmoothing("IN_OUT")
    local seen = sweep:CreateAnimation("Alpha")
    seen:SetFromAlpha(0.55)
    seen:SetToAlpha(0.55)
    seen:SetDuration(0.9)
    frame.band, frame.bandSweep, frame.bandAcross = band, sweep, across

    -- The banner's starburst: opening behind the badge, then turning slowly while it's up.
    local rays = frame:CreateTexture(nil, "BORDER")
    rays:SetTexture(ns.MEDIA .. "Spark")
    rays:SetBlendMode("ADD")
    rays:SetSize(230, 230)
    rays:SetVertexColor(1, 0.82, 0.35)
    rays:SetAlpha(0)
    local open = rays:CreateAnimationGroup()
    local unfold = open:CreateAnimation("Scale")
    unfold:SetScaleFrom(0.2, 0.2)
    unfold:SetScaleTo(1, 1)
    unfold:SetDuration(0.7)
    unfold:SetSmoothing("OUT")
    local light = open:CreateAnimation("Alpha")
    light:SetFromAlpha(0)
    light:SetToAlpha(0.75)
    light:SetDuration(0.5)
    open:SetScript("OnFinished", function() rays:SetAlpha(0.75) end)
    local turn = rays:CreateAnimationGroup()
    turn:SetLooping("REPEAT")
    local spin = turn:CreateAnimation("Rotation")
    spin:SetDegrees(-360)
    spin:SetDuration(16)
    frame.rays, frame.raysOpen, frame.raysTurn = rays, open, turn

    -- The banner's title, changing to "... complete!" at the close: popping in from a little larger.
    local titlePop = frame.title:CreateAnimationGroup()
    local shrinkIn = titlePop:CreateAnimation("Scale")
    shrinkIn:SetScaleFrom(1.3, 1.3)
    shrinkIn:SetScaleTo(1, 1)
    shrinkIn:SetDuration(0.4)
    shrinkIn:SetSmoothing("OUT")
    local titleIn = titlePop:CreateAnimation("Alpha")
    titleIn:SetFromAlpha(0)
    titleIn:SetToAlpha(1)
    titleIn:SetDuration(0.25)
    frame.titlePop = titlePop
    frame.linesIn = {}
    for i, text in ipairs({ frame.line1, frame.line2 }) do
        local group = text:CreateAnimationGroup()
        local fadeIn = group:CreateAnimation("Alpha")
        fadeIn:SetFromAlpha(0)
        fadeIn:SetToAlpha(1)
        fadeIn:SetDuration(0.35)
        fadeIn:SetStartDelay(0.15 * i)
        group:SetScript("OnPlay", function() text:SetAlpha(0) end)
        group:SetScript("OnFinished", function() text:SetAlpha(1) end)
        frame.linesIn[i] = group
    end

    -- The border flashing gold at the close, easing back.
    frame.flashBorder = function(self, elapsed)
        self.flashed = math.min(1, (self.flashed or 0) + elapsed / 1.4)
        local k = 1 - self.flashed
        self:SetBackdropBorderColor(0.32 + 0.68 * k, 0.32 + 0.5 * k, 0.38 - 0.13 * k, 1)
        if self.flashed >= 1 then self.fx:SetScript("OnUpdate", nil) end
    end
    frame.fx = CreateFrame("Frame", nil, frame)
    frame:SetScript("OnHide", function()
        -- Closed mid-sweep: the sweep and its reveal go (they'd only run on a hidden frame).
        frame.big:SetScript("OnUpdate", nil)
        frame.big.onDone = nil
        frame.raysTurn:Stop()
        frame:SetScript("OnUpdate", nil)
        frame:ClearAllPoints()
        frame:SetPoint("TOP", UIParent, "TOP", 0, TOP)
        celebrating = false
        local queued = waiting
        waiting = nil
        if queued then C_Timer.After(0.2, function() Toast.Show(queued) end) end
    end)
end

local function Layout(big)
    local ring = big and frame.big or frame.small
    frame.small:SetShown(not big)
    frame.big:SetShown(big)
    frame.reveal:Stop()
    frame.badge:Hide()
    frame:SetSize(big and 500 or 340, big and 138 or 76)
    frame.title:SetFontObject(big and BIG_TITLE or "GameFontNormalLarge")
    frame.rays:ClearAllPoints()
    frame.rays:SetPoint("CENTER", frame.big, "CENTER")
    local band = (big and 138 or 76) * 1.4
    frame.band:SetSize(band, band)
    frame.band:ClearAllPoints()
    frame.band:SetPoint("CENTER", frame, "LEFT", -band / 2, 0)
    frame.bandAcross:SetOffset((big and 500 or 340) + band, 0)
    local left = big and 128 or 78
    frame.title:ClearAllPoints()
    frame.title:SetPoint("TOPLEFT", left, big and -30 or -14)
    frame.title:SetPoint("TOPRIGHT", -12, big and -30 or -14)
    frame.line1:ClearAllPoints()
    frame.line1:SetPoint("TOPLEFT", frame.title, "BOTTOMLEFT", 0, -6)
    frame.line1:SetPoint("TOPRIGHT", frame.title, "BOTTOMRIGHT", 0, -6)
    frame.line2:ClearAllPoints()
    frame.line2:SetPoint("TOPLEFT", frame.line1, "BOTTOMLEFT", 0, -4)
    frame.line2:SetPoint("TOPRIGHT", frame.line1, "BOTTOMRIGHT", 0, -4)
    return ring
end

local function Present(hold)
    frame.fade:Stop()
    frame:SetAlpha(1)
    frame:Show()
    frame.enter:Stop()
    frame.enter:Play()
    frame.slid = 0
    frame:SetScript("OnUpdate", frame.slideTo)
    frame.slideTo(frame, 0)
    Hold(hold)
end

local function Sheen()
    frame.bandSweep:Stop()
    frame.bandSweep:Play()
end

local function Celebrate(ring)
    ring:SetGlow(true)
    frame.burst:SetVertexColor(unpack(ring.color))
    frame.flash:SetVertexColor(1, 0.9, 0.6)
    for _, group in ipairs({ frame.swell, frame.blaze, frame.jolt, frame.raysOpen }) do
        group:Stop()
        group:Play()
    end
    frame.raysTurn:Play()
    frame.flashed = 0
    frame.fx:SetScript("OnUpdate", function(_, elapsed) frame.flashBorder(frame, elapsed) end)
    Sheen()
    for _, fly in ipairs(frame.sparks) do
        fly:Stop()
        fly:Play()
    end
end

local function Sound(kit)
    if (ns.db.sound or testing) and kit then PlaySound(kit) end
end

-- What a toast shows for a zone: its counts, its group's and the whole count (Lore.TurnedIn's shape).
local function InfoFor(zone, allDone, allTotal)
    local Lore = ns.Lore
    local _, group = Lore.Zone(zone)
    local done, total = Lore.Count(zone)
    local groupDone, groupTotal = Lore.GroupCount(group)
    return { zone = zone, group = group, counted = Lore.IN_TOTAL[group], zoneDone = done, zoneTotal = total,
             groupDone = groupDone, groupTotal = groupTotal, allDone = allDone, allTotal = allTotal }
end

local function Has(list, key)
    for _, value in ipairs(list or {}) do
        if value == key then return true end
    end
    return false
end

-- info: Lore.TurnedIn's counts after the turn-in, or nil for a quest the list hasn't got. earned: the
-- badges this turn-in earned (Badge.Record), so a ring closed long ago isn't celebrated again.
function Toast.Show(info, earned)
    if not info or info.zoneTotal == 0 then return end
    -- A ring closed somewhere else by this turn-in (a quest there counted done with it): that one.
    if earned and not Has(earned, (ns.Lore.Zone(info.zone))) then
        for zone, entry in ipairs(ns.Lore.Zones()) do
            if Has(earned, entry[1]) then
                info = InfoFor(zone, info.allDone, info.allTotal)
                break
            end
        end
    end
    local zoneClosed = Has(earned, (ns.Lore.Zone(info.zone)))
    local groupClosed = Has(earned, "group:" .. info.group)
    local allClosed = Has(earned, "seal")
    local closing = zoneClosed or groupClosed or allClosed
    if not closing and not ns.db.toasts and not testing then return end
    if not frame then Build() end
    if celebrating and not closing and frame:IsShown() then
        waiting = info -- after the banner, never over it
        return
    end
    celebrating = closing
    shown = shown + 1
    local this = shown
    for _, group in ipairs({ frame.swell, frame.blaze, frame.jolt, frame.land, frame.raysOpen, frame.raysTurn,
        frame.bandSweep, frame.titlePop, frame.linesIn[1], frame.linesIn[2] }) do group:Stop() end
    frame.rays:SetAlpha(0)
    frame.fx:SetScript("OnUpdate", nil)
    frame:SetBackdropBorderColor(0.32, 0.32, 0.38, 1)
    frame.line1:SetAlpha(1)
    frame.line2:SetAlpha(1)
    for _, fly in ipairs(frame.sparks) do fly:Stop() end

    local Lore, colors = ns.Lore, ns.COLORS
    local zoneName = Lore.Zone(info.zone)
    local groupName = Lore.Groups()[info.group] or ""
    frame.zone = info.zone
    local ring = Layout(closing)
    ring:SetGlow(false)

    local Badge = ns.Badge
    local done, outOf, color, sound, badge
    if allClosed then
        done, outOf, color = info.allDone, info.allTotal, colors.total
        frame.title:SetText("Lorebound!")
        frame.line1:SetText(("Every one of the %d quests Lorebound counts, done."):format(outOf))
        frame.line2:SetText(("The last was in %s. You've earned %s."):format(zoneName, Badge.Name("seal")))
        sound = SOUNDKIT.UI_LEGENDARY_LOOT_TOAST
        badge = { "seal" }
    elseif groupClosed then
        done, outOf, color = info.groupDone, info.groupTotal, colors.group
        frame.title:SetText(("%s complete!"):format(groupName))
        local crest = info.group == 1 or info.group == 2
        badge = crest and { "group", info.group } or { "zone", info.zone }
        frame.line1:SetText(crest and ("You've earned %s."):format(Badge.Name("group", info.group))
            or ("All %d quests in %s."):format(outOf, groupName))
        frame.line2:SetText(("Lorebound %d / %d"):format(info.allDone, info.allTotal))
        sound = SOUNDKIT.UI_LEGENDARY_LOOT_TOAST
    elseif zoneClosed then
        done, outOf, color = info.zoneDone, info.zoneTotal, colors.zone
        frame.title:SetText(("%s complete!"):format(zoneName))
        frame.line1:SetText(("All %d quests done: %s is yours."):format(outOf, Badge.Name("zone", info.zone)))
        frame.line2:SetText(("|cffa870ff%s %d / %d|r"):format(groupName, info.groupDone, info.groupTotal))
        sound = SOUNDKIT.UI_WORLDQUEST_COMPLETE
        badge = { "zone", info.zone }
    else
        done, outOf, color = info.zoneDone, info.zoneTotal, colors.zone
        frame.title:SetText(zoneName)
        local left = outOf - done
        frame.line1:SetText(("%d / %d quests  ·  %d to go"):format(done, outOf, left))
        frame.line2:SetText(("|cffa870ff%s %d / %d|r"):format(groupName, info.groupDone, info.groupTotal))
    end
    local finalTitle = frame.title:GetText()
    frame.title:SetTextColor(1, 1, 1)
    if closing then -- until the close: the name of what's closing, and nothing below it yet
        frame.title:SetText(allClosed and "Lorebound" or groupClosed and groupName or zoneName)
        frame.line1:SetAlpha(0)
        frame.line2:SetAlpha(0)
    end
    ring:Paint(color, 0.25)
    frame.pulse:SetVertexColor(color[1], color[2], color[3])
    ring.label:SetText("")

    Present(closing and BIG_HOLD or HOLD)
    -- Closing: the ring sweeps shut from empty. Else it ticks up from where it was, its share counting up.
    ring:Draw(closing and 0 or math.max(0, done - 1) / outOf)
    if not closing then ring.label:SetText(("%d%%"):format(math.floor(math.max(0, done - 1) / outOf * 100))) end
    C_Timer.After(BEAT, function() -- once the toast has arrived, so the eye is on it
        if this ~= shown or not frame:IsShown() then return end
        if closing then
            ring:SetProgress(1, true, function(closedRing)
                Celebrate(closedRing)
                Sound(sound)
                frame.title:SetText(finalTitle)
                frame.title:SetTextColor(1, 0.82, 0.25)
                frame.titlePop:Play()
                for _, group in ipairs(frame.linesIn) do group:Play() end
                -- The badge takes the ring's place.
                frame.badge:Set(badge[1], badge[2], true)
                frame.badge:Show()
                frame.reveal:Play()
                closedRing:Hide()
            end, { duration = SWEEP, build = true })
        else
            ring:SetProgress(done / outOf, true, function()
                frame.land:Stop()
                frame.land:Play()
                Sheen()
            end, { duration = MOVE, count = true })
            frame.plusAnim:Stop()
            frame.plusAnim:Play()
        end
    end)
end

-- A pretend turn-in for the settings' test buttons: the toast for the zone you're in (or the first with
-- quests), or with closing the fanfare for closing its ring. Nothing is recorded.
function Toast.Test(closing)
    local Lore = ns.Lore
    if not ns.LoadData() then return end
    Lore.Refresh()
    local here = GetRealZoneText and Lore.FindZone(GetRealZoneText() or "")
    local zone = here and select(2, Lore.Count(here)) > 0 and here
    if not zone then
        for i in ipairs(Lore.Zones()) do
            if select(2, Lore.Count(i)) > 0 then zone = i break end
        end
    end
    if not zone then return end
    local info = InfoFor(zone, Lore.TotalCount())
    info.zoneDone = closing and info.zoneTotal or math.max(1, info.zoneDone)
    testing = true
    Toast.Show(info, closing and { (Lore.Zone(zone)) } or nil)
    testing = false
end
