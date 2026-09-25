--!strict

--[[
	Locomotion for an agent's rig through the Animator: idle and walk blended from how fast the
	rig is actually moving, measured from its root every frame, so it works for the Humanoid
	mover and the CFrame mover alike (a CFrame-driven rig has no Humanoid velocity to read).
	Extra one-shots (an attack, a scream) are loaded alongside and played by name.

	Everything is undone when the agent is destroyed. Which animation belongs to which state is
	still content: a state calls `Locomotion.Play(agent, "Attack")` when it wants to.
]]

local Animator = require(script.Parent)
local FormatMessage = require(script.Parent.Parent.Utility.FormatMessage)
local Options = require(script.Parent.Parent.Utility.Options)
local Types = require(script.Parent.Parent.Types)

------------------------------------------------------------------------------------------------------------------------

-- Roblox's own R15 animations, so a rig animates with no uploaded asset at all.
local DEFAULT_ANIMATIONS: { [string]: Animator.AnimationInfo } = {
	Idle = { Id = 507766666, Weighted = true, Priority = Enum.AnimationPriority.Idle },
	Walk = { Id = 507777826, Weighted = true, Priority = Enum.AnimationPriority.Movement },
	Attack = { Id = 522635514, Weighted = false, Priority = Enum.AnimationPriority.Action },
}
table.freeze(DEFAULT_ANIMATIONS)

local DEFAULT_OPTIONS = table.freeze({
	-- Studs per second the walk cycle is authored for; faster rigs play it faster.
	WalkSpeed = 16,
	-- Below this speed the rig idles.
	MovingThreshold = 0.5,
	-- Seconds to blend between idle and walk.
	Fade = 0.15,
})

--[=[
	@interface LocomotionOptions
	@within Locomotion

	.Animations { [string]: AnimationInfo }? -- Tracks to load. Must include weighted `Idle` and `Walk`. Default: Roblox's R15 idle, walk, and a one-shot `Attack` swing.
	.WalkSpeed number? -- Studs per second the walk cycle is authored for. Default `16`.
	.MovingThreshold number? -- Studs per second below which the rig idles. Default `0.5`.
	.Fade number? -- Seconds to blend idle and walk. Default `0.15`.
]=]
export type LocomotionOptions = {
	Animations: { [string]: Animator.AnimationInfo }?,
	WalkSpeed: number?,
	MovingThreshold: number?,
	Fade: number?,
}

type ResolvedOptions = {
	WalkSpeed: number,
	MovingThreshold: number,
	Fade: number,
}

local DATA_KEY = "Locomotion"

local Locomotion = {}

--[=[
	@class Locomotion

	Idle and walk for an agent's rig, blended from its real speed through the [NPCAnimator], plus
	one-shots by name. Attach after `Build()`; it goes when the agent does.

	```lua
	VluxyAI.Locomotion.Attach(agent)
	-- in a state:
	VluxyAI.Locomotion.Play(agent, "Attack")
	```
]=]

--[=[
	@within Locomotion
	@param agent Agent
	@param options LocomotionOptions?
	@return NPCAnimator -- Also kept at `agent.Data.Locomotion`.
	@error string -- The rig has no Animator, or the animations lack a weighted `Idle` or `Walk`.
]=]
function Locomotion.Attach(agent: Types.Agent, options: LocomotionOptions?): Animator.NPCAnimator
	local given = table.clone((options or {}) :: any) :: { [string]: any }
	local animations: { [string]: Animator.AnimationInfo } = given.Animations or DEFAULT_ANIMATIONS
	given.Animations = nil
	local resolved = Options.Resolve("Locomotion.Attach", DEFAULT_OPTIONS, given) :: ResolvedOptions

	for _, name in { "Idle", "Walk" } do
		local info = animations[name]
		if info == nil or not info.Weighted then
			FormatMessage.Error(`Locomotion.Attach: Animations needs a weighted "{name}"`, 2)
		end
	end

	local existing = agent.Data[DATA_KEY]
	if existing then
		if options ~= nil then
			FormatMessage.Warn(`{agent.Name}: Locomotion is already attached; the new options are ignored`)
		end
		return existing
	end
	if not agent:IsRunning() and agent:GetState() == nil and (agent :: any)._destroyed then
		FormatMessage.Error(`{agent.Name}: Locomotion.Attach on a destroyed agent`, 2)
	end
	if agent.Entity.PrimaryPart == nil then
		FormatMessage.Error(`{agent.Name}: Locomotion.Attach needs a PrimaryPart on the rig`, 2)
	end

	local animator = Animator.new(agent.Entity, animations):Load()
	agent.Data[DATA_KEY] = animator

	local RunService = game:GetService("RunService")
	local root = agent.Entity.PrimaryPart :: BasePart
	local walk = animator:GetTrack("Walk")
	local lastPosition = root.Position

	local connection = RunService.Heartbeat:Connect(function(deltaTime: number)
		local position = root.Position
		local offset = position - lastPosition
		lastPosition = position

		local speed = Vector3.new(offset.X, 0, offset.Z).Magnitude / math.max(deltaTime, 1e-4)
		local moving = speed > resolved.MovingThreshold

		animator:SetWeight("Walk", if moving then 1 else 0, resolved.Fade)
		animator:SetWeight("Idle", if moving then 0 else 1, resolved.Fade)
		if moving then
			walk:AdjustSpeed(speed / resolved.WalkSpeed)
		end
	end)

	agent.Destroyed:Once(function()
		connection:Disconnect()
		animator:Destroy()
		agent.Data[DATA_KEY] = nil
	end)

	return animator
end

--[=[
	@within Locomotion
	@param agent Agent
	@param name string -- A one-shot loaded by `Attach`.
	@return boolean -- `false` when nothing is attached or the name is unknown.

	Plays a one-shot if locomotion is attached, so a state works with or without it. An unknown
	name is warned about once per agent and returns `false`; a weighted name is an error, as it
	is on the animator.
]=]
function Locomotion.Play(agent: Types.Agent, name: string): boolean
	local animator = agent.Data[DATA_KEY] :: Animator.NPCAnimator?
	if animator == nil then
		return false
	end

	if animator:GetAnimations()[name] == nil then
		local warned = agent.Data[DATA_KEY .. "Warned"] or {}
		if not warned[name] then
			warned[name] = true
			agent.Data[DATA_KEY .. "Warned"] = warned
			FormatMessage.Warn(`{agent.Name}: Locomotion has no animation named "{name}"`)
		end
		return false
	end

	animator:Play(name)
	return true
end

--[=[
	@within Locomotion
	@param agent Agent
	@return NPCAnimator? -- What `Attach` made, if it was called.
]=]
function Locomotion.Get(agent: Types.Agent): Animator.NPCAnimator?
	return agent.Data[DATA_KEY]
end

return Locomotion
