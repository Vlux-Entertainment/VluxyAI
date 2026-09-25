--!strict

--[[
	NPC animation helper carried over from 0.1. Weighted animations are looped, always playing,
	and blended by weight (idle, walk, run); unweighted ones are one-shots you play and stop
	(attack, scream). Tracks are keyed by the names you give them, so a state says
	`animator:SetWeight("Run", 1)` and nothing else knows asset ids.

	The one non-obvious rule: a weighted track is never given weight 0, because a track at weight
	0 can be dropped by the engine and pop when brought back. It sits at ALMOST_ZERO instead.
]]

local FormatMessage = require(script.Parent.Utility.FormatMessage)
local Trove = require(script.Parent.Utility.Trove)

------------------------------------------------------------------------------------------------------------------------

local ALMOST_ZERO = 0.001

--[=[
	@interface AnimationInfo
	@within Animator

	.Id number -- The animation asset id.
	.Weighted boolean -- `true` for a looped, always-playing track blended by weight; `false` for a one-shot.
	.Priority Enum.AnimationPriority? -- Default `Enum.AnimationPriority.Movement` for weighted, `Action` for one-shots.
	.Speed number? -- Playback speed. Default `1`.

	One animation in the table given to [Animator.new].
]=]
export type AnimationInfo = {
	Id: number,
	Weighted: boolean,
	Priority: Enum.AnimationPriority?,
	Speed: number?,
}

type self = {
	Entity: Model,

	_animator: Animator,
	_infos: { [string]: AnimationInfo },
	_tracks: { [string]: AnimationTrack },
	_loaded: boolean,
	_trove: Trove.Trove,
}

local NPCAnimator = {}
NPCAnimator.__index = NPCAnimator

export type NPCAnimator = typeof(setmetatable({} :: self, NPCAnimator))

--[=[
	@class Animator

	Plays and blends animations on an NPC rig by name.

	```lua
	local animator = VluxyAI.Animator.new(model, {
		Idle = { Id = 123, Weighted = true },
		Walk = { Id = 456, Weighted = true },
		Swing = { Id = 789, Weighted = false },
	}):Load()

	animator:SetWeight("Walk", 1)
	animator:Play("Swing")
	```

	Load every animation up front in `Load`; adding tracks later is not supported.
]=]

--[=[
	@within Animator
	@param entity Model -- Needs an `Animator` somewhere inside (usually under the Humanoid or AnimationController).
	@param animations { [string]: AnimationInfo }
	@return Animator
	@error string -- The model has no `Animator`.
]=]
function NPCAnimator.new(entity: Model, animations: { [string]: AnimationInfo }): NPCAnimator
	local animator: Animator? = entity:FindFirstChildOfClass("Animator")
	if animator == nil then
		local humanoid = entity:FindFirstChildOfClass("Humanoid")
		local controller = entity:FindFirstChildOfClass("AnimationController")
		local holder: Instance? = humanoid or controller
		animator = if holder then holder:FindFirstChildOfClass("Animator") else nil
	end
	if animator == nil then
		FormatMessage.Error(
			`{entity:GetFullName()} has no Animator; add one under its Humanoid or AnimationController`,
			2
		)
	end

	local self: self = {
		Entity = entity,

		_animator = animator :: Animator,
		_infos = table.clone(animations),
		_tracks = {},
		_loaded = false,
		_trove = Trove.new(),
	}

	return setmetatable(self, NPCAnimator)
end

--[[
	Returns a track or errors with the names that exist, so a typo reads as a typo.
]]
function NPCAnimator._track(self: NPCAnimator, name: string): AnimationTrack
	if not self._loaded then
		FormatMessage.Error(`{self.Entity:GetFullName()}: call Load() before using the animator`, 3)
	end

	local track: AnimationTrack? = self._tracks[name]
	if track == nil then
		local names = {}
		for known in self._infos do
			table.insert(names, known)
		end
		table.sort(names)
		FormatMessage.Error(
			`{self.Entity:GetFullName()}: no animation named "{name}"; known: {table.concat(names, ", ")}`,
			3
		)
	end

	return track :: AnimationTrack
end

--[=[
	@within Animator
	@return Animator

	Loads every animation. Weighted tracks start playing at almost-zero weight so they blend in
	without a pop. Calling it twice does nothing.
]=]
function NPCAnimator.Load(self: NPCAnimator): NPCAnimator
	if self._loaded then
		return self
	end
	self._loaded = true

	for name, info in self._infos do
		local animation = Instance.new("Animation")
		animation.Name = name
		animation.AnimationId = `rbxassetid://{info.Id}`
		animation.Parent = self.Entity
		self._trove:Add(animation)

		local track = self._animator:LoadAnimation(animation)
		track.Priority = info.Priority
			or (if info.Weighted then Enum.AnimationPriority.Movement else Enum.AnimationPriority.Action)
		track.Looped = info.Weighted
		track:AdjustSpeed(info.Speed or 1)
		self._trove:Add(track)

		if info.Weighted then
			track:Play()
			track:AdjustWeight(ALMOST_ZERO)
		end

		self._tracks[name] = track
	end

	return self
end

--[=[
	@within Animator
	@param name string
	@param weight number -- `0` to `1`. Clamped above zero so the track never drops out.
	@param fade number? -- Seconds to blend. Default `0.1`.
	@return Animator
	@error string -- Unknown name, or the animation is not weighted.
]=]
function NPCAnimator.SetWeight(self: NPCAnimator, name: string, weight: number, fade: number?): NPCAnimator
	local track = self:_track(name)
	if not self._infos[name].Weighted then
		FormatMessage.Error(`{self.Entity:GetFullName()}: "{name}" is a one-shot; use Play and Stop`, 2)
	end

	track:AdjustWeight(math.max(ALMOST_ZERO, weight), fade or 0.1)

	return self
end

--[=[
	@within Animator
	@param name string
	@param fade number?
	@param weight number?
	@param speed number?
	@return Animator
	@error string -- Unknown name, or the animation is weighted.

	Plays a one-shot.
]=]
function NPCAnimator.Play(self: NPCAnimator, name: string, fade: number?, weight: number?, speed: number?): NPCAnimator
	local track = self:_track(name)
	if self._infos[name].Weighted then
		FormatMessage.Error(`{self.Entity:GetFullName()}: "{name}" is weighted; use SetWeight`, 2)
	end

	track:Play(fade, weight, speed)

	return self
end

--[=[
	@within Animator
	@param name string
	@param fade number?
	@return Animator
	@error string -- Unknown name, or the animation is weighted.

	Stops a one-shot.
]=]
function NPCAnimator.Stop(self: NPCAnimator, name: string, fade: number?): NPCAnimator
	local track = self:_track(name)
	if self._infos[name].Weighted then
		FormatMessage.Error(`{self.Entity:GetFullName()}: "{name}" is weighted; use SetWeight`, 2)
	end

	track:Stop(fade)

	return self
end

--[=[
	@within Animator
	@param name string
	@return AnimationTrack
	@error string -- Unknown name.

	The loaded track, for anything the helpers do not cover (markers, `TimePosition`).
]=]
function NPCAnimator.GetTrack(self: NPCAnimator, name: string): AnimationTrack
	return self:_track(name)
end

--[=[
	@within Animator
	@return { [string]: AnimationInfo } -- The table given to `new`.
]=]
function NPCAnimator.GetAnimations(self: NPCAnimator): { [string]: AnimationInfo }
	return self._infos
end

--[=[
	@within Animator

	Stops and destroys every track and the Animation instances it made.
]=]
function NPCAnimator.Destroy(self: NPCAnimator)
	for _, track in self._tracks do
		track:Stop()
	end
	table.clear(self._tracks)
	self._trove:Destroy()
end

return NPCAnimator
