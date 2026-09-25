--!strict

--[[
	The shared options resolver every constructor uses.
]]

local Harness = require("../Support/Harness")

local function load()
	return Harness.Load("lib/Utility/Options.luau")
end

return {
	["nil options give a copy of the defaults"] = function(expect)
		local Options = load()
		local defaults = { Range = 40, Memory = 3 }
		local resolved = Options.Resolve("Sight.new", defaults)
		expect.equal(resolved.Range, 40)
		expect.equal(resolved.Memory, 3)
		resolved.Range = 1
		expect.equal(defaults.Range, 40, "the defaults are untouched")
	end,

	["given keys override defaults"] = function(expect)
		local Options = load()
		local resolved = Options.Resolve("Sight.new", { Range = 40, Memory = 3 }, { Range = 10 })
		expect.equal(resolved.Range, 10)
		expect.equal(resolved.Memory, 3)
	end,

	["an unknown key errors with the owner and the known keys"] = function(expect)
		local Options = load()
		local message = expect.errors(function()
			Options.Resolve("Sight.new", { Range = 40, Memory = 3 }, { Rnage = 10 })
		end)
		expect.includes(message, '[VluxyAI] Sight.new: unknown option "Rnage"; expected one of Memory, Range')
	end,

	["allowed keys without a default are accepted and listed"] = function(expect)
		local Options = load()
		local targets = function() end
		local resolved = Options.Resolve("Sight.new", { Range = 40 }, { Targets = targets }, { "Targets" })
		expect.equal(resolved.Targets, targets)

		local message = expect.errors(function()
			Options.Resolve("Sight.new", { Range = 40 }, { Target = targets }, { "Targets" })
		end)
		expect.includes(message, "expected one of Range, Targets")
	end,

	["options must be a table"] = function(expect)
		local Options = load()
		local message = expect.errors(function()
			Options.Resolve("Sight.new", { Range = 40 }, 5 :: any)
		end)
		expect.includes(message, "options must be a table, got a number")
	end,
}
