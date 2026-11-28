------------------------------------------------------------
-- test_suite.lua - following Glass UI (GlassUI#152, docs/SUITE.md and
-- SUITE-LOOK.md there).
--
-- With Glass UI loaded, Stakeout follows it by default: it asks once at its
-- load, builds the suite's material in the suite's body and accent, and
-- reports what it built (not live). Its own "Use Glass UI appearance" off, its
-- saved look applies and is reported as declined. Without Glass UI, or with
-- one that doesn't speak API 1, nothing changes.
--
-- The stand-in Glass UI below answers as the real one does; what it can't
-- show is how the suite's page reads the report, which GlassUI's own tests
-- cover.
------------------------------------------------------------

dofile("tests/wow_stubs.lua")

-- The Hunt checkbox is the settings' last control: its box and the line under
-- it (44 px) end inside the window, with a margin.
local function huntInside(h)
    local hc = StakeoutConfigFrame and StakeoutConfigFrame.huntCheck
    local p = hc and hc._points[#hc._points]
    return p ~= nil and -p[5] + 44 + 8 <= h
end
-- Each checkbox's grey line stays on one line inside the window: its width
-- bound to the column (past it, "..."), and its text short enough not to
-- need that. About 5 units a character in GameFontDisableSmall (the owner's
-- screenshot, 70959: "Experimental. With Questie: droppers and turn-ins too.",
-- 54 characters, took 271 of the window's 712). The kit's 6 a character is
-- an upper bound, too wide for this.
local function descsInside()
    local f, bad = StakeoutConfigFrame, {}
    for _, cb in ipairs({ f.questCheck, f.huntCheck, f.followCheck }) do
        local d = cb and cb.desc
        if d then
            local p = cb._points[#cb._points]
            local text = d:GetText() or ""
            if not d:GetWidth() or p[4] + 26 + d:GetWidth() > f:GetWidth()
                or #text * 5.1 > d:GetWidth() then
                bad[#bad + 1] = text
            end
        end
    end
    return #bad == 0, table.concat(bad, " | ")
end
local H = dofile("tests/harness.lua")

local SMOKED = { tint = { 0.05, 0.06, 0.08, 0.62 }, backing = { 0.04, 0.05, 0.07, 0.92 }, wash = 0.14 }
local CLASS = { classShade = 0.6, backing = { 0.04, 0.05, 0.07, 0.35 }, wash = 1 }
local ICE = { 0.65, 0.835, 0.905 }

-- A Glass UI speaking the suite's API 1, recording what Stakeout asks and
-- reports. opts: answer = false (its own switch is off for Stakeout), preset,
-- tint, bare (no Look, Body or Accent: an older API-1 Glass UI), api.
local function suite(opts)
    opts = opts or {}
    local S = { API = opts.api or 1, asked = {}, reports = {} }
    function S.Theme(addon)
        S.asked[#S.asked + 1] = addon
        if opts.answer == false then return nil, "not-following" end
        return { name = "pearl", preset = opts.preset or "pearl" }
    end
    function S.Report(addon, state) S.reports[#S.reports + 1] = { addon = addon, state = state } end
    if not opts.bare then
        function S.Look()
            return { tint = opts.tint or "smoked", accent = "ice", hover = "glow", press = "flash", emptySlots = "frosted" }
        end
        -- Fresh tables, as the real one hands out.
        function S.Body(tint)
            local b = tint == "smoked" and SMOKED or tint == "class" and CLASS or nil
            if not b then return nil end
            return { tint = b.tint and { unpack(b.tint) }, classShade = b.classShade,
                     backing = { unpack(b.backing) }, wash = b.wash }
        end
        function S.Accent(name) if name == "ice" then return { unpack(ICE) } end end
    end
    rawset(_G, "GlassUI", { Suite = S })
    return S
end

-- A session: a fresh event table (a new UI), these saved settings, loaded.
local function session(saved)
    WoW.dropEvents()
    WoW.chat = {}
    WoW.combat = false
    local T = WoW.loadAddon({ savedDB = saved })
    return T, WoW.ns.theme
end

local function color(tex) return tex._color and table.concat(tex._color, ",") or "none" end
local function rgba(t) return table.concat(t, ",") end
local function near(a, b) return type(a) == "number" and math.abs(a - b) < 1e-9 end

-- The config window's font string showing `text`.
local function label(text)
    for _, c in ipairs(StakeoutConfigFrame._regions) do
        if c._type == "FontString" and c:GetText() == text then return c end
    end
end

------------------------------------------------------------
-- Glass UI loaded: Stakeout follows it, whatever its own look
------------------------------------------------------------
do
    local S = suite()
    local T, Theme = session({ svLoadCheck = 1 })
    eq(StakeoutDB.followGlassUI, true, "following Glass UI is the default")
    eq(S.asked[1], "Stakeout", "Stakeout asks Glass UI at its load")
    eq(#S.asked, 1, "once")
    eq(Theme.Active(), "glass", "and wears glass, though its own look is WoW Forever")
    check(Theme.Following(), "Glass UI's glass")
    eq(Theme._test.Glass().preset, "pearl", "in the suite's material")

    eq(#S.reports, 1, "one report")
    local r = S.reports[1]
    eq(r.addon, "Stakeout", "under Stakeout's name")
    eq(r.state.api, 1, "API 1")
    eq(r.state.built, "pearl", "built: the suite's material")
    eq(r.state.live, false, "not live: a suite change waits for a /reload")
    eq(r.state.look and r.state.look.tint, "smoked", "the tint it built")
    eq(r.state.look and r.state.look.accent, "ice", "and the accent")
    eq(r.state.own, nil, "nothing of its own")
    eq(r.state.declined, nil, "nothing declined")
    check(type(r.state.minor) == "number", "the library's minor")

    local g = T.frame().glass
    eq(color(g.tint), rgba(SMOKED.tint), "the shell in the suite's body")
    eq(color(g.backing), rgba(SMOKED.backing), "over the suite's backing")
    check(near(g.wash.glassPeak, Theme._test.Glass().STYLE.wash * SMOKED.wash),
        "with the body's wash, a factor of the material's: " .. tostring(g.wash.glassPeak))

    -- Glass UI's link to the settings opens them, and never closes them.
    r.state.options()
    check(StakeoutConfigFrame and StakeoutConfigFrame:IsShown(), "Glass UI's link opens the settings")
    r.state.options()
    check(StakeoutConfigFrame:IsShown(), "and a second click keeps them open")

    local title = label("Watch list")
    eq(title and title._textColor and rgba({ title._textColor[1], title._textColor[2], title._textColor[3] }),
        rgba(ICE), "section titles in the suite's accent")
    check(StakeoutConfigFrame.followCheck and StakeoutConfigFrame.followCheck:GetChecked(),
        "the settings show the switch, on")
    local w, h = StakeoutConfigFrame:GetSize()
    eq(h, 668, "and the window makes room for it (and for quest targets, two checkboxes and Skip dead mobs; "
        .. "the layout rows are on the Customize panel since #98)")
    check(huntInside(h), "the Hunt control, the last one, still inside the window")
    -- The whole window on a 768-high UIParent (its height with UI scale off,
    -- whatever the resolution), not only its controls inside its own height
    -- (Codex on #95's plan). The kit's UIParent has no size, so the number.
    check(h <= 768, ("the full window fits a 768-high screen (%s)"):format(h))
    -- The Button icon label sits on its picker's row (#95), on the Customize
    -- panel since #98: clear of the first icon, the last inside the panel.
    local f = StakeoutConfigFrame
    local lp, ip = f.iconLabel._points[#f.iconLabel._points], f.iconPicker[1]._points[#f.iconPicker[1]._points]
    check(lp[4] + f.iconLabel:GetStringWidth() + 2 <= ip[4] - 2,
        ("the Button icon label (%d + %d) ends before the first icon's highlight (%d)"):format(lp[4],
            f.iconLabel:GetStringWidth(), ip[4] - 2))
    local panelW = StakeoutCustomizeFrame and StakeoutCustomizeFrame:GetWidth() or 0
    check(f.iconPicker[#f.iconPicker]._points[1][4] + 26 + 2 <= panelW - 16,
        "and the last icon's highlight stays inside the Customize panel")
    local inside, which = descsInside()
    check(inside, "every grey line under a checkbox stays inside the window: " .. which)

    -- The saved look is kept while following, and says so.
    SlashCmdList.STAKEOUT("look glass")
    check(WoW.chatText():find("kept for when Stakeout doesn't follow Glass UI", 1, true),
        "choosing a look while following says it's kept for later")
    eq(StakeoutDB.theme, "glass", "and keeps it")

    -- Turning the switch off saves it, for the next /reload.
    StakeoutConfigFrame.followCheck:SetChecked(false)
    StakeoutConfigFrame.followCheck._scripts.OnClick(StakeoutConfigFrame.followCheck)
    eq(StakeoutDB.followGlassUI, false, "the switch saves off")
    check(WoW.chatText():find("won't wear Glass UI's look after a", 1, true), "and says when it applies")
    eq(Theme.Active(), "glass", "the session keeps what it built")
end

------------------------------------------------------------
-- Stakeout's switch off: its own look, declined
------------------------------------------------------------
do
    local S = suite()
    local T, Theme = session({ svLoadCheck = 1, followGlassUI = false })
    eq(#S.asked, 0, "switched off, Stakeout doesn't ask")
    eq(Theme.Active(), "forever", "and wears its own look, WoW Forever")
    check(T.frame()._backdrop ~= nil and T.frame().glass == nil, "the backdrops")
    local r = S.reports[1]
    eq(r and r.state.declined, "WoW Forever", "reported as declined, naming the look in effect")
    eq(r.state.built, nil, "nothing built")
    eq(r.state.reason, nil, "and no failure")
    eq(r.state.live, false, "not live")
    SlashCmdList.STAKEOUT("config")
    check(StakeoutConfigFrame.followCheck and not StakeoutConfigFrame.followCheck:GetChecked(),
        "the switch shows, off")
    eq(label("Watch list")._textColor, nil, "section titles keep their own colour")
end

do
    local S = suite()
    local T, Theme = session({ svLoadCheck = 1, followGlassUI = false, theme = "glass" })
    eq(Theme.Active(), "glass", "switched off with Glass saved: its own glass")
    check(not Theme.Following(), "not Glass UI's")
    eq(Theme._test.Glass().preset, "clean", "in the recipe's material")
    eq(color(T.frame().glass.tint), rgba(Theme._test.SHELL.tint), "and the recipe's body")
    eq(S.reports[1].state.declined, "Glass", "declined, naming its own glass")
end

------------------------------------------------------------
-- Glass UI's own switch off for Stakeout: Stakeout's own look
------------------------------------------------------------
do
    local S = suite({ answer = false })
    local _, Theme = session({ svLoadCheck = 1 })
    eq(S.asked[1], "Stakeout", "asked")
    eq(Theme.Active(), "forever", "Glass UI said not to follow: its own look")
    local st = S.reports[1].state
    check(st.built == nil and st.declined == nil and st.reason == nil,
        "reported as its own look, neither declined nor failed")
end

------------------------------------------------------------
-- The suite's material can't be built: the failure is reported
------------------------------------------------------------
do
    local S = suite({ preset = "obsidian" })
    local _, Theme = session({ svLoadCheck = 1, theme = "glass" })
    check(not Theme.Following(), "an unknown preset isn't followed")
    eq(Theme.Active(), "glass", "its own glass instead")
    eq(Theme._test.Glass().preset, "clean", "the recipe's")
    local st = S.reports[1].state
    eq(st.reason, "library-too-old", "reported: the library is too old for it")
    check(st.built == nil and st.declined == nil, "a failure, not a choice")
end

------------------------------------------------------------
-- An older API-1 Glass UI (no Look, Body, Accent): its material, our body
------------------------------------------------------------
do
    local S = suite({ bare = true })
    local T, Theme = session({ svLoadCheck = 1 })
    check(Theme.Following(), "follows the material")
    eq(color(T.frame().glass.tint), rgba(Theme._test.SHELL.tint), "in the recipe's body")
    local own = S.reports[1].state.own
    check(own and own.tint and own.accent, "reported as its own tint and accent")
end

------------------------------------------------------------
-- The class tint: painted once the class colour can be read
------------------------------------------------------------
do
    suite({ tint = "class" })
    WoW.playerClass = nil
    local T = session({ svLoadCheck = 1 })
    local g = T.frame().glass
    local built = g.tint.glassColor
    eq(color(g.tint), rgba(built), "the class colour unreadable at load: the built tint")
    eq(color(g.backing), rgba(CLASS.backing), "the class body's backing")
    WoW.playerClass = "WARRIOR"
    WoW.fire("PLAYER_ENTERING_WORLD")
    local s = CLASS.classShade
    eq(color(g.tint), rgba({ 0.78 * s, 0.61 * s, 0.43 * s, built[4] }),
        "at PLAYER_ENTERING_WORLD, the class colour, shaded, at the built alpha")
end

------------------------------------------------------------
-- Not Glass UI's API 1, or no Glass UI: nothing changes
------------------------------------------------------------
do
    local S = suite({ api = 2 })
    local T, Theme = session({ svLoadCheck = 1 })
    eq(#S.asked + #S.reports, 0, "another API version counts as absent: nothing asked or said")
    eq(Theme.Active(), "forever", "WoW Forever")
    SlashCmdList.STAKEOUT("config")
    eq(StakeoutConfigFrame.followCheck, nil, "and no switch in the settings")
    local _, h = StakeoutConfigFrame:GetSize()
    eq(h, 624, "nor room for one (quest targets and Skip dead mobs only)")
    check(huntInside(h), "the Hunt control, the last one, still inside the window")
end

do
    rawset(_G, "GlassUI", nil)
    local _, Theme = session({ svLoadCheck = 1 })
    eq(Theme.Active(), "forever", "without Glass UI, WoW Forever stays the default")
    check(not Theme.Following(), "nothing followed")
end

done("test_suite")
