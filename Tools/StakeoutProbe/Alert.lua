-- StakeoutProbe: the in-game check of #94, Shift+right-click on a quest button
-- for an alert when one appears. It reads Stakeout's buttons, the player's
-- target and Stakeout's last announcement (its test seam), and never writes to
-- Stakeout. It switches the ActionButtonUseKeyDown CVar for two gestures and
-- puts it back. The owner does the clicks, and answers what only they can
-- hear or see.
--
-- Procedure: /fp steps so alert.

local _, NS = ...
local Probe = NS.Probe
local function G(name) return rawget(_G, name) end
local function secret(v)
    local fn = G("issecretvalue")
    return fn ~= nil and fn(v) == true
end
-- The secret check first: comparing a secret, even to nil, throws.
local function plain(v)
    if secret(v) then return nil end
    return v
end

local function seam()
    local s = G("Stakeout")
    return type(s) == "table" and type(s._test) == "table" and s._test or nil
end

-- The quest buttons on screen, and which of them wear the alert mark.
local function questButtons()
    local shown, armed = {}, {}
    for i = 1, 40 do
        local btn = G("StakeoutBtn" .. i)
        if not btn then break end
        if btn:IsShown() and btn.questButton then
            local name = plain(btn.npcName) or "?"
            shown[#shown + 1] = name
            if btn.bell and btn.bell:IsShown() then armed[#armed + 1] = name end
        end
    end
    return shown, armed
end

local function targetGuid()
    local fn = G("UnitGUID")
    return fn and plain(fn("target")) or nil
end

-- The target's mark: a number, "none", or "unreadable" (a secret).
local function targetMark()
    local fn = G("GetRaidTargetIndex")
    if not fn then return "none" end
    local m = fn("target")
    if secret(m) then return "unreadable" end
    return m or "none"
end

local function keyDown()
    local fn = G("GetCVarBool")
    return fn ~= nil and fn("ActionButtonUseKeyDown") and true or false
end

local restoreKeyDown   -- defined with the CVar steps below; the first step calls it

local before   -- step 1's target and mark
local function snapshot()
    restoreKeyDown()   -- a run stopped by a /reload while switched
    if not seam() then error("Stakeout isn't loaded, or isn't this branch's build (no test seam).", 0) end
    local shown = questButtons()
    if #shown == 0 then
        error("No quest button on screen: stand near a quest mob Stakeout shows a button for, then Run again.", 0)
    end
    local g = targetGuid()
    if not g then error("Target something first (another mob or an NPC, not the quest mob), then Run again.", 0) end
    before = { guid = g, mark = targetMark() }
    return true, ("target %s (mark %s); quest buttons: %s; ActionButtonUseKeyDown %s"):format(g,
        tostring(before.mark), table.concat(shown, ", "), keyDown() and "1" or "0")
end

local function armedCheck()
    local _, armed = questButtons()
    local g, m = targetGuid(), targetMark()
    local same = before ~= nil and g == before.guid and (m == before.mark or m == "unreadable")
    return #armed > 0 and same, ("armed: %s; target %s (mark %s), %s"):format(
        #armed > 0 and table.concat(armed, ", ") or "none", tostring(g), tostring(m),
        same and "unchanged" or "CHANGED")
end

local function noneArmed()
    local _, armed = questButtons()
    return #armed == 0, #armed == 0 and "none armed" or ("still armed: " .. table.concat(armed, ", "))
end

-- The mixed gestures. The secure action and the toggle both run on one edge:
-- the down edge at ActionButtonUseKeyDown 1, the up edge at 0. So Shift added
-- before the mouse goes up targets at 1 (the down edge had no Shift) and
-- toggles at 0; Shift let go before the mouse goes up toggles at 1 and
-- targets at 0. Each step starts with no target and no alert armed.
local function gesture(shiftAddedLate)
    return function()
        local _, armed = questButtons()
        local targeted, toggled = targetGuid() ~= nil, #armed > 0
        local down = keyDown()
        local wantToggle = (shiftAddedLate and not down) or (not shiftAddedLate and down)
        local ok = (toggled == wantToggle) and (targeted == not wantToggle)
        return ok, ("ActionButtonUseKeyDown %s, Shift %s: targeted %s, toggled %s (expected %s)"):format(
            down and "1" or "0", shiftAddedLate and "added before release" or "let go before release",
            tostring(targeted), tostring(toggled), wantToggle and "a toggle" or "a target")
    end
end

-- The owner's setting, saved once before the switch, in the module's
-- SavedVariables so a /reload in between still puts it back: the next run of
-- this procedure does, at its first step, if it was left switched.
local function saved()
    local db = G("StakeoutProbeDB")
    return type(db) == "table" and db or nil
end
restoreKeyDown = function()
    local db, set = saved(), G("SetCVar")
    if db and db.alertKeyDown ~= nil and set then
        set("ActionButtonUseKeyDown", db.alertKeyDown and "1" or "0")
        db.alertKeyDown = nil
    end
end
local function setKeyDown(flip)
    return function()
        local db, set = saved(), G("SetCVar")
        if not (db and set) then error("SetCVar or StakeoutProbeDB isn't available", 0) end
        if flip then
            -- Back and Run again: the original stays the one saved first.
            if db.alertKeyDown == nil then db.alertKeyDown = keyDown() end
            set("ActionButtonUseKeyDown", db.alertKeyDown and "0" or "1")
        else
            restoreKeyDown()
        end
        return true, "ActionButtonUseKeyDown is " .. (keyDown() and "1" or "0")
    end
end
-- Leaving a switched step by Stop (or Back to before the switch) puts it back.
local function restoreOn(outcomes)
    return function(outcome)
        if outcomes[outcome] then restoreKeyDown() end
    end
end

-- A wait for the armed target's own alert, from the moment the step began:
-- the baseline is taken on entry and dropped on leaving, so a later run (or
-- another NPC's announcement) never passes it.
local waits = {}
local function alertWait(key)
    return function()
        local s = seam()
        local now = G("GetTime")()
        local w = waits[key]
        if not w then
            local _, armed = questButtons()
            if #armed == 0 then return false, "no alert armed: Shift+right-click the quest button" end
            local names = {}
            for _, n in ipairs(armed) do names[n] = true end
            w = { from = now, names = names }
            waits[key] = w
        end
        -- Each name's last alert, so another NPC alerting in the same second
        -- can't hide this one.
        for n in pairs(w.names) do
            local t = s and s.announcedAt and s.announcedAt(n)
            if t and t >= w.from then
                return true, ("alert: %s, %.0f s after the step began"):format(n, t - w.from)
            end
        end
        return false, "no alert for it yet"
    end
end
local function forget(key) return function() waits[key] = nil end end
local function alertSeen(key)
    return function()
        local w = waits[key]
        local s = seam()
        for n in pairs(w and w.names or {}) do
            local t = s and s.announcedAt and s.announcedAt(n)
            if t and t >= w.from then return true, "alert: " .. n end
        end
        return false, "no alert for the armed target"
    end
end

Probe:Steps("alert", {
    rev = 4,
    title = "Stakeout: an alert from a quest button (#94)",
    { text = "Out of combat, stand where Stakeout shows a button for a quest mob, with one of those mobs' nameplates "
          .. "in view. Target something ELSE (another mob or an NPC). Then press Run.", run = snapshot },
    { text = "Shift+right-click that quest mob's button. Your target should stay as it is, and a small mark "
          .. "appear on the button. Then press Run.", run = armedCheck, check = armedCheck,
      screenshot = "alert-armed" },
    { text = "Shift+right-click it again: the mark goes (chat says \"Alert off\"). Then press Run.", run = noneArmed,
      check = noneArmed },
    { text = "Pull a mob. During the fight, Shift+right-click the quest button on, then off again. Did chat say "
          .. "\"Alert on\" then \"Alert off\", and the mark come and go, in combat?", ask = true },
    { text = "Out of combat, alert off, clear your target (Esc). Press the RIGHT mouse button on the quest button "
          .. "WITHOUT Shift, hold it, press Shift, then let go of the mouse. Then press Run.",
      run = gesture(true), check = gesture(true) },
    { text = "Turn the alert off if it's on, clear your target. Now hold Shift, press the right button on the "
          .. "quest button, let go of Shift, then let go of the mouse. Then press Run.",
      run = gesture(false), check = gesture(false) },
    { text = "Press Run to switch ActionButtonUseKeyDown the other way for the next two clicks (the probe puts it "
          .. "back after).", run = setKeyDown(true) },
    { text = "Alert off, target cleared. RIGHT mouse button down WITHOUT Shift, press Shift, let go of the mouse. "
          .. "Then press Run.", run = gesture(true), check = gesture(true),
      leave = restoreOn({ stopped = true, back = true }) },
    { text = "Alert off, target cleared. Hold Shift, RIGHT mouse button down, let go of Shift, let go of the mouse. "
          .. "Then press Run.", run = gesture(false), check = gesture(false), leave = restoreOn({ stopped = true }) },
    { text = "Press Run to put ActionButtonUseKeyDown back as it was.", run = setKeyDown(false),
      leave = restoreOn({ stopped = true, skipped = true }) },
    { text = "Turn its alert ON (Shift+right-click; clear the target if it got one). Walk away until its "
          .. "nameplates are gone, stay away for over a minute, then walk back. Stakeout should alert on its own "
          .. "when a nameplate shows (up to 5 minutes here).", wait = alertWait("walk"), timeout = 300,
      check = alertSeen("walk"), leave = forget("walk") },
    { text = "Kill one of them and wait nearby, its alert still on, for one to respawn. Stakeout should alert as "
          .. "soon as the new one's nameplate shows (up to 10 minutes here).", wait = alertWait("respawn"),
      timeout = 600, check = alertSeen("respawn"), leave = forget("respawn") },
    { text = "Did each alert play your alert sound, with \"Detected: <name>\" in chat?", ask = true },
    { text = "A plain right-click on the quest button: does it still target the mob (no mark)? And a left-click "
          .. "target and mark it?", ask = true },
    { text = "The new sounds: open Stakeout's settings and pick each new one in the Sound dropdown (Minimap Ping, "
          .. "Sonar Ping, Radar Ping, Sonar, Radar Blip, Deep Sea Sonar, Bell Chime, Notification, HUD Ping). Each "
          .. "should play, and chat say \"Alert sound set to\". Type any that stayed silent or said \"Couldn't play\" "
          .. "in the box (or nothing), set the sound you want back, then press Next." },
    { text = "Done. Shift+right-click the quest button if its alert is still on and you don't want it." },
})

NS._test = NS._test or {}
NS._test.alert = { questButtons = questButtons, gesture = gesture, targetMark = targetMark, snapshot = snapshot,
    setKeyDown = setKeyDown, restoreOn = restoreOn, restoreKeyDown = restoreKeyDown }
