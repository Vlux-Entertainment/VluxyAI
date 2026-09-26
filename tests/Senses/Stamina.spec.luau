--!strict

--[[
	Stamina: draining above the threshold, recovering below it, clamped to [0, 1].
]]

local Harness = require("../Support/Harness")

local roblox = require("@lune/roblox")
local Vector3 = roblox.Vector3

local function agentAt(position: any)
	local agent = { Name = "Fake", Blackboard = {}, Data = {}, Position = position }
	function agent.GetPosition(self)
		return self.Position
	end
	return agent
end

return {
	["it drains while moving faster than Threshold and recovers otherwise"] = function(expect)
		local Stamina = Harness.Load("lib/Senses/Stamina.luau")
		local sense = Stamina.new({ Threshold = 10, Drain = 0.5, Regen = 0.25 })
		local agent = agentAt(Vector3.new(0, 0, 0))

		sense:Tick(agent, 0.1)
		expect.equal(agent.Blackboard.Stamina, 1, "starts full")

		-- 20 studs a second for a second.
		for _ = 1, 10 do
			agent.Position += Vector3.new(2, 0, 0)
			sense:Tick(agent, 0.1)
		end
		expect.near(agent.Blackboard.Stamina, 0.5, 1e-6)

		-- Standing still for a second.
		for _ = 1, 10 do
			sense:Tick(agent, 0.1)
		end
		expect.near(agent.Blackboard.Stamina, 0.75, 1e-6)
	end,

	["the meter stays between 0 and 1, and starts from the blackboard"] = function(expect)
		local Stamina = Harness.Load("lib/Senses/Stamina.luau")
		local sense = Stamina.new({ Threshold = 1, Drain = 10 })
		local agent = agentAt(Vector3.new(0, 0, 0))
		agent.Blackboard.Stamina = 0.3
		sense:Tick(agent, 0.1)
		expect.equal(agent.Blackboard.Stamina, 0.3, "no speed yet on the first tick; it recovers only from the next")
		agent.Position = Vector3.new(50, 0, 0)
		sense:Tick(agent, 0.1)
		expect.equal(agent.Blackboard.Stamina, 0)

		expect.includes(
			expect.errors(function()
				Stamina.new({ Drain = -1 })
			end),
			"Drain"
		)
	end,
}
