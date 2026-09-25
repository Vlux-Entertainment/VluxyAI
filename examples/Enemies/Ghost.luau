--!strict

--[[
	Ghost: the Humanoid does no work. An anchored, see-through rig driven by the CFrame mover
	along ordinary navmesh paths, floating a little above the floor (HeightOffset is set by hand
	here; left out, the mover measures it from where the rig starts). It drifts between random
	points and rushes at anyone it sees. Shows that the runner and the pathfinders never cared
	about rigs, and gives the server-side "logical position" model a body to test with.

	Blackboard (from Sight): SeenTarget, SeenPosition.
	Data: Map, Random. Timers: Rest, Drift.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Context = require(script.Parent.Parent.Context)
local Map = require(script.Parent.Parent.Map)
local VluxyAI = require(ReplicatedStorage.Packages.VluxyAI)

local DRIFT_SPEED = 4
local HAUNT_SPEED = 11
local DRIFT_TIMEOUT = 25

local function seesSomeone(agent: VluxyAI.Agent): boolean
	return agent.Blackboard.SeenTarget ~= nil
end

local Brain: VluxyAI.Brain = {
	Initial = "Rest",
	States = {
		Rest = {
			Enter = function(agent: VluxyAI.Agent)
				agent:Stop()
				agent:StartTimer("Rest", agent.Data.Random:NextNumber(1, 4))
			end,
			Transitions = {
				{ To = "Haunt", When = seesSomeone },
				{
					To = "Drift",
					When = function(agent: VluxyAI.Agent)
						return agent:TimerDone("Rest")
					end,
				},
			},
		},

		Drift = {
			Enter = function(agent: VluxyAI.Agent)
				agent:SetSpeed(DRIFT_SPEED)
				agent:StartTimer("Drift", DRIFT_TIMEOUT)
				agent:MoveTo(Map.RandomPoint(agent.Data.Map, agent.Data.Random))
			end,
			Transitions = {
				{ To = "Haunt", When = seesSomeone },
				{
					To = "Rest",
					When = function(agent: VluxyAI.Agent)
						local status = agent:GetPathStatus()
						return status == "Arrived" or status == "Failed" or agent:TimerDone("Drift")
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
		:UsePathfinder(VluxyAI.Pathfinders.Navmesh.new())
		:UseMover(VluxyAI.Movers.CFrame.new(model, { Speed = DRIFT_SPEED, HeightOffset = 3.5, TurnSpeed = 6 }))
		:AddSense(VluxyAI.Senses.Sight.new({ Range = 35, FieldOfView = 360, Memory = 2 }))
		:SetData({ Map = context.Map, Random = context.Random })
		:Build()
end

return Ghost :: Context.Enemy
