--!strict

--[[
	Two ways an agent kills a character, both decided and finished on the server, both announced
	through the agent's event channel so clients can present them.

	Live: the victim's root is anchored and held in a pose relative to the killer for the length
	of the animation while both rigs play their animation, and killed at the end. Everyone in the
	world sees it happen. Anchoring makes the hold server-authoritative whoever owns the root,
	which network ownership alone does not.

	Black box: the kill is announced at once and resolved after a short delay, during which the
	client is expected to cut to black (or whatever it likes). The hard cut hides any gap
	between where the client drew the enemy and where the server had it.

	Nothing here touches remotes; the "Kill" event reaches clients through the game's
	Broadcaster wiring, and so does "KillCancelled" when a kill that was announced ends without a
	death, so a client can lift whatever it put up.
]]

local Cleaner = require(script.Parent.Parent.Utility.Cleaner)
local FormatMessage = require(script.Parent.Parent.Utility.FormatMessage)
local Options = require(script.Parent.Parent.Utility.Options)
local Signal = require(script.Parent.Parent.Utility.Signal)
local Types = require(script.Parent.Parent.Types)

------------------------------------------------------------------------------------------------------------------------

local EVENT = "Kill"
local CANCEL_EVENT = "KillCancelled"

-- Victims currently held by a live kill, so a second killer cannot take the same one.
local held: { [Model]: boolean } = setmetatable({}, { __mode = "k" }) :: any

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
	Kills are decided on the server. A client calling one would anchor a root it does not own and
	emit an event nobody relays, so it is an error with a reason rather than quiet half-work.
]]
local function assertServer(what: string)
	local RunService = game:GetService("RunService")
	if not RunService:IsServer() then
		FormatMessage.Error(`{what} runs on the server only; present the kill on the client from the "Kill" event`, 3)
	end
end

--[[
	Plays an animation on a rig's Animator if it has one, returning the track.
]]
local function playAnimation(character: Model, id: number?): (() -> ())?
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

	-- A track per kill would pile up on a long-lived killer's Animator; both go with the hold.
	return function()
		track:Stop()
		track:Destroy()
		animation:Destroy()
	end
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

	A kill that was announced and then cancelled (or lost to another cause of death) emits
	`"KillCancelled"` with `{ Kind, Victim }`, so the client can put its screen back.
]=]

--[=[
	@within Kill
	@param agent Agent -- The killer.
	@param victim Model -- The character to kill. Needs a Humanoid and a PrimaryPart.
	@param options LiveKillOptions?
	@return KillHandle

	Emits `Kill` with `Kind = "Live"`, anchors the victim's root, holds it at `Offset` from the
	killer every frame, plays the animations, and after `Duration` sets the victim's health to
	zero (bypassing a ForceField, as a kill should). `Cancel` releases the victim alive.

	Finishes `false` at once, with a warning, when the victim has no humanoid or root, is dead, or
	is already held by another live kill, or when the agent is not running. Finishes `false` if the
	killer is destroyed or the victim dies of something else during the hold.
]=]
function Kill.Live(agent: Types.Agent, victim: Model, options: LiveKillOptions?): KillHandle
	assertServer("Kill.Live")
	local resolved = Options.Resolve(
		"Kill.Live",
		LIVE_DEFAULTS,
		options :: any,
		{ "KillerAnimation", "VictimAnimation" }
	) :: typeof(LIVE_DEFAULTS)

	local finished: Types.Signal<boolean> = Signal.new()
	local cleaner = Cleaner.new()
	local done = false

	local announced = false
	local function finish(killed: boolean)
		if done then
			return
		end
		done = true
		cleaner:Destroy()
		if announced and not killed then
			agent:Emit(CANCEL_EVENT, { Kind = "Live", Victim = victim })
		end
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
	local refusal: string? = nil
	if humanoid == nil or root == nil then
		refusal = `Kill.Live needs a Humanoid and a PrimaryPart on {victim:GetFullName()}`
	elseif humanoid.Health <= 0 then
		refusal = `Kill.Live: {victim:GetFullName()} is already dead`
	elseif held[victim] then
		refusal = `Kill.Live: {victim:GetFullName()} is already being killed`
	elseif not agent:IsRunning() then
		refusal = "Kill.Live: the agent is not running"
	end
	if refusal ~= nil or humanoid == nil or root == nil then
		FormatMessage.Warn(`{agent.Name}: {refusal}`)
		task.defer(finish, false)
		return handle
	end

	held[victim] = true
	cleaner:Add(function()
		held[victim] = nil
	end)

	-- The killer's end of the hold: no killer, no kill.
	cleaner:Connect(agent.Destroyed, function()
		finish(false)
	end)

	agent:Emit(EVENT, { Kind = "Live", Victim = victim, Duration = resolved.Duration })
	announced = true

	-- Take the victim: an anchored root is the server's whoever owns it, and PlatformStand keeps
	-- the humanoid from trying to walk. Both are put back if the victim leaves alive.
	local wasAnchored = root.Anchored
	local wasPlatformStanding = humanoid.PlatformStand
	root.Anchored = true
	humanoid.PlatformStand = true
	cleaner:Add(function()
		if humanoid.Health > 0 then
			root.Anchored = wasAnchored
			humanoid.PlatformStand = wasPlatformStanding
		end
	end)

	local stopKiller = playAnimation(agent.Entity, resolved.KillerAnimation)
	local stopVictim = playAnimation(victim, resolved.VictimAnimation)
	cleaner:Add(function()
		if stopKiller then
			stopKiller()
		end
		if stopVictim then
			stopVictim()
		end
	end)

	local RunService = game:GetService("RunService")
	local elapsed = 0
	cleaner:Connect(RunService.Heartbeat, function(deltaTime: number)
		-- Someone else got there first: this kill did not happen.
		if humanoid.Health <= 0 then
			finish(false)
			return
		end

		elapsed += deltaTime
		root.CFrame = agent.Entity:GetPivot() * resolved.Offset

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
	`Delay`. `Cancel` within the delay spares them. Finishes `false` if the victim died of
	something else meanwhile, or if the agent was not running to begin with.
]=]
function Kill.BlackBox(agent: Types.Agent, victim: Model, options: BlackBoxKillOptions?): KillHandle
	assertServer("Kill.BlackBox")
	local resolved = Options.Resolve("Kill.BlackBox", BLACK_BOX_DEFAULTS, options :: any) :: typeof(BLACK_BOX_DEFAULTS)

	local finished: Types.Signal<boolean> = Signal.new()
	local done = false
	local announced = false
	local function finish(killed: boolean)
		if done then
			return
		end
		done = true
		if announced and not killed then
			agent:Emit(CANCEL_EVENT, { Kind = "BlackBox", Victim = victim })
		end
		finished:Fire(killed)
	end

	if not agent:IsRunning() then
		FormatMessage.Warn(`{agent.Name}: Kill.BlackBox: the agent is not running`)
		task.defer(finish, false)
	else
		agent:Emit(EVENT, { Kind = "BlackBox", Victim = victim, Duration = resolved.Delay })
		announced = true

		task.delay(resolved.Delay, function()
			if done then
				return
			end
			local humanoid = victim:FindFirstChildOfClass("Humanoid")
			if humanoid == nil or humanoid.Health <= 0 then
				finish(false)
				return
			end
			killHumanoid(victim)
			finish(true)
		end)
	end

	return {
		Finished = finished,
		Cancel = function()
			finish(false)
		end,
	}
end

return Kill
