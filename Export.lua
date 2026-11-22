local _, ns = ...

-- "Export to website" (/lb export): this character's progress as a code to paste at lb.frogwizard.net/me,
-- which shows the rings, badges and every quest's status from a phone. The statuses are the journal's own,
-- worked out here, so the site never disagrees with the game. Sections, joined by "~":
--
--   LMP1 ~ list version ~ name (with the surname) ~ realm ~ raceID ~ classID ~ faction (1 Alliance, 2 Horde) ~ level ~ time
--   ~ turned in today ~ this week ~ statuses ~ reasons ~ learned ~ badges
--
-- statuses: one letter per quest of the list, in ID order (the site has the same order for that list
-- version), runs written as the letter and their length: a not for you, b done, c in your log,
-- d available, e coming up, f locked out, g skipped (counted done).
-- reasons: "id.code.a.b" for each quest locked out, skipped or coming up, joined by ";" (Lore's Why codes),
-- so the site says what the journal says.
-- learned: quests met in game that the list hasn't got, "id^name^zone^level^status letter", joined by ";".
-- badges: "zone index:time" (a zone of the list), "z<zone name>:time" (a zone only learned quests made),
-- "g1:time" (a continent's crest) or "s:time" (the Seal), joined by ";".

local Export = {}
ns.Export = Export

local LETTER = { "b", "c", "d", "e", "f", "a" } -- by Lore's statuses: DONE ACTIVE AVAILABLE LATER LOCKED HIDDEN

-- "First Surname": Forever gives characters a surname, UnitName's second answer (elsewhere the realm, or
-- nothing for yourself).
local function FullName()
    local name, surname = UnitName("player")
    local realm = GetRealmName and GetRealmName()
    if type(surname) == "string" and surname ~= "" and surname ~= realm then return name .. " " .. surname end
    return name
end

local function Letter(id)
    local Lore = ns.Lore
    local state = Lore.StatusOf(id)
    if state == Lore.DONE and Lore.IsPassed(id) then return "g" end
    return LETTER[state] or "a"
end

function Export.Code()
    local data, Lore, Plain = ns.LoadData(), ns.Lore, ns.Plain
    if not data then return nil end
    Lore.Refresh()

    -- Statuses, run-length.
    local runs, last, count = {}, nil, 0
    local reasons = {}
    for _, id in ipairs(Lore.ListIds()) do
        local letter = Letter(id)
        if letter == last then
            count = count + 1
        else
            if last then runs[#runs + 1] = count > 1 and (last .. count) or last end
            last, count = letter, 1
        end
        if letter == "e" or letter == "f" or letter == "g" then -- coming up, locked out or skipped: the game's own why
            local code, a, b = Lore.Reason(id)
            if code then reasons[#reasons + 1] = ("%d.%d.%s.%s"):format(id, code, a or "", b or "") end
        end
    end
    if last then runs[#runs + 1] = count > 1 and (last .. count) or last end

    local learned = {}
    for id, entry in pairs(ns.db.learned) do
        if Lore.IsLearned(id) then
            learned[#learned + 1] = table.concat({ id, Plain(entry[1]), Plain(entry[2]), entry[3] or "", Letter(id) }, "^")
        end
    end

    -- Zones of the list by their place in it; zones only learned quests made by name (their order differs).
    local badges, zoneIndex, learnedZone = {}, {}, {}
    for zone, entry in ipairs(Lore.Zones()) do
        if zone <= Lore.listZones then zoneIndex[entry[1]] = zone else learnedZone[entry[1]] = true end
    end
    for key, at in pairs(ns.charDB.badges) do
        local index = zoneIndex[key]
        if index then badges[#badges + 1] = index .. ":" .. at end
        if learnedZone[key] then badges[#badges + 1] = "z" .. Plain(key):gsub(":", " ") .. ":" .. at end
        if key == "group:1" or key == "group:2" then badges[#badges + 1] = "g" .. key:sub(-1) .. ":" .. at end
        if key == "seal" then badges[#badges + 1] = "s:" .. at end
    end

    local name = FullName()
    local _, _, race = UnitRace("player")
    local _, _, class = UnitClass("player")
    local today, week = ns.TurnInCounts()
    return table.concat({
        "LMP1", data.version or "", Plain(name), Plain(GetRealmName and GetRealmName()), race or "", class or "",
        Lore.Faction() or "", UnitLevel("player") or "", time(), today, week,
        table.concat(runs), table.concat(reasons, ";"), table.concat(learned, ";"), table.concat(badges, ";"),
    }, "~")
end

function Export.Open()
    local code = Export.Code()
    if not code then return end
    ns.Share.ShowCode({
        title = "Export to website",
        about = "Your progress on this character, to see on your phone: copy the code (Ctrl+C) and paste it at the address below. The site gives you a link (and a QR code) that each new export updates.",
        code = code, url = ns.PROGRESS_URL,
    })
end
