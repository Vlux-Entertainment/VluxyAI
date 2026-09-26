--!strict

--[[
	Director: tension raised, drained by the clock and clamped; difficulty; Scale; and the sense
	that writes the three keys to any agent.
]]

local Fakes = require("../Support/Fakes")
local Harness = require("../Support/Harness")

local function load(clock: any)
	return Harness.Load("lib/Director.luau", { globals = { os = clock.os } })
end

return {
	["tension rises, drains at Fall per second and stays in [0, 1]"] = function(expect)
		local clock = Harness.ManualClock(100)
		local Director = load(clock)
		local director = Director.new({ Fall = 0.1 })

		expect.equal(director:GetTension(), 0)
		director:Raise(0.5)
		expect.near(director:GetTension(), 0.5)
		clock:Advance(2)
		expect.near(director:GetTension(), 0.3)
		director:Raise(5)
		expect.near(director:GetTension(), 1, 1e-6, "clamped")
		clock:Advance(20)
		expect.near(director:GetTension(), 0, 1e-6, "drained to nothing, not below")
		director:SetTension(0.4)
		director:Lower(0.1)
		expect.near(director:GetTension(), 0.3)
	end,

	["difficulty is a plain number and Scale combines both"] = function(expect)
		local clock = Harness.ManualClock(100)
		local Director = load(clock)
		local director = Director.new({ Tension = 0.5, Difficulty = 2 })

		expect.equal(director:GetDifficulty(), 2)
		expect.near(director:Scale(10), 10, 1e-6, "no factors")
		expect.near(director:Scale(10, 0.5), 12.5, 1e-6, "half again at full tension, so a quarter now")
		expect.near(director:Scale(10, 0, 0.25), 12.5, 1e-6, "a quarter per difficulty step above 1")
		expect.near(director:Scale(10, 0.5, 0.25), 15.625)
		director:SetDifficulty(1)
		expect.near(director:Scale(10, 0, 0.25), 10)
	end,

	["Sense writes tension, difficulty and the shared blackboard under the prefix"] = function(expect)
		local clock = Harness.ManualClock(100)
		local Director = load(clock)
		local director = Director.new({ Tension = 0.25 })
		director.Blackboard.Alarm = "kitchen"

		local sense = director:Sense()
		local agent = Fakes.Agent()
		sense:Tick(agent, 0.1)
		expect.near(agent.Blackboard.DirectorTension, 0.25)
		expect.equal(agent.Blackboard.DirectorDifficulty, 1)
		expect.equal(agent.Blackboard.DirectorShared, director.Blackboard, "shared by reference")
		expect.equal(agent.Blackboard.DirectorShared.Alarm, "kitchen")

		local other = Fakes.Agent()
		director:Sense({ Prefix = "" }):Tick(other, 0.1)
		expect.near(other.Blackboard.Tension, 0.25)

		local message = expect.errors(function()
			Director.new({ Decay = 1 })
		end)
		expect.includes(message, 'unknown option "Decay"')
	end,
}
