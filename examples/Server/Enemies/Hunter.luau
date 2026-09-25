--!strict

--[[
	Hunter: the utility-scoring predator. It roams between the map's nodes, choosing the next one
	by score (far from here, not visited lately), and with players in view chooses which one to
	chase by score (close, hurt, and the one it already chases). It sprints while hunting, tires,
	and has to rest; stamina comes from a custom sense written right here, in a dozen lines, that
	watches how fast the rig is moving.

	Shows: Utility.Weighted for destinations and Utility.Best for targets while transitions still
	choose the mode, a custom sense, Proximity for the reach check, and a cheap property of the
	candidate (its health) read by a consideration.

	Blackboard (from Sight, Proximity, Stamina): SeenTargets, SeenPosition, NearestTarget,
	NearestDistance, Stamina. Data: Nodes, VisitedAt, Target, Random. Timers: Attack.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Context = require(script.Parent.Parent.Context)
local VluxyAI = require(ReplicatedStorage.Packages.VluxyAI)

local Curves = VluxyAI.Utility.Curves

local ROAM_SPEED = 9
local HUNT_SPEED = 18
local ATTACK_RANGE = 4
local STAMINA_DRAIN = 0.12 -- per second while sprinting
local STAMINA_REGEN = 0.2 -- per second otherwise

------------------------------------------------------------------------------------------------------------------------

--[[
	A custom sense: writes `Stamina` in [0, 1], draining while the rig moves faster than a walk
	and recovering otherwise. A sense is anything with Tick; this one needs no options.
]]
local Stamina = {}
Stamina.__index = Stamina

-- A built-in sense would take these thresholds through Options.Resolve; this one reads the
-- module's constants to stay a dozen lines. Do that only for a sense that lives with its brain.
function Stamina.new(): VluxyAI.Sense
	return setmetatable({ _last = nil :: Vector3? }, Stamina) :: any
end

function Stamina.Tick(self: any, agent: VluxyAI.Agent, deltaTime: number)
	local position = agent:GetPosition()
	local speed = if self._last then (position - self._last).Magnitude / math.max(deltaTime, 1e-4) else 0
	self._last = position

	local stamina = agent.Blackboard.Stamina or 1
	if speed > ROAM_SPEED + 1 then
		stamina -= STAMINA_DRAIN * deltaTime
	else
		stamina += STAMINA_REGEN * deltaTime
	end
	agent.Blackboard.Stamina = math.clamp(stamina, 0, 1)
end

------------------------------------------------------------------------------------------------------------------------

-- Which node to roam to next: prefer far ones and ones not visited for a while.
local roamConsiderations: { VluxyAI.Consideration<Vector3> } = {
	{
		Input = function(agent: VluxyAI.Agent, node: Vector3)
			return (node - agent:GetPosition()).Magnitude
		end,
		Max = 80,
		Curve = Curves.SquareRoot,
	},
	{
		Input = function(agent: VluxyAI.Agent, node: Vector3)
			local visitedAt = agent.Data.VisitedAt[node]
			return if visitedAt then os.clock() - visitedAt else 60
		end,
		Max = 60,
		Curve = Curves.Quadratic,
	},
}

-- Which player to chase: close, hurt, and sticky to the current choice.
local chaseConsiderations: { VluxyAI.Consideration<BasePart> } = {
	{
		Input = function(agent: VluxyAI.Agent, root: BasePart)
			return (root.Position - agent:GetPosition()).Magnitude
		end,
		Max = 60,
		Invert = true,
		Curve = Curves.Quadratic,
	},
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
	{
		Input = function(agent: VluxyAI.Agent, root: BasePart)
			return if agent.Data.Target == root then 1 else 0.6
		end,
	},
}

local function seesSomeone(agent: VluxyAI.Agent): boolean
	return #agent.Blackboard.SeenTargets > 0
end

local function exhausted(agent: VluxyAI.Agent): boolean
	return agent.Blackboard.Stamina <= 0
end

local function rested(agent: VluxyAI.Agent): boolean
	return agent.Blackboard.Stamina >= 0.8
end

local function targetInReach(agent: VluxyAI.Agent): boolean
	local blackboard = agent.Blackboard
	return agent.Data.Target ~= nil
		and blackboard.NearestTarget == agent.Data.Target
		and blackboard.NearestDistance <= ATTACK_RANGE
end

local Brain: VluxyAI.Brain = {
	Initial = "Roam",
	States = {
		Roam = {
			Enter = function(agent: VluxyAI.Agent)
				agent:SetSpeed(ROAM_SPEED)
				agent.Data.Target = nil
				local node = VluxyAI.Utility.Weighted(agent, agent.Data.Nodes, roamConsiderations, agent.Data.Random)
				if node then
					agent.Data.Destination = node
					agent:MoveTo(node)
				end
			end,
			Transitions = {
				{
					To = "Hunt",
					When = function(agent: VluxyAI.Agent)
						return seesSomeone(agent) and agent.Blackboard.Stamina > 0.3
					end,
				},
				-- Re-enter to pick the next node.
				{
					To = "Roam",
					When = function(agent: VluxyAI.Agent)
						local status = agent:GetPathStatus()
						if status == "Arrived" and agent.Data.Destination then
							agent.Data.VisitedAt[agent.Data.Destination] = os.clock()
						end
						return status == "Arrived" or status == "Failed"
					end,
				},
			},
		},

		Hunt = {
			Enter = function(agent: VluxyAI.Agent)
				agent:SetSpeed(HUNT_SPEED)
			end,
			Transitions = {
				{ To = "Attack", When = targetInReach },
				{ To = "Rest", When = exhausted },
				{
					To = "Roam",
					When = function(agent: VluxyAI.Agent)
						return agent.Blackboard.SeenPosition == nil
					end,
				},
			},
			Update = function(agent: VluxyAI.Agent)
				local visible = agent.Blackboard.SeenTargets :: { BasePart }
				local chosen = VluxyAI.Utility.Best(agent, visible, chaseConsiderations)

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

		Rest = {
			Enter = function(agent: VluxyAI.Agent)
				agent:Stop()
				agent.Data.Target = nil
			end,
			Transitions = {
				{ To = "Roam", When = rested },
			},
		},

		Attack = VluxyAI.Combat.Attack.State({
			Damage = 15,
			Cooldown = 1.2,
			TargetKey = "NearestTarget",
			Then = "Hunt",
		}),
	},
}

local function Hunter(model: Model, context: Context.Context): VluxyAI.Agent
	return VluxyAI.new(model)
		:SetName("Hunter")
		:UseBrain(Brain)
		:UsePathfinder(VluxyAI.Pathfinders.Ladder.new({
			VluxyAI.Pathfinders.Straight.new(),
			VluxyAI.Pathfinders.Navmesh.new(),
		}))
		:UseMover(VluxyAI.Movers.Humanoid.new(model, { Speed = ROAM_SPEED }))
		:AddSense(VluxyAI.Senses.Sight.new({ Range = 50, FieldOfView = 140, Memory = 3 }))
		:AddSense(VluxyAI.Senses.Proximity.new({ Range = 60 }))
		:AddSense(Stamina.new())
		:SetBlackboard({ Stamina = 1 })
		:SetData({ Nodes = context.Map.PatrolNodes, VisitedAt = {}, Random = context.Random })
		:SetNavigation({ RepathInterval = 0.25 })
		:Build()
end

return Hunter :: Context.Enemy
