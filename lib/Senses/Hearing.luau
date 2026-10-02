--!strict

--[[
	What the agent heard. Any code fires a [Types.Signal] with a world position and an optional
	loudness (`1` by default), an optional kind and an optional source Instance; the sense buffers
	those between ticks and, on each tick, keeps the loudest noise close enough to hear that
	`Accept` lets through, then drops the rest. A noise carries to `Range * loudness`
	studs, so a gunshot at loudness 3 is heard three times as far as a footstep at 1.

	Writes to the blackboard:

	- `HeardPosition` Vector3? -- Where the last heard noise was.
	- `HeardAt` number? -- `os.clock()` of that tick.
	- `HeardLoudness` number? -- Its loudness as heard, after walls. `nil` when nothing is
	  remembered: it is not a distance, so there is no `math.huge` sentinel.
	- `HeardKind` string? -- What it was, when the noise was fired with a third argument
	  (`"Footstep"`, `"Door"`, `"Gunshot"`), so a brain can react to a door differently from a step.
	- `HeardSource` Instance? -- Who or what made it, when the noise was fired with a fourth
	  argument (a player's character from [PlayerNoise], a rig from a mover's `Noise`).
	- `HeardStrength` number? -- How strongly it arrived: its loudness (after walls) times the
	  share of its reach left, `loudness * (1 - distance / (Range * loudness))`. Full loudness
	  at the agent's feet, `0` at the edge of hearing, so a brain can ignore a faint, far noise.

	All six are memory: they stay for `Memory` seconds after the last heard noise, then go
	`nil` together. They live on the blackboard, not in the sense, so a state may clear them
	early.

	One instance may serve many agents. The buffer is kept per agent, in a weak-keyed table, so
	one agent's tick emptying its buffer does not rob the others: a noise is appended to the
	buffer of every agent that has ticked at least once (an agent registers on its first Tick),
	each buffer is emptied by that agent's tick, and each is capped at `BUFFER_LIMIT` entries
	with the oldest dropped first, so an agent that stops ticking does not grow it without bound.
	The signal is connected in `new` and disconnected in `Destroy`.

	The one decision: `Accept` filters before the loudest is picked, not after. A monster chasing
	one player hands it a filter that refuses everyone else, so a louder second player cannot
	mask the chased one's steps; filtering the winner afterwards would hear nothing at all.
]]

local FormatMessage = require(script.Parent.Parent.Utility.FormatMessage)
local Options = require(script.Parent.Parent.Utility.Options)
local Perception = require(script.Parent.Perception)
local SafeAreas = require(script.Parent.Parent.World.SafeAreas)
local Tables = require(script.Parent.Parent.Utility.Tables)
local Types = require(script.Parent.Parent.Types)

------------------------------------------------------------------------------------------------------------------------

local DEFAULT_OPTIONS = table.freeze({
	Prefix = "",
	Range = 30,
	Memory = 5,
	Occlusion = 1,
	OcclusionWalls = 3,
	MinStrength = 0,
	Accept = nil :: ((source: Instance?, agent: Types.Agent) -> boolean)?,
})

--[[
	Noises kept per agent between ticks. Past this the oldest is dropped.
]]
local BUFFER_LIMIT = 64

--[=[
	@interface HearingOptions
	@within Hearing

	.Range number? -- Studs a noise of loudness `1` carries. A noise is heard within `Range * loudness`. Default `30`.
	.Memory number? -- Seconds the heard keys outlive the last heard noise. Default `5`.
	.Occlusion number? -- Loudness multiplier per wall between the noise and the agent, `0` to `1`. `1` (the default) casts no rays; `0.5` halves a noise per wall.
	.OcclusionWalls number? -- Walls counted at most. Default `3`.
	.MinStrength number? -- A noise arriving weaker than this (see `HeardStrength`) is not heard. Default `0`.
	.Accept ((source: Instance?, agent: Agent) -> boolean)? -- Checked for every noise before the loudest is picked; a noise it returns `false` for is not heard. `source` is the noise's fourth argument (`nil` when it had none). Default: every noise is heard.
	.Prefix string? -- Prepended to every key this sense writes, so two instances can coexist. Default `""`.
]=]
export type HearingOptions = {
	Prefix: string?,
	Range: number?,
	Memory: number?,
	Occlusion: number?,
	OcclusionWalls: number?,
	MinStrength: number?,
	Accept: ((source: Instance?, agent: Types.Agent) -> boolean)?,
}

type ResolvedOptions = {
	Prefix: string,
	Range: number,
	Memory: number,
	Occlusion: number,
	OcclusionWalls: number,
	MinStrength: number,
	Accept: ((source: Instance?, agent: Types.Agent) -> boolean)?,
}

type Noise = {
	Position: Vector3,
	Loudness: number,
	Kind: string?,
	Source: Instance?,
}

type self = {
	_options: ResolvedOptions,
	_buffers: { [Types.Agent]: { Noise } },
	_noises: Types.NoiseSignal,
	_connection: Types.Connection?,
	_destroyed: boolean,
}

local Hearing = {}
Hearing.__index = Hearing

export type Hearing = typeof(setmetatable({} :: self, Hearing))

------------------------------------------------------------------------------------------------------------------------

--[=[
	@class Hearing

	A [Types.Sense] that listens to a noise signal. Make one with `VluxyAI.Signal.new()`, hand it
	to every agent that should hear, and fire it with `(position, loudness?, kind?, source?)`
	whenever something makes a sound. Each tick the sense keeps the loudest noise within
	`Range * loudness` studs of the agent (the nearest on a tie) that `Accept` lets through, and
	writes `HeardPosition`, `HeardAt`, `HeardLoudness`, `HeardKind`, `HeardSource` and
	`HeardStrength`, which stay for `Memory` seconds and then clear.

	```lua
	-- During a chase, hear only the chased player.
	VluxyAI.Senses.Hearing.new(noises, {
		Accept = function(source, agent)
			local chased = agent.Blackboard.ChaseTarget
			return chased == nil or source == chased
		end,
	})
	``` One instance may serve many agents: noises
	are buffered per agent, and each agent's tick empties only its own buffer.
]=]

--[=[
	@within Hearing
	@param noises NoiseSignal -- Fired with a position, an optional loudness (default `1`), an optional kind and an optional source.
	@param options HearingOptions?
	@return Hearing
	@error "unknown option" -- A key not in `HearingOptions`.
	@error "Range must be zero or more"
	@error "MinStrength must be zero or more"
]=]
function Hearing.new(noises: Types.NoiseSignal, options: HearingOptions?): Types.Sense
	local resolved = Options.Resolve("Hearing.new", DEFAULT_OPTIONS, options :: any, { "Accept" }) :: ResolvedOptions

	if resolved.Range < 0 then
		FormatMessage.Error("Hearing: Range must be zero or more", 3)
	end
	if resolved.MinStrength < 0 then
		FormatMessage.Error("Hearing: MinStrength must be zero or more", 3)
	end

	local self: self = {
		_options = resolved,
		_buffers = setmetatable({}, { __mode = "k" }) :: any,
		_noises = noises,
		_connection = nil,
		_destroyed = false,
	}

	local hearing = setmetatable(self, Hearing)
	hearing:_connect()

	return hearing :: any
end

--[=[
	@within Hearing
	@param loudness number -- The noise's loudness as it arrives, after walls.
	@param distance number -- Studs between the noise and the listener.
	@param range number -- The sense's `Range`.
	@return number -- `loudness * (1 - distance / (range * loudness))`, never below `0`; the full loudness when the reach is `0`.

	How strongly a noise arrives, written as `HeardStrength`. Pure.
]=]
function Hearing.Strength(loudness: number, distance: number, range: number): number
	local reach = range * loudness
	if reach <= 0 then
		return loudness
	end
	return loudness * math.max(0, 1 - distance / reach)
end

--[[
	Listens to the noise signal. Called at construction and again from Tick after every agent
	that shared the sense was destroyed, so a later agent still hears.
]]
function Hearing._connect(self: Hearing)
	if self._connection ~= nil or self._destroyed then
		return
	end

	self._connection = self._noises:Connect(
		function(position: Vector3, loudness: number?, kind: string?, source: Instance?)
			self:_onNoise(position, loudness, kind, source)
		end
	)
end

------------------------------------------------------------------------------------------------------------------------

--[[
	Buffers a noise for every registered agent until its next tick. A bad position is dropped
	with a warning rather than breaking the tick later.
]]
function Hearing._onNoise(self: Hearing, position: Vector3, loudness: number?, kind: string?, source: Instance?)
	if typeof(position) ~= "Vector3" then
		FormatMessage.Warn(`Hearing: a noise was fired with {typeof(position)} instead of a Vector3 position`)
		return
	end

	local resolvedLoudness = if loudness == nil then 1 else loudness
	if type(resolvedLoudness) ~= "number" or resolvedLoudness < 0 then
		FormatMessage.Warn(`Hearing: a noise was fired with loudness {tostring(loudness)}; it must be a number >= 0`)
		return
	end

	local noise: Noise = {
		Position = position,
		Loudness = resolvedLoudness,
		Kind = if type(kind) == "string" then kind else nil,
		Source = source,
	}
	for _, buffer in self._buffers do
		table.insert(buffer, noise)
		if #buffer > BUFFER_LIMIT then
			table.remove(buffer, 1)
		end
	end
end

------------------------------------------------------------------------------------------------------------------------

--[=[
	@within Hearing
	@param agent Agent
	@param deltaTime number

	Judges every noise buffered for this agent since its last tick, writes the keys listed above
	to `agent.Blackboard` and empties the buffer. The first tick registers the agent, so it hears
	noises fired from then on.
]=]
function Hearing.Tick(self: Hearing, agent: Types.Agent, deltaTime: number)
	local _ = deltaTime
	local options = self._options
	local blackboard = Tables.Prefixed(agent.Blackboard, options.Prefix)

	self:_connect()

	local buffer = self._buffers[agent]
	if buffer == nil then
		buffer = {}
		self._buffers[agent] = buffer
	end

	local origin = Perception.PositionOf(agent)
	local now = os.clock()

	local accept = options.Accept
	local heard: Noise? = nil
	local heardDistance = math.huge
	local heardLoudness = 0
	local heardStrength = 0
	for _, noise in buffer do
		if accept ~= nil and not accept(noise.Source, agent) then
			continue
		end
		local distance = (noise.Position - origin).Magnitude
		local loudness = noise.Loudness

		-- Only a noise that could be heard through open air is worth the rays, and one from inside
		-- a safe area is not worth going to at all.
		if distance > options.Range * loudness or SafeAreas.Contains(noise.Position) then
			continue
		end
		if options.Occlusion < 1 then
			local walls =
				Perception.CountWalls(origin, noise.Position, Perception.IgnoreList(agent), options.OcclusionWalls)
			loudness *= options.Occlusion ^ walls
			if distance > options.Range * loudness then
				continue
			end
		end
		local strength = Hearing.Strength(loudness, distance, options.Range)
		if strength < options.MinStrength then
			continue
		end

		local louder = heard == nil or loudness > heardLoudness
		local asLoudButNearer = heard ~= nil and loudness == heardLoudness and distance < heardDistance
		if louder or asLoudButNearer then
			heard = noise
			heardDistance = distance
			heardLoudness = loudness
			heardStrength = strength
		end
	end
	table.clear(buffer)

	if heard ~= nil then
		blackboard.HeardPosition = heard.Position
		blackboard.HeardAt = now
		blackboard.HeardLoudness = heardLoudness
		blackboard.HeardKind = heard.Kind
		blackboard.HeardSource = heard.Source
		blackboard.HeardStrength = heardStrength
		return
	end

	local heardAt = blackboard.HeardAt
	if type(heardAt) == "number" and now - heardAt > options.Memory then
		blackboard.HeardPosition = nil
		blackboard.HeardAt = nil
		blackboard.HeardLoudness = nil
		blackboard.HeardKind = nil
		blackboard.HeardSource = nil
		blackboard.HeardStrength = nil
	end
end

--[=[
	@within Hearing

	Disconnects from the noise signal and drops every agent's buffer. The signal itself is yours;
	it is not destroyed.
]=]
function Hearing.Destroy(self: Hearing, agent: Types.Agent?)
	if agent ~= nil then
		self._buffers[agent] = nil
		if next(self._buffers) ~= nil then
			return
		end
	else
		self._destroyed = true
		table.clear(self._buffers)
	end

	local connection = self._connection
	if connection ~= nil then
		connection:Disconnect()
		self._connection = nil
	end
end

--[=[
	@within Hearing
	@param patch HearingOptions -- The options to change; the rest keep their values.
	@error "unknown option"

	Changes options after construction, for difficulty and pacing: a director widening the cone
	or shortening the memory mid-round. The same rules as `new` apply.
]=]
function Hearing.Configure(self: Hearing, patch: HearingOptions)
	self._options = Options.Resolve("Hearing.Configure", self._options, patch :: any, { "Accept" }) :: ResolvedOptions
	if self._options.Range < 0 then
		FormatMessage.Error("Hearing: Range must be zero or more", 3)
	end
end

return Hearing
