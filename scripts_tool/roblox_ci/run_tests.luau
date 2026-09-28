--!strict
-- LUMENFALL Roblox leg: lune TestEZ runner (AGE-142).
-- Usage (from repo root): lune run scripts_tool/roblox_ci/run_tests.luau
--
-- TestEZ v0.4.2 vendored at roblox/testez, adapted for lune file-require
-- (headers marked `lune-compat`; see docs/ROBLOX_CI.md). Plans and runs
-- roblox/tests/*.spec.luau directly — no Instance discovery, because lune
-- cannot require Instance objects. Prints a TESTEZ_RESULT= marker consumed
-- by build_matrix.sh; exits 1 on any failure.

local task = require("@lune/task")
local roblox = require("@lune/roblox")

-- Roblox globals TestEZ and specs rely on. lune shadows the bare `game` and
-- `script` identifiers to nil inside chunks, so specs reference _G.game.
_G.game = roblox.Instance.new("DataModel")
_G.__LUNE_RUNNER = true
_G.Color3 = roblox.Color3
_G.tick = os.clock
_G.wait = function(t)
	task.wait(t)
end

local base = "../../roblox/testez/"
local TestPlanner = require(base .. "TestPlanner")
local TestRunner = require(base .. "TestRunner")
local TextReporterQuiet = require(base .. "Reporters/TextReporterQuiet")

local specModules = {
	require("../../roblox/tests/tokens_spec"),
}

local modulesList = {}
for i, spec in specModules do
	table.insert(modulesList, {
		method = spec,
		path = { string.format("spec_%02d", i) },
		pathStringForSorting = string.format("spec_%02d", i),
	})
end

local plan = TestPlanner.createPlan(modulesList, nil, nil)
local results = TestRunner.runPlan(plan, TextReporterQuiet)
TextReporterQuiet.report(results)

local failed = results.failureCount + #results.errors
print(string.format(
	"TESTEZ_RESULT=%s pass=%d fail=%d",
	failed == 0 and "PASS" or "FAIL",
	results.successCount,
	failed
))
if failed > 0 then
	error("TestEZ suite failed", 0)
end
