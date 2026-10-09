--!strict

--[[
	A headless agent end to end: the real package, a Graph pathfinder, a Record mover and no
	Entity, stepped by hand the way a server scheduler would. What has to hold is that nothing
	reaches for a Model: the brain runs, the agent walks the graph, and GetPivot, Teleport and
	the Broadcaster all answer from the mover.
]]

local Harness = require("../Support/Harness")

local roblox = require("@lune/roblox")
local Vector3 = roblox.Vector3

local function load()
	return Harness.Load("lib/init.luau", {
		services = { RunService = { Heartbeat = Harness.ManualHeartbeat() } },
	})
end

local function corridor()
	return {
		{ Position = Vector3.new(0, 0, 0), Links = { 2 } },
		{ Position = Vector3.new(20, 0, 0), Links = { 1, 3 } },
		{ Position = Vector3.new(20, 0, 20), Links = { 2 } },
	}
end

--[[
	Walk to the far end of the corridor, then stop in Done.
]]
local function walker(target: any)
	return {
		Initial = "Walk",
		States = {
			Walk = {
				Enter = function(agent: any)
					agent:MoveTo(target)
				end,
				Transitions = {
					{
						To = "Done",
						When = function(agent: any)
							return agent:HasArrived()
						end,
					},
				},
			},
			Done = {},
		},
	}
end

local function stepFor(agent: any, seconds: number)
	for _ = 1, math.ceil(seconds / 0.1) do
		agent:Step(0.1)
	end
end

return {
	["Presets.Headless builds an agent with no Entity that walks a Graph"] = function(expect)
		local VluxyAI = load()
		local target = Vector3.new(20, 0, 20)
		local agent = VluxyAI.Presets
			.Headless({
				Name = "Goblin 12",
				Position = Vector3.new(0, 0, 0),
				Pathfinder = VluxyAI.Pathfinders.Graph.new(corridor()),
				Mover = { Speed = 10 },
			})
			:UseBrain(walker(target))
			:Build()
			:Start(true)

		expect.equal(agent.Entity, nil)
		expect.equal(agent.Name, "Goblin 12")
		expect.equal(agent:GetState(), "Walk")

		stepFor(agent, 6)

		expect.equal(agent:GetState(), "Done")
		local position = agent:GetPosition()
		expect.near(position.X, 20, 2.5, "X: within ArriveDistance")
		expect.near(position.Z, 20, 2.5, "Z: within ArriveDistance")
		-- The last leg runs +Z, so that is where it faces.
		expect.near(agent:GetPivot().LookVector.Z, 1, 1e-3, "facing +Z")
		agent:Destroy()
	end,

	["VluxyAI.new() with a Record mover is the same thing by hand"] = function(expect)
		local VluxyAI = load()
		local agent = VluxyAI.new()
			:SetName("Bare")
			:UseBrain(walker(Vector3.new(20, 0, 0)))
			:UsePathfinder(VluxyAI.Pathfinders.Graph.new(corridor()))
			:UseMover(VluxyAI.Movers.Record.new({ Position = Vector3.new(0, 0, 0), Speed = 20 }))
			:Build()
			:Start(true)

		stepFor(agent, 3)
		expect.equal(agent:GetState(), "Done")
		expect.near(agent:GetPosition().X, 20, 2.5, "X: within ArriveDistance")
		agent:Destroy()
	end,

	["a paused headless agent does not move"] = function(expect)
		local VluxyAI = load()
		local agent = VluxyAI.Presets
			.Headless({
				Position = Vector3.new(0, 0, 0),
				Pathfinder = VluxyAI.Pathfinders.Graph.new(corridor()),
				Mover = { Speed = 10 },
			})
			:UseBrain(walker(Vector3.new(20, 0, 20)))
			:Build()
			:Start(true)

		agent:Step(0.1)
		agent:Pause()
		local before = agent:GetPosition()
		stepFor(agent, 2)
		expect.equal(agent:GetPosition(), before)
		agent:Destroy()
	end,

	["Teleport and the Broadcaster read the mover"] = function(expect)
		local VluxyAI = load()
		local agent = VluxyAI.Presets
			.Headless({
				Position = Vector3.new(0, 0, 0),
				Yaw = math.pi,
				Pathfinder = VluxyAI.Pathfinders.Graph.new(corridor()),
			})
			:UseBrain({ Initial = "Idle", States = { Idle = {} } })
			:Build()
			:Start(true)

		agent:Teleport(Vector3.new(5, 0, 5))
		expect.equal(agent:GetPosition(), Vector3.new(5, 0, 5))

		local broadcaster = VluxyAI.Sync.Broadcaster.new(agent)
		local snapshot = broadcaster:Snapshot()
		expect.equal(snapshot.Position, Vector3.new(5, 0, 5))
		expect.near(math.abs(snapshot.Yaw), math.pi, 1e-3, "yaw kept through Teleport")
		broadcaster:Destroy()
		agent:Destroy()
	end,

	["rig-only features say the agent is headless"] = function(expect)
		local VluxyAI = load()
		local agent = VluxyAI.Presets
			.Headless({
				Position = Vector3.new(0, 0, 0),
				Pathfinder = VluxyAI.Pathfinders.Graph.new(corridor()),
			})
			:UseBrain({ Initial = "Idle", States = { Idle = {} } })
			:Build()

		local message = expect.errors(function()
			VluxyAI.Locomotion.Attach(agent)
		end)
		expect.includes(message, "headless")
		agent:Destroy()
	end,

	["a headless definition without GetPivot on the mover is refused"] = function(expect)
		local VluxyAI = load()
		local message = expect.errors(function()
			VluxyAI.new():UseBrain({ Initial = "Idle", States = { Idle = {} } }):Build()
		end)
		expect.includes(message, "Definition.Entity is missing")
	end,
}
