--!strict

--[[
	Stalker: stands still until it sees a player, chases the last place it saw them, and hits
	when close with a clear line. Shows the Sight sense writing the blackboard, declarative
	transitions choosing the mode, and the Ladder pathfinder trying a straight line before the
	navmesh.

	Blackboard (from Sight): SeenTarget, SeenDistance, SeenPosition.
	Timers: Attack (the cooldown).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Context = require(script.Parent.Parent.Context)
local Locomotion = require(script.Parent.Parent.Locomotion)
local VluxyAI = require(ReplicatedStorage.Packages.VluxyAI)

local ATTACK_RANGE = 4
local ATTACK_DAMAGE = 10
local ATTACK_COOLDOWN = 1

local function seesSomeone(agent: VluxyAI.Agent): boolean
	return agent.Blackboard.SeenTarget ~= nil
end

local function forgot(agent: VluxyAI.Agent): boolean
	return agent.Blackboard.SeenPosition == nil
end

-- Sight only sees with a clear line, so SeenDistance is "close and nothing in the way".
local function inReach(agent: VluxyAI.Agent): boolean
	return agent.Blackboard.SeenDistance <= ATTACK_RANGE
end

local Brain: VluxyAI.Brain = {
	Initial = "Idle",
	States = {
		Idle = {
			Enter = function(agent: VluxyAI.Agent)
				agent:Stop()
			end,
			Transitions = {
				{ To = "Chase", When = seesSomeone },
			},
		},

		Chase = {
			Transitions = {
				{ To = "Attack", When = inReach },
				{ To = "Idle", When = forgot },
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
				agent:StartTimer("Attack", ATTACK_COOLDOWN)
				Locomotion.PlayAttack(agent)

				local humanoid = VluxyAI.Perception.HumanoidOf(agent.Blackboard.SeenTarget)
				if humanoid then
					humanoid:TakeDamage(ATTACK_DAMAGE)
				end
			end,
			Transitions = {
				{
					To = "Chase",
					When = function(agent: VluxyAI.Agent)
						return agent:TimerDone("Attack")
					end,
				},
			},
		},
	},
}

local function Stalker(model: Model, _context: Context.Context): VluxyAI.Agent
	return VluxyAI.new(model)
		:SetName("Stalker")
		:UseBrain(Brain)
		:UsePathfinder(VluxyAI.Pathfinders.Ladder.new({
			VluxyAI.Pathfinders.Straight.new(),
			VluxyAI.Pathfinders.Navmesh.new(),
		}))
		:UseMover(VluxyAI.Movers.Humanoid.new(model, { Speed = 14 }))
		:AddSense(VluxyAI.Senses.Sight.new({ Range = 45, FieldOfView = 120, Memory = 4 }))
		:SetNavigation({ RepathInterval = 0.25 })
		:Build()
end

return Stalker :: Context.Enemy
