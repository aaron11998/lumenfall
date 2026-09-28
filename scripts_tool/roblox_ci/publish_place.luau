--!strict
-- LUMENFALL Roblox leg: Open Cloud place publisher (AGE-142).
-- Usage: lune run scripts_tool/roblox_ci/publish_place.luau [--place-id ID]
--
-- Uploads the CI-built .rbxlx place to Roblox via the Open Cloud
-- universes/places PATCH endpoint (v1). Runs ONLY from the dispatch-gated
-- workflow job (workflow_dispatch with confirm_roblox_publish=true) — never
-- on push. The API key comes from env ROBLOX_OPEN_CLOUD_API_KEY and is
-- NEVER printed or logged.
--
-- Roblox Open Cloud publish:
--   PATCH https://apis.roblox.com/cloud/v2/universes/{universe}/places/{place}/contents
--   x-api-key: <key>
--   Content-Type: application/xml
--   body: the .rbxlx XML
--
-- Convention: universe id = place id (single-place universe, LUMENFALL CI
-- staging place). Override with ROBLOX_UNIVERSE_ID / ROBLOX_PLACE_ID env or
-- --place-id flag (universe defaults to the same value).

local http = require("@lune/net").request
local fs = require("@lune/fs")

local function arg(name: string): string?
	local args = _G.args
	if args == nil then
		return nil
	end
	local i = 1
	while args[i] ~= nil do
		if args[i] == name then
			return args[i + 1]
		end
		i += 1
	end
	return nil
end

local placeId = arg("--place-id") or process.env.ROBLOX_PLACE_ID
local universeId = process.env.ROBLOX_UNIVERSE_ID or placeId
local apiKey = process.env.ROBLOX_OPEN_CLOUD_API_KEY
local refName = process.env.ROBLOX_REF or process.env.CI_COMMIT_REF_NAME or "local"
local buildNum = process.env.ROBLOX_BUILDNUM or process.env.CI_PIPELINE_IID or "dev"

if placeId == nil or universeId == nil then
	print("PUBLISH_RESULT=SKIP (ROBLOX_PLACE_ID / ROBLOX_UNIVERSE_ID not set)")
	return
end
if apiKey == nil or #apiKey == 0 then
	print("PUBLISH_RESULT=SKIP (ROBLOX_OPEN_CLOUD_API_KEY not set)")
	return
end

-- Find the newest built place file.
local outRoot = "builds"
local best: string? = nil
for entry in fs.readDir(outRoot) do
	local candidate = `{outRoot}/{entry}/roblox/lumenfall_{refName}_{buildNum}.rbxlx`
	if fs.isFile(candidate) then
		best = candidate
		break
	end
end
if best == nil then
	-- Fall back to any roblox place under the ref's build dir.
	for entry in fs.readDir(outRoot) do
		local dir = `{outRoot}/{entry}/roblox`
		if fs.isDir(dir) then
			for name in fs.readDir(dir) do
				if name:sub(-6) == ".rbxlx" then
					best = `{dir}/{name}`
				end
			end
		end
	end
end

if best == nil then
	print("PUBLISH_RESULT=FAIL (no .rbxlx place file found under builds/)")
	error("no place file to publish", 0)
end

print(`publishing: {best} -> place {placeId}`)
local body = fs.readFile(best)

local response = http({
	url = `https://apis.roblox.com/cloud/v2/universes/{universeId}/places/{placeId}/contents?versionType=Published`,
	method = "PATCH",
	headers = {
		["x-api-key"] = apiKey,
		["Content-Type"] = "application/xml",
	},
	body = body,
})

if response.ok then
	print(`PUBLISH_RESULT=OK status={response.statusCode} file={best}`)
else
	-- Never echo the key; the response body may carry API error details.
	print(`PUBLISH_RESULT=FAIL status={response.statusCode} (see publish log)`)
	print(response.body)
	error(`Open Cloud publish failed (HTTP {response.statusCode})`, 0)
end
