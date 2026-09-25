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
		services = { RunService = { Heartbeat = heartbeat } },
	})
	local Signal = Fakes.Signal()
	local events = {}
	local agent = {
		Name = "Killer",
		Entity = {
			GetPivot = function()
				return CFrame.new(10, 0, 0)
			end,
			FindFirstChildOfClass = function()
				return nil
			end,
		},
		Events = Signal.new(),
		Emit = function(_self, name, payload)
			table.insert(events, { Name = name, Payload = payload })
		end,
	}
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
		expect.equal(root.Owners[1], "server")
		expect.truthy(humanoid.PlatformStand)

		s.heartbeat:Fire(0.5)
		expect.near(root.CFrame.Position.X, 10, 1e-4, "held in front of the killer")
		expect.near(root.CFrame.Position.Z, -3, 1e-4)
		expect.equal(root.AssemblyLinearVelocity, Vector3.zero)
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
		expect.equal(root.AutoOwnership, 1, "ownership handed back")
		expect.equal(s.heartbeat:Count(), 0)

		handle:Cancel()
		expect.sequence(outcomes, { false }, "a second Cancel does nothing")
	end,

	["Live on a victim with no humanoid finishes false and announces nothing"] = function(expect)
		local warnings = {}
		local heartbeat = Harness.ManualHeartbeat()
		local Kill = Harness.Load("lib/Combat/Kill.luau", {
			services = { RunService = { Heartbeat = heartbeat } },
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
}
