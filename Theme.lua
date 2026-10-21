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
-------------------------------------------------------------------------------
local _, ns = ...

local Theme = {}
ns.theme = Theme

Theme.LOOKS  = { "forever", "glass" }
Theme.LABELS = { forever = "WoW Forever", glass = "Glass" }

local active   -- the session's look, fixed by Init
local Glass    -- this addon's LibGlass instance, under the glass look

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

-- A LibGlass instance with what the reflective shell needs (r9: Reflect,
-- SetSurfaceAlpha), or nil and why not.
local function NewGlass()
    local stub = rawget(_G, "LibStub")
    local lib = stub and stub("LibGlass-1.0", true)
    if not lib then return nil, "LibGlass-1.0 isn't loaded" end
    local ok, inst = pcall(lib.New, lib, { preset = "clean" })
    if not ok then return nil, tostring(inst) end
    if type(inst.Reflect) ~= "function" or type(inst.SetSurfaceAlpha) ~= "function" then
        return nil, "the loaded LibGlass-1.0 is older than r9"
    end
    return inst
end

-- Fix the session's look from the saved choice. Returns the look in use and,
-- when glass was chosen but can't be had, why.
function Theme.Init(choice)
    if active then return active end
    active = "forever"
    if choice == "glass" then
        local inst, why = NewGlass()
        if not inst then return active, why end
        Glass, active = inst, "glass"
    end
    return active
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

-- A window's outer shell. opts.header: the height (px) of its title area,
-- which the shell's reflection lights and fades out over; opts.small for a
-- frame that can be under ~40 px tall (the target frame).
function Theme.Window(frame, opts)
    if active ~= "glass" then return false end
    opts = opts or {}
    local g = Glass.Apply(frame, opts.small and "small" or "large")
    Paint(g, SHELL)
    -- No edge: the reflection's top highlight takes its place.
    Glass.SetEdge(g, 0, 0, 0)
    -- BACKGROUND -7: over the library's shadow (-8), under its tint (-6).
    local backing = frame:CreateTexture(nil, "BACKGROUND", nil, -7)
    backing:SetAllPoints(frame)
    backing:AddMaskTexture(g.mask)
    backing:SetColorTexture(unpack(SHELL.backing))
    g.backing = backing
    local header = opts.header
    Glass.Reflect(g, frame, (header and header > 0) and { header = header } or nil)
    frame.glass = g
    return true
end

-- A reading region under a list or text: one plain masked texture on `host`,
-- over `area` (default: host) grown by `outset` px. It follows the window,
-- never the number of rows.
function Theme.Reading(host, area, outset)
    if active ~= "glass" then return false end
    area, outset = area or host, outset or 0
    local pane = host:CreateTexture(nil, "BACKGROUND", nil, -7)
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
Theme._test = { Glass = function() return Glass end, SHELL = SHELL, READING = READING, CONTROL = CONTROL }
