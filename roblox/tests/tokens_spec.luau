--!strict
-- TestEZ suite for the Roblox leg (AGE-142).
-- Runs in two contexts:
--   * lune (CI):        lune run scripts_tool/roblox_ci/run_tests.luau
--   * Roblox Studio:    via rojo sync — ReplicatedStorage.Shared.Tokens exists
-- Environment detection: lune injects a nil `script` global into chunks but a
-- DataModel `game` is only provided by the runner through _G.

local function loadTokens()
	if _G.game ~= nil then
		-- lune/CI context
		return require("../../roblox/src/shared/Tokens")
	end
	-- Studio/rojo runtime context
	return require(game:GetService("ReplicatedStorage").Shared.Tokens)
end

local Tokens = loadTokens()

return function()
	describe("Tokens module", function()
		it("resolves the canonical dark background token", function()
			local value = Tokens.get("color.semantic.dark.bg-primary")
			expect(value).to.be.a("string")
			expect(string.sub(value :: string, 1, 1)).to.equal("#")
		end)

		it("returns nil for unknown tokens", function()
			expect(Tokens.get("color.does.not.exist")).to.equal(nil)
		end)

		it("sorts group listings by name", function()
			local group = Tokens.group("color")
			expect(#group > 0).to.equal(true)
			for i = 2, #group do
				expect(group[i - 1].name < group[i].name).to.equal(true)
			end
		end)

		it("parses hex tokens into Color3", function()
			local c = Tokens.color3("color.primitive.accent-500")
			expect(c).to.be.ok()
			if c ~= nil then
				expect(c.R).to.be.near(0.976, 0.01) -- #F97316
				expect(c.G).to.be.near(0.451, 0.01)
				expect(c.B).to.be.near(0.086, 0.01)
			end
		end)

		it("exposes the generated token set non-empty and stable", function()
			local all = Tokens.group("color")
			expect(#all >= 5).to.equal(true)
		end)
	end)
end
