--!strict

--[[
	Two ways an agent kills a character, both decided and finished on the server, both announced
	through the agent's event channel so clients can present them.

	Live: the victim is taken from their player, held in a pose relative to the killer for the
	length of the animation while both rigs play their animation, and killed at the end. Everyone
	in the world sees it happen.

	Black box: the kill is announced at once and resolved after a short delay, during which the
	client is expected to cut to black (or whatever it likes). The hard cut hides any gap
	between where the client drew the enemy and where the server had it.

	Nothing here touches remotes; the "Kill" event reaches clients through the game's
	Broadcaster wiring.
]]

local FormatMessage = require(script.Parent.Parent.Utility.FormatMessage)
local Options = require(script.Parent.Parent.Utility.Options)
local Signal = require(script.Parent.Parent.Utility.Signal)
local Trove = require(script.Parent.Parent.Utility.Trove)
local Types = require(script.Parent.Parent.Types)

------------------------------------------------------------------------------------------------------------------------

local EVENT = "Kill"

local LIVE_DEFAULTS = table.freeze({
	-- Seconds the hold and the animations last before the victim dies.
	Duration = 1.5,
	-- Where the victim is held, relative to the killer's pivot.
	Offset = CFrame.new(0, 0, -2.5) * CFrame.Angles(0, math.pi, 0),
	-- Animation asset ids; nil plays none.
	KillerAnimation = nil :: number?,
	VictimAnimation = nil :: number?,
})

local BLACK_BOX_DEFAULTS = table.freeze({
	-- Seconds between the announcement and the death, for the client to cut.
	Delay = 0.6,
})

--[=[
	@interface LiveKillOptions
	@within Kill

	.Duration number? -- Seconds the hold lasts before the victim dies. Default `1.5`.
	.Offset CFrame? -- Where the victim is held, relative to the killer's pivot. Default 2.5 studs in front, facing the killer.
	.KillerAnimation number? -- Animation asset id played on the killer. Default none.
	.VictimAnimation number? -- Animation asset id played on the victim. Default none.
]=]
export type LiveKillOptions = {
	Duration: number?,
	Offset: CFrame?,
	KillerAnimation: number?,
	VictimAnimation: number?,
}

--[=[
	@interface BlackBoxKillOptions
	@within Kill

	.Delay number? -- Seconds between the announcement and the death. Default `0.6`.
]=]
export type BlackBoxKillOptions = {
	Delay: number?,
}

--[=[
	@interface KillHandle
	@within Kill

	.Finished Signal<boolean> -- Fired once: `true` when the victim died, `false` when cancelled.
	.Cancel (self: KillHandle) -> () -- Releases the victim alive.

	What both kill functions return.
]=]
export type KillHandle = {
	Finished: Types.Signal<boolean>,
	Cancel: (self: KillHandle) -> (),
}

local Kill = {}

--[[
	Plays an animation on a rig's Animator if it has one, returning the track.
]]
local function playAnimation(character: Model, id: number?): AnimationTrack?
	if id == nil then
		return nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local animator = if humanoid then humanoid:FindFirstChildOfClass("Animator") else nil
	if animator == nil then
		return nil
	end

	local animation = Instance.new("Animation")
	animation.AnimationId = `rbxassetid://{id}`
	local track = animator:LoadAnimation(animation)
	track.Priority = Enum.AnimationPriority.Action4
	track:Play()

	return track
end

local function killHumanoid(character: Model)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health > 0 then
		humanoid.Health = 0
	end
end

--[=[
	@class Kill

	Kills a character from an agent in one of two ways, decided and finished on the server, and
	announced as a `"Kill"` event on [Agent].Events with `{ Kind, Victim, Duration }` so a client
	[Replica] can present it: `replica:On("Kill", ...)`.

	- [Kill.Live]: the victim is held next to the killer while both play an animation, then dies.
	- [Kill.BlackBox]: announced at once, resolved after a delay; the client cuts to black.
]=]

--[=[
	@within Kill
	@param agent Agent -- The killer.
	@param victim Model -- The character to kill. Needs a Humanoid and a PrimaryPart.
	@param options LiveKillOptions?
	@return KillHandle

	Emits `Kill` with `Kind = "Live"`, takes the victim's root for the server, holds it at
	`Offset` from the killer every frame, plays the animations, and after `Duration` sets the
	victim's health to zero. `Cancel` releases the victim alive. A victim with no humanoid or root
	is finished at once with `false`.
]=]
function Kill.Live(agent: Types.Agent, victim: Model, options: LiveKillOptions?): KillHandle
	local resolved = Options.Resolve(
		"Kill.Live",
		LIVE_DEFAULTS,
		options :: any,
		{ "KillerAnimation", "VictimAnimation" }
	) :: typeof(LIVE_DEFAULTS)

	local finished: Types.Signal<boolean> = Signal.new()
	local trove = Trove.new()
	local done = false

	local function finish(killed: boolean)
		if done then
			return
		end
		done = true
		trove:Destroy()
		finished:Fire(killed)
	end

	local handle: KillHandle = {
		Finished = finished,
		Cancel = function()
			finish(false)
		end,
	}

	local humanoid = victim:FindFirstChildOfClass("Humanoid")
	local root = victim.PrimaryPart
	if humanoid == nil or root == nil then
		FormatMessage.Warn(`{agent.Name}: Kill.Live needs a Humanoid and a PrimaryPart on {victim:GetFullName()}`)
		task.defer(finish, false)
		return handle
	end

	agent:Emit(EVENT, { Kind = "Live", Victim = victim, Duration = resolved.Duration })

	-- Take the victim: the server drives their root for the length of the hold.
	local ownerOk = pcall(function()
		root:SetNetworkOwner(nil)
	end)
	local wasPlatformStanding = humanoid.PlatformStand
	humanoid.PlatformStand = true
	trove:Add(function()
		if humanoid.Health > 0 then
			humanoid.PlatformStand = wasPlatformStanding
			if ownerOk then
				pcall(function()
					root:SetNetworkOwnershipAuto()
				end)
			end
		end
	end)

	local killerTrack = playAnimation(agent.Entity, resolved.KillerAnimation)
	local victimTrack = playAnimation(victim, resolved.VictimAnimation)
	trove:Add(function()
		if killerTrack then
			killerTrack:Stop()
		end
		if victimTrack then
			victimTrack:Stop()
		end
	end)

	local RunService = game:GetService("RunService")
	local elapsed = 0
	trove:Connect(RunService.Heartbeat, function(deltaTime: number)
		elapsed += deltaTime
		root.CFrame = agent.Entity:GetPivot() * resolved.Offset
		root.AssemblyLinearVelocity = Vector3.zero

		if elapsed >= resolved.Duration then
			killHumanoid(victim)
			finish(true)
		end
	end)

	return handle
end

--[=[
	@within Kill
	@param agent Agent -- The killer.
	@param victim Model -- The character to kill.
	@param options BlackBoxKillOptions?
	@return KillHandle

	Emits `Kill` with `Kind = "BlackBox"` at once and sets the victim's health to zero after
	`Delay`. `Cancel` within the delay spares them.
]=]
function Kill.BlackBox(agent: Types.Agent, victim: Model, options: BlackBoxKillOptions?): KillHandle
	local resolved = Options.Resolve("Kill.BlackBox", BLACK_BOX_DEFAULTS, options :: any) :: typeof(BLACK_BOX_DEFAULTS)

	local finished: Types.Signal<boolean> = Signal.new()
	local done = false
	local function finish(killed: boolean)
		if done then
			return
		end
		done = true
		finished:Fire(killed)
	end

	agent:Emit(EVENT, { Kind = "BlackBox", Victim = victim, Duration = resolved.Delay })

	task.delay(resolved.Delay, function()
		if done then
			return
		end
		killHumanoid(victim)
		finish(true)
	end)

	return {
		Finished = finished,
		Cancel = function()
			finish(false)
		end,
	}
end

return Kill
