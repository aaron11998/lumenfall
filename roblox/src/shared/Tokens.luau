--!strict
-- LUMENFALL Roblox leg: runtime representation of one design token (AGE-142).
-- Values are generated from tokens/v1/tokens.json (AGE-143 token pipeline)
-- by scripts_tool/roblox_ci/gen_tokens.lua — do not hand-edit TokenDefs.

export type Token = {
	name: string,
	group: string,
	value: string,
}

local TokenDefs: { [string]: Token } = {
	["color.primitive.ink-900"] = { name = "color.primitive.ink-900", group = "color", value = "#101418" },
	["color.primitive.accent-500"] = { name = "color.primitive.accent-500", group = "color", value = "#F97316" },
	["color.primitive.accent-700"] = { name = "color.primitive.accent-700", group = "color", value = "#C2410C" },
	["color.primitive.teal-400"] = { name = "color.primitive.teal-400", group = "color", value = "#2DD4BF" },
	["color.primitive.success-600"] = { name = "color.primitive.success-600", group = "color", value = "#059669" },
	["color.semantic.dark.bg-primary"] = { name = "color.semantic.dark.bg-primary", group = "color", value = "#080A0C" },
	["radius.radius-md"] = { name = "radius.radius-md", group = "radius", value = "8" },
}

local Tokens = {}

-- Resolve a dotted token path ("color.primitive.ink-900") to its value.
-- Returns nil for unknown tokens (callers decide whether that is fatal).
function Tokens.get(name: string): string?
	local def = TokenDefs[name]
	if def == nil then
		return nil
	end
	return def.value
end

-- All tokens in one group, sorted by name (stable output for tests/telemetry).
function Tokens.group(group: string): { Token }
	local out: { Token } = {}
	for _, def in TokenDefs do
		if def.group == group then
			table.insert(out, def)
		end
	end
	table.sort(out, function(a: Token, b: Token): boolean
		return a.name < b.name
	end)
	return out
end

-- Convert "#RRGGBB" to Roblox Color3 (0-1 floats).
function Tokens.color3(name: string): Color3?
	local value = Tokens.get(name)
	if value == nil then
		return nil
	end
	local r = tonumber(string.sub(value, 2, 3), 16)
	local g = tonumber(string.sub(value, 4, 5), 16)
	local b = tonumber(string.sub(value, 6, 7), 16)
	if r == nil or g == nil or b == nil then
		return nil
	end
	local c3 = _G.Color3
	if c3 == nil then
		return nil
	end
	return c3.fromRGB(r, g, b)
end

return Tokens
