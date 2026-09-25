--!strict

--[[
	The agent as a whole, with a fake pathfinder, mover and senses: tick order, the heartbeat
	accumulator, the shorthand methods and teardown. Trove is the real package, loaded through
	the harness the same way the agent loads it in a game.
]]

local Fakes = require("../Support/Fakes")
local Harness = require("../Support/Harness")

local roblox = require("@lune/roblox")
local Vector3 = roblox.Vector3

local function load(options: { warnings: { string }?, heartbeat: any? }?)
	local resolved = options or {}
	return Harness.Load("lib/Agent.luau", {
		services = {
			RunService = { Heartbeat = resolved.heartbeat or Harness.ManualHeartbeat() },
		},
		warn = function(message)
			if resolved.warnings then
				table.insert(resolved.warnings, tostring(message))
			end
		end,
	})
end

return {
	["a definition builds an agent with its fields filled"] = function(expect)
		local Agent = load()
		local brain = Fakes.Brain("Idle", { "Idle" }, {})
		local agent = Agent.new({
			Entity = Fakes.Entity("Cylinder"),
			Brain = brain,
			Blackboard = { Seen = false },
			Data = { Hits = 0 },
		})

		expect.equal(agent.Name, "Cylinder")
		expect.equal(agent.Brain, brain)
		expect.equal(agent.Blackboard.Seen, false)
		expect.equal(agent.Data.Hits, 0)
		expect.equal(agent.Navigator, nil)
		expect.equal(agent:GetState(), nil)
		expect.falsy(agent:IsRunning())
	end,

	["Name on the definition wins over the entity name"] = function(expect)
		local Agent = load()
		local agent = Agent.new({
			Entity = Fakes.Entity("Cylinder"),
			Brain = Fakes.Brain("Idle", { "Idle" }, {}),
			Name = "Stalker",
		})
		expect.equal(agent.Name, "Stalker")
	end,

	["Blackboard and Data are copied per agent"] = function(expect)
		local Agent = load()
		local definition = {
			Entity = Fakes.Entity(),
			Brain = Fakes.Brain("Idle", { "Idle" }, {}),
			Blackboard = { Memory = { Positions = {} } },
		}
		local first = Agent.new(definition)
		local second = Agent.new(definition)

		table.insert(first.Blackboard.Memory.Positions, "x")
		expect.equal(#second.Blackboard.Memory.Positions, 0)
		expect.equal(#definition.Blackboard.Memory.Positions, 0)
	end,

	["an invalid definition errors with the field path"] = function(expect)
		local Agent = load()
		local message = expect.errors(function()
			Agent.new({ Entity = Fakes.Entity(), Brain = { Initial = "X", States = {} } })
		end)
		expect.includes(message, "Definition.Brain.States has no states")
	end,

	["Start enters the initial state and Step ticks senses, navigator, then brain"] = function(expect)
		local Agent = load()
		local log = {}
		local brain = Fakes.Brain("Idle", { "Idle" }, log)
		local agent = Agent.new({
			Entity = Fakes.Entity(),
			Brain = brain,
			Senses = { Fakes.Sense("sight", log), Fakes.Sense("hearing", log) },
		})

		agent:Start(true)
		expect.truthy(agent:IsRunning())
		expect.equal(agent:GetState(), "Idle")
		agent:Step(0.1)
		expect.sequence(log, { "enter Idle", "sight", "hearing", "update Idle" })
	end,

	["Step before Start does nothing"] = function(expect)
		local Agent = load()
		local log = {}
		local agent = Agent.new({ Entity = Fakes.Entity(), Brain = Fakes.Brain("Idle", { "Idle" }, log) })
		agent:Step(0.1)
		expect.equal(#log, 0)
	end,

	["StateChanged fires with the new and old names"] = function(expect)
		local Agent = load()
		local changes = {}
		local brain = Fakes.Brain("Idle", { "Idle", "Chase" }, {}, {
			Idle = function()
				return "Chase"
			end,
		})
		local agent = Agent.new({ Entity = Fakes.Entity(), Brain = brain })
		agent.StateChanged:Connect(function(new, old)
			table.insert(changes, `{tostring(old)}->{new}`)
		end)

		agent:Start(true)
		agent:Step(0.1)
		expect.sequence(changes, { "nil->Idle", "Idle->Chase" })
	end,

	["SetState forces a transition and warns before Start"] = function(expect)
		local warnings = {}
		local Agent = load({ warnings = warnings })
		local log = {}
		local agent = Agent.new({ Entity = Fakes.Entity(), Brain = Fakes.Brain("Idle", { "Idle", "Chase" }, log) })

		agent:SetState("Chase")
		expect.equal(#warnings, 1)
		expect.includes(warnings[1], "before Start")

		agent:Start(true)
		agent:SetState("Chase")
		expect.equal(agent:GetState(), "Chase")
		expect.sequence(log, { "enter Idle", "exit Idle", "enter Chase" })
	end,

	["the Heartbeat loop ticks once per Tick of accumulated time"] = function(expect)
		local heartbeat = Harness.ManualHeartbeat()
		local Agent = load({ heartbeat = heartbeat })
		local deltas = {}
		local brain = {
			Initial = "Idle",
			States = {
				Idle = {
					Update = function(_agent, deltaTime)
						table.insert(deltas, deltaTime)
						return nil
					end,
				},
			},
		}
		local agent = Agent.new({ Entity = Fakes.Entity(), Brain = brain, Tick = 0.2 })

		agent:Start()
		expect.equal(heartbeat:Count(), 1)
		heartbeat:Fire(0.1)
		expect.equal(#deltas, 0, "not enough time yet")
		heartbeat:Fire(0.1)
		expect.equal(#deltas, 1)
		expect.near(deltas[1], 0.2)
		heartbeat:Fire(0.9)
		expect.equal(#deltas, 2, "a long frame is one tick, not several")
		expect.near(deltas[2], 0.9)

		agent:Destroy()
		expect.equal(heartbeat:Count(), 0, "Destroy disconnects the heartbeat")
	end,

	["Start twice does nothing and Start after Destroy errors"] = function(expect)
		local Agent = load()
		local log = {}
		local agent = Agent.new({ Entity = Fakes.Entity(), Brain = Fakes.Brain("Idle", { "Idle" }, log) })

		agent:Start(true):Start(true)
		expect.sequence(log, { "enter Idle" })

		agent:Destroy()
		local message = expect.errors(function()
			agent:Start(true)
		end)
		expect.includes(message, "destroyed agent")
	end,

	["a pathfinder and mover give the agent a navigator and MoveTo works"] = function(expect)
		local Agent = load()
		local pathfinder = Fakes.Pathfinder()
		local mover = Fakes.Mover(Vector3.new(0, 0, 0))
		local agent = Agent.new({
			Entity = Fakes.Entity(),
			Brain = Fakes.Brain("Idle", { "Idle" }, {}),
			Pathfinder = pathfinder,
			Mover = mover,
		})

		expect.truthy(agent.Navigator)
		expect.equal(agent.Mover, mover)
		expect.equal(agent.Pathfinder, pathfinder)

		agent:Start(true)
		agent:MoveTo(Vector3.new(10, 0, 0))
		expect.equal(#pathfinder.Calls, 1)
		expect.equal(#mover.Followed, 1)
		expect.falsy(agent:HasArrived())

		mover.Position = Vector3.new(10, 0, 0)
		mover:Finish(true)
		expect.truthy(agent:HasArrived())

		agent:Stop()
		expect.equal(agent.Navigator:GetStatus(), "Idle")
	end,

	["GetPosition prefers the mover and falls back to the entity pivot"] = function(expect)
		local Agent = load()
		local withMover = Agent.new({
			Entity = Fakes.Entity(),
			Brain = Fakes.Brain("Idle", { "Idle" }, {}),
			Pathfinder = Fakes.Pathfinder(),
			Mover = Fakes.Mover(Vector3.new(4, 5, 6)),
		})
		expect.equal(withMover:GetPosition(), Vector3.new(4, 5, 6))

		local without = Agent.new({
			Entity = Fakes.Entity("Rig", Vector3.new(1, 2, 3)),
			Brain = Fakes.Brain("Idle", { "Idle" }, {}),
		})
		expect.equal(without:GetPosition(), Vector3.new(1, 2, 3))
	end,

	["MoveTo before Start warns and does nothing, and IsDestroyed reports Destroy"] = function(expect)
		local warnings = {}
		local Agent = load({ warnings = warnings })
		local pathfinder = Fakes.Pathfinder()
		local agent = Agent.new({
			Entity = Fakes.Entity(),
			Brain = Fakes.Brain("Idle", { "Idle" }, {}),
			Pathfinder = pathfinder,
			Mover = Fakes.Mover(Vector3.new(0, 0, 0)),
		})

		agent:MoveTo(Vector3.new(10, 0, 0))
		expect.equal(#pathfinder.Calls, 0)
		expect.equal(#warnings, 1)
		expect.includes(warnings[1], "MoveTo before Start")
		expect.falsy(agent:IsDestroyed())

		agent:Start(true)
		agent:Destroy()
		expect.truthy(agent:IsDestroyed())
		agent:MoveTo(Vector3.new(10, 0, 0))
		expect.includes(warnings[2], "destroyed agent")
	end,

	["MoveTo without a navigator errors and Stop is a no-op"] = function(expect)
		local Agent = load()
		local agent = Agent.new({ Entity = Fakes.Entity(), Brain = Fakes.Brain("Idle", { "Idle" }, {}) })

		local message = expect.errors(function()
			agent:MoveTo(Vector3.new())
		end)
		expect.includes(message, "MoveTo needs a Pathfinder and a Mover")
		agent:Stop()
		expect.falsy(agent:HasArrived())
	end,

	["Step drives the navigator so a stuck mover recovers without another MoveTo"] = function(expect)
		local clock = Harness.ManualClock(0)
		local Agent = Harness.Load("lib/Agent.luau", {
			globals = { os = clock.os },
			services = { RunService = { Heartbeat = Harness.ManualHeartbeat() } },
		})
		local pathfinder = Fakes.Pathfinder()
		local mover = Fakes.Mover(Vector3.new(0, 0, 0))
		local agent = Agent.new({
			Entity = Fakes.Entity(),
			Brain = Fakes.Brain("Idle", { "Idle" }, {}),
			Pathfinder = pathfinder,
			Mover = mover,
			Navigation = { RepathInterval = 0.5 },
		})

		agent:Start(true)
		agent:MoveTo(Vector3.new(10, 0, 0))
		mover:Finish(false)
		clock:Advance(1)
		agent:Step(0.1)
		expect.equal(#pathfinder.Calls, 2)
	end,

	["Destroy exits the state, stops moving and destroys everything it owns, once"] = function(expect)
		local Agent = load()
		local log = {}
		local pathfinder = Fakes.Pathfinder()
		local mover = Fakes.Mover(Vector3.new(0, 0, 0))
		local sense = Fakes.Sense("sight", log)
		local agent = Agent.new({
			Entity = Fakes.Entity(),
			Brain = Fakes.Brain("Idle", { "Idle" }, log),
			Pathfinder = pathfinder,
			Mover = mover,
			Senses = { sense },
		})
		local changes = 0
		agent.StateChanged:Connect(function()
			changes += 1
		end)
		local destroyedFires = 0
		agent.Destroyed:Connect(function()
			destroyedFires += 1
		end)

		agent:Start(true)
		agent:MoveTo(Vector3.new(10, 0, 0))
		agent:Destroy()

		expect.sequence(log, { "enter Idle", "exit Idle" })
		expect.equal(agent:GetState(), nil)
		expect.falsy(agent:IsRunning())
		expect.equal(mover.Stops, 1)
		expect.truthy(mover.Destroyed)
		expect.truthy(pathfinder.Destroyed)
		expect.truthy(sense.Destroyed)

		agent:Destroy()
		expect.equal(mover.Stops, 1, "second Destroy does nothing")
		expect.equal(destroyedFires, 1, "Destroyed fired once")
		agent:Step(0.1)
		expect.equal(#log, 2, "no ticks after Destroy")
	end,

	["Destroy from inside a sense stops the rest of the tick"] = function(expect)
		local Agent = load()
		local log = {}
		local agent
		local killer = {
			Tick = function()
				table.insert(log, "killer")
				agent:Destroy()
			end,
		}
		agent = Agent.new({
			Entity = Fakes.Entity(),
			Brain = Fakes.Brain("Idle", { "Idle" }, log),
			Senses = { killer, Fakes.Sense("after", log) },
		})

		agent:Start(true)
		agent:Step(0.1)
		expect.sequence(log, { "enter Idle", "killer", "exit Idle" })
	end,

	["SetState after Destroy says so"] = function(expect)
		local warnings = {}
		local Agent = load({ warnings = warnings })
		local agent = Agent.new({ Entity = Fakes.Entity(), Brain = Fakes.Brain("Idle", { "Idle" }, {}) })

		agent:Start(true)
		agent:Destroy()
		agent:SetState("Idle")
		expect.equal(#warnings, 1)
		expect.includes(warnings[1], "destroyed agent")
	end,

	["timers run out on the clock"] = function(expect)
		local clock = Harness.ManualClock(100)
		local Agent = Harness.Load("lib/Agent.luau", {
			globals = { os = clock.os },
			services = { RunService = { Heartbeat = Harness.ManualHeartbeat() } },
		})
		local agent = Agent.new({ Entity = Fakes.Entity(), Brain = Fakes.Brain("Idle", { "Idle" }, {}) })

		expect.truthy(agent:TimerDone("Attack"), "a timer never started is done")
		expect.equal(agent:TimerLeft("Attack"), 0)

		agent:StartTimer("Attack", 2)
		expect.falsy(agent:TimerDone("Attack"))
		expect.near(agent:TimerLeft("Attack"), 2)
		clock:Advance(1.5)
		expect.falsy(agent:TimerDone("Attack"))
		expect.near(agent:TimerLeft("Attack"), 0.5)
		clock:Advance(0.5)
		expect.truthy(agent:TimerDone("Attack"))
		expect.equal(agent:TimerLeft("Attack"), 0)

		agent:StartTimer("Attack", 1)
		expect.falsy(agent:TimerDone("Attack"), "restarted")
	end,

	["Destroy from the initial Enter leaves no heartbeat behind"] = function(expect)
		local heartbeat = Harness.ManualHeartbeat()
		local Agent = load({ heartbeat = heartbeat })
		local agent
		local brain = {
			Initial = "Idle",
			States = {
				Idle = {
					Enter = function()
						agent:Destroy()
					end,
				},
			},
		}
		agent = Agent.new({ Entity = Fakes.Entity(), Brain = brain })

		agent:Start()
		expect.falsy(agent:IsRunning())
		expect.equal(heartbeat:Count(), 0)
	end,

	["a sense's Destroy receives the agent"] = function(expect)
		local Agent = load()
		local received = nil
		local sense = {
			Tick = function() end,
			Destroy = function(_self, agent)
				received = agent
			end,
		}
		local agent =
			Agent.new({ Entity = Fakes.Entity(), Brain = Fakes.Brain("Idle", { "Idle" }, {}), Senses = { sense } })

		agent:Destroy()
		expect.equal(received, agent)
	end,

	["a part that errors on Destroy does not stop the rest, and Destroyed still fires"] = function(expect)
		local warnings = {}
		local Agent = load({ warnings = warnings })
		local mover = Fakes.Mover(Vector3.new(0, 0, 0))
		local broken = {
			Tick = function() end,
			Destroy = function()
				error("sense broke")
			end,
		}
		local agent = Agent.new({
			Entity = Fakes.Entity(),
			Brain = Fakes.Brain("Idle", { "Idle" }, {}),
			Pathfinder = Fakes.Pathfinder(),
			Mover = mover,
			Senses = { broken },
		})
		local destroyed = false
		agent.Destroyed:Connect(function()
			destroyed = true
		end)

		agent:Start(true)
		agent:Destroy()
		expect.truthy(mover.Destroyed, "the mover after the broken sense was still destroyed")
		expect.truthy(destroyed)
		expect.equal(#warnings, 1)
		expect.includes(warnings[1], "sense broke")
	end,

	["Emit still works from a Destroyed handler and stops afterwards"] = function(expect)
		local Agent = load()
		local agent = Agent.new({ Entity = Fakes.Entity(), Brain = Fakes.Brain("Idle", { "Idle" }, {}) })
		local seen = {}
		agent.Events:Connect(function(name)
			table.insert(seen, name)
		end)
		agent.Destroyed:Connect(function()
			agent:Emit("LastWords")
		end)

		agent:Start(true)
		agent:Destroy()
		agent:Emit("TooLate")
		expect.sequence(seen, { "LastWords" })
	end,

	["a sense without Destroy is fine"] = function(expect)
		local Agent = load()
		local sense = { Tick = function() end }
		local agent =
			Agent.new({ Entity = Fakes.Entity(), Brain = Fakes.Brain("Idle", { "Idle" }, {}), Senses = { sense } })
		agent:Start(true)
		agent:Step(0.1)
		agent:Destroy()
		expect.truthy(true)
	end,
}
