--!strict

--[[
	Stalker: stands still until it sees a player, chases the last place it saw them, and hits
	when close with a clear line. Shows the Sight sense writing the blackboard, declarative
	transitions choosing the mode, and the Ladder pathfinder trying a straight line before the
	navmesh.

	Blackboard (from Sight): SeenTarget, SeenDistance, SeenPosition, SeenAt.
	Data: AttackUntil (cooldown end).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Context = require(script.Parent.Parent.Context)
local VluxyAI = require(ReplicatedStorage.Packages.VluxyAI)

local ATTACK_RANGE = 4
local ATTACK_DAMAGE = 10
local ATTACK_COOLDOWN = 1

local function canAttack(agent: VluxyAI.Agent): boolean
	local blackboard = agent.Blackboard
	return blackboard.SeenTarget ~= nil and blackboard.SeenDistance <= ATTACK_RANGE
end

local Brain: VluxyAI.Brain = {
	Initial = "Idle",
	States = {
		Idle = {
			Enter = function(agent: VluxyAI.Agent)
				agent:Stop()
			end,
			Transitions = {
				{
					To = "Chase",
					When = function(agent: VluxyAI.Agent)
						return agent.Blackboard.SeenTarget ~= nil
					end,
				},
			},
		},

		Chase = {
			Transitions = {
				{ To = "Attack", When = canAttack },
				{
					To = "Idle",
					When = function(agent: VluxyAI.Agent)
						return agent.Blackboard.SeenPosition == nil
					end,
				},
			},
			Update = function(agent: VluxyAI.Agent)
				-- SeenPosition lingers for Sight's Memory after the target is lost, so the stalker
				-- runs to where it last saw them before giving up.
				agent:MoveTo(agent.Blackboard.SeenPosition)
				return nil
			end,
		},

		Attack = {
			Enter = function(agent: VluxyAI.Agent)
				agent:Stop()
				agent.Data.AttackUntil = os.clock() + ATTACK_COOLDOWN

				local target = agent.Blackboard.SeenTarget :: BasePart
				local character = target:FindFirstAncestorOfClass("Model")
				local humanoid = character and character:FindFirstChildOfClass("Humanoid")
				if humanoid then
					humanoid:TakeDamage(ATTACK_DAMAGE)
				end
			end,
			Update = function(agent: VluxyAI.Agent)
				if os.clock() < agent.Data.AttackUntil then
					return nil
				end
				return if agent.Blackboard.SeenTarget then "Chase" else "Idle"
			end,
		},
	},
}

local function Stalker(model: Model, _context: Context.Context): VluxyAI.Agent
	return VluxyAI.new(model)
		:SetName("Stalker")
		:UseBrain(Brain)
		:UsePathfinder(VluxyAI.Pathfinders.Ladder.new({
			VluxyAI.Pathfinders.Straight.new({ Radius = 2, Height = 5 }),
			VluxyAI.Pathfinders.Navmesh.new({ AgentRadius = 2, AgentHeight = 5 }),
		}))
		:UseMover(VluxyAI.Movers.Humanoid.new(model, { Speed = 14 }))
		:AddSense(VluxyAI.Senses.Sight.new({ Range = 45, FieldOfView = 120, Memory = 4 }))
		:SetNavigation({ RepathInterval = 0.25, ArriveDistance = 2 })
		:Build()
end

return Stalker :: Context.Enemy
