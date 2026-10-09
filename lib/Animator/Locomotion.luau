--!strict

--[[
	Locomotion for a rig through the Animator: idle, walk and an optional run blended from how
	fast the rig is actually moving, measured from its pivot every frame, so it works for the
	Humanoid mover, the CFrame mover and a client puppet alike (the last two have no velocity to
	read). Extra one-shots (an attack, a scream) are loaded alongside and played by name.

	`Attach` ties it to an agent, `AttachReplica` to a [Replica]; everything is undone when that
	owner is destroyed. The blend itself is `Blend`, pure and specced. Which animation belongs to
	which state is still content: a state calls `Locomotion.Play(agent, "Attack")` when it wants to.
]]

local Animator = require(script.Parent)
local FormatMessage = require(script.Parent.Parent.Utility.FormatMessage)
local Options = require(script.Parent.Parent.Utility.Options)
local Replica = require(script.Parent.Parent.Sync.Replica)
local Types = require(script.Parent.Parent.Types)

------------------------------------------------------------------------------------------------------------------------

-- Animators whose tracks are held still by Freeze. Weak, so a destroyed one is not kept.
local frozen: { [any]: boolean? } = setmetatable({}, { __mode = "k" }) :: any

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
	-- Studs per second the run cycle is authored for, when there is a Run.
	RunSpeed = 24,
	-- Below this speed the rig idles.
	MovingThreshold = 0.5,
	-- Seconds to blend between tracks.
	Fade = 0.15,
	-- Seconds over which the measured speed settles, so one hitched frame does not flicker the blend.
	SpeedSmoothing = 0.1,
})

--[=[
	@interface LocomotionOptions
	@within Locomotion

	.Animations { [string]: AnimationInfo }? -- Tracks to load. Must include weighted `Idle` and `Walk`; a weighted `Run` is blended in above `WalkSpeed`. Default: Roblox's R15 idle, walk, and a one-shot `Attack` swing.
	.WalkSpeed number? -- Studs per second the walk cycle is authored for. Default `16`.
	.RunSpeed number? -- Studs per second the run cycle is authored for; between `WalkSpeed` and this the walk crossfades into the run. Only used with a `Run`. Default `24`.
	.MovingThreshold number? -- Studs per second below which the rig idles. Default `0.5`.
	.Fade number? -- Seconds to blend between tracks. Default `0.15`.
	.SpeedSmoothing number? -- Seconds over which the measured speed settles; `0` uses each frame's raw speed. Default `0.1`.
]=]
export type LocomotionOptions = {
	Animations: { [string]: Animator.AnimationInfo }?,
	WalkSpeed: number?,
	RunSpeed: number?,
	MovingThreshold: number?,
	Fade: number?,
	SpeedSmoothing: number?,
}

type ResolvedOptions = {
	WalkSpeed: number,
	RunSpeed: number,
	MovingThreshold: number,
	Fade: number,
	SpeedSmoothing: number,
}

--[=[
	@interface LocomotionBlend
	@within Locomotion

	.Idle number -- Weight of the idle track, `0` to `1`.
	.Walk number -- Weight of the walk track.
	.Run number -- Weight of the run track; `0` without a run.
	.WalkPlayback number -- Playback speed of the walk track.
	.RunPlayback number -- Playback speed of the run track.
]=]
export type LocomotionBlend = {
	Idle: number,
	Walk: number,
	Run: number,
	WalkPlayback: number,
	RunPlayback: number,
}

-- What locomotion can be attached to: both keep it in their Data.
type Owner = Types.Agent | Replica.Replica

local DATA_KEY = "Locomotion"

local Locomotion = {}

--[=[
	@class Locomotion

	Idle, walk and run for a rig, blended from its real speed through the [NPCAnimator], plus
	one-shots by name. On the server attach it to an agent after `Build()`; on the client attach
	it to a puppet [Replica]. It goes when its owner does.

	```lua
	VluxyAI.Locomotion.Attach(agent)
	-- in a state:
	VluxyAI.Locomotion.Play(agent, "Attack")

	-- client, a puppet replica:
	VluxyAI.Locomotion.AttachReplica(replica, {
		Animations = { Idle = idle, Walk = walk, Run = run },
		WalkSpeed = 10,
		RunSpeed = 22,
	})
	```
]=]

--[=[
	@within Locomotion
	@param speed number -- Studs per second along the floor.
	@param options LocomotionOptions -- `WalkSpeed`, `RunSpeed` and `MovingThreshold` are read; missing ones take their defaults.
	@param hasRun boolean -- Whether there is a run track to blend into.
	@return LocomotionBlend

	The weights and playback speeds for a speed. At or below `MovingThreshold` it idles; up to
	`WalkSpeed` it walks; with a run, the walk crossfades into the run between `WalkSpeed` and
	`RunSpeed`, and above that it runs. Each track plays at `speed` over the speed it is authored
	for. Pure.
]=]
function Locomotion.Blend(
	speed: number,
	options: { WalkSpeed: number?, RunSpeed: number?, MovingThreshold: number? },
	hasRun: boolean
): LocomotionBlend
	local walkSpeed = options.WalkSpeed or DEFAULT_OPTIONS.WalkSpeed
	local runSpeed = options.RunSpeed or DEFAULT_OPTIONS.RunSpeed
	local threshold = options.MovingThreshold or DEFAULT_OPTIONS.MovingThreshold

	local blend: LocomotionBlend =
		{ Idle = 1, Walk = 0, Run = 0, WalkPlayback = speed / walkSpeed, RunPlayback = speed / runSpeed }
	if speed <= threshold then
		return blend
	end

	blend.Idle = 0
	if not hasRun or speed <= walkSpeed then
		blend.Walk = 1
	elseif speed >= runSpeed then
		blend.Run = 1
	else
		local toward = (speed - walkSpeed) / (runSpeed - walkSpeed)
		blend.Walk = 1 - toward
		blend.Run = toward
	end
	return blend
end

--[[
	Resolves the options and checks the animations, for Attach and AttachReplica alike.
]]
local function resolve(
	owner: string,
	options: LocomotionOptions?
): ({ [string]: Animator.AnimationInfo }, ResolvedOptions)
	local given = table.clone((options or {}) :: any) :: { [string]: any }
	local animations: { [string]: Animator.AnimationInfo } = given.Animations or DEFAULT_ANIMATIONS
	given.Animations = nil
	local resolved = Options.Resolve(owner, DEFAULT_OPTIONS, given) :: ResolvedOptions

	for _, name in { "Idle", "Walk" } do
		local info = animations[name]
		if info == nil or not info.Weighted then
			FormatMessage.Error(`{owner}: Animations needs a weighted "{name}"`, 3)
		end
	end
	local run = animations.Run
	if run ~= nil and not run.Weighted then
		FormatMessage.Error(`{owner}: Animations.Run must be weighted`, 3)
	end
	if run ~= nil and resolved.RunSpeed <= resolved.WalkSpeed then
		FormatMessage.Error(`{owner}: RunSpeed must be above WalkSpeed`, 3)
	end
	return animations, resolved
end

--[[
	Loads the animator and blends it every Heartbeat from the pivot's measured, smoothed speed.
]]
local function drive(
	rig: Model,
	animations: { [string]: Animator.AnimationInfo },
	resolved: ResolvedOptions
): (Animator.NPCAnimator, RBXScriptConnection)
	local animator = Animator.new(rig, animations):Load()
	local hasRun = animations.Run ~= nil
	local walk = animator:GetTrack("Walk")
	local run = if hasRun then animator:GetTrack("Run") else nil

	local RunService = game:GetService("RunService")
	local lastPosition = rig:GetPivot().Position
	local speed = 0

	local connection = RunService.Heartbeat:Connect(function(deltaTime: number)
		local position = rig:GetPivot().Position
		local offset = position - lastPosition
		lastPosition = position

		-- Frozen: every track holds its pose until Freeze(owner, false).
		if frozen[animator] then
			return
		end

		local measured = Vector3.new(offset.X, 0, offset.Z).Magnitude / math.max(deltaTime, 1e-4)
		if resolved.SpeedSmoothing > 0 then
			speed += (measured - speed) * (1 - math.exp(-deltaTime / resolved.SpeedSmoothing))
		else
			speed = measured
		end

		local blend = Locomotion.Blend(speed, resolved, hasRun)
		animator:SetWeight("Idle", blend.Idle, resolved.Fade)
		animator:SetWeight("Walk", blend.Walk, resolved.Fade)
		if blend.Walk > 0 then
			walk:AdjustSpeed(blend.WalkPlayback)
		end
		if run ~= nil then
			animator:SetWeight("Run", blend.Run, resolved.Fade)
			if blend.Run > 0 then
				run:AdjustSpeed(blend.RunPlayback)
			end
		end
	end)

	return animator, connection
end

--[=[
	@within Locomotion
	@param agent Agent
	@param options LocomotionOptions?
	@return NPCAnimator -- Also kept at `agent.Data.Locomotion`.
	@error string -- The rig has no Animator, or the animations lack a weighted `Idle` or `Walk`.
]=]
function Locomotion.Attach(agent: Types.Agent, options: LocomotionOptions?): Animator.NPCAnimator
	local animations, resolved = resolve("Locomotion.Attach", options)

	local existing = agent.Data[DATA_KEY]
	if existing then
		if options ~= nil then
			FormatMessage.Warn(`{agent.Name}: Locomotion is already attached; the new options are ignored`)
		end
		return existing
	end
	if agent:IsDestroyed() then
		FormatMessage.Error(`{agent.Name}: Locomotion.Attach on a destroyed agent`, 2)
	end
	if (agent.Entity :: Model?) == nil then
		FormatMessage.Error(`{agent.Name}: Locomotion.Attach needs a rig; this agent is headless`, 2)
	end
	if agent.Entity.PrimaryPart == nil then
		FormatMessage.Error(`{agent.Name}: Locomotion.Attach needs a PrimaryPart on the rig`, 2)
	end

	local animator, connection = drive(agent.Entity, animations, resolved)
	agent.Data[DATA_KEY] = animator

	agent.Destroyed:Once(function()
		connection:Disconnect()
		frozen[animator] = nil
		animator:Destroy()
		agent.Data[DATA_KEY] = nil
	end)

	return animator
end

--[=[
	@within Locomotion
	@param replica Replica -- Its `Entity` must be a Model with an `Animator` inside.
	@param options LocomotionOptions?
	@return NPCAnimator -- Also kept at `replica.Data.Locomotion`.
	@error string -- The entity is not a Model, has no Animator, or the animations lack a weighted `Idle` or `Walk`.

	Locomotion for a client rig a [Replica] moves: the blend follows the rig's own smoothed pivot
	motion, so it needs neither an agent nor physics (a puppet is usually anchored). `Freeze`,
	`Play` and `Get` take the replica as they take an agent. Undone when the replica is destroyed.
]=]
function Locomotion.AttachReplica(replica: Replica.Replica, options: LocomotionOptions?): Animator.NPCAnimator
	local animations, resolved = resolve("Locomotion.AttachReplica", options)

	local entity = replica.Entity
	local existing = replica.Data[DATA_KEY]
	if existing then
		if options ~= nil then
			FormatMessage.Warn(`{entity:GetFullName()}: Locomotion is already attached; the new options are ignored`)
		end
		return existing
	end
	if not entity:IsA("Model") then
		FormatMessage.Error(`Locomotion.AttachReplica: the replica's Entity must be a Model, got {entity.ClassName}`, 2)
	end

	local animator, connection = drive(entity :: Model, animations, resolved)
	replica.Data[DATA_KEY] = animator

	replica.Destroyed:Once(function()
		connection:Disconnect()
		frozen[animator] = nil
		animator:Destroy()
		replica.Data[DATA_KEY] = nil
	end)

	return animator
end

--[=[
	@within Locomotion
	@param agent Agent | Replica
	@param isFrozen boolean
	@return boolean -- `false` when nothing is attached.

	Holds every animation on the rig in its current pose (`true`), or lets them run again
	(`false`): the statue that stops mid-step the moment it is looked at. While frozen the blend is
	left alone, so the pose does not drift. Calling it with the state it is already in does
	nothing, so a sense may call it every tick.
]=]
function Locomotion.Freeze(agent: Owner, isFrozen: boolean): boolean
	local animator = agent.Data[DATA_KEY] :: Animator.NPCAnimator?
	if animator == nil then
		return false
	end
	if (frozen[animator] == true) == isFrozen then
		return true
	end
	if isFrozen then
		frozen[animator] = true
	else
		frozen[animator] = nil
	end
	for name in animator:GetAnimations() do
		local track = animator:GetTrack(name)
		if track.IsPlaying then
			track:AdjustSpeed(if isFrozen then 0 else 1)
		end
	end
	return true
end

--[=[
	@within Locomotion
	@param agent Agent | Replica
	@param name string -- A one-shot loaded by `Attach` or `AttachReplica`.
	@return boolean -- `false` when nothing is attached or the name is unknown.

	Plays a one-shot if locomotion is attached, so a state works with or without it. An unknown
	name is warned about once per owner and returns `false`; a weighted name is an error, as it
	is on the animator.
]=]
function Locomotion.Play(agent: Owner, name: string): boolean
	local animator = agent.Data[DATA_KEY] :: Animator.NPCAnimator?
	if animator == nil then
		return false
	end

	if animator:GetAnimations()[name] == nil then
		local warned = agent.Data[DATA_KEY .. "Warned"] or {}
		if not warned[name] then
			warned[name] = true
			agent.Data[DATA_KEY .. "Warned"] = warned
			local who = (agent :: any).Name or agent.Entity:GetFullName()
			FormatMessage.Warn(`{who}: Locomotion has no animation named "{name}"`)
		end
		return false
	end

	animator:Play(name)
	return true
end

--[=[
	@within Locomotion
	@param agent Agent | Replica
	@return NPCAnimator? -- What `Attach` or `AttachReplica` made, if it was called.
]=]
function Locomotion.Get(agent: Owner): Animator.NPCAnimator?
	return agent.Data[DATA_KEY]
end

return Locomotion
