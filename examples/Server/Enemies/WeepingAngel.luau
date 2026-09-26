--!strict

--[[
	Weeping Angel: the statue that moves when you blink. It never patrols. Once it has spotted you it only moves while
	nobody is looking at it, freezes the instant anyone is, and strikes when it gets close while
	unwatched. If it loses you for long enough it goes dormant again. Shows the Watched sense
	(the sight check run from the players' side) and the CFrame mover halting an anchored rig
	instantly.

	"Looking" is judged from each player's head facing, which on a default rig is the direction
	they walk. A game that wants the real camera direction replicates it and passes `Eye` to the
	Watched sense.

	When it has sat dormant too long, it burrows: it sinks into the floor where nobody is looking
	and rises, also unseen, wherever the shared clue map says someone most likely is. It does not
	know where you are; it knows where the noises and sightings were.

	Blackboard (from Sight, Watched, SafeWatch and Hideout): SeenTarget, SeenDistance, SeenPosition,
	IsWatched, SafeTarget, LurkSpot. Timers: Attack, States.Stare.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Context = require(script.Parent.Parent.Context)
local VluxyAI = require(ReplicatedStorage.Packages.VluxyAI)

-- Unwatched it outpaces a walking player (16); only a sprint (24) or a look over the shoulder saves you.
local SPEED = 20
local ATTACK_RANGE = 3.5
local ATTACK_DAMAGE = 100
local ATTACK_COOLDOWN = 1.5

-- Burrowing: after DEAD_TIME dormant it sinks BURROW_DEPTH studs over BURROW_TIME and rises at
-- its lurk spot: the warmest cell of the shared clue map that nobody can see.
local DEAD_TIME = 12
local BURROW_TIME = 1.5
local BURROW_DEPTH = 7
local MIN_BURROW_DISTANCE = 30
-- Chance its lurk spot ignores the clues and is any unseen spot instead.
local LURK_STRAY = 0.25

------------------------------------------------------------------------------------------------------------------------

--[[
	A custom sense that is really a reflex: while anyone is looking, the rig's animations hold
	their pose, so the statue is caught mid-step rather than idling. Runs after Watched, which
	writes IsWatched.
]]
local StatueFreeze: VluxyAI.Sense = {
	Tick = function(_self: any, agent: VluxyAI.Agent, _deltaTime: number)
		VluxyAI.Locomotion.Freeze(agent, agent.Blackboard.IsWatched == true)
	end,
} :: any

------------------------------------------------------------------------------------------------------------------------

local function seesSomeone(agent: VluxyAI.Agent): boolean
	return agent.Blackboard.SeenTarget ~= nil
end

local function forgot(agent: VluxyAI.Agent): boolean
	return agent.Blackboard.SeenPosition == nil
end

local function watched(agent: VluxyAI.Agent): boolean
	return agent.Blackboard.IsWatched == true
end

-- Sight has a 360 degree field here, so this is "close with a clear line", walls included.
local function inReach(agent: VluxyAI.Agent): boolean
	return agent.Blackboard.SeenDistance <= ATTACK_RANGE
end

-- The one it was creeping up on got into a safe room, or it sees someone in one and has not just
-- lingered over them.
local safeSighted = VluxyAI.When.SafeSighted()

local function lingered(agent: VluxyAI.Agent): boolean
	return agent:TimerDone("States.Stare")
end

-- Stuck somewhere nobody comes: dormant a while, unwatched, and a lurk spot well away from here.
local function deadArea(agent: VluxyAI.Agent): boolean
	local spot = agent.Blackboard.LurkSpot
	if agent:TimeInState() < DEAD_TIME or watched(agent) or spot == nil then
		return false
	end
	local here = agent:GetPosition()
	return Vector3.new(spot.X - here.X, 0, spot.Z - here.Z).Magnitude >= MIN_BURROW_DISTANCE
end

local Brain: VluxyAI.Brain = {
	Initial = "Dormant",
	States = {
		Dormant = {
			Enter = function(agent: VluxyAI.Agent)
				agent:Stop()
			end,
			Transitions = {
				{ To = "Linger", When = safeSighted },
				{ To = "Aware", When = seesSomeone },
				{ To = "Burrow", When = deadArea },
			},
		},

		-- Someone reached a safe room: stand there, a statue, for four seconds, then burrow away
		-- whether or not it is watched (or go dormant in the rare case there is nowhere to go).
		Linger = VluxyAI.States.Stare({
			Target = "SafePosition",
			Duration = 4,
			Cooldown = 10,
			Face = false,
			Transitions = {
				{
					To = "Burrow",
					When = function(agent: VluxyAI.Agent)
						return lingered(agent) and agent.Blackboard.LurkSpot ~= nil
					end,
				},
				{
					To = "Dormant",
					When = function(agent: VluxyAI.Agent)
						return lingered(agent) and agent.Blackboard.LurkSpot == nil
					end,
				},
			},
		}),

		-- Into the floor where it stands, then up at the lurk spot the Hideout sense chose.
		Burrow = VluxyAI.States.Burrow({
			To = "LurkSpot",
			Depth = BURROW_DEPTH,
			Time = BURROW_TIME,
			Then = "Dormant",
		}),

		-- Frozen: someone is looking. Nothing happens here but waiting.
		Aware = {
			Enter = function(agent: VluxyAI.Agent)
				agent:Stop()
			end,
			Transitions = {
				{ To = "Linger", When = safeSighted },
				{ To = "Dormant", When = forgot },
				{
					To = "Advance",
					When = function(agent: VluxyAI.Agent)
						return not watched(agent)
					end,
				},
			},
		},

		Advance = {
			Transitions = {
				{ To = "Linger", When = safeSighted },
				{ To = "Aware", When = watched },
				{ To = "Dormant", When = forgot },
				{ To = "Attack", When = inReach },
			},
			Update = function(agent: VluxyAI.Agent)
				agent:MoveTo(agent.Blackboard.SeenPosition)
				return nil
			end,
		},

		-- One touch is the end: a black-box kill, the screen cuts before anything is seen.
		Attack = VluxyAI.Combat.Attack.State({
			Damage = ATTACK_DAMAGE,
			Cooldown = ATTACK_COOLDOWN,
			TargetKey = "SeenTarget",
			Then = "Aware",
			Kill = "BlackBox",
		}),
	},
}

local function WeepingAngel(model: Model, context: Context.Context): VluxyAI.Agent
	return VluxyAI
		.new(model)
		:SetName("WeepingAngel")
		:UseBrain(Brain)
		-- A* over the maze's node graph for every route; Roblox's navmesh only when the graph has no
		-- way there. A target in plain view is walked at straight (UseDirect below).
		:UsePathfinder(
			VluxyAI.Pathfinders.Hybrid.new({
				Graph = context.Graph,
				Local = VluxyAI.Pathfinders.Navmesh.new(),
				Prefer = "Graph",
				RefineEnds = false,
			})
		)
		-- Walk straight at anything in a clear line; plan only when that is blocked or stuck.
		:UseDirect(
			VluxyAI.Pathfinders.Straight.new({
				-- Doors never block an enemy (a collision group), so only a locked one blocks the line.
				Ignore = VluxyAI.Doors.IgnoreUnlocked(VluxyAI.Pathfinders.Straight.DefaultIgnore),
			})
		)
		-- Force a door open on the way through, whether the path crosses it or the enemy walks up to it.
		:OnStep(
			"Door",
			VluxyAI.Doors.Step(nil, { WalkThrough = true })
		)
		:AddSense(VluxyAI.Doors.Opener())
		:UseMover(VluxyAI.Movers.CFrame.new(model, { Speed = SPEED, TurnSpeed = 20 }))
		:AddSense(VluxyAI.Senses.Sight.new({ Range = 60, FieldOfView = 360, Memory = 8 }))
		:AddSense(VluxyAI.Senses.Watched.new({ Range = 80, FieldOfView = 100 }))
		-- Where to come up: the most suspicious spot on the shared clue map that nobody can see,
		-- and now and then any unseen spot, for variety.
		:AddSense(
			VluxyAI.Senses.Hideout.new(context.Interest, { Key = "LurkSpot", Stray = LURK_STRAY })
		)
		:AddSense(VluxyAI.Senses.SafeWatch.new({ Spots = context.Graph }))
		-- A statue never speaks where you can see it: whispers only while it creeps up unwatched,
		-- a laugh as it gives up on someone in a safe room.
		:AddSense(
			VluxyAI.Voice.new({
				Lines = {
					Advance = { 770334887, 89930215709196, 136833080474934 },
					Linger = { 89425134113608, 114769944354949 },
				},
				Interval = { 4, 9 },
				OnEnter = { Advance = 0.3, Linger = 1, ["*"] = 0 },
				Volume = 0.56,
			})
		)
		-- A statue: every animation holds still while anyone is looking at it.
		:AddSense(StatueFreeze)
		:SetData({ Random = context.Random })
		:SetTick(0.05)
		:SetNavigation({ RepathInterval = 0.2, MaxPathAge = 2 })
		:Build()
end

return WeepingAngel :: Context.Enemy
