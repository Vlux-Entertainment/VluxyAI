--!strict

--[[
	Ghost: no Humanoid at all. An anchored, half-transparent cylinder driven by the CFrame mover
	along ordinary navmesh paths, floating a little above the floor. It drifts between random
	points and rushes at anyone it sees. Shows that the runner and the pathfinders never cared
	about rigs, and gives the server-side "logical position" model a body to test with.

	Blackboard (from Sight): SeenTarget, SeenPosition.
	Data: Map, Random, WaitUntil, Since.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Context = require(script.Parent.Parent.Context)
local Map = require(script.Parent.Parent.Map)
local VluxyAI = require(ReplicatedStorage.Packages.VluxyAI)

local DRIFT_SPEED = 4
local HAUNT_SPEED = 11
local DRIFT_TIMEOUT = 25

local Brain: VluxyAI.Brain = {
	Initial = "Rest",
	States = {
		Rest = {
			Enter = function(agent: VluxyAI.Agent)
				agent:Stop()
				agent.Data.WaitUntil = os.clock() + agent.Data.Random:NextNumber(1, 4)
			end,
			Transitions = {
				{
					To = "Haunt",
					When = function(agent: VluxyAI.Agent)
						return agent.Blackboard.SeenTarget ~= nil
					end,
				},
				{
					To = "Drift",
					When = function(agent: VluxyAI.Agent)
						return os.clock() >= agent.Data.WaitUntil
					end,
				},
			},
		},

		Drift = {
			Enter = function(agent: VluxyAI.Agent)
				agent:SetSpeed(DRIFT_SPEED)
				agent.Data.Since = os.clock()
				agent:MoveTo(Map.RandomPoint(agent.Data.Map, agent.Data.Random))
			end,
			Transitions = {
				{
					To = "Haunt",
					When = function(agent: VluxyAI.Agent)
						return agent.Blackboard.SeenTarget ~= nil
					end,
				},
				{
					To = "Rest",
					When = function(agent: VluxyAI.Agent)
						local status = agent:GetPathStatus()
						return status == "Arrived"
							or status == "Failed"
							or os.clock() - agent.Data.Since > DRIFT_TIMEOUT
					end,
				},
			},
		},

		Haunt = {
			Enter = function(agent: VluxyAI.Agent)
				agent:SetSpeed(HAUNT_SPEED)
			end,
			Transitions = {
				{
					To = "Rest",
					When = function(agent: VluxyAI.Agent)
						return agent.Blackboard.SeenPosition == nil
					end,
				},
			},
			Update = function(agent: VluxyAI.Agent)
				agent:MoveTo(agent.Blackboard.SeenPosition)
				return nil
			end,
		},
	},
}

local function Ghost(model: Model, context: Context.Context): VluxyAI.Agent
	return VluxyAI.new(model)
		:SetName("Ghost")
		:UseBrain(Brain)
		:UsePathfinder(VluxyAI.Pathfinders.Navmesh.new({ AgentRadius = 2, AgentHeight = 5 }))
		:UseMover(VluxyAI.Movers.CFrame.new(model, { Speed = DRIFT_SPEED, HeightOffset = 3.5, TurnSpeed = 6 }))
		:AddSense(
			VluxyAI.Senses.Sight.new({ Range = 35, FieldOfView = 360, Memory = 2, EyeOffset = Vector3.new(0, 1, 0) })
		)
		:SetData({ Map = context.Map, Random = context.Random })
		:SetNavigation({ ArriveDistance = 2 })
		:Build()
end

return Ghost :: Context.Enemy
