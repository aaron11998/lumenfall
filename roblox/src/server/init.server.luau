--!strict
-- LUMENFALL Roblox leg: server bootstrap (AGE-142).
-- Minimal lifecycle scaffold: registers a join hook that tags players with
-- the current build stamp so CI-built places are identifiable in Live
-- (build info injected at publish time by scripts_tool/roblox_ci/publish_place.luau).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Tokens = require(Shared:WaitForChild("Tokens"))

local Server = {}

-- Sanity: the token module must expose the canonical dark-mode background.
-- A missing token means the generated module drifted from the contract.
local function assertBackgroundToken(): boolean
	local bg = Tokens.get("color.semantic.dark.bg-primary")
	return bg ~= nil and string.sub(bg, 1, 1) == "#"
end

function Server.onPlayerAdded(player: Player)
	if assertBackgroundToken() then
		player:SetAttribute("LumenfallThemeOk", true)
	else
		player:SetAttribute("LumenfallThemeOk", false)
		warn("[lumenfall] token contract drifted: dark bg-primary missing")
	end
end

if Players.LocalPlayer == nil then
	-- Server context only (rojo builds run this in ServerScriptService).
	Players.PlayerAdded:Connect(Server.onPlayerAdded)
	for _, player in Players:GetPlayers() do
		Server.onPlayerAdded(player)
	end
end

return Server
