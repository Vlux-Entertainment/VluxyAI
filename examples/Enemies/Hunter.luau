--!strict

--[[
	Hunter: like the Stalker, but with several players in view it chooses which one to chase by
	utility scoring: closer is better, hurt is better, and the player it already chases gets a
	bonus so it does not flip-flop. Shows Utility choosing a target while transitions still
	choose the mode.

	Blackboard (from Sight and Proximity): SeenTargets, SeenPosition, NearestDistance.
	Data: Target (the chosen root), AttackUntil.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Context = require(script.Parent.Parent.Context)
local VluxyAI = require(ReplicatedStorage.Packages.VluxyAI)

local Curves = VluxyAI.Utility.Curves

local ATTACK_RANGE = 4
local ATTACK_DAMAGE = 15
local ATTACK_COOLDOWN = 1.2

local function healthOf(root: BasePart): number
	local character = root:FindFirstAncestorOfClass("Model")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return if humanoid then humanoid.Health else 100
end

local considerations: { VluxyAI.Consideration<BasePart> } = {
	-- Closer scores higher, and sharply so.
	{
		Input = function(agent, root)
			return (root.Position - agent:GetPosition()).Magnitude
		end,
		Max = 60,
		Invert = true,
		Curve = Curves.Quadratic,
	},
	-- Hurt players are easier prey. Never below 0.3 so health alone cannot veto.
	{
		Input = function(_agent: VluxyAI.Agent, root: BasePart)
			return healthOf(root)
		end,
		Max = 100,
		Invert = true,
		Curve = function(x)
			return 0.3 + 0.7 * x
		end,
	},
	-- Stick with the current target unless someone is clearly better.
	{
		Input = function(agent, root)
			return if agent.Data.Target == root then 1 else 0.6
		end,
	},
}

local function targetInReach(agent: VluxyAI.Agent): boolean
	local target = agent.Data.Target :: BasePart?
	return target ~= nil and (target.Position - agent:GetPosition()).Magnitude <= ATTACK_RANGE
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
				agent.Data.AttackUntil = os.clock() + ATTACK_COOLDOWN

				local target = agent.Data.Target :: BasePart
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
				return "Hunt"
			end,
		},
	},
}

local function Hunter(model: Model, _context: Context.Context): VluxyAI.Agent
	return VluxyAI.new(model)
		:SetName("Hunter")
		:UseBrain(Brain)
		:UsePathfinder(VluxyAI.Pathfinders.Ladder.new({
			VluxyAI.Pathfinders.Straight.new({ Radius = 2, Height = 5 }),
			VluxyAI.Pathfinders.Navmesh.new({ AgentRadius = 2, AgentHeight = 5 }),
		}))
		:UseMover(VluxyAI.Movers.Humanoid.new(model, { Speed = 13 }))
		:AddSense(VluxyAI.Senses.Sight.new({ Range = 50, FieldOfView = 140, Memory = 3 }))
		:AddSense(VluxyAI.Senses.Proximity.new({ Range = 60 }))
		:SetNavigation({ RepathInterval = 0.25, ArriveDistance = 2 })
		:Build()
end

return Hunter :: Context.Enemy
