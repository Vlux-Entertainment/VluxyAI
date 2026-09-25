--!strict

--[[
	Stalker: the horror-game monster. It patrols the map's nodes, breaks off to investigate any
	noise (a player jumping, the orange pad, or the Guardian raising the alarm), hunts on sight
	while walking toward the last place it saw you, and when it loses you it searches a few spots
	around that place before going back to patrol. Attacks when close with a clear line.

	Shows: Sight and Hearing writing the blackboard, blackboard memory (SeenPosition lingers,
	HeardAt marks a noise as answered), declarative transitions ordered by priority, a state that
	walks a list of points, and the Ladder trying a straight line before the navmesh.

	Blackboard (from Sight, Hearing): SeenTarget, SeenDistance, SeenPosition, HeardPosition,
	HeardAt. Data: Nodes, Index, InvestigatedAt, LastSeen, SearchPoints, SearchIndex.
	Timers: Attack, Search.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Combat = require(script.Parent.Parent.Combat)
local Context = require(script.Parent.Parent.Context)
local VluxyAI = require(ReplicatedStorage.Packages.VluxyAI)

local PATROL_SPEED = 10
local HUNT_SPEED = 15
local ATTACK_RANGE = 4
local SEARCH_RADIUS = 12
local SEARCH_POINTS = 3
local SEARCH_TIME = 14

local function seesSomeone(agent: VluxyAI.Agent): boolean
	return agent.Blackboard.SeenTarget ~= nil
end

local function forgot(agent: VluxyAI.Agent): boolean
	return agent.Blackboard.SeenPosition == nil
end

local function inReach(agent: VluxyAI.Agent): boolean
	return agent.Blackboard.SeenDistance <= ATTACK_RANGE
end

--[[
	A noise the stalker has not already gone to look at.
]]
local function newNoise(agent: VluxyAI.Agent): boolean
	local heardAt = agent.Blackboard.HeardAt
	return heardAt ~= nil and heardAt ~= agent.Data.InvestigatedAt
end

local function arrivedOrFailed(agent: VluxyAI.Agent): boolean
	local status = agent:GetPathStatus()
	return status == "Arrived" or status == "Failed"
end

local Brain: VluxyAI.Brain = {
	Initial = "Patrol",
	States = {
		Patrol = {
			Enter = function(agent: VluxyAI.Agent)
				agent:SetSpeed(PATROL_SPEED)
				agent:MoveTo(agent.Data.Nodes[agent.Data.Index])
			end,
			Transitions = {
				{ To = "Hunt", When = seesSomeone },
				{ To = "Investigate", When = newNoise },
			},
			Update = function(agent: VluxyAI.Agent)
				if arrivedOrFailed(agent) then
					agent.Data.Index = agent.Data.Index % #agent.Data.Nodes + 1
					agent:MoveTo(agent.Data.Nodes[agent.Data.Index])
				end
				return nil
			end,
		},

		Investigate = {
			Enter = function(agent: VluxyAI.Agent)
				agent:SetSpeed(PATROL_SPEED)
				agent.Data.InvestigatedAt = agent.Blackboard.HeardAt
				agent.Data.LastSeen = agent.Blackboard.HeardPosition
				agent:MoveTo(agent.Blackboard.HeardPosition)
			end,
			Transitions = {
				{ To = "Hunt", When = seesSomeone },
				-- A newer noise re-enters this state at the new spot.
				{ To = "Investigate", When = newNoise },
				{ To = "Search", When = arrivedOrFailed },
			},
		},

		Hunt = {
			Enter = function(agent: VluxyAI.Agent)
				agent:SetSpeed(HUNT_SPEED)
			end,
			Transitions = {
				{ To = "Attack", When = inReach },
				{ To = "Search", When = forgot },
			},
			Update = function(agent: VluxyAI.Agent)
				-- SeenPosition lingers for Sight's Memory after the target is lost, so this walks to
				-- the last sighting on its own; LastSeen keeps it for Search after that.
				agent.Data.LastSeen = agent.Blackboard.SeenPosition
				agent:MoveTo(agent.Blackboard.SeenPosition)
				return nil
			end,
		},

		Search = {
			Enter = function(agent: VluxyAI.Agent)
				agent:SetSpeed(PATROL_SPEED)
				agent:StartTimer("Search", SEARCH_TIME)

				local around = agent.Data.LastSeen or agent:GetPosition()
				local random = agent.Data.Random :: Random
				local points = {}
				for _ = 1, SEARCH_POINTS do
					local angle = random:NextNumber(0, math.pi * 2)
					local distance = random:NextNumber(SEARCH_RADIUS / 2, SEARCH_RADIUS)
					table.insert(
						points,
						around + Vector3.new(math.cos(angle) * distance, 0, math.sin(angle) * distance)
					)
				end
				agent.Data.SearchPoints = points
				agent.Data.SearchIndex = 1
				agent:MoveTo(points[1])
			end,
			Transitions = {
				{ To = "Hunt", When = seesSomeone },
				{ To = "Investigate", When = newNoise },
				{
					To = "Patrol",
					When = function(agent: VluxyAI.Agent)
						return agent:TimerDone("Search")
					end,
				},
			},
			Update = function(agent: VluxyAI.Agent)
				if not arrivedOrFailed(agent) then
					return nil
				end

				local index = agent.Data.SearchIndex + 1
				if index > #agent.Data.SearchPoints then
					return "Patrol"
				end
				agent.Data.SearchIndex = index
				agent:MoveTo(agent.Data.SearchPoints[index])
				return nil
			end,
		},

		Attack = Combat.AttackState({ Damage = 10, Cooldown = 1, TargetKey = "SeenTarget", Then = "Hunt" }),
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
		:SetData({ Nodes = context.Map.PatrolNodes, Index = 1, Random = context.Random })
		:SetNavigation({ RepathInterval = 0.25 })
		:Build()
end

return Stalker :: Context.Enemy
