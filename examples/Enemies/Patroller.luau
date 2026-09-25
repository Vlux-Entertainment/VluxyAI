--!strict

--[[
	Patroller: walks the map's patrol nodes in order and breaks off to investigate a noise
	(a player jumping, or the orange noise pad). Shows the Hearing sense with a noise signal the
	game owns, and the blackboard holding a memory the states act on.

	Blackboard (from Hearing): HeardPosition, HeardAt.
	Data: Nodes, Index (next node), InvestigatedAt (the HeardAt already answered).
	Timers: Look.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Context = require(script.Parent.Parent.Context)
local VluxyAI = require(ReplicatedStorage.Packages.VluxyAI)

local LOOK_DURATION = 2.5

--[[
	A noise the patroller has not already gone to look at.
]]
local function newNoise(agent: VluxyAI.Agent): boolean
	local heardAt = agent.Blackboard.HeardAt
	return heardAt ~= nil and heardAt ~= agent.Data.InvestigatedAt
end

local Brain: VluxyAI.Brain = {
	Initial = "Patrol",
	States = {
		Patrol = {
			Enter = function(agent: VluxyAI.Agent)
				agent:MoveTo(agent.Data.Nodes[agent.Data.Index])
			end,
			Transitions = {
				{ To = "Investigate", When = newNoise },
			},
			Update = function(agent: VluxyAI.Agent)
				local status = agent:GetPathStatus()
				if status == "Arrived" or status == "Failed" then
					agent.Data.Index = agent.Data.Index % #agent.Data.Nodes + 1
					agent:MoveTo(agent.Data.Nodes[agent.Data.Index])
				end
				return nil
			end,
		},

		Investigate = {
			Enter = function(agent: VluxyAI.Agent)
				agent.Data.InvestigatedAt = agent.Blackboard.HeardAt
				agent:MoveTo(agent.Blackboard.HeardPosition)
			end,
			Transitions = {
				-- A newer noise re-enters this state at the new spot.
				{ To = "Investigate", When = newNoise },
				{
					To = "Look",
					When = function(agent: VluxyAI.Agent)
						return agent:HasArrived()
					end,
				},
				{
					To = "Patrol",
					When = function(agent: VluxyAI.Agent)
						return agent:GetPathStatus() == "Failed"
					end,
				},
			},
		},

		Look = {
			Enter = function(agent: VluxyAI.Agent)
				agent:Stop()
				agent:StartTimer("Look", LOOK_DURATION)
			end,
			Transitions = {
				{ To = "Investigate", When = newNoise },
				{
					To = "Patrol",
					When = function(agent: VluxyAI.Agent)
						return agent:TimerDone("Look")
					end,
				},
			},
		},
	},
}

local function Patroller(model: Model, context: Context.Context): VluxyAI.Agent
	return VluxyAI.new(model)
		:SetName("Patroller")
		:UseBrain(Brain)
		:UsePathfinder(VluxyAI.Pathfinders.Navmesh.new())
		:UseMover(VluxyAI.Movers.Humanoid.new(model, { Speed = 9 }))
		:AddSense(VluxyAI.Senses.Hearing.new(context.Noises, { Range = 40, Memory = 6 }))
		:SetData({ Nodes = context.Map.PatrolNodes, Index = 1 })
		:Build()
end

return Patroller :: Context.Enemy
