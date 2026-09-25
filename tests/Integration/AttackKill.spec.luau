--!strict

--[[
	The real Agent, the real attack state and the real Kill together: what the unit specs with
	fakes cannot see. A kill cancelled by Destroy must still announce KillCancelled, and the
	victim must be released alive.
]]

local Fakes = require("../Support/Fakes")
local Harness = require("../Support/Harness")

local roblox = require("@lune/roblox")
local task = require("@lune/task")
local CFrame = roblox.CFrame
local Vector3 = roblox.Vector3

local function fakeVictim(health: number)
	local humanoid = { Health = health, PlatformStand = false }
	function humanoid.TakeDamage(self, amount)
		self.Health -= amount
	end
	local root = { CFrame = CFrame.new(50, 0, 0), Anchored = false }
	local character = { PrimaryPart = root, Name = "Victim" }
	function character.FindFirstChildOfClass(_self, className)
		return if className == "Humanoid" then humanoid else nil
	end
	function character.GetFullName()
		return "Workspace.Victim"
	end
	function root.FindFirstAncestorOfClass(_self, className)
		return if className == "Model" then character else nil
	end
	return character, root, humanoid
end

local function setup(kind: string, health: number)
	local heartbeat = Harness.ManualHeartbeat()
	local services = {
		RunService = {
			Heartbeat = heartbeat,
			IsServer = function()
				return true
			end,
		},
	}
	local Agent = Harness.Load("lib/Agent.luau", { services = services })
	local Attack = Harness.Load("lib/Combat/Attack.luau", { services = services })

	local victim, root, humanoid = fakeVictim(health)
	local entity = Fakes.Entity("Killer")
	entity.FindFirstChildOfClass = function()
		return nil
	end

	local brain = {
		Initial = "Idle",
		States = {
			Idle = {},
			Attack = Attack.State({ Damage = 10, Cooldown = 0.01, TargetKey = "Target", Then = "Idle", Kill = kind }),
		},
	}
	local agent = Agent.new({
		Entity = entity,
		Brain = brain,
		Pathfinder = Fakes.Pathfinder(),
		Mover = Fakes.Mover(Vector3.new(0, 0, 0)),
		Blackboard = { Target = root },
	})

	local events = {}
	agent.Events:Connect(function(name, payload)
		table.insert(events, `{name}:{payload.Kind}`)
	end)

	return { agent = agent, events = events, victim = victim, root = root, humanoid = humanoid, heartbeat = heartbeat }
end

return {
	["a live kill cancelled by Destroy announces KillCancelled and frees the victim"] = function(expect)
		local s = setup("Live", 10)
		s.agent:Start(true)
		s.agent:SetState("Attack")
		expect.sequence(s.events, { "Kill:Live" })
		expect.truthy(s.root.Anchored, "held")

		s.heartbeat:Fire(0.5)
		s.agent:Destroy()
		task.wait()
		expect.sequence(s.events, { "Kill:Live", "KillCancelled:Live" })
		expect.equal(s.humanoid.Health, 10, "alive")
		expect.falsy(s.root.Anchored, "released")
		expect.falsy(s.humanoid.PlatformStand)
		expect.equal(s.heartbeat:Count(), 0, "nothing left on the heartbeat")
	end,

	["a black-box kill cancelled by Destroy announces KillCancelled"] = function(expect)
		local s = setup("BlackBox", 10)
		s.agent:Start(true)
		s.agent:SetState("Attack")
		s.agent:Destroy()
		task.wait(0.8)
		expect.sequence(s.events, { "Kill:BlackBox", "KillCancelled:BlackBox" })
		expect.equal(s.humanoid.Health, 10, "spared")
	end,

	["a live kill left to finish kills without a cancel"] = function(expect)
		local s = setup("Live", 10)
		s.agent:Start(true)
		s.agent:SetState("Attack")
		expect.equal(s.agent:GetState(), "Attack")
		s.agent:Step(0.1)
		expect.equal(s.agent:GetState(), "Attack", "the kill is still running, whatever the cooldown")
		s.heartbeat:Fire(2)
		task.wait(0.05)
		expect.sequence(s.events, { "Kill:Live" })
		expect.equal(s.humanoid.Health, 0)
		s.agent:Step(0.1)
		expect.equal(s.agent:GetState(), "Idle", "cooldown over, kill finished")
	end,
}
