--!strict

--[[
	What the agent hears from the world's own `Sound` instances. Every `Sound` carrying `Tag` that
	is playing and sits on a part or an attachment is judged each tick: the volume it would have
	at the agent's position, following the sound's `Volume`, `RollOffMode`, `RollOffMinDistance`
	and `RollOffMaxDistance` the way Roblox plays it, times an optional number attribute on the
	sound that makes it matter more or less to the AI. The loudest one above `Threshold` is the
	sound heard this tick.

	Writes to the blackboard:

	- `HeardSound` Sound? -- The sound heard this tick. `nil` when none is audible.
	- `HeardSoundDistance` number -- Studs from the agent to it; `math.huge` when none.
	- `HeardSoundPosition` Vector3? -- Where it plays from.
	- `HeardSoundLoudness` number? -- Its volume at the agent, after roll-off and the attribute.
	- `HeardSoundAt` number? -- `os.clock()` of the last tick it was audible.

	The last three are memory: they stay for `Memory` seconds after the sound was last audible,
	then go `nil` together. They live on the blackboard, not in the sense, so one instance serves
	any number of agents and a state may clear them early.

	The one decision worth knowing: `Attenuate` is the roll-off curve as a pure function of the
	mode's name, so a spec can check the numbers without Roblox, and a game can reuse it for its
	own noise model. `Inverse` stops attenuating past the max distance, as Roblox does; the two
	linear modes reach silence there.

	Sounds are read duck-typed (`IsPlaying`, `Volume`, the roll-off fields, `Parent:IsA`,
	`GetAttribute`, `IsDescendantOf`), so a spec can pass plain tables through a fake
	CollectionService.
]]

local FormatMessage = require(script.Parent.Parent.Utility.FormatMessage)
local Options = require(script.Parent.Parent.Utility.Options)
local Perception = require(script.Parent.Perception)
local Types = require(script.Parent.Parent.Types)

------------------------------------------------------------------------------------------------------------------------

local DEFAULT_OPTIONS = table.freeze({
	Tag = "AI_SOUND",
	Threshold = 0.05,
	MultiplierAttribute = "AI_SOUND/Multiplier",
	Memory = 5,
})

local ALLOWED_OPTIONS = { "Filter" }

--[=[
	@interface SoundsOptions
	@within Sounds

	.Tag string? -- The `CollectionService` tag a `Sound` must carry to be heard. Default `"AI_SOUND"`.
	.Threshold number? -- The volume a sound must still have at the agent, after roll-off and the attribute, to be heard. Default `0.05`.
	.MultiplierAttribute string? -- A number attribute on the `Sound` that multiplies its volume for the AI: `2` carries twice as loud, `0.5` half, `0` is never heard. Missing means `1`. Default `"AI_SOUND/Multiplier"`.
	.Memory number? -- Seconds the memory keys outlive the last audible tick. Default `5`.
	.Filter ((sound: Sound, agent: Agent) -> boolean)? -- Return `false` to ignore a sound for this agent. The agent's own sounds (under its entity) are ignored without it.
]=]
export type SoundsOptions = {
	Tag: string?,
	Threshold: number?,
	MultiplierAttribute: string?,
	Memory: number?,
	Filter: ((sound: Sound, agent: Types.Agent) -> boolean)?,
}

type ResolvedOptions = {
	Tag: string,
	Threshold: number,
	MultiplierAttribute: string,
	Memory: number,
	Filter: ((sound: Sound, agent: Types.Agent) -> boolean)?,
}

type self = {
	_options: ResolvedOptions,
	_collectionService: CollectionService,
}

local Sounds = {}
Sounds.__index = Sounds

export type Sounds = typeof(setmetatable({} :: self, Sounds))

------------------------------------------------------------------------------------------------------------------------

--[=[
	@class Sounds

	A [Types.Sense] that hears the `Sound` instances in the world. Tag a sound with
	`CollectionService` (`"AI_SOUND"` by default), parent it to a part or an attachment so it is
	3D, and every agent with this sense judges it each tick while it plays: the sound's `Volume`
	rolled off over the distance the way Roblox plays it, times the sound's `AI_SOUND/Multiplier`
	attribute when it has one. The loudest sound still above `Threshold` is written as
	`HeardSound` with its position, distance, loudness at the agent and the time, and the memory
	keys stay for `Memory` seconds after it stops so a state can go and look. Exposed as
	`VluxyAI.Senses.Sounds`. The tag and the attribute name are prefixed so they do not collide
	with a game's own; both are options.

	```lua
	-- the game, once per sound worth noticing
	CollectionService:AddTag(radio.Sound, "AI_SOUND")
	radio.Sound:SetAttribute("AI_SOUND/Multiplier", 2) -- twice as far as its roll-off alone

	-- the agent
	:AddSense(VluxyAI.Senses.Sounds.new({ Threshold = 0.1, Memory = 8 }))

	-- a transition in the brain
	{ To = "Investigate", When = function(agent)
		return agent.Blackboard.HeardSoundAt ~= nil and agent.Blackboard.HeardSoundAt ~= agent.Data.InvestigatedAt
	end }
	```

	A sound with no tag, one that is not playing, one parented to a folder or to `SoundService`
	(so it is 2D), one with `Volume` `0` and one the agent itself carries are never heard. The
	one signal-based sense, [Hearing], is for events your code fires; this one is for sounds the
	world is already playing. One instance may serve many agents: it keeps no per-agent state.
]=]

--[=[
	@within Sounds
	@param options SoundsOptions?
	@return Sounds
	@error "unknown option" -- A key not in `SoundsOptions`.
	@error "Threshold must be zero or more"
]=]
function Sounds.new(options: SoundsOptions?): Types.Sense
	local resolved = Options.Resolve("Sounds.new", DEFAULT_OPTIONS, options :: any, ALLOWED_OPTIONS) :: ResolvedOptions

	if type(resolved.Tag) ~= "string" or resolved.Tag == "" then
		FormatMessage.Error("Sounds: Tag must be a non-empty string", 3)
	end
	if type(resolved.Threshold) ~= "number" or resolved.Threshold < 0 then
		FormatMessage.Error("Sounds: Threshold must be zero or more", 3)
	end

	local self: self = {
		_options = resolved,
		_collectionService = game:GetService("CollectionService"),
	}

	return setmetatable(self, Sounds) :: any
end

------------------------------------------------------------------------------------------------------------------------

--[=[
	@within Sounds
	@param distance number -- Studs from the sound to the listener.
	@param volume number -- The sound's `Volume`.
	@param minDistance number -- `RollOffMinDistance`: full volume up to here.
	@param maxDistance number -- `RollOffMaxDistance`: silence (linear modes) or no further attenuation (inverse) from here.
	@param mode string -- The `RollOffMode` name: `Inverse`, `InverseTapered`, `Linear` or `LinearSquare`. Anything else is `Inverse`.
	@return number -- The volume at the listener, in `[0, volume]`.

	The roll-off curves as Roblox plays them, pure. Within `minDistance` a sound is at full volume.
	`Inverse` falls as `minDistance / distance` and stops falling at `maxDistance`; `Linear` and
	`LinearSquare` fall to nothing at `maxDistance`, the second along a squared curve;
	`InverseTapered` is the quieter of `Inverse` and `LinearSquare`, so it follows the inverse
	curve up close and still reaches silence at `maxDistance`.
]=]
function Sounds.Attenuate(
	distance: number,
	volume: number,
	minDistance: number,
	maxDistance: number,
	mode: string
): number
	if volume <= 0 then
		return 0
	end
	if distance <= minDistance then
		return volume
	end

	local function inverse(): number
		local at = math.min(distance, math.max(maxDistance, minDistance))
		if at <= 0 then
			return 1
		end
		return math.min(1, minDistance / at)
	end

	local function linear(): number
		if maxDistance <= minDistance then
			return 0
		end
		return 1 - math.clamp((distance - minDistance) / (maxDistance - minDistance), 0, 1)
	end

	local gain: number
	if mode == "Linear" then
		gain = linear()
	elseif mode == "LinearSquare" then
		gain = linear() ^ 2
	elseif mode == "InverseTapered" then
		gain = math.min(inverse(), linear() ^ 2)
	else
		gain = inverse()
	end

	return volume * gain
end

--[[
	Where a sound plays from: its parent part's position or its parent attachment's world
	position. `nil` for a sound that is not 3D (no parent, or a parent that is neither).
]]
local function positionOf(sound: any): Vector3?
	local parent = sound.Parent
	if parent == nil or type(parent.IsA) ~= "function" then
		return nil
	end

	if parent:IsA("Attachment") then
		return parent.WorldPosition
	end
	if parent:IsA("BasePart") then
		return parent.Position
	end

	return nil
end

--[[
	The sound's multiplier from its attribute: a number of zero or more, else `1`.
]]
local function multiplierOf(sound: any, attribute: string): number
	if type(sound.GetAttribute) ~= "function" then
		return 1
	end

	local value = sound:GetAttribute(attribute)
	if type(value) == "number" and value >= 0 then
		return value
	end

	return 1
end

--[[
	Does the agent carry this sound itself? Its own footsteps are not news.
]]
local function isOwn(sound: any, agent: Types.Agent): boolean
	local isDescendantOf = sound.IsDescendantOf
	return type(isDescendantOf) == "function" and isDescendantOf(sound, agent.Entity) == true
end

------------------------------------------------------------------------------------------------------------------------

--[=[
	@within Sounds
	@param agent Agent
	@param deltaTime number

	Judges every tagged sound and writes the keys listed above to `agent.Blackboard`.
]=]
function Sounds.Tick(self: Sounds, agent: Types.Agent, deltaTime: number)
	local _ = deltaTime
	local options = self._options
	local blackboard = agent.Blackboard

	local origin = Perception.PositionOf(agent)
	local now = os.clock()

	local heard: any = nil
	local heardPosition: Vector3? = nil
	local heardDistance = math.huge
	local heardLoudness = 0

	for _, sound in self._collectionService:GetTagged(options.Tag) do
		local candidate = sound :: any
		if candidate.IsPlaying ~= true then
			continue
		end

		local volume = candidate.Volume
		if type(volume) ~= "number" or volume <= 0 then
			continue
		end

		local position = positionOf(candidate)
		if position == nil then
			continue
		end

		if isOwn(candidate, agent) then
			continue
		end
		if options.Filter ~= nil and options.Filter(candidate, agent) == false then
			continue
		end

		local multiplier = multiplierOf(candidate, options.MultiplierAttribute)
		if multiplier <= 0 then
			continue
		end

		local distance = (position - origin).Magnitude
		local mode = candidate.RollOffMode
		local modeName = if type(mode) == "string" then mode else tostring(mode and mode.Name or "Inverse")
		local loudness = multiplier
			* Sounds.Attenuate(distance, volume, candidate.RollOffMinDistance, candidate.RollOffMaxDistance, modeName)

		if loudness < options.Threshold then
			continue
		end

		local louder = loudness > heardLoudness
		local asLoudButNearer = loudness == heardLoudness and distance < heardDistance
		if heard == nil or louder or asLoudButNearer then
			heard = candidate
			heardPosition = position
			heardDistance = distance
			heardLoudness = loudness
		end
	end

	if heard ~= nil then
		blackboard.HeardSound = heard
		blackboard.HeardSoundDistance = heardDistance
		blackboard.HeardSoundPosition = heardPosition
		blackboard.HeardSoundLoudness = heardLoudness
		blackboard.HeardSoundAt = now
		return
	end

	blackboard.HeardSound = nil
	blackboard.HeardSoundDistance = math.huge

	local heardAt = blackboard.HeardSoundAt
	if type(heardAt) == "number" and now - heardAt > options.Memory then
		blackboard.HeardSoundPosition = nil
		blackboard.HeardSoundLoudness = nil
		blackboard.HeardSoundAt = nil
	end
end

return Sounds
