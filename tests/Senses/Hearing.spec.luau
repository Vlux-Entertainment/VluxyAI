--!strict

--[[
	Hearing: which buffered noise wins a tick, how loudness stretches the range, how long the
	heard keys last, and how one instance keeps a buffer per agent. The package Signal carries
	the noises and a manual clock drives the memory.
]]

local Fakes = require("../Support/Fakes")
local Harness = require("../Support/Harness")
local SenseFakes = require("./SenseFakes")

local roblox = require("@lune/roblox")
local Vector3 = roblox.Vector3

local function setup(options: { hearing: any?, warnings: { string }? }?)
	local resolved = options or {}
	local clock = Harness.ManualClock(100)
	local Hearing = Harness.Load("lib/Senses/Hearing.luau", {
		globals = SenseFakes.Globals({ clock = clock }),
		warn = function(message)
			if resolved.warnings then
				table.insert(resolved.warnings, tostring(message))
			end
		end,
	})

	local Signal = Fakes.Signal()
	local noises = Signal.new()
	local hearing = Hearing.new(noises, resolved.hearing)
	local agent = SenseFakes.Agent(Vector3.new(0, 0, 0))

	-- An agent hears only noises fired after its first tick, so register it before the case fires.
	hearing:Tick(agent, 0)

	return {
		hearing = hearing,
		noises = noises,
		agent = agent,
		blackboard = agent.Blackboard,
		clock = clock,
	}
end

--[[
	The private per-agent buffer, for the cases about registration and the cap.
]]
local function bufferOf(hearing: any, agent: any): { any }?
	return hearing._buffers[agent]
end

return {
	["a noise within range is heard, with its position, time and loudness"] = function(expect)
		local s = setup()

		s.noises:Fire(Vector3.new(10, 0, 0))
		s.hearing:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.HeardPosition, Vector3.new(10, 0, 0))
		expect.equal(s.blackboard.HeardAt, 100)
		expect.equal(s.blackboard.HeardLoudness, 1, "loudness defaults to 1")
	end,

	["a noise beyond range is not heard"] = function(expect)
		local s = setup({ hearing = { Range = 30 } })

		s.noises:Fire(Vector3.new(31, 0, 0))
		s.hearing:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.HeardPosition, nil)
		expect.equal(s.blackboard.HeardAt, nil)
		expect.equal(s.blackboard.HeardLoudness, nil)

		s.noises:Fire(Vector3.new(30, 0, 0))
		s.hearing:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.HeardPosition, Vector3.new(30, 0, 0), "exactly at range is heard")
	end,

	["loudness scales the range"] = function(expect)
		local s = setup({ hearing = { Range = 30 } })

		s.noises:Fire(Vector3.new(50, 0, 0), 1)
		s.hearing:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.HeardPosition, nil, "too quiet at 50 studs")

		s.noises:Fire(Vector3.new(50, 0, 0), 2)
		s.hearing:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.HeardPosition, Vector3.new(50, 0, 0), "loudness 2 carries 60 studs")
		expect.equal(s.blackboard.HeardLoudness, 2)

		s.noises:Fire(Vector3.new(10, 0, 0), 0.25)
		s.clock:Advance(10)
		s.hearing:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.HeardPosition, nil, "loudness 0.25 carries only 7.5 studs")
	end,

	["the loudest heard noise wins the tick"] = function(expect)
		local s = setup({ hearing = { Range = 30 } })

		s.noises:Fire(Vector3.new(2, 0, 0), 1)
		s.noises:Fire(Vector3.new(40, 0, 0), 2)
		s.noises:Fire(Vector3.new(5, 0, 0), 1.5)
		s.hearing:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.HeardPosition, Vector3.new(40, 0, 0))
		expect.equal(s.blackboard.HeardLoudness, 2)
	end,

	["a noise too far to hear does not win on loudness"] = function(expect)
		local s = setup({ hearing = { Range = 30 } })

		s.noises:Fire(Vector3.new(5, 0, 0), 1)
		s.noises:Fire(Vector3.new(200, 0, 0), 3)
		s.hearing:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.HeardPosition, Vector3.new(5, 0, 0))
	end,

	["equally loud noises: the nearest wins"] = function(expect)
		local s = setup()

		s.noises:Fire(Vector3.new(20, 0, 0))
		s.noises:Fire(Vector3.new(0, 3, 0))
		s.noises:Fire(Vector3.new(0, 0, 12))
		s.hearing:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.HeardPosition, Vector3.new(0, 3, 0))
	end,

	["the noise is measured from the agent's GetPosition"] = function(expect)
		local s = setup({ hearing = { Range = 10 } })
		s.agent.GetPosition = function()
			return Vector3.new(100, 0, 0)
		end

		s.noises:Fire(Vector3.new(105, 0, 0))
		s.hearing:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.HeardPosition, Vector3.new(105, 0, 0))
	end,

	["the heard keys last Memory seconds after the last heard noise, then clear together"] = function(expect)
		local s = setup({ hearing = { Memory = 5 } })

		s.noises:Fire(Vector3.new(10, 0, 0))
		s.hearing:Tick(s.agent, 0.1)

		s.clock:Advance(5)
		s.hearing:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.HeardPosition, Vector3.new(10, 0, 0), "still remembered at Memory")
		expect.equal(s.blackboard.HeardAt, 100)
		expect.equal(s.blackboard.HeardLoudness, 1)

		s.clock:Advance(0.01)
		s.hearing:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.HeardPosition, nil)
		expect.equal(s.blackboard.HeardAt, nil)
		expect.equal(s.blackboard.HeardLoudness, nil)
	end,

	["a new noise refreshes the memory"] = function(expect)
		local s = setup({ hearing = { Memory = 5 } })

		s.noises:Fire(Vector3.new(10, 0, 0))
		s.hearing:Tick(s.agent, 0.1)
		s.clock:Advance(4)
		s.noises:Fire(Vector3.new(-10, 0, 0))
		s.hearing:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.HeardPosition, Vector3.new(-10, 0, 0))
		expect.equal(s.blackboard.HeardAt, 104)

		s.clock:Advance(4)
		s.hearing:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.HeardPosition, Vector3.new(-10, 0, 0), "8 seconds after the first, 4 after the last")
	end,

	["the buffer is cleared every tick, so a noise is heard once"] = function(expect)
		local s = setup()

		s.noises:Fire(Vector3.new(10, 0, 0))
		s.hearing:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.HeardAt, 100)

		s.clock:Advance(1)
		s.hearing:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.HeardAt, 100, "not heard again on the next tick")
	end,

	["a noise too far to hear is dropped, not kept for later"] = function(expect)
		local s = setup({ hearing = { Range = 10 } })

		s.noises:Fire(Vector3.new(50, 0, 0))
		s.hearing:Tick(s.agent, 0.1)
		s.agent.GetPosition = function()
			return Vector3.new(50, 0, 0)
		end
		s.hearing:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.HeardPosition, nil)
	end,

	["Destroy disconnects from the signal"] = function(expect)
		local s = setup()

		s.hearing:Destroy()
		s.noises:Fire(Vector3.new(10, 0, 0))
		s.hearing:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.HeardPosition, nil)
		s.hearing:Destroy()
	end,

	["a noise without a Vector3 position is dropped with a warning"] = function(expect)
		local warnings = {}
		local s = setup({ warnings = warnings })

		s.noises:Fire("here" :: any)
		s.noises:Fire(Vector3.new(1, 0, 0), -1 :: any)
		s.hearing:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.HeardPosition, nil)
		expect.equal(#warnings, 2)
		expect.includes(warnings[1], "[VluxyAI]")
	end,

	["two agents on one instance both hear the same noise"] = function(expect)
		local s = setup()
		local other = SenseFakes.Agent(Vector3.new(5, 0, 0))
		s.hearing:Tick(other, 0)

		s.noises:Fire(Vector3.new(10, 0, 0))
		s.hearing:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.HeardPosition, Vector3.new(10, 0, 0), "the first agent hears it")

		s.hearing:Tick(other, 0.1)
		expect.equal(other.Blackboard.HeardPosition, Vector3.new(10, 0, 0), "the second still hears it")
		expect.equal(other.Blackboard.HeardAt, 100)
	end,

	["destroying one of two agents keeps the other hearing"] = function(expect)
		local s = setup()
		local other = SenseFakes.Agent(Vector3.new(5, 0, 0))
		s.hearing:Tick(other, 0)

		s.hearing:Destroy(s.agent)
		expect.equal(bufferOf(s.hearing, s.agent), nil, "the destroyed agent's buffer is gone")

		s.noises:Fire(Vector3.new(10, 0, 0))
		s.hearing:Tick(other, 0.1)
		expect.equal(other.Blackboard.HeardPosition, Vector3.new(10, 0, 0), "the survivor still hears")

		s.hearing:Destroy(other)
		s.noises:Fire(Vector3.new(-10, 0, 0))
		expect.equal(bufferOf(s.hearing, other), nil, "nothing left listening")
	end,

	["an agent destroyed before anyone ticked does not silence a later agent"] = function(expect)
		local s = setup()
		local early = SenseFakes.Agent(Vector3.new(0, 0, 0))
		local late = SenseFakes.Agent(Vector3.new(0, 0, 0))

		s.hearing:Destroy(s.agent)
		s.hearing:Destroy(early)
		s.hearing:Tick(late, 0)
		s.noises:Fire(Vector3.new(10, 0, 0))
		s.hearing:Tick(late, 0.1)
		expect.equal(late.Blackboard.HeardPosition, Vector3.new(10, 0, 0), "listening resumed for the late agent")
	end,

	["Destroy with no agent tears down for good"] = function(expect)
		local s = setup()
		s.hearing:Destroy()
		local late = SenseFakes.Agent(Vector3.new(0, 0, 0))
		s.hearing:Tick(late, 0)
		s.noises:Fire(Vector3.new(10, 0, 0))
		s.hearing:Tick(late, 0.1)
		expect.equal(late.Blackboard.HeardPosition, nil)
	end,

	["an agent that has never ticked does not accumulate noises"] = function(expect)
		local s = setup()
		local idle = SenseFakes.Agent(Vector3.new(0, 0, 0))

		s.noises:Fire(Vector3.new(10, 0, 0))
		s.noises:Fire(Vector3.new(-10, 0, 0))
		expect.equal(bufferOf(s.hearing, idle), nil, "no buffer before the first tick")
		expect.equal(#(bufferOf(s.hearing, s.agent) :: any), 2, "the registered agent buffers them")

		s.hearing:Tick(idle, 0.1)
		expect.equal(idle.Blackboard.HeardPosition, nil, "noises fired before its first tick are not heard")
		expect.equal(#(bufferOf(s.hearing, idle) :: any), 0, "registered now")

		s.noises:Fire(Vector3.new(10, 0, 0))
		s.hearing:Tick(idle, 0.1)
		expect.equal(idle.Blackboard.HeardPosition, Vector3.new(10, 0, 0), "and hears from then on")
	end,

	["a buffer holds at most 64 noises, dropping the oldest"] = function(expect)
		local s = setup()

		for index = 1, 6 do
			s.noises:Fire(Vector3.new(index, 0, 0))
		end
		for _ = 1, 64 do
			s.noises:Fire(Vector3.new(1000, 0, 0))
		end
		expect.equal(#(bufferOf(s.hearing, s.agent) :: any), 64, "capped")

		s.hearing:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.HeardPosition, nil, "the six audible noises were the oldest and were dropped")
	end,

	["a negative Range is refused"] = function(expect)
		local Hearing = Harness.Load("lib/Senses/Hearing.luau", { globals = SenseFakes.Globals() })
		local Signal = Fakes.Signal()
		local message = expect.errors(function()
			Hearing.new(Signal.new(), { Range = -1 })
		end)
		expect.includes(message, "Range")
	end,

	["an unknown option is refused, naming the module"] = function(expect)
		local Hearing = Harness.Load("lib/Senses/Hearing.luau", { globals = SenseFakes.Globals() })
		local Signal = Fakes.Signal()
		local message = expect.errors(function()
			Hearing.new(Signal.new(), { Rnage = 10 } :: any)
		end)
		expect.includes(message, "[VluxyAI] Hearing.new")
		expect.includes(message, "Rnage")
	end,
}
