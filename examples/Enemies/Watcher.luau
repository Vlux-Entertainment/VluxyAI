--!strict

--[[
	Watcher: the weeping angel. It never patrols. Once it has spotted you it only moves while
	nobody is looking at it, freezes the instant anyone is, and strikes when it gets close. If it
	loses you for long enough it goes dormant again. Shows the Watched sense (the sight check
	run from the players' side) and the CFrame mover halting instantly.

	Blackboard (from Sight, Watched, Proximity): SeenTarget, SeenPosition, IsWatched,
	NearestTarget, NearestDistance.
	Data: AttackUntil.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Context = require(script.Parent.Parent.Context)
local VluxyAI = require(ReplicatedStorage.Packages.VluxyAI)

local ATTACK_RANGE = 3.5
local ATTACK_DAMAGE = 35
local ATTACK_COOLDOWN = 1.5

local function seesSomeone(agent: VluxyAI.Agent): boolean
	return agent.Blackboard.SeenTarget ~= nil
end

local function forgot(agent: VluxyAI.Agent): boolean
	return agent.Blackboard.SeenPosition == nil
end

local function watched(agent: VluxyAI.Agent): boolean
	return agent.Blackboard.IsWatched == true
end

local function inReach(agent: VluxyAI.Agent): boolean
	return agent.Blackboard.NearestDistance <= ATTACK_RANGE
end

local Brain: VluxyAI.Brain = {
	Initial = "Dormant",
	States = {
		Dormant = {
			Enter = function(agent: VluxyAI.Agent)
				agent:Stop()
			end,
			Transitions = {
				{ To = "Aware", When = seesSomeone },
			},
		},

		Aware = {
			Enter = function(agent: VluxyAI.Agent)
				agent:Stop()
			end,
			Transitions = {
				{ To = "Dormant", When = forgot },
				{ To = "Attack", When = inReach },
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
				{ To = "Aware", When = watched },
				{ To = "Dormant", When = forgot },
				{ To = "Attack", When = inReach },
			},
			Update = function(agent: VluxyAI.Agent)
				agent:MoveTo(agent.Blackboard.SeenPosition)
				return nil
			end,
		},

		Attack = {
			Enter = function(agent: VluxyAI.Agent)
				agent:Stop()
				agent.Data.AttackUntil = os.clock() + ATTACK_COOLDOWN

				local target = agent.Blackboard.NearestTarget :: BasePart?
				local character = target and target:FindFirstAncestorOfClass("Model")
				local humanoid = character and character:FindFirstChildOfClass("Humanoid")
				if humanoid then
					humanoid:TakeDamage(ATTACK_DAMAGE)
				end
			end,
			Transitions = {
				{
					To = "Aware",
					When = function(agent: VluxyAI.Agent)
						return os.clock() >= agent.Data.AttackUntil
					end,
				},
			},
		},
	},
}

local function Watcher(model: Model, _context: Context.Context): VluxyAI.Agent
	return VluxyAI.new(model)
		:SetName("Watcher")
		:UseBrain(Brain)
		:UsePathfinder(VluxyAI.Pathfinders.Ladder.new({
			VluxyAI.Pathfinders.Straight.new({ Radius = 2, Height = 5 }),
			VluxyAI.Pathfinders.Navmesh.new({ AgentRadius = 2, AgentHeight = 5 }),
		}))
		:UseMover(VluxyAI.Movers.CFrame.new(model, { Speed = 16, HeightOffset = 2.5, TurnSpeed = 20 }))
		:AddSense(VluxyAI.Senses.Sight.new({ Range = 60, FieldOfView = 360, Memory = 8 }))
		:AddSense(VluxyAI.Senses.Watched.new({ Range = 80, FieldOfView = 100 }))
		:AddSense(VluxyAI.Senses.Proximity.new({ Range = 20 }))
		:SetTick(0.05)
		:SetNavigation({ RepathInterval = 0.2, ArriveDistance = 1.5 })
		:Build()
end

return Watcher :: Context.Enemy
