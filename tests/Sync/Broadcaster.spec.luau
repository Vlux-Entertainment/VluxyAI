--!strict

--[[
	The server broadcaster: relays state changes and events, samples position at a rate and only
	when the rig moved, snapshots for late joiners, and goes with the agent.
]]

local Fakes = require("../Support/Fakes")
local Harness = require("../Support/Harness")

local roblox = require("@lune/roblox")
local CFrame = roblox.CFrame
local Vector3 = roblox.Vector3

local function setup(options: any?)
	local heartbeat = Harness.ManualHeartbeat()
	local Broadcaster = Harness.Load("lib/Sync/Broadcaster.luau", {
		services = { RunService = { Heartbeat = heartbeat } },
	})
	local Signal = Fakes.Signal()

	local pivot = CFrame.new(0, 0, 0)
	local agent = {
		Name = "Fake",
		Entity = {
			GetPivot = function()
				return pivot
			end,
		},
		StateChanged = Signal.new(),
		Events = Signal.new(),
		Destroyed = Signal.new(),
		GetState = function()
			return "Idle"
		end,
	}
	local function move(cframe)
		pivot = cframe
	end

	local broadcaster = Broadcaster.new(agent, options)
	local samples = {}
	broadcaster.PositionChanged:Connect(function(position, yaw)
		table.insert(samples, { Position = position, Yaw = yaw })
	end)

	return { broadcaster = broadcaster, agent = agent, heartbeat = heartbeat, samples = samples, move = move }
end

return {
	["state changes and events are relayed"] = function(expect)
		local s = setup()
		local got = {}
		s.broadcaster.StateChanged:Connect(function(new, old)
			table.insert(got, `{tostring(old)}->{new}`)
		end)
		s.broadcaster.EventSent:Connect(function(name, payload)
			table.insert(got, `{name}:{payload}`)
		end)

		s.agent.StateChanged:Fire("Hunt", "Idle")
		s.agent.Events:Fire("Scream", 3)
		expect.sequence(got, { "Idle->Hunt", "Scream:3" })
	end,

	["positions are sampled at the rate and only when the rig moved"] = function(expect)
		local s = setup({ PositionRate = 10 })

		s.heartbeat:Fire(0.05)
		expect.equal(#s.samples, 0, "too soon")
		s.heartbeat:Fire(0.05)
		expect.equal(#s.samples, 1, "first sample")

		s.heartbeat:Fire(0.1)
		expect.equal(#s.samples, 1, "unmoved rig sends nothing")

		s.move(CFrame.new(5, 0, 0))
		s.heartbeat:Fire(0.1)
		expect.equal(#s.samples, 2)
		expect.near(s.samples[2].Position.X, 5)

		s.move(CFrame.new(5, 0, 0) * CFrame.Angles(0, math.pi / 2, 0))
		s.heartbeat:Fire(0.1)
		expect.equal(#s.samples, 3, "a turn is worth a sample")
		expect.near(s.samples[3].Yaw, math.pi / 2, 1e-3)
	end,

	["frames near the interval do not halve the rate"] = function(expect)
		local s = setup({ PositionRate = 10, MoveEpsilon = 0 })
		for index = 1, 60 do
			s.move(CFrame.new(index, 0, 0))
			s.heartbeat:Fire(0.09)
		end
		expect.truthy(#s.samples >= 50, `about 54 samples in 5.4 seconds, got {#s.samples}`)
	end,

	["a rate of zero sends nothing and connects no heartbeat"] = function(expect)
		local s = setup({ PositionRate = 0 })
		expect.equal(s.heartbeat:Count(), 0)
		s.broadcaster:Step(1)
		expect.equal(#s.samples, 0)
	end,

	["Snapshot carries state, position and yaw"] = function(expect)
		local s = setup()
		s.move(CFrame.new(1, 2, 3) * CFrame.Angles(0, math.pi, 0))
		local snapshot = s.broadcaster:Snapshot()
		expect.equal(snapshot.State, "Idle")
		expect.near(snapshot.Position.X, 1)
		expect.near(math.abs(snapshot.Yaw), math.pi, 1e-3)
	end,

	["the broadcaster goes with the agent"] = function(expect)
		local s = setup()
		local relayed = 0
		s.broadcaster.StateChanged:Connect(function()
			relayed += 1
		end)

		s.agent.Destroyed:Fire()
		s.agent.StateChanged:Fire("Hunt", "Idle")
		expect.equal(relayed, 0)
		expect.equal(s.heartbeat:Count(), 0)
	end,

	["a negative rate or unknown option is refused"] = function(expect)
		local s = setup()
		local Broadcaster = Harness.Load("lib/Sync/Broadcaster.luau", {
			services = { RunService = { Heartbeat = Harness.ManualHeartbeat() } },
		})
		local message = expect.errors(function()
			Broadcaster.new(s.agent, { PositionRate = -1 })
		end)
		expect.includes(message, "PositionRate must be 0 or more")

		message = expect.errors(function()
			Broadcaster.new(s.agent, { Rate = 5 })
		end)
		expect.includes(message, 'unknown option "Rate"')
	end,
}
