-- [lune-compat, AGE-142] lune file-require adaptation
local __lune_base = "../../roblox/testez/"
--[[
	Constants used throughout the testing framework.
]]

local TestEnum = {}

TestEnum.TestStatus = {
	Success = "Success",
	Failure = "Failure",
	Skipped = "Skipped"
}

TestEnum.NodeType = {
	Describe = "Describe",
	It = "It",
	BeforeAll = "BeforeAll",
	AfterAll = "AfterAll",
	BeforeEach = "BeforeEach",
	AfterEach = "AfterEach"
}

TestEnum.NodeModifier = {
	None = "None",
	Skip = "Skip",
	Focus = "Focus"
}

return TestEnum