--!strict

--[[
	Proximity: who is within range, nearest first, and the math.huge sentinel when nobody is.
]]

local Harness = require("../Support/Harness")
local SenseFakes = require("./SenseFakes")

local roblox = require("@lune/roblox")
local Vector3 = roblox.Vector3

local function setup(options: any?)
	local Proximity = Harness.Load("lib/Senses/Proximity.luau", { globals = SenseFakes.Globals() })
	local agent = SenseFakes.Agent(Vector3.new(0, 0, 0))

	return {
		proximity = Proximity.new(options),
		agent = agent,
		blackboard = agent.Blackboard,
	}
end

return {
	["targets within Range are listed nearest first, with the nearest and its distance"] = function(expect)
		local far = SenseFakes.Part(Vector3.new(0, 0, 40))
		local near = SenseFakes.Part(Vector3.new(3, 4, 0))
		local behind = SenseFakes.Part(Vector3.new(-20, 0, 0))
		local s = setup({ Range = 50, Targets = SenseFakes.Targets({ far, near, behind }) })

		s.proximity:Tick(s.agent, 0.1)
		expect.equal(#s.blackboard.NearbyTargets, 3)
		expect.equal(s.blackboard.NearbyTargets[1], near)
		expect.equal(s.blackboard.NearbyTargets[2], behind)
		expect.equal(s.blackboard.NearbyTargets[3], far)
		expect.equal(s.blackboard.NearestTarget, near)
		expect.near(s.blackboard.NearestDistance, 5)
	end,

	["targets beyond Range are left out; exactly at Range is in"] = function(expect)
		local atRange = SenseFakes.Part(Vector3.new(30, 0, 0))
		local past = SenseFakes.Part(Vector3.new(30.01, 0, 0))
		local s = setup({ Range = 30, Targets = SenseFakes.Targets({ past, atRange }) })

		s.proximity:Tick(s.agent, 0.1)
		expect.equal(#s.blackboard.NearbyTargets, 1)
		expect.equal(s.blackboard.NearestTarget, atRange)
	end,

	["with nobody near, the list is empty, the target nil and the distance math.huge"] = function(expect)
		local s = setup({ Range = 10, Targets = SenseFakes.Targets({ SenseFakes.Part(Vector3.new(50, 0, 0)) }) })

		s.proximity:Tick(s.agent, 0.1)
		expect.equal(#s.blackboard.NearbyTargets, 0)
		expect.equal(s.blackboard.NearestTarget, nil)
		expect.equal(s.blackboard.NearestDistance, math.huge)
	end,

	["a target that leaves clears the keys on the next tick"] = function(expect)
		local targets = { SenseFakes.Part(Vector3.new(5, 0, 0)) }
		local s = setup({
			Targets = function()
				return targets
			end,
		})

		s.proximity:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.NearestTarget, targets[1])
		table.clear(targets)
		s.proximity:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.NearestTarget, nil)
		expect.equal(s.blackboard.NearestDistance, math.huge)
	end,

	["distance is measured from the agent's GetPosition"] = function(expect)
		local target = SenseFakes.Part(Vector3.new(105, 0, 0))
		local s = setup({ Range = 10, Targets = SenseFakes.Targets({ target }) })
		s.agent.GetPosition = function()
			return Vector3.new(100, 0, 0)
		end

		s.proximity:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.NearestTarget, target)
		expect.near(s.blackboard.NearestDistance, 5)
	end,

	["Targets receives the agent"] = function(expect)
		local seen = nil
		local s = setup({
			Targets = function(agent)
				seen = agent
				return {}
			end,
		})

		s.proximity:Tick(s.agent, 0.1)
		expect.equal(seen, s.agent)
	end,

	["the default Range is 100"] = function(expect)
		local inside = SenseFakes.Part(Vector3.new(100, 0, 0))
		local outside = SenseFakes.Part(Vector3.new(100.5, 0, 0))
		local s = setup({ Targets = SenseFakes.Targets({ outside, inside }) })

		s.proximity:Tick(s.agent, 0.1)
		expect.equal(#s.blackboard.NearbyTargets, 1)
		expect.equal(s.blackboard.NearestTarget, inside)
	end,

	["a negative Range is refused"] = function(expect)
		local Proximity = Harness.Load("lib/Senses/Proximity.luau", { globals = SenseFakes.Globals() })
		local message = expect.errors(function()
			Proximity.new({ Range = -5 })
		end)
		expect.includes(message, "Range")
	end,

	["Destroy is safe to call"] = function(expect)
		local s = setup()
		s.proximity:Destroy()
		expect.truthy(true)
	end,
}
