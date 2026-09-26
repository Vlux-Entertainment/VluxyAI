--!strict

--[[
	Throttle: the first tick runs at once, later ones every interval with the gathered time, per
	agent, and Destroy forwards.
]]

local Harness = require("../Support/Harness")
local SenseFakes = require("./SenseFakes")

local function load()
	return Harness.Load("lib/Senses/Throttle.luau")
end

--[[
	A sense that logs every tick it receives.
]]
local function recorder()
	local sense = { Ticks = {} :: { any }, Destroyed = {} :: { any } }
	function sense.Tick(self, agent, deltaTime: number)
		table.insert(self.Ticks, { agent = agent, dt = deltaTime })
	end
	function sense.Destroy(self, agent)
		table.insert(self.Destroyed, agent or "all")
	end
	return sense
end

return {
	["the first tick runs at once, then one per interval with the time gathered"] = function(expect)
		local Throttle = load()
		local inner = recorder()
		local throttled = Throttle.new(inner, 0.3)
		local agent = SenseFakes.Agent()

		throttled:Tick(agent, 0.1)
		expect.equal(#inner.Ticks, 1, "first tick at once")
		throttled:Tick(agent, 0.1)
		throttled:Tick(agent, 0.1)
		expect.equal(#inner.Ticks, 1, "0.2 gathered, under the interval")
		throttled:Tick(agent, 0.1)
		expect.equal(#inner.Ticks, 2)
		expect.near(inner.Ticks[2].dt, 0.3, 1e-9, "the inner sense sees the time that passed")
		throttled:Tick(agent, 0.5)
		expect.equal(#inner.Ticks, 3, "a long frame runs it once")
		expect.near(inner.Ticks[3].dt, 0.5)
	end,

	["time is kept per agent"] = function(expect)
		local Throttle = load()
		local inner = recorder()
		local throttled = Throttle.new(inner, 1)
		local a, b = SenseFakes.Agent(), SenseFakes.Agent()

		throttled:Tick(a, 0.1)
		throttled:Tick(a, 0.6)
		throttled:Tick(b, 0.1)
		throttled:Tick(a, 0.5)
		expect.equal(#inner.Ticks, 3)
		expect.equal(inner.Ticks[3].agent, a)
		expect.near(inner.Ticks[3].dt, 1.1)
	end,

	["Destroy forwards and forgets the agent's clock"] = function(expect)
		local Throttle = load()
		local inner = recorder()
		local throttled = Throttle.new(inner, 1)
		local a = SenseFakes.Agent()

		throttled:Tick(a, 0.1)
		throttled:Destroy(a)
		expect.equal(inner.Destroyed[1], a)
		throttled:Tick(a, 0.1)
		expect.equal(#inner.Ticks, 2, "a forgotten agent starts over with an immediate tick")
		throttled:Destroy()
		expect.equal(inner.Destroyed[2], "all")
	end,

	["new checks its arguments"] = function(expect)
		local Throttle = load()
		expect.includes(
			expect.errors(function()
				Throttle.new({} :: any, 1)
			end),
			"needs a sense with Tick"
		)
		expect.includes(
			expect.errors(function()
				Throttle.new(recorder(), 0)
			end),
			"interval must be above 0"
		)
	end,
}
