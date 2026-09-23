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
H.eq(#names, 2, "blanks and repeats are dropped")
H.eq(names[1], "Gruff Swiftbite", "names are trimmed")
H.eq(names[2], "Mother Fang", "order is kept")
H.eq(#T.ParseNames(""), 0, "nothing in, nothing out")
H.eq(T.ParseNames("Captain Flat Tusk")[1], "Captain Flat Tusk", "one multi-word name, no separator")

------------------------------------------------------------
-- /stakeout add
------------------------------------------------------------
slash("add Mother Fang; Fedfennel")
H.eq(#StakeoutDB.npcList, 2, "two names in one command")
WoW.messages = {}
slash("add Fedfennel; Morgaine the Sly")
H.eq(#StakeoutDB.npcList, 3, "only the new one is added")
H.check(WoW.chat():find("Already listed:|r Fedfennel", 1, true), "the duplicate is reported")

------------------------------------------------------------
-- ExportLines: every line fits a macro and round-trips
------------------------------------------------------------
local list = {}
for i = 1, 40 do list[i] = string.format("Some Long Named Rare Number %02d", i) end
local lines = T.ExportLines(list)
H.check(#lines > 1, "a long list spans several lines")
local back = {}
for _, line in ipairs(lines) do
    H.check(#line <= 255, "each line fits a 255-character macro (got " .. #line .. ")")
    H.eq(line:sub(1, 14), "/stakeout add ", "each line is a /stakeout add command")
    for _, n in ipairs(T.ParseNames(line:sub(15))) do back[#back + 1] = n end
end
H.eq(#back, 40, "every name comes back")
H.eq(back[40], list[40], "in order")
H.eq(#T.ExportLines({}), 0, "an empty list exports nothing")

WoW.messages = {}
slash("clear")
slash("export")
H.check(WoW.chat():find("empty", 1, true), "exporting an empty list says so")

slash("add Mother Fang")
slash("export")
H.eq(StakeoutExportFrame.eb:GetText(), "/stakeout add Mother Fang", "export fills the copy box")

------------------------------------------------------------
-- remove / list / reset / help
------------------------------------------------------------
WoW.messages = {}
slash("remove Mother Fang")
H.eq(#StakeoutDB.npcList, 0, "remove takes a multi-word name")
slash("remove Nobody")
H.check(WoW.chat():find("not found", 1, true), "removing an unknown name says so")
for _, cmd in ipairs({ "list", "reset", "help", "config", "config" }) do
    H.check(pcall(slash, cmd), "/stakeout " .. cmd .. " runs")
end

H.done("test_slash")
