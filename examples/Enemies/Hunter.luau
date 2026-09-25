--!strict

--[[
	Hunter: like the Stalker, but with several players in view it chooses which one to chase by
	utility scoring: closer is better, hurt is better, and the player it already chases gets a
	bonus so it does not flip-flop. Shows Utility choosing a target while transitions still
	choose the mode, and Proximity supplying the reach check.

	Considerations read the blackboard and cheap properties of the candidate itself (its position,
	its health); they never raycast. That is the line: the world is sampled by senses, and a
	candidate is inspected by the code that has to rank it.

	Blackboard (from Sight and Proximity): SeenTargets, SeenPosition, NearestTarget, NearestDistance.
	Data: Target (the chosen root). Timers: Attack.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Context = require(script.Parent.Parent.Context)
local Locomotion = require(script.Parent.Parent.Locomotion)
local VluxyAI = require(ReplicatedStorage.Packages.VluxyAI)

local Curves = VluxyAI.Utility.Curves

local ATTACK_RANGE = 4
local ATTACK_DAMAGE = 15
local ATTACK_COOLDOWN = 1.2

local considerations: { VluxyAI.Consideration<BasePart> } = {
	-- Closer scores higher, and sharply so.
	{
		Input = function(agent: VluxyAI.Agent, root: BasePart)
			return (root.Position - agent:GetPosition()).Magnitude
		end,
		Max = 60,
		Invert = true,
		Curve = Curves.Quadratic,
	},
	-- Hurt players are easier prey. Never below 0.3 so health alone cannot veto.
	{
		Input = function(_agent: VluxyAI.Agent, root: BasePart)
			local humanoid = VluxyAI.Perception.HumanoidOf(root)
			return if humanoid then humanoid.Health else 100
		end,
		Max = 100,
		Invert = true,
		Curve = function(x)
			return 0.3 + 0.7 * x
		end,
	},
	-- Stick with the current target unless someone is clearly better.
	{
		Input = function(agent: VluxyAI.Agent, root: BasePart)
			return if agent.Data.Target == root then 1 else 0.6
		end,
	},
}

-- The chosen target is the nearest thing and it is within reach.
local function targetInReach(agent: VluxyAI.Agent): boolean
	local blackboard = agent.Blackboard
	return agent.Data.Target ~= nil
		and blackboard.NearestTarget == agent.Data.Target
		and blackboard.NearestDistance <= ATTACK_RANGE
end

local Brain: VluxyAI.Brain = {
	Initial = "Idle",
	States = {
		Idle = {
			Enter = function(agent: VluxyAI.Agent)
				agent:Stop()
				agent.Data.Target = nil
			end,
			Transitions = {
				{
					To = "Hunt",
					When = function(agent: VluxyAI.Agent)
						return #agent.Blackboard.SeenTargets > 0
					end,
				},
			},
		},

		Hunt = {
			Transitions = {
				{ To = "Attack", When = targetInReach },
				{
					To = "Idle",
					When = function(agent: VluxyAI.Agent)
						return agent.Blackboard.SeenPosition == nil
					end,
				},
			},
			Update = function(agent: VluxyAI.Agent)
				local visible = agent.Blackboard.SeenTargets :: { BasePart }
				local chosen = VluxyAI.Utility.Best(agent, visible, considerations)

				if chosen then
					agent.Data.Target = chosen
					agent:MoveTo(chosen.Position)
				else
					-- Nobody visible: head for the last sighting until Sight forgets it.
					agent:MoveTo(agent.Blackboard.SeenPosition)
				end
				return nil
			end,
		},

		Attack = {
			Enter = function(agent: VluxyAI.Agent)
				agent:Stop()
				agent:StartTimer("Attack", ATTACK_COOLDOWN)
				Locomotion.PlayAttack(agent)

				local humanoid = VluxyAI.Perception.HumanoidOf(agent.Data.Target)
				if humanoid then
					humanoid:TakeDamage(ATTACK_DAMAGE)
				end
			end,
			Transitions = {
				{
					To = "Hunt",
					When = function(agent: VluxyAI.Agent)
						return agent:TimerDone("Attack")
					end,
				},
			},
		},
	},
}

local function Hunter(model: Model, _context: Context.Context): VluxyAI.Agent
	return VluxyAI.new(model)
		:SetName("Hunter")
		:UseBrain(Brain)
		:UsePathfinder(VluxyAI.Pathfinders.Ladder.new({
			VluxyAI.Pathfinders.Straight.new(),
			VluxyAI.Pathfinders.Navmesh.new(),
		}))
		:UseMover(VluxyAI.Movers.Humanoid.new(model, { Speed = 13 }))
		:AddSense(VluxyAI.Senses.Sight.new({ Range = 50, FieldOfView = 140, Memory = 3 }))
		:AddSense(VluxyAI.Senses.Proximity.new({ Range = 60 }))
		:SetNavigation({ RepathInterval = 0.25 })
		:Build()
end

return Hunter :: Context.Enemy
