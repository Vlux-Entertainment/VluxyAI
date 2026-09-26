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

	Blackboard (from Sight, Proximity, Stamina): SeenTargets, SeenPosition, PredictedPosition, NearestTarget,
	NearestDistance, Stamina. Data: Nodes, VisitedAt, Target, LastSeen, Random. Timers: Attack, States.Search.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Context = require(script.Parent.Parent.Context)
local VluxyAI = require(ReplicatedStorage.Packages.VluxyAI)

local Curves = VluxyAI.Utility.Curves
local States = VluxyAI.States

local ROAM_SPEED = 9
-- Outruns a walking player (16) but not a sprinting one (24), and tires after about eight seconds.
local HUNT_SPEED = 20
local ATTACK_RANGE = 4
-- After losing sight: search around where the target was heading before going back to roaming.
local SEARCH_RADIUS = 16
local SEARCH_POINTS = 3
local SEARCH_TIME = 10
-- A player this close is noticed whichever way it faces, so creeping up behind it does not work.
local NOTICE_RADIUS = 10
local STAMINA_DRAIN = 0.07 -- per second while sprinting: about fourteen seconds from full
local STAMINA_REGEN = 0.2 -- per second otherwise

------------------------------------------------------------------------------------------------------------------------

------------------------------------------------------------------------------------------------------------------------

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

local function readyToHunt(agent: VluxyAI.Agent): boolean
	return seesSomeone(agent) and agent.Blackboard.Stamina > 0.3
end

local function exhausted(agent: VluxyAI.Agent): boolean
	return agent.Blackboard.Stamina <= 0
end

local function rested(agent: VluxyAI.Agent): boolean
	return agent.Blackboard.Stamina >= 0.8
end

-- Lost: nobody in view, and it has reached where they were heading (or cannot get there).
local function lostThem(agent: VluxyAI.Agent): boolean
	local status = agent:GetPathStatus()
	return #agent.Blackboard.SeenTargets == 0
		and (agent.Blackboard.SeenPosition == nil or status == "Arrived" or status == "Failed")
end

-- The one it was chasing just got into a safe room, or it sees someone in one and has not just
-- stood and stared at them.
local safeSighted = VluxyAI.When.SafeSighted()

local function targetInReach(agent: VluxyAI.Agent): boolean
	local blackboard = agent.Blackboard
	return agent.Data.Target ~= nil
		and blackboard.NearestTarget == agent.Data.Target
		and blackboard.NearestDistance <= ATTACK_RANGE
end

local Brain: VluxyAI.Brain = {
	Initial = "Roam",
	States = {
		-- Looking for you: the warmest cell of the shared map it has not just checked.
		Roam = States.Roam({
			Interest = "Interest",
			Speed = ROAM_SPEED,
			Linger = { 0.3, 1 },
			-- A fifth of its picks ignore the clues, so it is not perfectly predictable.
			Stray = 0.2,
			Enter = function(agent: VluxyAI.Agent)
				agent.Data.Target = nil
			end,
			Transitions = {
				{ To = "Stare", When = safeSighted },
				{ To = "Hunt", When = readyToHunt },
				{ To = "Investigate", When = VluxyAI.When.New("HeardAt") },
			},
		}),

		-- A footstep or a door: go and look, then back to searching.
		Investigate = States.Investigate({
			Target = "HeardPosition",
			Speed = ROAM_SPEED + 1,
			Then = "Roam",
			Transitions = {
				{ To = "Stare", When = safeSighted },
				{ To = "Hunt", When = readyToHunt },
			},
		}),

		Hunt = {
			Enter = function(agent: VluxyAI.Agent)
				agent:SetSpeed(HUNT_SPEED)
			end,
			Transitions = {
				{ To = "Attack", When = targetInReach },
				{ To = "Stare", When = safeSighted },
				{ To = "Rest", When = exhausted },
				{ To = "Search", When = lostThem },
			},
			Update = function(agent: VluxyAI.Agent)
				local visible = agent.Blackboard.SeenTargets :: { BasePart }
				local chosen = VluxyAI.Utility.Best(agent, visible, chaseConsiderations)

				-- Where they are, or where they were heading: Sight carries the last sighting forward
				-- along their velocity, so the chase follows them round the corner.
				local heading = agent.Blackboard.PredictedPosition or agent.Blackboard.SeenPosition
				if heading then
					agent.Data.LastSeen = heading
				end
				if chosen then
					agent.Data.Target = chosen
					agent:MoveTo(chosen.Position)
				elseif heading then
					agent:MoveTo(heading)
				end
				return nil
			end,
		},

		Search = States.Search({
			Around = "LastSeen",
			Radius = SEARCH_RADIUS,
			Points = SEARCH_POINTS,
			Duration = SEARCH_TIME,
			-- Brisk but not a sprint: faster than ROAM_SPEED + 1 would drain stamina.
			Speed = ROAM_SPEED + 1,
			Then = "Roam",
			Transitions = {
				{ To = "Stare", When = safeSighted },
				{
					To = "Hunt",
					When = function(agent: VluxyAI.Agent)
						return seesSomeone(agent) and agent.Blackboard.Stamina > 0.3
					end,
				},
			},
		}),

		-- Its prey reached a safe room: stand there a moment, then back to roaming as normal, unless
		-- they step back out where it can see them.
		Stare = States.Stare({
			Target = "SafePosition",
			Duration = 4,
			Cooldown = 20,
			Then = "Roam",
			Transitions = { { To = "Hunt", When = readyToHunt } },
		}),

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
	return VluxyAI
		.Presets
		.Humanoid(model, {
			Graph = context.Graph,
			Doors = true,
			Mover = { Speed = ROAM_SPEED },
			Sight = { Range = 50, FieldOfView = 160, Memory = 8, Predict = 3, NoticeRadius = NOTICE_RADIUS },
			Proximity = { Range = 60 },
		})
		:SetName("Hunter")
		:UseBrain(Brain)
		-- Tires when it sprints: anything faster than a roam drains the meter.
		:AddSense(
			VluxyAI.Senses.Stamina.new({ Threshold = ROAM_SPEED + 1, Drain = STAMINA_DRAIN, Regen = STAMINA_REGEN })
		)
		-- It hears footsteps and doors too, and every sighting warms the shared clue map.
		:AddSense(
			VluxyAI.Senses.Hearing.new(context.Noises, { Range = 40, Memory = 6 })
		)
		:AddSense(VluxyAI.Senses.Clues.new(context.Interest))
		-- Low groans while it searches, growls on the hunt, heavy groans while it rests.
		:AddSense(
			VluxyAI.Voice.new({
				Lines = {
					Roam = { 93710802942553, 9113636490 },
					Hunt = { 129294628821291, 130156156621885, 105926319962443 },
					Rest = { 9113636491, 9113636681 },
					Stare = { 133090070543313 },
				},
				Interval = { 5, 12 },
				OnEnter = { Hunt = 0.8, Stare = 1, ["*"] = 0.2 },
				Volume = 0.56,
			})
		)
		:AddSense(context.Crowd)
		:SetBlackboard({ Stamina = 1 })
		:SetData({ Interest = context.Interest, Random = context.Random })
		:Build()
end

return Hunter :: Context.Enemy
