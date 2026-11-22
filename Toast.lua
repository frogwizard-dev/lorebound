local _, ns = ...

-- After each quest turned in: a toast near the top of the screen with the zone's ring ticking up. When a
-- turn-in closes a ring (the zone, its continent or group, or the whole Lorebound count) a bigger banner
-- instead: the ring sweeps shut, a halo bursts, sparks fly out, a fanfare plays and the badge it earns
-- (Badge.lua) takes the ring's place. Our own frame on
-- UIParent, built the first time it's needed; clicking it opens the journal on that zone.

local Toast = {}
ns.Toast = Toast

local HOLD, BIG_HOLD = 4, 7 -- seconds on screen before fading
local SPARKS = 10
local frame, fadeTimer
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
    frame:SetPoint("TOP", UIParent, "TOP", 0, -140)
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
    frame:Hide()

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
    pop:SetScaleFrom(0.35, 0.35)
    pop:SetScaleTo(1, 1)
    pop:SetDuration(0.45)
    pop:SetSmoothing("OUT")
    local appear = reveal:CreateAnimation("Alpha")
    appear:SetFromAlpha(0)
    appear:SetToAlpha(1)
    appear:SetDuration(0.3)
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
    frame.plus = over:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    frame.plus:SetText("+1")
    frame.plus:SetPoint("BOTTOM", frame.small, "TOP", 0, -6)
    frame.plus:SetAlpha(0)
    local up = frame.plus:CreateAnimationGroup()
    local rise = up:CreateAnimation("Translation")
    rise:SetOffset(0, 26)
    rise:SetDuration(0.9)
    rise:SetSmoothing("OUT")
    local show = up:CreateAnimation("Alpha")
    show:SetFromAlpha(1)
    show:SetToAlpha(0)
    show:SetDuration(0.9)
    show:SetSmoothing("IN")
    frame.plusAnim = up

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
    grow:SetScaleTo(1.9, 1.9)
    grow:SetDuration(1.1)
    grow:SetSmoothing("OUT")
    local fadeBurst = swell:CreateAnimation("Alpha")
    fadeBurst:SetFromAlpha(1)
    fadeBurst:SetToAlpha(0)
    fadeBurst:SetDuration(1.1)
    frame.burst, frame.swell = burst, swell

    frame.sparks = {}
    for i = 1, SPARKS do
        local spark = frame:CreateTexture(nil, "OVERLAY", nil, 6)
        spark:SetTexture(ns.MEDIA .. "Spark")
        spark:SetBlendMode("ADD")
        spark:SetSize(22, 22)
        spark:SetPoint("CENTER", frame.big, "CENTER")
        spark:SetAlpha(0)
        local angle = (i - 1) / SPARKS * 2 * math.pi + 0.3
        local distance = 70 + (i % 3) * 18
        local fly = spark:CreateAnimationGroup()
        local move = fly:CreateAnimation("Translation")
        move:SetOffset(distance * math.sin(angle), distance * math.cos(angle))
        move:SetDuration(0.8 + (i % 4) * 0.1)
        move:SetSmoothing("OUT")
        local fadeSpark = fly:CreateAnimation("Alpha")
        fadeSpark:SetFromAlpha(1)
        fadeSpark:SetToAlpha(0)
        fadeSpark:SetDuration(0.9 + (i % 4) * 0.1)
        fadeSpark:SetSmoothing("IN")
        frame.sparks[i] = fly
    end

    local fade = frame:CreateAnimationGroup()
    local out = fade:CreateAnimation("Alpha")
    out:SetFromAlpha(1)
    out:SetToAlpha(0)
    out:SetDuration(0.6)
    fade:SetScript("OnFinished", function() frame:Hide() end)
    frame.fade = fade
    frame:SetScript("OnHide", function()
        -- Closed mid-sweep: the sweep and its reveal go (they'd only run on a hidden frame).
        frame.big:SetScript("OnUpdate", nil)
        frame.big.onDone = nil
        celebrating = false
        local next = waiting
        waiting = nil
        if next then C_Timer.After(0.2, function() Toast.Show(next) end) end
    end)
end

local function Layout(big)
    local ring = big and frame.big or frame.small
    frame.small:SetShown(not big)
    frame.big:SetShown(big)
    frame.reveal:Stop()
    frame.badge:Hide()
    frame:SetSize(big and 420 or 340, big and 124 or 76)
    local left = big and 124 or 78
    frame.title:ClearAllPoints()
    frame.title:SetPoint("TOPLEFT", left, big and -26 or -14)
    frame.title:SetPoint("TOPRIGHT", -12, big and -26 or -14)
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
    Hold(hold)
end

local function Celebrate(ring)
    ring:SetGlow(true)
    frame.burst:SetVertexColor(unpack(ring.color))
    frame.swell:Stop()
    frame.swell:Play()
    for _, fly in ipairs(frame.sparks) do
        fly:Stop()
        fly:Play()
    end
end

local function Sound(kit)
    if (ns.db.sound or testing) and kit then PlaySound(kit) end
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
        for zone, z in ipairs(ns.Lore.Zones()) do
            if Has(earned, z[1]) then
                local done, total = ns.Lore.Count(zone)
                local groupDone, groupTotal = ns.Lore.GroupCount(z[2])
                info = {
                    zone = zone, group = z[2], counted = ns.Lore.IN_TOTAL[z[2]], zoneDone = done, zoneTotal = total,
                    groupDone = groupDone, groupTotal = groupTotal, allDone = info.allDone, allTotal = info.allTotal,
                }
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
    frame.swell:Stop()
    for _, fly in ipairs(frame.sparks) do fly:Stop() end

    local Lore, colors = ns.Lore, ns.COLORS
    local zoneName = Lore.Zone(info.zone)
    local groupName = Lore.Groups()[info.group] or ""
    frame.zone = info.zone
    local ring = Layout(closing)
    ring:SetGlow(false)

    local Badge = ns.Badge
    local done, of, color, sound, badge
    if allClosed then
        done, of, color = info.allDone, info.allTotal, colors.total
        frame.title:SetText("Lorebound!")
        frame.line1:SetText(("Every one of the %d quests Lorebound counts, done."):format(of))
        frame.line2:SetText(("The last was in %s. You've earned %s."):format(zoneName, Badge.Name("seal")))
        sound = SOUNDKIT.UI_LEGENDARY_LOOT_TOAST
        badge = { "seal" }
    elseif groupClosed then
        done, of, color = info.groupDone, info.groupTotal, colors.group
        frame.title:SetText(("%s complete!"):format(groupName))
        local crest = info.group == 1 or info.group == 2
        badge = crest and { "group", info.group } or { "zone", info.zone }
        frame.line1:SetText(crest and ("You've earned %s."):format(Badge.Name("group", info.group))
            or ("All %d quests in %s."):format(of, groupName))
        frame.line2:SetText(("Lorebound %d / %d"):format(info.allDone, info.allTotal))
        sound = SOUNDKIT.UI_LEGENDARY_LOOT_TOAST
    elseif zoneClosed then
        done, of, color = info.zoneDone, info.zoneTotal, colors.zone
        frame.title:SetText(("%s complete!"):format(zoneName))
        frame.line1:SetText(("All %d quests done: %s is yours."):format(of, Badge.Name("zone", info.zone)))
        frame.line2:SetText(("|cffa870ff%s %d / %d|r"):format(groupName, info.groupDone, info.groupTotal))
        sound = SOUNDKIT.UI_WORLDQUEST_COMPLETE
        badge = { "zone", info.zone }
    else
        done, of, color = info.zoneDone, info.zoneTotal, colors.zone
        frame.title:SetText(zoneName)
        local left = of - done
        frame.line1:SetText(("%d / %d quests  ·  %d to go"):format(done, of, left))
        frame.line2:SetText(("|cffa870ff%s %d / %d|r"):format(groupName, info.groupDone, info.groupTotal))
    end
    if closing then frame.title:SetTextColor(1, 0.82, 0.25) else frame.title:SetTextColor(1, 1, 1) end
    ring:Paint(color, 0.25)
    ring.label:SetText(closing and "" or ("%d%%"):format(math.floor(done / of * 100)))

    Present(closing and BIG_HOLD or HOLD)
    ring:Draw(math.max(0, done - 1) / of)
    if closing then
        ring:SetProgress(1, true, function(r)
            Celebrate(r)
            Sound(sound)
            -- The badge takes the ring's place.
            frame.badge:Set(badge[1], badge[2])
            frame.badge:Show()
            frame.reveal:Play()
            r:Hide()
        end)
    else
        ring:SetProgress(done / of, true)
        frame.plusAnim:Stop()
        frame.plusAnim:Play()
    end
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
    local name, group = Lore.Zone(zone)
    local done, total = Lore.Count(zone)
    local groupDone, groupTotal = Lore.GroupCount(group)
    local allDone, allTotal = Lore.TotalCount()
    testing = true
    Toast.Show({
        zone = zone, group = group, counted = Lore.IN_TOTAL[group], zoneDone = closing and total or math.max(1, done),
        zoneTotal = total, groupDone = groupDone, groupTotal = groupTotal, allDone = allDone, allTotal = allTotal,
    }, closing and { name } or nil)
    testing = false
end
