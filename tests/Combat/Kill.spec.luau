--!strict

--[[
	The two kills against a fake victim: what is announced, how the victim is held and released,
	when they die, and what Cancel does. The animations are skipped (no ids), so no Animator is
	needed.
]]

local Fakes = require("../Support/Fakes")
local Harness = require("../Support/Harness")

local roblox = require("@lune/roblox")
local task = require("@lune/task")
local CFrame = roblox.CFrame
local Vector3 = roblox.Vector3

local function fakeVictim(withHumanoid: boolean?)
	local humanoid = { Health = 100, PlatformStand = false }
	local root = {
		CFrame = CFrame.new(50, 0, 0),
		AssemblyLinearVelocity = Vector3.new(1, 1, 1),
		Owners = {} :: { any },
		AutoOwnership = 0,
	}
	function root.SetNetworkOwner(self, owner)
		table.insert(self.Owners, if owner == nil then "server" else owner)
	end
	function root.SetNetworkOwnershipAuto(self)
		self.AutoOwnership += 1
	end

	root.Anchored = false
	local victim = { PrimaryPart = root, Humanoid = humanoid }
	function victim.FindFirstChildOfClass(_self, className)
		if className == "Humanoid" and withHumanoid ~= false then
			return humanoid
		end
		return nil
	end
	function victim.GetFullName()
		return "Workspace.Victim"
	end
	return victim, root, humanoid
end

local function setup()
	local heartbeat = Harness.ManualHeartbeat()
	local Kill = Harness.Load("lib/Combat/Kill.luau", {
		services = { RunService = {
			Heartbeat = heartbeat,
			IsServer = function()
				return true
			end,
		} },
	})
	local Signal = Fakes.Signal()
	local events = {}
	local agent = {
		Name = "Killer",
		Running = true,
		Entity = {
			GetPivot = function()
				return CFrame.new(10, 0, 0)
			end,
			FindFirstChildOfClass = function()
				return nil
			end,
		},
		Events = Signal.new(),
		Destroyed = Signal.new(),
		Emit = function(_self, name, payload)
			table.insert(events, { Name = name, Payload = payload })
		end,
	}
	function agent.IsRunning(self)
		return self.Running
	end
	return { Kill = Kill, agent = agent, heartbeat = heartbeat, events = events }
end

return {
	["Live announces, takes the victim, holds them at the offset and kills after Duration"] = function(expect)
		local s = setup()
		local victim, root, humanoid = fakeVictim()
		local outcomes = {}

		local handle = s.Kill.Live(s.agent, victim, { Duration = 1, Offset = CFrame.new(0, 0, -3) })
		handle.Finished:Connect(function(killed)
			table.insert(outcomes, killed)
		end)

		expect.equal(#s.events, 1)
		expect.equal(s.events[1].Name, "Kill")
		expect.equal(s.events[1].Payload.Kind, "Live")
		expect.equal(s.events[1].Payload.Victim, victim)
		expect.equal(s.events[1].Payload.Duration, 1)
		expect.truthy(root.Anchored, "the root is anchored for the hold")
		expect.truthy(humanoid.PlatformStand)

		s.heartbeat:Fire(0.5)
		expect.near(root.CFrame.Position.X, 10, 1e-4, "held in front of the killer")
		expect.near(root.CFrame.Position.Z, -3, 1e-4)
		expect.equal(humanoid.Health, 100, "alive during the hold")

		s.heartbeat:Fire(0.5)
		expect.equal(humanoid.Health, 0)
		expect.sequence(outcomes, { true })
		expect.equal(s.heartbeat:Count(), 0, "released")
		expect.truthy(humanoid.PlatformStand, "a dead victim is left as is")
	end,

	["Cancel releases the victim alive"] = function(expect)
		local s = setup()
		local victim, root, humanoid = fakeVictim()
		local outcomes = {}

		local handle = s.Kill.Live(s.agent, victim, { Duration = 2 })
		handle.Finished:Connect(function(killed)
			table.insert(outcomes, killed)
		end)
		s.heartbeat:Fire(0.5)
		handle:Cancel()

		expect.sequence(outcomes, { false })
		expect.equal(humanoid.Health, 100)
		expect.falsy(humanoid.PlatformStand, "restored")
		expect.falsy(root.Anchored, "unanchored again")
		expect.equal(s.heartbeat:Count(), 0)

		handle:Cancel()
		expect.sequence(outcomes, { false }, "a second Cancel does nothing")
	end,

	["Live on a victim with no humanoid finishes false and announces nothing"] = function(expect)
		local warnings = {}
		local heartbeat = Harness.ManualHeartbeat()
		local Kill = Harness.Load("lib/Combat/Kill.luau", {
			services = {
				RunService = {
					Heartbeat = heartbeat,
					IsServer = function()
						return true
					end,
				},
			},
			warn = function(message)
				table.insert(warnings, tostring(message))
			end,
		})
		local s = setup()
		local victim = fakeVictim(false)
		local outcomes = {}

		local handle = Kill.Live(s.agent, victim)
		handle.Finished:Connect(function(killed)
			table.insert(outcomes, killed)
		end)
		task.wait()
		expect.sequence(outcomes, { false })
		expect.equal(#s.events, 0)
		expect.equal(#warnings, 1)
	end,

	["a victim already held by a live kill is refused"] = function(expect)
		local warnings = {}
		local heartbeat = Harness.ManualHeartbeat()
		local Kill = Harness.Load("lib/Combat/Kill.luau", {
			services = {
				RunService = {
					Heartbeat = heartbeat,
					IsServer = function()
						return true
					end,
				},
			},
			warn = function(message)
				table.insert(warnings, tostring(message))
			end,
		})
		local s = setup()
		local victim, _root, humanoid = fakeVictim()
		local outcomes = {}

		local first = Kill.Live(s.agent, victim, { Duration = 1 })
		local second = Kill.Live(s.agent, victim, { Duration = 1 })
		second.Finished:Connect(function(killed)
			table.insert(outcomes, killed)
		end)
		task.wait()
		expect.sequence(outcomes, { false })
		expect.includes(warnings[1], "already being held")

		first:Cancel()
		expect.falsy(humanoid.PlatformStand, "the refused hold did not disturb the first one")
		local third = Kill.Live(s.agent, victim, { Duration = 1 })
		expect.truthy(humanoid.PlatformStand, "free again after the first was released")
		third:Cancel()
	end,

	["the killer being destroyed mid-hold releases the victim alive"] = function(expect)
		local s = setup()
		local victim, _root, humanoid = fakeVictim()
		local outcomes = {}

		local handle = s.Kill.Live(s.agent, victim, { Duration = 2 })
		handle.Finished:Connect(function(killed)
			table.insert(outcomes, killed)
		end)
		s.heartbeat:Fire(0.5)
		s.agent.Destroyed:Fire()
		expect.sequence(outcomes, { false })
		expect.equal(humanoid.Health, 100)
		expect.falsy(humanoid.PlatformStand)
		expect.equal(s.heartbeat:Count(), 0)
	end,

	["a kill from an agent that is not running is refused"] = function(expect)
		local s = setup()
		s.agent.Running = false
		local victim = fakeVictim()
		local outcomes = {}
		local handle = s.Kill.Live(s.agent, victim)
		handle.Finished:Connect(function(killed)
			table.insert(outcomes, killed)
		end)
		local box = s.Kill.BlackBox(s.agent, victim)
		box.Finished:Connect(function(killed)
			table.insert(outcomes, killed)
		end)
		task.wait()
		expect.sequence(outcomes, { false, false })
		expect.equal(#s.events, 0, "nothing announced")
	end,

	["a victim who dies of something else mid-hold is not this kill"] = function(expect)
		local s = setup()
		local victim, _root, humanoid = fakeVictim()
		local outcomes = {}

		local handle = s.Kill.Live(s.agent, victim, { Duration = 2 })
		handle.Finished:Connect(function(killed)
			table.insert(outcomes, killed)
		end)
		s.heartbeat:Fire(0.5)
		humanoid.Health = 0
		s.heartbeat:Fire(0.5)
		expect.sequence(outcomes, { false })
		expect.equal(s.heartbeat:Count(), 0)
	end,

	["kills refuse to run on a client"] = function(expect)
		local Kill = Harness.Load("lib/Combat/Kill.luau", {
			services = {
				RunService = {
					Heartbeat = Harness.ManualHeartbeat(),
					IsServer = function()
						return false
					end,
				},
			},
		})
		local s = setup()
		local victim = fakeVictim()
		local message = expect.errors(function()
			Kill.Live(s.agent, victim)
		end)
		expect.includes(message, "Kill.Live runs on the server only")
		message = expect.errors(function()
			Kill.BlackBox(s.agent, victim)
		end)
		expect.includes(message, "Kill.BlackBox runs on the server only")
	end,

	["BlackBox announces at once and kills after the delay"] = function(expect)
		local s = setup()
		local victim, _root, humanoid = fakeVictim()
		local outcomes = {}

		local handle = s.Kill.BlackBox(s.agent, victim, { Delay = 0.05 })
		handle.Finished:Connect(function(killed)
			table.insert(outcomes, killed)
		end)
		expect.equal(s.events[1].Payload.Kind, "BlackBox")
		expect.equal(s.events[1].Payload.Duration, 0.05)
		expect.equal(humanoid.Health, 100)

		task.wait(0.1)
		expect.equal(humanoid.Health, 0)
		expect.sequence(outcomes, { true })
	end,

	["BlackBox on a victim who died meanwhile reports false"] = function(expect)
		local s = setup()
		local victim, _root, humanoid = fakeVictim()
		local outcomes = {}
		local handle = s.Kill.BlackBox(s.agent, victim, { Delay = 0.05 })
		handle.Finished:Connect(function(killed)
			table.insert(outcomes, killed)
		end)
		humanoid.Health = 0
		task.wait(0.1)
		expect.sequence(outcomes, { false })
	end,

	["BlackBox cancelled within the delay spares the victim"] = function(expect)
		local s = setup()
		local victim, _root, humanoid = fakeVictim()
		local outcomes = {}

		local handle = s.Kill.BlackBox(s.agent, victim, { Delay = 0.05 })
		handle.Finished:Connect(function(killed)
			table.insert(outcomes, killed)
		end)
		handle:Cancel()
		task.wait(0.1)
		expect.equal(humanoid.Health, 100)
		expect.sequence(outcomes, { false })
	end,

	["Scare announces, holds, hurts at the end and lets the victim go alive"] = function(expect)
		local s = setup()
		local victim, root, humanoid = fakeVictim()
		humanoid.TakeDamage = function(self, amount)
			self.Health -= amount
		end
		local outcomes = {}

		local handle = s.Kill.Scare(s.agent, victim, { Duration = 1, Damage = 15 })
		handle.Finished:Connect(function(done)
			table.insert(outcomes, done)
		end)

		expect.equal(s.events[1].Name, "Scare")
		expect.equal(s.events[1].Payload.Kind, "Scare")
		expect.equal(s.events[1].Payload.Duration, 1)
		expect.truthy(root.Anchored)

		s.heartbeat:Fire(0.5)
		expect.equal(humanoid.Health, 100, "unhurt during the hold")
		s.heartbeat:Fire(0.5)
		expect.equal(humanoid.Health, 85, "hurt as the hold ends")
		expect.sequence(outcomes, { true })
		expect.falsy(root.Anchored, "let go")
		expect.falsy(humanoid.PlatformStand)
		expect.equal(#s.events, 1, "no cancel event for a scare that ran its course")

		local again, root2 = fakeVictim()
		local cut = s.Kill.Scare(s.agent, again, { Duration = 2 })
		s.heartbeat:Fire(0.5)
		cut:Cancel()
		expect.equal(s.events[#s.events].Name, "ScareCancelled")
		expect.falsy(root2.Anchored)
	end,

	["a Health provider replaces the Humanoid for Live, Scare and BlackBox"] = function(expect)
		local s = setup()
		local victim, root = fakeVictim(false)
		local health = 40
		local log = {}
		local provider = {
			Get = function()
				return health
			end,
			Damage = function(_character, amount)
				health -= amount
				table.insert(log, `damage {amount}`)
			end,
			Kill = function()
				health = 0
				table.insert(log, "kill")
			end,
		}

		local handle = s.Kill.Live(s.agent, victim, { Duration = 1, Health = provider })
		local outcomes = {}
		handle.Finished:Connect(function(killed)
			table.insert(outcomes, killed)
		end)
		expect.truthy(root.Anchored, "held without a humanoid")
		s.heartbeat:Fire(1)
		expect.sequence(log, { "kill" })
		expect.sequence(outcomes, { true })

		health = 40
		table.clear(log)
		s.Kill.Scare(s.agent, victim, { Duration = 0.5, Damage = 10, Health = provider })
		s.heartbeat:Fire(0.5)
		expect.sequence(log, { "damage 10" })
		expect.equal(health, 30)

		local boxed = {}
		local box = s.Kill.BlackBox(s.agent, victim, { Delay = 0.01, Health = provider })
		box.Finished:Connect(function(killed)
			table.insert(boxed, killed)
		end)
		task.wait(0.05)
		expect.sequence(boxed, { true })
		expect.equal(health, 0)

		local dead = s.Kill.Live(s.agent, victim, { Health = provider })
		local deadOutcome = {}
		dead.Finished:Connect(function(killed)
			table.insert(deadOutcome, killed)
		end)
		task.wait(0.01)
		expect.sequence(deadOutcome, { false }, "already dead by the provider's account")
	end,

	["a string KillerAnimation plays a Locomotion one-shot and stops it with the hold"] = function(expect)
		local heartbeat = Harness.ManualHeartbeat()
		local played, stopped = {}, {}
		local fakeLocomotion = {
			Play = function(_agent, name)
				table.insert(played, name)
				return true
			end,
			Get = function()
				return {
					Stop = function(_self, name)
						table.insert(stopped, name)
					end,
				}
			end,
		}
		local Kill = Harness.Load("lib/Combat/Kill.luau", {
			modules = { ["lib/Animator/Locomotion"] = fakeLocomotion },
			services = {
				RunService = {
					Heartbeat = heartbeat,
					IsServer = function()
						return true
					end,
				},
			},
		})
		local s = setup()
		local victim = fakeVictim()

		local handle = Kill.Live(s.agent, victim, { Duration = 1, KillerAnimation = "Grab" })
		expect.sequence(played, { "Grab" })
		heartbeat:Fire(1)
		expect.sequence(stopped, { "Grab" }, "stopped when the hold ends")
		expect.truthy(handle)
	end,
}
