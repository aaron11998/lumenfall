--!strict
-- LUMENFALL Roblox leg: client bootstrap (AGE-142).
-- Applies the semantic dark theme (design tokens) to the core UI surface.
-- Kept deliberately small: proves the shared token module loads client-side
-- and that token values parse into Roblox datatypes.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Tokens = require(Shared:WaitForChild("Tokens"))

local Client = {}

local function applyBackground(instance: GuiObject?)
	if instance == nil then
		return false
	end
	local bg = Tokens.color3("color.semantic.dark.bg-primary")
	if bg == nil then
		return false
	end
	instance.BackgroundColor3 = bg
	return true
end

Client.applyBackground = applyBackground
return Client
