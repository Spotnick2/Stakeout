-------------------------------------------------------------------------------
-- Stakeout: the look of its windows (#28)
--
-- Two looks: "forever", the WoW Forever backdrops Stakeout always had (the
-- default), and "glass", LibGlass-1.0's reflective shell as GlassRaidFrames
-- and AltStable draw it (C:\Projects\WoW\References\Docs\LIBGLASS-WINDOW-STYLING.md).
--
-- The look is fixed once a session (Init, from the saved choice) and built
-- into each window as it is made, so a new choice applies after a /reload.
-- Every helper returns true when it dressed the frame in glass. On false the
-- caller paints its own backdrop, exactly as before there was a choice.
--
-- The target frame parents secure buttons. What glass adds there is textures
-- and plain child frames that never take the mouse, built out of combat (the
-- frame at ADDON_LOADED, a button's glass when the button is made), and never
-- re-anchored, re-levelled or resized afterwards: they follow through their
-- anchors.
--
-- Following Glass UI (..\GlassUI, its docs/SUITE.md and SUITE-LOOK.md;
-- GlassUI#152). With Glass UI loaded, Stakeout follows it by default, as the
-- other members do (the owner, 2026-10-21): Pearl glass, or whatever material
-- the suite answers, in the suite's body (tint, backing, wash) and accent
-- (the section titles). The reading regions and controls keep the recipe's
-- values. "Use Glass UI appearance" in Stakeout's settings turns it off; the
-- saved look applies then, and is reported as declined, never as a failure.
-- Without Glass UI, the saved look applies, WoW Forever by default.
--
-- Asked once, at ADDON_LOADED (`## OptionalDeps: GlassUI` has Glass UI ready
-- by then). Not live: a suite change waits for a /reload, and the report says
-- so (`live = false`).
-------------------------------------------------------------------------------
local _, ns = ...

local Theme = {}
ns.theme = Theme

Theme.LOOKS  = { "forever", "glass" }
Theme.LABELS = { forever = "WoW Forever", glass = "Glass" }

local active   -- the session's look, fixed by Init
local Glass    -- this addon's LibGlass instance, under the glass look
local following    -- what the session built from Glass UI's suite, or nil
local shells = {}  -- every window shell, for a class tint painted late
local classPending -- a class tint wanted before the class colour could be read
local retryFrame

local SUITE_ADDON = "Stakeout"

-- The recipe's values (LIBGLASS-WINDOW-STYLING.md), by surface role. The
-- shell's tint over its backing covers about 90%; the reading region and
-- controls sit on top of it.
local SHELL = {
    tint = { 0.085, 0.095, 0.115, 0.78 }, backing = { 0.03, 0.03, 0.035, 0.55 },
    rim = 0.12, dark = 0.55, shadow = 0.18,
}
local READING = { 0.072, 0.082, 0.10, 0.94 }
local CONTROL = {
    tint = { 0.095, 0.11, 0.135, 0.90 }, wash = 0.025,
    rim = 0.22, dark = 0.35, shadow = 0.05,
}
-- How far a target button's picture sits inside its glass, so the rim shows.
local ICON_INSET = 2

function Theme.IsLook(name)
    return type(name) == "string" and Theme.LABELS[name] ~= nil
end

-- A LibGlass instance in `preset` with what the reflective shell needs (r9:
-- Reflect, SetSurfaceAlpha) and the library's minor; or nil, why not, and the
-- suite's reason code for it.
local function NewGlass(preset)
    local stub = rawget(_G, "LibStub")
    local lib, minor
    if stub then lib, minor = stub("LibGlass-1.0", true) end
    if not lib then return nil, "LibGlass-1.0 isn't loaded", "build-failed" end
    local ok, inst = pcall(lib.New, lib, { preset = preset })
    if not ok then
        local why = tostring(inst)
        return nil, why, why:find("unknown preset", 1, true) and "library-too-old" or "build-failed"
    end
    if type(inst.Reflect) ~= "function" or type(inst.SetSurfaceAlpha) ~= "function" then
        return nil, "the loaded LibGlass-1.0 is older than r9", "library-too-old"
    end
    return inst, minor
end

-- Glass UI's suite API when it speaks version 1; anything else counts as absent.
local function SuiteAPI()
    local G = rawget(_G, "GlassUI")
    if type(G) ~= "table" then return nil end
    local S = rawget(G, "Suite")
    if type(S) ~= "table" or rawget(S, "API") ~= 1 then return nil end
    if type(rawget(S, "Theme")) ~= "function" or type(rawget(S, "Report")) ~= "function" then
        return nil
    end
    return S
end

-- One of the suite's optional functions, feature-detected on its own.
local function SuiteCall(suite, name, ...)
    local fn = rawget(suite, name)
    if type(fn) ~= "function" then return nil end
    local ok, r = pcall(fn, ...)
    if ok then return r end
end

local function IsColor(c, n)
    if type(c) ~= "table" then return false end
    for i = 1, n do
        if type(c[i]) ~= "number" or c[i] < 0 or c[i] > 1 then return false end
    end
    return true
end

local function Copy(c) return { unpack(c) } end

-- The suite's body for a tint (Suite.Body, the one owner of its numbers),
-- checked and copied, or nil. A class body has no colour, only its shade.
local function SuiteBody(suite, tint)
    local b = SuiteCall(suite, "Body", tint)
    if type(b) ~= "table" or type(b.wash) ~= "number" or b.wash < 0 or not IsColor(b.backing, 4) then
        return nil
    end
    if IsColor(b.tint, 4) then
        return { tint = Copy(b.tint), backing = Copy(b.backing), wash = b.wash }
    elseif b.tint == nil and type(b.classShade) == "number" then
        return { classShade = b.classShade, backing = Copy(b.backing), wash = b.wash }
    end
end

-- The player's class colour, or nil while it can't be read (early in a login)
-- or isn't a plain value.
local function ClassColor()
    local ok, _, class = pcall(UnitClass, "player")
    if not ok or type(class) ~= "string" or (issecretvalue and issecretvalue(class)) then return nil end
    local ok2, c = pcall(C_ClassColor.GetClassColor, class)
    if not ok2 or type(c) ~= "table" then return nil end
    local r, g, b = c.r, c.g, c.b
    for _, v in ipairs({ r, g, b }) do
        if type(v) ~= "number" or (issecretvalue and issecretvalue(v)) then return nil end
    end
    return r, g, b
end

-- The suite's answer: a fresh `following` with its own LibGlass instance, or
-- nil, with the report's reason when the suite's material couldn't be built.
local function Follow(suite)
    local ok, answer = pcall(suite.Theme, SUITE_ADDON)
    if not (ok and type(answer) == "table" and type(answer.preset) == "string") then return nil end
    local inst, minor, code = NewGlass(answer.preset)
    if not inst then return nil, code end
    local f = { preset = answer.preset, inst = inst, minor = minor, own = {} }
    local look = SuiteCall(suite, "Look")
    look = type(look) == "table" and look or {}
    if type(look.tint) == "string" then f.body = SuiteBody(suite, look.tint) end
    if f.body then f.tint = look.tint else f.own.tint = true end
    local rgb = type(look.accent) == "string" and SuiteCall(suite, "Accent", look.accent)
    if IsColor(rgb, 3) then
        f.accent, f.accentRGB = look.accent, { rgb[1], rgb[2], rgb[3] }
    else
        f.own.accent = true
    end
    return f
end

-- The saved look, built: glass from the recipe, or WoW Forever. The second
-- return says why glass, chosen, couldn't be had.
local function OwnLook(choice)
    if choice ~= "glass" then return "forever" end
    local inst, minorOrWhy = NewGlass("clean")
    if not inst then return "forever", nil, minorOrWhy end
    Glass = inst
    return "glass", minorOrWhy
end

-- Is Glass UI here, speaking the suite's API? (The settings' switch shows
-- only then.)
function Theme.SuiteAvailable()
    return SuiteAPI() ~= nil
end

-- Fix the session's look, and tell Glass UI what was built. `choice` is the
-- saved look; `follow` is Stakeout's own "Use Glass UI appearance"; `options`
-- opens Stakeout's settings (Glass UI's link to them). Returns the look in
-- use and, when glass was chosen but can't be had, why.
function Theme.Init(choice, follow, options)
    if active then return active end
    local suite = SuiteAPI()
    local report = { api = 1, live = false, options = options }
    local why, reason
    if suite and follow ~= false then following, reason = Follow(suite) end
    if following then
        Glass, active = following.inst, "glass"
        following.inst = nil
        -- The preset's own wash: the body's is a factor of it.
        following.wash = Glass.STYLE.wash
        report.built, report.minor = following.preset, following.minor
        report.look = { tint = following.tint, accent = following.accent }
        report.own = next(following.own) and following.own or nil
    else
        active, report.minor, why = OwnLook(choice)
        report.reason = reason
        if suite and follow == false then report.declined = Theme.LABELS[active] end
    end
    if suite then pcall(suite.Report, SUITE_ADDON, report) end
    return active, why
end

-- Is this session's glass Glass UI's?
function Theme.Following()
    return following ~= nil
end

function Theme.Active()
    return active or "forever"
end

local function Paint(g, role)
    Glass.SetSurfaceTint(g, unpack(role.tint))
    Glass.SetWash(g, role.wash or 0)
    Glass.SetSurfaceAlpha(g, "rim", role.rim)
    Glass.SetSurfaceAlpha(g, "dark", role.dark)
    Glass.SetSurfaceAlpha(g, "shadow", role.shadow)
    Glass.SetSurfaceAlpha(g, "grain", 0)
end

-- A shell's body: the suite's while following, else the recipe's. A class
-- tint keeps the built alpha (SetSurfaceTint's nil), and the built colour
-- until the class colour can be read (Theme.Retry).
local function PaintShell(g)
    Paint(g, SHELL)
    local body = following and following.body
    if not body then return end
    if body.classShade then
        local r, gg, b = ClassColor()
        local s = body.classShade
        if r then
            Glass.SetSurfaceTint(g, r * s, gg * s, b * s)
        else
            Glass.SetSurfaceTint(g)
            classPending = true
        end
    else
        Glass.SetSurfaceTint(g, unpack(body.tint))
    end
    Glass.SetWash(g, following.wash * body.wash)
end

-- PLAYER_ENTERING_WORLD: the class colour can be read by now. Colours on the
-- shells' own textures only, so it is safe in combat too.
function Theme.Retry()
    if not classPending or not ClassColor() then return end
    classPending = false
    for _, g in ipairs(shells) do PaintShell(g) end
end

local function WaitForClass()
    if retryFrame or not classPending then return end
    retryFrame = CreateFrame("Frame")
    retryFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    retryFrame:SetScript("OnEvent", Theme.Retry)
end

-- A section title in the suite's accent, while following. It keeps its
-- font's own colour otherwise.
function Theme.Accent(fs)
    local c = following and following.accentRGB
    if c then fs:SetTextColor(c[1], c[2], c[3]) end
end

-- A window's outer shell. opts.header: the height (px) of its title area,
-- which the shell's reflection lights and fades out over; opts.small for a
-- frame that can be under ~40 px tall (the target frame).
function Theme.Window(frame, opts)
    if active ~= "glass" then return false end
    opts = opts or {}
    local g = Glass.Apply(frame, opts.small and "small" or "large")
    PaintShell(g)
    shells[#shells + 1] = g
    WaitForClass()
    -- No edge: the reflection's top highlight takes its place.
    Glass.SetEdge(g, 0, 0, 0)
    -- BACKGROUND -7: over the library's shadow (-8), under its tint (-6).
    local backing = frame:CreateTexture(nil, "BACKGROUND", nil, -7)
    backing:SetAllPoints(frame)
    backing:AddMaskTexture(g.mask)
    local body = following and following.body
    backing:SetColorTexture(unpack(body and body.backing or SHELL.backing))
    g.backing = backing
    local header = opts.header
    Glass.Reflect(g, frame, (header and header > 0) and { header = header } or nil)
    frame.glass = g
    return true
end

-- A reading region under a list or text: one plain masked texture on `host`,
-- over `area` (default: host) grown by `outset` px. It follows the window,
-- never the number of rows. BACKGROUND 0: over a shell on the same frame
-- (the library's layers stop at -3), under the text.
function Theme.Reading(host, area, outset)
    if active ~= "glass" then return false end
    area, outset = area or host, outset or 0
    local pane = host:CreateTexture(nil, "BACKGROUND", nil, 0)
    pane:SetPoint("TOPLEFT", area, "TOPLEFT", -outset, outset)
    pane:SetPoint("BOTTOMRIGHT", area, "BOTTOMRIGHT", outset, -outset)
    pane:SetColorTexture(unpack(READING))
    local S = Glass.SIZES.thin_small
    pane:AddMaskTexture(Glass.Mask(host, S.mask, S.maskMargin, 0, pane))
    host.glassReading = pane
    return true
end

-- A control with its own surface: the add box.
function Theme.Control(frame)
    if active ~= "glass" then return false end
    local g = Glass.Apply(frame, "small")
    Paint(g, CONTROL)
    Glass.SetEdge(g, 0.10, 0.015, 0.12, 3)
    frame.glass = g
    return true
end

-- A target button: a glass pill under it, and its picture and highlight inset
-- and rounded so the pill's rim shows around them. The button stays exactly
-- the secure button it was; this runs once, when it is made (out of combat).
function Theme.Button(btn)
    if active ~= "glass" then return false end
    local pill, g = Glass.Pill(btn, { highlight = false })
    Paint(g, CONTROL)
    Glass.SetEdge(g, 0, 0, 0)
    -- No shadow, as Pill builds it: it would spill onto the next button.
    Glass.SetSurfaceAlpha(g, "shadow", 0)
    local S = Glass.SIZES[g.size]
    local mask = Glass.Mask(btn, S.mask, S.maskMargin, ICON_INSET)
    for _, tex in ipairs({ btn.icon, btn.highlight }) do
        tex:ClearAllPoints()
        tex:SetPoint("TOPLEFT", btn, "TOPLEFT", ICON_INSET, -ICON_INSET)
        tex:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -ICON_INSET, ICON_INSET)
        tex:AddMaskTexture(mask)
    end
    btn.glassPill = pill
    return true
end

-- Test seam (tests/). Harmless in game.
Theme._test = { Glass = function() return Glass end, SHELL = SHELL, READING = READING, CONTROL = CONTROL,
                following = function() return following end }
