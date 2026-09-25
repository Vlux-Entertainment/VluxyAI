--!strict

--[[
	Wanderer: the smallest useful AI. Picks a random point, walks there, waits, repeats. Built
	from the Humanoid preset, so the whole stack is one line, and it reads none of the senses the
	preset adds: it only shows the runner, the navmesh pathfinder and the humanoid mover.

	Blackboard: none read. Data: Map, Random (from the playground), Since (when the walk began).
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
				agent:StartTimer("Rest", agent.Data.Random:NextNumber(1, 3))
			end,
			Transitions = {
				{
					To = "Wander",
					When = function(agent: VluxyAI.Agent)
						return agent:TimerDone("Rest")
					end,
				},
			},
		},

		Wander = {
			Enter = function(agent: VluxyAI.Agent)
				agent:StartTimer("Walk", WALK_TIMEOUT)
				agent:MoveTo(Map.RandomPoint(agent.Data.Map, agent.Data.Random))
			end,
			Transitions = {
				{
					To = "Idle",
					When = function(agent: VluxyAI.Agent)
						-- A random point may be inside a wall; Failed just means pick another.
						local status = agent:GetPathStatus()
						return status == "Arrived" or status == "Failed" or agent:TimerDone("Walk")
					end,
				},
			},
		},
	},
}

local function Wanderer(model: Model, context: Context.Context): VluxyAI.Agent
	return VluxyAI.Presets
		.Humanoid(model, { Mover = { Speed = 10 } })
		:SetName("Wanderer")
		:UseBrain(Brain)
		:SetData({ Map = context.Map, Random = context.Random })
		:Build()
end

return Wanderer :: Context.Enemy
