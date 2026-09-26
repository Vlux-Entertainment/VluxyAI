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

	Scare: the live hold without the death. The victim is grabbed, both animations play, an
	optional amount of damage lands, and they are let go. Announced as "Scare" so the client can
	do its jump scare.

	Health is read and changed through the Humanoid unless a HealthProvider is given, for games
	that keep health elsewhere.

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
local SCARE_EVENT = "Scare"
local SCARE_CANCEL_EVENT = "ScareCancelled"

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
	Health = nil :: Types.HealthProvider?,
})

local LIVE_ALLOWED = { "KillerAnimation", "VictimAnimation", "Health" }

local SCARE_DEFAULTS = table.freeze({
	Duration = 1,
	Offset = CFrame.new(0, 0, -2.5) * CFrame.Angles(0, math.pi, 0),
	Damage = 0,
	KillerAnimation = nil :: number?,
	VictimAnimation = nil :: number?,
	Health = nil :: Types.HealthProvider?,
})

local BLACK_BOX_DEFAULTS = table.freeze({
	-- Seconds between the announcement and the death, for the client to cut.
	Delay = 0.6,
	Health = nil :: Types.HealthProvider?,
})

--[[
	The victim's health through the provider when there is one, else the Humanoid.
]]
local function healthOf(victim: Model, humanoid: Humanoid?, health: Types.HealthProvider?): number
	if health ~= nil then
		return health.Get(victim)
	end
	return if humanoid then humanoid.Health else 0
end

local function hurt(victim: Model, humanoid: Humanoid?, health: Types.HealthProvider?, amount: number)
	if amount <= 0 then
		return
	end
	if health ~= nil then
		health.Damage(victim, amount)
	elseif humanoid then
		humanoid:TakeDamage(amount)
	end
end

--[=[
	@interface LiveKillOptions
	@within Kill

	.Duration number? -- Seconds the hold lasts before the victim dies. Default `1.5`.
	.Offset CFrame? -- Where the victim is held, relative to the killer's pivot. Default 2.5 studs in front, facing the killer.
	.KillerAnimation number? -- Animation asset id played on the killer. Default none.
	.VictimAnimation number? -- Animation asset id played on the victim. Default none.
	.Health HealthProvider? -- Where the victim's health lives, when not on the Humanoid.
]=]
export type LiveKillOptions = {
	Duration: number?,
	Offset: CFrame?,
	KillerAnimation: number?,
	VictimAnimation: number?,
	Health: Types.HealthProvider?,
}

--[=[
	@interface ScareOptions
	@within Kill

	.Duration number? -- Seconds the hold lasts before the victim is let go. Default `1`.
	.Offset CFrame? -- Where the victim is held, relative to the killer's pivot. Default 2.5 studs in front, facing the killer.
	.Damage number? -- Dealt when the hold ends. Default `0`.
	.KillerAnimation number? -- Animation asset id played on the killer. Default none.
	.VictimAnimation number? -- Animation asset id played on the victim. Default none.
	.Health HealthProvider? -- Where the victim's health lives, when not on the Humanoid.
]=]
export type ScareOptions = {
	Duration: number?,
	Offset: CFrame?,
	Damage: number?,
	KillerAnimation: number?,
	VictimAnimation: number?,
	Health: Types.HealthProvider?,
}

--[=[
	@interface BlackBoxKillOptions
	@within Kill

	.Delay number? -- Seconds between the announcement and the death. Default `0.6`.
	.Health HealthProvider? -- Where the victim's health lives, when not on the Humanoid.
]=]
export type BlackBoxKillOptions = {
	Delay: number?,
	Health: Types.HealthProvider?,
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

local function killVictim(character: Model, health: Types.HealthProvider?)
	if health ~= nil then
		if health.Kill then
			health.Kill(character)
		else
			health.Damage(character, math.huge)
		end
		return
	end
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
	- [Kill.Scare]: the live hold without the death, announced as `"Scare"`; the victim is let go.

	A kill that was announced and then cancelled (or lost to another cause of death) emits
	`"KillCancelled"` with `{ Kind, Victim }`, so the client can put its screen back; a scare cut
	short emits `"ScareCancelled"`.
]=]

--[[
	The hold both Live and Scare are made of: announce, anchor the victim at the offset, play the
	animations, and after Duration run `ending` (which says whether the victim died). Everything
	is put back if the victim leaves alive.
]]
local function hold(
	agent: Types.Agent,
	victim: Model,
	kind: string,
	event: string,
	cancelEvent: string,
	duration: number,
	offset: CFrame,
	killerAnimation: number?,
	victimAnimation: number?,
	health: Types.HealthProvider?,
	ending: (victim: Model, humanoid: Humanoid?) -> boolean
): KillHandle
	local finished: Types.Signal<boolean> = Signal.new()
	local cleaner = Cleaner.new()
	local done = false

	local announced = false
	local function finish(completed: boolean)
		if done then
			return
		end
		done = true
		cleaner:Destroy()
		if announced and not completed then
			agent:Emit(cancelEvent, { Kind = kind, Victim = victim })
		end
		finished:Fire(completed)
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
	if root == nil or (humanoid == nil and health == nil) then
		refusal = `Kill.{kind} needs a Humanoid (or a Health provider) and a PrimaryPart on {victim:GetFullName()}`
	elseif healthOf(victim, humanoid, health) <= 0 then
		refusal = `Kill.{kind}: {victim:GetFullName()} is already dead`
	elseif held[victim] then
		refusal = `Kill.{kind}: {victim:GetFullName()} is already being held`
	elseif not agent:IsRunning() then
		refusal = `Kill.{kind}: the agent is not running`
	end
	if refusal ~= nil or root == nil then
		FormatMessage.Warn(`{agent.Name}: {refusal}`)
		task.defer(finish, false)
		return handle
	end

	held[victim] = true
	cleaner:Add(function()
		held[victim] = nil
	end)

	-- The killer's end of the hold: no killer, no hold.
	cleaner:Connect(agent.Destroyed, function()
		finish(false)
	end)

	agent:Emit(event, { Kind = kind, Victim = victim, Duration = duration })
	announced = true

	-- Take the victim: an anchored root is the server's whoever owns it, and PlatformStand keeps
	-- the humanoid from trying to walk. Both are put back if the victim leaves alive.
	local wasAnchored = root.Anchored
	local wasPlatformStanding = if humanoid then humanoid.PlatformStand else false
	root.Anchored = true
	if humanoid then
		humanoid.PlatformStand = true
	end
	cleaner:Add(function()
		if healthOf(victim, humanoid, health) > 0 then
			root.Anchored = wasAnchored
			if humanoid then
				humanoid.PlatformStand = wasPlatformStanding
			end
		end
	end)

	local stopKiller = playAnimation(agent.Entity, killerAnimation)
	local stopVictim = playAnimation(victim, victimAnimation)
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
		-- Someone else got there first: this hold did not happen.
		if healthOf(victim, humanoid, health) <= 0 then
			finish(false)
			return
		end

		elapsed += deltaTime
		root.CFrame = agent.Entity:GetPivot() * offset

		if elapsed >= duration then
			finish(ending(victim, humanoid))
		end
	end)

	return handle
end

--[=[
	@within Kill
	@param agent Agent -- The killer.
	@param victim Model -- The character to kill. Needs a Humanoid (or a `Health` provider) and a PrimaryPart.
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
	local resolved = Options.Resolve("Kill.Live", LIVE_DEFAULTS, options :: any, LIVE_ALLOWED) :: typeof(LIVE_DEFAULTS)

	return hold(
		agent,
		victim,
		"Live",
		EVENT,
		CANCEL_EVENT,
		resolved.Duration,
		resolved.Offset,
		resolved.KillerAnimation,
		resolved.VictimAnimation,
		resolved.Health,
		function(character: Model, _humanoid: Humanoid?): boolean
			killVictim(character, resolved.Health)
			return true
		end
	)
end

--[=[
	@within Kill
	@param agent Agent -- The scarer.
	@param victim Model -- The character to grab. Needs a Humanoid (or a `Health` provider) and a PrimaryPart.
	@param options ScareOptions?
	@return KillHandle -- Finishes `true` when the hold ran its course and the victim was let go, `false` when cut short.

	The live hold without the death: emits `Scare` with `Kind = "Scare"`, holds the victim at
	`Offset` while both animations play, deals `Damage` when the time is up, and releases them.
	A jump scare, a grab that throws the player off, a bite that does not finish them. The same
	refusals as [Kill.Live]; a victim already held by a kill or another scare is refused.
]=]
function Kill.Scare(agent: Types.Agent, victim: Model, options: ScareOptions?): KillHandle
	assertServer("Kill.Scare")
	local resolved =
		Options.Resolve("Kill.Scare", SCARE_DEFAULTS, options :: any, LIVE_ALLOWED) :: typeof(SCARE_DEFAULTS)

	return hold(
		agent,
		victim,
		"Scare",
		SCARE_EVENT,
		SCARE_CANCEL_EVENT,
		resolved.Duration,
		resolved.Offset,
		resolved.KillerAnimation,
		resolved.VictimAnimation,
		resolved.Health,
		function(character: Model, humanoid: Humanoid?): boolean
			hurt(character, humanoid, resolved.Health, resolved.Damage)
			return true
		end
	)
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
	local resolved =
		Options.Resolve("Kill.BlackBox", BLACK_BOX_DEFAULTS, options :: any, { "Health" }) :: typeof(BLACK_BOX_DEFAULTS)

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
			if (humanoid == nil and resolved.Health == nil) or healthOf(victim, humanoid, resolved.Health) <= 0 then
				finish(false)
				return
			end
			killVictim(victim, resolved.Health)
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
