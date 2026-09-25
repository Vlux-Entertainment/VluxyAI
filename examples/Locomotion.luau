--!strict

--[[
	Animation for the example rigs, through the package's Animator. Blends the default R15 idle
	and walk from how fast the rig is actually moving, measured from its root each frame, so it
	works for the Humanoid mover and the CFrame mover alike. Exposes the animator on
	`agent.Data.Animator` so a state can play the one-shot Attack.

	This is example code: which animations belong to which state is content, and a game wires it
	the way it likes. The package only ships the Animator.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local VluxyAI = require(ReplicatedStorage.Packages.VluxyAI)

-- Roblox's own R15 animations, so the playground depends on no uploaded asset.
local ANIMATIONS: { [string]: VluxyAI.AnimationInfo } = {
	Idle = { Id = 507766666, Weighted = true, Priority = Enum.AnimationPriority.Idle },
	Walk = { Id = 507777826, Weighted = true, Priority = Enum.AnimationPriority.Movement },
	Attack = { Id = 522635514, Weighted = false, Priority = Enum.AnimationPriority.Action },
}

-- The walk cycle is authored for this speed; faster rigs play it faster.
local WALK_ANIMATION_SPEED = 16
local MOVING_THRESHOLD = 0.5

local Locomotion = {}

--[[
	Loads the animations on the agent's rig and keeps idle and walk blended until the agent is
	destroyed. Returns the animator, also stored at `agent.Data.Animator`.
]]
function Locomotion.Attach(agent: VluxyAI.Agent): VluxyAI.Animator
	local animator = VluxyAI.Animator.new(agent.Entity, ANIMATIONS):Load()
	agent.Data.Animator = animator

	local root = agent.Entity.PrimaryPart :: BasePart
	local walk = animator:GetTrack("Walk")
	local lastPosition = root.Position

	local connection = RunService.Heartbeat:Connect(function(deltaTime: number)
		local position = root.Position
		local offset = position - lastPosition
		lastPosition = position

		local speed = Vector3.new(offset.X, 0, offset.Z).Magnitude / math.max(deltaTime, 1e-4)
		local moving = speed > MOVING_THRESHOLD

		animator:SetWeight("Walk", if moving then 1 else 0, 0.15)
		animator:SetWeight("Idle", if moving then 0 else 1, 0.15)
		if moving then
			walk:AdjustSpeed(speed / WALK_ANIMATION_SPEED)
		end
	end)

	agent.Destroyed:Once(function()
		connection:Disconnect()
		animator:Destroy()
		agent.Data.Animator = nil
	end)

	return animator
end

--[[
	Plays the attack one-shot if the agent has an animator. States call this so they work with
	or without Locomotion attached.
]]
function Locomotion.PlayAttack(agent: VluxyAI.Agent)
	local animator = agent.Data.Animator
	if animator then
		animator:Play("Attack")
	end
end

return Locomotion
