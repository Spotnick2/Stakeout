------------------------------------------------------------
-- test_slash.lua - bulk add, export lines, and the slash commands.
--
-- SavedVariables never load back on this client, so the watch list is typed
-- back in each session: `/stakeout add A; B; C` from a macro, which
-- `/stakeout export` produces.
------------------------------------------------------------

dofile("tests/wow_stubs.lua")
local H = dofile("tests/harness.lua")

local T = WoW.loadAddon()
local slash = SlashCmdList.STAKEOUT

------------------------------------------------------------
-- ParseNames
------------------------------------------------------------
local names = T.ParseNames("  Gruff Swiftbite ;Mother Fang;; Gruff Swiftbite ; ")
eq(#names, 2, "blanks and repeats are dropped")
eq(names[1], "Gruff Swiftbite", "names are trimmed")
eq(names[2], "Mother Fang", "order is kept")
eq(#T.ParseNames(""), 0, "nothing in, nothing out")
eq(T.ParseNames("Captain Flat Tusk")[1], "Captain Flat Tusk", "one multi-word name, no separator")

------------------------------------------------------------
-- /stakeout add
------------------------------------------------------------
slash("add Mother Fang; Fedfennel")
eq(#StakeoutDB.npcList, 2, "two names in one command")
WoW.chat = {}
slash("add Fedfennel; Morgaine the Sly")
eq(#StakeoutDB.npcList, 3, "only the new one is added")
check(WoW.chatText():find("Already listed:|r Fedfennel", 1, true), "the duplicate is reported")

------------------------------------------------------------
-- ExportLines: every line fits a macro and round-trips
------------------------------------------------------------
local list = {}
for i = 1, 40 do list[i] = string.format("Some Long Named Rare Number %02d", i) end
local lines = T.ExportLines(list)
check(#lines > 1, "a long list spans several lines")
local back = {}
for _, line in ipairs(lines) do
    check(#line <= 255, "each line fits a 255-character macro (got " .. #line .. ")")
    eq(line:sub(1, 14), "/stakeout add ", "each line is a /stakeout add command")
    for _, n in ipairs(T.ParseNames(line:sub(15))) do back[#back + 1] = n end
end
eq(#back, 40, "every name comes back")
eq(back[40], list[40], "in order")
eq(#T.ExportLines({}), 0, "an empty list exports nothing")

WoW.chat = {}
slash("clear")
slash("export")
check(WoW.chatText():find("empty", 1, true), "exporting an empty list says so")

slash("add Mother Fang")
slash("export")
eq(StakeoutExportFrame.eb:GetText(), "/stakeout add Mother Fang", "export fills the copy box")

-- Opened from the config window (same strata, which comes forward when its
-- Export button is clicked): the export window must come out on top.
eq(StakeoutExportFrame._toplevel, true, "the export window comes forward when clicked")
check(StakeoutExportFrame._raisedAt ~= nil, "and is raised when it opens")
local raised = StakeoutExportFrame._raisedAt
slash("export")
check(StakeoutExportFrame._raisedAt > raised, "and again each time it opens")

------------------------------------------------------------
-- remove / list / reset / help
------------------------------------------------------------
WoW.chat = {}
slash("remove Mother Fang")
eq(#StakeoutDB.npcList, 0, "remove takes a multi-word name")
slash("remove Nobody")
check(WoW.chatText():find("not found", 1, true), "removing an unknown name says so")
for _, cmd in ipairs({ "list", "reset", "help", "config", "config" }) do
    check(pcall(slash, cmd), "/stakeout " .. cmd .. " runs")
end

------------------------------------------------------------
-- /stakeout quests (experimental, off by default)
------------------------------------------------------------
WoW.chat = {}
slash("help")
check(WoW.chatText():find("/stakeout quests on / off", 1, true) and WoW.chatText():find("(experimental)", 1, true),
    "the help names the quests command as experimental")
WoW.chat = {}
slash("quests")
check(WoW.chatText():find("Quest targets (experimental):", 1, true) and WoW.chatText():find("off", 1, true),
    "/stakeout quests says it is off: " .. WoW.chatText())
check(WoW.chatText():find("/stakeout quests on", 1, true), "...and how to try it")
eq(StakeoutDB.questTargets, false, "asking changes nothing")
WoW.chat = {}
slash("quests on")
eq(StakeoutDB.questTargets, true, "/stakeout quests on")
check(WoW.chatText():find("Quest targets (experimental):", 1, true) and WoW.chatText():find("on", 1, true),
    "...confirmed")
check(WoW.chatText():find("Without quest data", 1, true), "...with the subset it covers without Questie")
slash("quests OFF")
eq(StakeoutDB.questTargets, false, "/stakeout quests off (any case)")
slash("quests maybe")
eq(StakeoutDB.questTargets, false, "anything else only reports")

------------------------------------------------------------
-- The settings window's quest targets checkbox (#61): the same switch
------------------------------------------------------------
slash("config")
local qc = StakeoutConfigFrame.questCheck
check(qc ~= nil, "the settings window has a quest targets checkbox")
eq(qc:GetChecked(), false, "...off, as the setting is")
local qlabel = qc.text or qc.Text
check(qlabel and qlabel:GetText():find("quest", 1, true), "...labelled for quests")
check(qc.desc and qc.desc:GetText():find("Experimental", 1, true), "...and marked experimental")
WoW.chat = {}
qc:SetChecked(true)
qc._scripts.OnClick(qc, "LeftButton", false)
eq(StakeoutDB.questTargets, true, "ticking it turns quest targets on")
check(WoW.chatText():find("Quest targets (experimental):", 1, true) and WoW.chatText():find("Without quest data", 1, true),
    "...and says what it covers, as the command does")
slash("quests off")
eq(qc:GetChecked(), false, "/stakeout quests off while the window is open unticks it")
slash("quests on")
eq(qc:GetChecked(), true, "...and on ticks it")
slash("config")
check(not StakeoutConfigFrame:IsShown(), "the window closes")
StakeoutDB.questTargets = false
slash("config")
eq(qc:GetChecked(), false, "reopened, it shows the setting as it is now")
qc:SetChecked(false)
qc._scripts.OnClick(qc, "LeftButton", false)
eq(StakeoutDB.questTargets, false, "unticking it turns quest targets off")
slash("config")

done("test_slash")
