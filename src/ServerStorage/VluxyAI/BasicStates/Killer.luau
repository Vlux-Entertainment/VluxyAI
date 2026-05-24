--!strict

local VluxyAI = script.Parent.Parent

local NPCAnimator = require(VluxyAI.Animator.NPCAnimator)
local SPSMBuilder = require(VluxyAI.AIBuilder)

------------------------------------------------------------------------------------------------------------------------

local animationInfo = {
	Idle = { ID = 0, WEIGHTED = true, PRIORITY = Enum.AnimationPriority.Idle } :: NPCAnimator.ANIMATION_INFO,
	Walk = { ID = 0, WEIGHTED = true, PRIORITY = Enum.AnimationPriority.Movement } :: NPCAnimator.ANIMATION_INFO,
	Run = { ID = 0, WEIGHTED = true, PRIORITY = Enum.AnimationPriority.Movement } :: NPCAnimator.ANIMATION_INFO,
}

type NPCAnimator = typeof(NPCAnimator.new(Instance.new("Model"), animationInfo))

------------------------------------------------------------------------------------------------------------------------

type States = {
	Init: SPSMBuilder.State<self>,
	Idle: SPSMBuilder.State<self>,
	Target: SPSMBuilder.State<self>,
}

type self = SPSMBuilder.StandardStater & {
	states: States,
	animator: NPCAnimator,
	data: {},
}

------------------------------------------------------------------------------------------------------------------------

local States = {
	Init = {},
	Idle = {},
	Target = {},
} :: States

------------------------------------------------------------------------------------------------------------------------

function States.Init.Start(self)
	self.fallbackState = "Idle"

	--pathfinding setup
	self.pathfinder:SetAgentSettings({
		AgentRadius = 2,
		WaypointSpacing = 2,
	})

	self.pathfinder:SetPathSettings({
		EntitySpeed = 8,
		VisualizePath = true,
		PathingUpdateSpeed = 0.25,
		PredictTargetPosition = false,
		ShaveDownWaypoints = true,
	})

	--animation setup
	self.animator = NPCAnimator.new(self.entity, animationInfo)
	self._cleaner:Add(self.animator._cleaner)
	self.animator:Build()
end

function States.Init.Update(self)
	return self.fallbackState
end

------------------------------------------------------------------------------------------------------------------------

function States.Idle.Start(self)
	print("Starting Idle State")

	self.pathfinder:Toggle(false)
end

function States.Idle.Update(self)
	print("Updating Idle State")

	local player, _dist = self.targetingBaseAgent:NearestPlayerInBounds(15)

	if player then
		local root = self.targetingBaseAgent:GetAliveRootFromPlayer(player)
		if not root then
			return nil
		end
		local isSpotted = self.perceptionAgent:AgentSeesPosition(root.Position)
		if not isSpotted then
			return nil
		end

		self.perceptionAgent:SetTarget(root)

		return "Target"
	else
		return nil
	end
end

------------------------------------------------------------------------------------------------------------------------

function States.Target.Start(self)
	print("Starting Target State")

	self.pathfinder:Toggle(true)
end

function States.Target.Update(self)
	if not self.perceptionAgent._target then
		return "Idle"
	end

	if not self.perceptionAgent:AgentSeesTarget() then
		return "Idle"
	end

	self.pathfinder:MoveTo(self.perceptionAgent._target.Position)

	return nil
end

function States.Target.End(self)
	print("Ending Target State")

	self.pathfinder:Toggle(false)
end

------------------------------------------------------------------------------------------------------------------------

return States
