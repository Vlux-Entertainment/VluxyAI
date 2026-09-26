--!strict

--[[
	Stalker: the horror-game monster. It knows someone is in the maze but not where, so it roams
	the shared Interest map, going wherever the clues are warmest and never back to a cell it just
	checked. It breaks off to investigate any noise (a footstep, a jump, the orange pad, the
	Guardian's alarm), hunts on sight toward where you were heading, and when it loses you it
	searches a few spots around there before going back to roaming. Attacks when close.

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
-- Faster than a walking player (16), slower than a sprinting one (24): walking away is not enough.
local HUNT_SPEED = 19
local ATTACK_RANGE = 4
-- A player this close is noticed whichever way it faces, so creeping up behind it does not work.
local NOTICE_RADIUS = 10
local SEARCH_RADIUS = 12
local SEARCH_POINTS = 3
local SEARCH_TIME = 14
-- A player in a safe room gets a stare this long, and is then left alone for STARE_COOLDOWN.
local STARE_TIME = 4
local STARE_COOLDOWN = 20

local Brain: VluxyAI.Brain = {
	Initial = "Roam",

	-- From every state but the two that are already on it: hunt whoever is in sight, and go and
	-- look at a noise nobody has looked at yet. Order matters: sight beats sound.
	Interrupts = {
		-- The one it was chasing got into a safe room, or it sees someone in one: stop where it
		-- is, stare for a moment, then carry on patrolling as if nothing happened.
		{
			To = "Stare",
			When = When.SafeSighted(),
			Except = { "Stare" },
		},
		{ To = "Hunt", When = When.Has("SeenTarget"), Except = { "Hunt", "Attack" } },
		{ To = "Investigate", When = When.New("HeardAt"), Except = { "Hunt", "Attack" } },
	},

	States = {
		-- Looking for you: the warmest cell it has not just checked, a pause there, the next.
		-- A quarter of its picks ignore the clues, so it is not perfectly predictable.
		Roam = States.Roam({ Interest = "Interest", Speed = PATROL_SPEED, Linger = { 0.5, 1.5 }, Stray = 0.25 }),

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
				-- Reached where they were heading and still nobody: search there rather than stand.
				{
					To = "Search",
					When = function(agent: VluxyAI.Agent)
						local status = agent:GetPathStatus()
						return agent.Blackboard.SeenTarget == nil and (status == "Arrived" or status == "Failed")
					end,
				},
			},
			Update = function(agent: VluxyAI.Agent)
				-- PredictedPosition is the last sighting carried forward along their velocity, so after
				-- losing sight this follows them round the corner; LastSeen keeps it for Search.
				local heading = agent.Blackboard.PredictedPosition or agent.Blackboard.SeenPosition
				if heading then
					agent.Data.LastSeen = heading
					agent:MoveTo(heading)
				end
				return nil
			end,
		},

		Stare = States.Stare({
			Target = "SafePosition",
			Duration = STARE_TIME,
			Cooldown = STARE_COOLDOWN,
			Then = "Roam",
		}),

		Search = States.Search({
			Around = "LastSeen",
			Radius = SEARCH_RADIUS,
			Points = SEARCH_POINTS,
			Duration = SEARCH_TIME,
			Speed = PATROL_SPEED,
			Then = "Roam",
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
	-- The playground's stack: A* over the maze first, straight at anything in plain view, doors
	-- forced open on the way through, safe rooms respected.
	return VluxyAI
		.Presets
		.Humanoid(model, {
			Graph = context.Graph,
			Doors = true,
			Mover = { Speed = PATROL_SPEED },
			Sight = { Range = 45, FieldOfView = 150, Memory = 8, Predict = 3, NoticeRadius = NOTICE_RADIUS },
		})
		:SetName("Stalker")
		:UseBrain(Brain)
		:AddSense(VluxyAI.Senses.Hearing.new(context.Noises, { Range = 40, Memory = 6 }))
		-- Every sighting warms the shared clue map, so the other enemies drift toward it too.
		:AddSense(
			VluxyAI.Senses.Clues.new(context.Interest)
		)
		-- Groans as it searches, growls as it hunts, "I see you" as it stares into a safe room.
		:AddSense(
			VluxyAI.Voice.new({
				Lines = {
					Roam = { 9113636490, 9113636491, 9113636681, 93710802942553 },
					Investigate = { 9113636490, 9113636491, 9113636681, 93710802942553 },
					Search = { 9113636490, 9113636491, 9113636681, 93710802942553 },
					Hunt = { 129294628821291, 130156156621885, 105926319962443 },
					Stare = { 8315677038 },
				},
				Interval = { 6, 14 },
				OnEnter = { Stare = 1, Hunt = 0.7, ["*"] = 0.2 },
				Volume = 0.56,
			})
		)
		:AddSense(context.Crowd)
		:SetData({ Interest = context.Interest, Random = context.Random })
		:Build()
end

return Stalker :: Context.Enemy
