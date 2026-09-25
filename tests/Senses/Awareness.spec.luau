--!strict

--[[
	Awareness: the meter rising on a While source, jumping once per At value, draining in
	silence, the levels, and the last known position following whichever source spoke last.
	The blackboard is written by hand as the other senses would have.
]]

local Harness = require("../Support/Harness")
local SenseFakes = require("./SenseFakes")

local roblox = require("@lune/roblox")
local Vector3 = roblox.Vector3

local function setup(options: any?)
	local clock = Harness.ManualClock(100)
	local Awareness = Harness.Load("lib/Senses/Awareness.luau", {
		globals = SenseFakes.Globals({ clock = clock }),
	})
	local agent = SenseFakes.Agent()
	return {
		Awareness = Awareness,
		sense = Awareness.new(options),
		agent = agent,
		blackboard = agent.Blackboard,
		clock = clock,
	}
end

return {
	["nothing present: the meter is 0, calm, with no last known position"] = function(expect)
		local s = setup()
		s.sense:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.Awareness, 0)
		expect.equal(s.blackboard.AwarenessLevel, "Calm")
		expect.equal(s.blackboard.LastKnownPosition, nil)
		expect.equal(s.blackboard.LastKnownAt, nil)
		expect.equal(s.blackboard.LastKnownSource, nil)
	end,

	["a While source raises the meter at Rise per second and sets the last known position"] = function(expect)
		local s = setup({ Rise = 1, Suspicious = 0.3, Alerted = 1 })
		s.blackboard.SeenTarget = "root"
		s.blackboard.SeenPosition = Vector3.new(5, 0, 5)

		s.sense:Tick(s.agent, 0.2)
		expect.near(s.blackboard.Awareness, 0.2)
		expect.equal(s.blackboard.AwarenessLevel, "Calm")
		expect.equal(s.blackboard.LastKnownPosition, Vector3.new(5, 0, 5))
		expect.equal(s.blackboard.LastKnownAt, 100)
		expect.equal(s.blackboard.LastKnownSource, "Sight")

		s.sense:Tick(s.agent, 0.2)
		expect.near(s.blackboard.Awareness, 0.4)
		expect.equal(s.blackboard.AwarenessLevel, "Suspicious")

		s.sense:Tick(s.agent, 1)
		expect.near(s.blackboard.Awareness, 1, 1e-6, "clamped at 1")
		expect.equal(s.blackboard.AwarenessLevel, "Alerted")
	end,

	["an At source jumps the meter once per new value"] = function(expect)
		local s = setup({ Fall = 0 })
		s.blackboard.HeardAt = 10
		s.blackboard.HeardPosition = Vector3.new(-3, 0, 0)

		s.sense:Tick(s.agent, 0.1)
		expect.near(s.blackboard.Awareness, 0.5, 1e-6, "the default Hearing weight")
		expect.equal(s.blackboard.LastKnownSource, "Hearing")
		expect.equal(s.blackboard.LastKnownPosition, Vector3.new(-3, 0, 0))

		s.sense:Tick(s.agent, 0.1)
		expect.near(s.blackboard.Awareness, 0.5, 1e-6, "the same noise does not count twice")

		s.blackboard.HeardAt = 12
		s.sense:Tick(s.agent, 0.1)
		expect.near(s.blackboard.Awareness, 1, 1e-6, "a new noise counts")

		s.blackboard.HeardAt = nil
		s.sense:Tick(s.agent, 0.1)
		s.blackboard.HeardAt = 12
		s.sense:Tick(s.agent, 0.1)
		expect.near(s.blackboard.Awareness, 1, 1e-6)
		expect.equal(s.agent.Data.Awareness.HeardAt, 12, "counted timestamps live in Data")
	end,

	["silence drains the meter at Fall per second and clears the last known position at 0"] = function(expect)
		local s = setup({ Rise = 10, Fall = 0.5 })
		s.blackboard.SeenTarget = "root"
		s.blackboard.SeenPosition = Vector3.new(1, 0, 1)
		s.sense:Tick(s.agent, 0.1)
		expect.near(s.blackboard.Awareness, 1, 1e-6)

		s.blackboard.SeenTarget = nil
		s.sense:Tick(s.agent, 1)
		expect.near(s.blackboard.Awareness, 0.5)
		expect.equal(s.blackboard.LastKnownPosition, Vector3.new(1, 0, 1), "still remembered while draining")
		expect.equal(s.blackboard.AwarenessLevel, "Suspicious")

		s.sense:Tick(s.agent, 1)
		expect.equal(s.blackboard.Awareness, 0)
		expect.equal(s.blackboard.AwarenessLevel, "Calm")
		expect.equal(s.blackboard.LastKnownPosition, nil, "forgotten once calm")
		expect.equal(s.blackboard.LastKnownAt, nil)
		expect.equal(s.blackboard.LastKnownSource, nil)
	end,

	["the latest source in the list wins the last known position when several speak"] = function(expect)
		local s = setup()
		s.blackboard.SeenTarget = "root"
		s.blackboard.SeenPosition = Vector3.new(1, 0, 0)
		s.blackboard.HeardAt = 3
		s.blackboard.HeardPosition = Vector3.new(2, 0, 0)

		s.sense:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.LastKnownSource, "Hearing")
		expect.equal(s.blackboard.LastKnownPosition, Vector3.new(2, 0, 0))

		s.sense:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.LastKnownSource, "Sight", "only sight is still present")
		expect.equal(s.blackboard.LastKnownPosition, Vector3.new(1, 0, 0))
	end,

	["Rise may be a function of the agent, and Sources and Weight are options"] = function(expect)
		local s = setup({
			Rise = function(agent)
				return agent.Blackboard.SeenDistance < 5 and 4 or 1
			end,
			Sources = { { Name = "Eyes", While = "SeenTarget", Position = "SeenPosition", Weight = 0.5 } },
		})
		s.blackboard.SeenTarget = "root"
		s.blackboard.SeenDistance = 3

		s.sense:Tick(s.agent, 0.1)
		expect.near(s.blackboard.Awareness, 0.2, 1e-6, "4 * 0.5 * 0.1")
		expect.equal(s.blackboard.LastKnownSource, nil, "no position key written")

		s.blackboard.HeardAt = 1
		s.sense:Tick(s.agent, 0.1)
		expect.near(s.blackboard.Awareness, 0.4, 1e-6, "hearing is not a source here")
	end,

	["new rejects a bad source and an unknown option"] = function(expect)
		local s = setup()
		local message = expect.errors(function()
			s.Awareness.new({ Sources = { { Name = "X" } } })
		end)
		expect.includes(message, "needs a While or an At key")

		message = expect.errors(function()
			s.Awareness.new({ Sources = { { While = "SeenTarget" } } })
		end)
		expect.includes(message, "Name must be a string")

		message = expect.errors(function()
			s.Awareness.new({ Decay = 1 })
		end)
		expect.includes(message, 'unknown option "Decay"')
	end,
}
