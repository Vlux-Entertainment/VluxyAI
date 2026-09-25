--!strict

--[[
	Wanderer: the smallest useful AI. Picks a random point, walks there, waits, repeats. No
	senses at all, so it shows the runner, the navmesh pathfinder and the humanoid mover with
	nothing else in the way.

	Blackboard: none. Data: WaitUntil (when Idle ends), Since (when the walk began).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Context = require(script.Parent.Parent.Context)
local Map = require(script.Parent.Parent.Map)
local VluxyAI = require(ReplicatedStorage.Packages.VluxyAI)

local WALK_TIMEOUT = 20

local Brain: VluxyAI.Brain = {
	Initial = "Idle",
	States = {
		Idle = {
			Enter = function(agent: VluxyAI.Agent)
				agent:Stop()
				agent.Data.WaitUntil = os.clock() + agent.Data.Random:NextNumber(1, 3)
			end,
			Update = function(agent: VluxyAI.Agent)
				if os.clock() >= agent.Data.WaitUntil then
					return "Wander"
				end
				return nil
			end,
		},

		Wander = {
			Enter = function(agent: VluxyAI.Agent)
				agent.Data.Since = os.clock()
				agent:MoveTo(Map.RandomPoint(agent.Data.Map, agent.Data.Random))
			end,
			Update = function(agent: VluxyAI.Agent)
				local status = agent:GetPathStatus()
				if status == "Arrived" or status == "Failed" then
					return "Idle"
				end
				if os.clock() - agent.Data.Since > WALK_TIMEOUT then
					return "Idle"
				end
				return nil
			end,
		},
	},
}

local function Wanderer(model: Model, context: Context.Context): VluxyAI.Agent
	return VluxyAI.new(model)
		:SetName("Wanderer")
		:UseBrain(Brain)
		:UsePathfinder(VluxyAI.Pathfinders.Navmesh.new({ AgentRadius = 2, AgentHeight = 5 }))
		:UseMover(VluxyAI.Movers.Humanoid.new(model, { Speed = 10 }))
		:SetData({ Map = context.Map, Random = context.Random })
		:Build()
end

return Wanderer :: Context.Enemy
