--!strict

--[[
	Stalker: the horror-game monster. It patrols the map's nodes, breaks off to investigate any
	noise (a player jumping, the orange pad, or the Guardian raising the alarm), hunts on sight
	while walking toward the last place it saw you, and when it loses you it searches a few spots
	around that place before going back to patrol. Attacks when close with a clear line.

	Shows: the brain written with Interrupts, When and States, so the only hand-written state is
	Hunt. Sight and Hearing write the blackboard; the interrupts read it from every state; the
	ready-made Patrol, Investigate and Search states do the walking; When.New makes a noise fire
	one investigation and not one per tick.

	Blackboard (from Sight, Hearing): SeenTarget, SeenDistance, SeenPosition, HeardPosition,
	HeardAt. Data: Nodes, Random, LastSeen, Patrol, Search. Timers: Attack, States.Search.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Context = require(script.Parent.Parent.Context)
local VluxyAI = require(ReplicatedStorage.Packages.VluxyAI)

local States = VluxyAI.States
local When = VluxyAI.When

local PATROL_SPEED = 10
local HUNT_SPEED = 15
local ATTACK_RANGE = 4
local SEARCH_RADIUS = 12
local SEARCH_POINTS = 3
local SEARCH_TIME = 14

local Brain: VluxyAI.Brain = {
	Initial = "Patrol",

	-- From every state but the two that are already on it: hunt whoever is in sight, and go and
	-- look at a noise nobody has looked at yet. Order matters: sight beats sound.
	Interrupts = {
		{ To = "Hunt", When = When.Has("SeenTarget"), Except = { "Hunt", "Attack" } },
		{ To = "Investigate", When = When.New("HeardAt"), Except = { "Hunt", "Attack" } },
	},

	States = {
		Patrol = States.Patrol({ Points = "Nodes", Speed = PATROL_SPEED }),

		-- Walks to the noise, then searches around it. A newer noise re-enters through the
		-- interrupt at the new spot.
		Investigate = States.Investigate({ Target = "HeardPosition", Speed = PATROL_SPEED, Then = "Search" }),

		Hunt = {
			Enter = function(agent: VluxyAI.Agent)
				agent:SetSpeed(HUNT_SPEED)
			end,
			Transitions = {
				{ To = "Attack", When = When.Below("SeenDistance", ATTACK_RANGE) },
				{ To = "Search", When = When.Missing("SeenPosition") },
			},
			Update = function(agent: VluxyAI.Agent)
				-- SeenPosition lingers for Sight's Memory after the target is lost, so this walks to
				-- the last sighting on its own; LastSeen keeps it for Search after that.
				agent.Data.LastSeen = agent.Blackboard.SeenPosition
				agent:MoveTo(agent.Blackboard.SeenPosition)
				return nil
			end,
		},

		Search = States.Search({
			Around = "LastSeen",
			Radius = SEARCH_RADIUS,
			Points = SEARCH_POINTS,
			Duration = SEARCH_TIME,
			Speed = PATROL_SPEED,
			Then = "Patrol",
		}),

		-- The finishing blow is a live kill: the stalker holds you while both animations play.
		Attack = VluxyAI.Combat.Attack.State({
			Damage = 34,
			Cooldown = 1.8,
			TargetKey = "SeenTarget",
			Then = "Hunt",
			Kill = "Live",
			-- Roblox's own R15 animations: a swing for the killer, a flail for the victim.
			KillerAnimation = 522635514,
			VictimAnimation = 507767968,
		}),
	},
}

local function Stalker(model: Model, context: Context.Context): VluxyAI.Agent
	return VluxyAI.new(model)
		:SetName("Stalker")
		:UseBrain(Brain)
		:UsePathfinder(VluxyAI.Pathfinders.Ladder.new({
			VluxyAI.Pathfinders.Straight.new(),
			VluxyAI.Pathfinders.Navmesh.new(),
		}))
		:UseMover(VluxyAI.Movers.Humanoid.new(model, { Speed = PATROL_SPEED }))
		:AddSense(VluxyAI.Senses.Sight.new({ Range = 45, FieldOfView = 120, Memory = 4 }))
		:AddSense(VluxyAI.Senses.Hearing.new(context.Noises, { Range = 40, Memory = 6 }))
		:SetData({ Nodes = context.Map.PatrolNodes, Random = context.Random })
		:SetNavigation({ RepathInterval = 0.25 })
		:Build()
end

return Stalker :: Context.Enemy
