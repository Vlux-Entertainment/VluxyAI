--!strict

--[[
	The attack state and Strike, against a fake Kill and a fake Locomotion supplied through the
	harness module overrides, so the state's own logic is what runs: damage or kill, the wait for
	a kill to end, and Exit cancelling a kill still in progress.
]]

local Fakes = require("../Support/Fakes")
local Harness = require("../Support/Harness")

local function setup(health: number)
	local Signal = Fakes.Signal()
	local kills = {} :: { any }
	local played = {} :: { string }

	local fakeKill = {}
	local function makeHandle(kind: string)
		local finished = Signal.new()
		local handle = { Kind = kind, Finished = finished, Cancelled = false }
		function handle.Cancel(self)
			self.Cancelled = true
			finished:Fire(false)
		end
		return handle
	end
	function fakeKill.Live(_agent, victim, options)
		local handle = makeHandle("Live")
		table.insert(kills, { Kind = "Live", Victim = victim, Options = options, Handle = handle })
		return handle
	end
	function fakeKill.BlackBox(_agent, victim, options)
		local handle = makeHandle("BlackBox")
		table.insert(kills, { Kind = "BlackBox", Victim = victim, Options = options, Handle = handle })
		return handle
	end
	function fakeKill.Scare(_agent, victim, options)
		local handle = makeHandle("Scare")
		table.insert(kills, { Kind = "Scare", Victim = victim, Options = options, Handle = handle })
		return handle
	end

	local fakeLocomotion = {
		Play = function(_agent, name)
			table.insert(played, name)
			return true
		end,
	}

	local Attack = Harness.Load("lib/Combat/Attack.luau", {
		modules = {
			["lib/Combat/Kill"] = fakeKill,
			["lib/Animator/Locomotion"] = fakeLocomotion,
		},
	})

	local humanoid = { Health = health, Damage = 0 }
	function humanoid.TakeDamage(self, amount)
		self.Damage += amount
		self.Health -= amount
	end
	local character = {}
	function character.FindFirstChildOfClass(_self, className)
		return if className == "Humanoid" then humanoid else nil
	end
	local root = {}
	function root.FindFirstAncestorOfClass(_self, className)
		return if className == "Model" then character else nil
	end

	local clock = Harness.ManualClock(0)
	local timers = {}
	local agent = {
		Name = "Killer",
		Blackboard = { Target = root },
		Data = {},
		Stops = 0,
	}
	function agent.Stop(self)
		self.Stops += 1
	end
	function agent.StartTimer(_self, name, seconds)
		timers[name] = clock:Now() + seconds
	end
	function agent.TimerDone(_self, name)
		return timers[name] == nil or clock:Now() >= timers[name]
	end

	return {
		Attack = Attack,
		agent = agent,
		root = root,
		character = character,
		humanoid = humanoid,
		kills = kills,
		played = played,
		clock = clock,
	}
end

return {
	["Strike hurts a healthy target and plays the swing"] = function(expect)
		local s = setup(100)
		local handle = s.Attack.Strike(s.agent, s.root, 30, { Kill = "Live" })
		expect.equal(handle, nil)
		expect.equal(s.humanoid.Damage, 30)
		expect.sequence(s.played, { "Attack" })
		expect.equal(#s.kills, 0)
	end,

	["Strike with no target or no humanoid does nothing"] = function(expect)
		local s = setup(100)
		expect.equal(s.Attack.Strike(s.agent, nil, 30), nil)
		local bare = {
			FindFirstAncestorOfClass = function()
				return nil
			end,
		}
		expect.equal(s.Attack.Strike(s.agent, bare :: any, 30), nil)
		expect.equal(#s.played, 0)
	end,

	["a blow that would finish the target is a kill of the chosen kind"] = function(expect)
		local s = setup(30)
		local handle = s.Attack.Strike(s.agent, s.root, 30, { Kill = "Live", KillerAnimation = 1, VictimAnimation = 2 })
		expect.truthy(handle)
		expect.equal(#s.kills, 1)
		expect.equal(s.kills[1].Kind, "Live")
		expect.equal(s.kills[1].Victim, s.character)
		expect.equal(s.kills[1].Options.KillerAnimation, 1)
		expect.equal(s.humanoid.Damage, 0, "no damage on a kill")

		local box = setup(10)
		box.Attack.Strike(box.agent, box.root, 30, { Kill = "BlackBox" })
		expect.equal(box.kills[1].Kind, "BlackBox")
	end,

	["without a Kill kind a finishing blow is plain damage"] = function(expect)
		local s = setup(10)
		s.Attack.Strike(s.agent, s.root, 30)
		expect.equal(s.humanoid.Damage, 30)
		expect.equal(#s.kills, 0)
	end,

	["the state stops, strikes on entry and leaves after the cooldown"] = function(expect)
		local s = setup(100)
		local state = s.Attack.State({ Damage = 10, Cooldown = 1, TargetKey = "Target", Then = "Hunt" })

		state.Enter(s.agent)
		expect.equal(s.agent.Stops, 1)
		expect.equal(s.humanoid.Damage, 10)
		expect.falsy(state.Transitions[1].When(s.agent), "cooling down")
		s.clock:Advance(1)
		expect.truthy(state.Transitions[1].When(s.agent))
		expect.equal(state.Transitions[1].To, "Hunt")
	end,

	["the state waits for a kill to finish even after the cooldown"] = function(expect)
		local s = setup(10)
		local state =
			s.Attack.State({ Damage = 10, Cooldown = 0.5, TargetKey = "Target", Then = "Hunt", Kill = "Live" })

		state.Enter(s.agent)
		s.clock:Advance(1)
		expect.falsy(state.Transitions[1].When(s.agent), "the kill is still running")
		s.kills[1].Handle.Finished:Fire(true)
		expect.truthy(state.Transitions[1].When(s.agent))
	end,

	["leaving the state early cancels a kill in progress"] = function(expect)
		local s = setup(10)
		local state =
			s.Attack.State({ Damage = 10, Cooldown = 0.5, TargetKey = "Target", Then = "Hunt", Kill = "Live" })

		state.Enter(s.agent)
		state.Exit(s.agent)
		expect.truthy(s.kills[1].Handle.Cancelled)
		expect.equal(s.agent.Data.AttackKill, nil)

		state.Exit(s.agent)
		expect.truthy(true, "a second Exit is harmless")
	end,

	["Kill = Scare makes every blow a scare carrying the damage"] = function(expect)
		local s = setup(100)
		local handle = s.Attack.Strike(s.agent, s.root, 20, { Kill = "Scare", KillerAnimation = 5 })
		expect.truthy(handle)
		expect.equal(#s.kills, 1)
		expect.equal(s.kills[1].Kind, "Scare")
		expect.equal(s.kills[1].Options.Damage, 20)
		expect.equal(s.kills[1].Options.KillerAnimation, 5)
		expect.equal(s.humanoid.Damage, 0, "the scare deals it, not Strike")
		expect.equal(#s.played, 0, "no swing; the hold animates")
	end,

	["a Health provider is used instead of the Humanoid"] = function(expect)
		local s = setup(100)
		local health = 25
		local log = {}
		local provider = {
			Get = function()
				return health
			end,
			Damage = function(_character, amount)
				health -= amount
				table.insert(log, amount)
			end,
		}

		s.Attack.Strike(s.agent, s.root, 10, { Kill = "Live", Health = provider })
		expect.sequence(log, { 10 }, "a non-finishing blow goes through the provider")
		expect.equal(s.humanoid.Damage, 0, "the humanoid is left alone")
		expect.equal(#s.kills, 0)

		s.Attack.Strike(s.agent, s.root, 15, { Kill = "Live", Health = provider })
		expect.equal(#s.kills, 1, "the provider's 15 left is a finishing blow")
		expect.equal(s.kills[1].Options.Health, provider, "handed on to the kill")

		local bare = {
			FindFirstAncestorOfClass = function()
				return s.character
			end,
		}
		local noHumanoid = {
			FindFirstChildOfClass = function()
				return nil
			end,
		}
		bare.FindFirstAncestorOfClass = function()
			return noHumanoid
		end
		s.Attack.Strike(s.agent, bare :: any, 5, { Health = provider })
		expect.sequence(log, { 10, 5 }, "no humanoid needed with a provider")
	end,
}
