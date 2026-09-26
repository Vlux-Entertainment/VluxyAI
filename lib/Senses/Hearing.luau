--!strict

--[[
	What the agent heard. Any code fires a [Types.Signal] with a world position and an optional
	loudness (`1` by default); the sense buffers those between ticks and, on each tick, keeps the
	loudest noise close enough to hear, then drops the rest. A noise carries to `Range * loudness`
	studs, so a gunshot at loudness 3 is heard three times as far as a footstep at 1.

	Writes to the blackboard:

	- `HeardPosition` Vector3? -- Where the last heard noise was.
	- `HeardAt` number? -- `os.clock()` of that tick.
	- `HeardLoudness` number? -- Its loudness as heard, after walls. `nil` when nothing is
	  remembered: it is not a distance, so there is no `math.huge` sentinel.

	All three are memory: they stay for `Memory` seconds after the last heard noise, then go
	`nil` together. They live on the blackboard, not in the sense, so a state may clear them
	early.

	One instance may serve many agents. The buffer is kept per agent, in a weak-keyed table, so
	one agent's tick emptying its buffer does not rob the others: a noise is appended to the
	buffer of every agent that has ticked at least once (an agent registers on its first Tick),
	each buffer is emptied by that agent's tick, and each is capped at `BUFFER_LIMIT` entries
	with the oldest dropped first, so an agent that stops ticking does not grow it without bound.
	The signal is connected in `new` and disconnected in `Destroy`.
]]

local FormatMessage = require(script.Parent.Parent.Utility.FormatMessage)
local Options = require(script.Parent.Parent.Utility.Options)
local Perception = require(script.Parent.Perception)
local Tables = require(script.Parent.Parent.Utility.Tables)
local Types = require(script.Parent.Parent.Types)

------------------------------------------------------------------------------------------------------------------------

local DEFAULT_OPTIONS = table.freeze({
	Prefix = "",
	Range = 30,
	Memory = 5,
	Occlusion = 1,
	OcclusionWalls = 3,
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
	.Prefix string? -- Prepended to every key this sense writes, so two instances can coexist. Default `""`.
]=]
export type HearingOptions = {
	Prefix: string?,
	Range: number?,
	Memory: number?,
	Occlusion: number?,
	OcclusionWalls: number?,
}

type ResolvedOptions = {
	Prefix: string,
	Range: number,
	Memory: number,
	Occlusion: number,
	OcclusionWalls: number,
}

type Noise = {
	Position: Vector3,
	Loudness: number,
}

type self = {
	_options: ResolvedOptions,
	_buffers: { [Types.Agent]: { Noise } },
	_noises: Types.Signal<(Vector3, number?)>,
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
	to every agent that should hear, and fire it with `(position, loudness?)` whenever something
	makes a sound. Each tick the sense keeps the loudest noise within `Range * loudness` studs of
	the agent (the nearest on a tie) and writes `HeardPosition`, `HeardAt` and `HeardLoudness`,
	which stay for `Memory` seconds and then clear. One instance may serve many agents: noises
	are buffered per agent, and each agent's tick empties only its own buffer.
]=]

--[=[
	@within Hearing
	@param noises Signal<(Vector3, number?)> -- Fired with a position and an optional loudness (default `1`).
	@param options HearingOptions?
	@return Hearing
	@error "unknown option" -- A key not in `HearingOptions`.
	@error "Range must be zero or more"
]=]
function Hearing.new(noises: Types.Signal<(Vector3, number?)>, options: HearingOptions?): Types.Sense
	local resolved = Options.Resolve("Hearing.new", DEFAULT_OPTIONS, options :: any) :: ResolvedOptions

	if resolved.Range < 0 then
		FormatMessage.Error("Hearing: Range must be zero or more", 3)
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

--[[
	Listens to the noise signal. Called at construction and again from Tick after every agent
	that shared the sense was destroyed, so a later agent still hears.
]]
function Hearing._connect(self: Hearing)
	if self._connection ~= nil or self._destroyed then
		return
	end

	self._connection = self._noises:Connect(function(position: Vector3, loudness: number?)
		self:_onNoise(position, loudness)
	end)
end

------------------------------------------------------------------------------------------------------------------------

--[[
	Buffers a noise for every registered agent until its next tick. A bad position is dropped
	with a warning rather than breaking the tick later.
]]
function Hearing._onNoise(self: Hearing, position: Vector3, loudness: number?)
	if typeof(position) ~= "Vector3" then
		FormatMessage.Warn(`Hearing: a noise was fired with {typeof(position)} instead of a Vector3 position`)
		return
	end

	local resolvedLoudness = if loudness == nil then 1 else loudness
	if type(resolvedLoudness) ~= "number" or resolvedLoudness < 0 then
		FormatMessage.Warn(`Hearing: a noise was fired with loudness {tostring(loudness)}; it must be a number >= 0`)
		return
	end

	local noise: Noise = { Position = position, Loudness = resolvedLoudness }
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

	local heard: Noise? = nil
	local heardDistance = math.huge
	local heardLoudness = 0
	for _, noise in buffer do
		local distance = (noise.Position - origin).Magnitude
		local loudness = noise.Loudness

		-- Only a noise that could be heard through open air is worth the rays.
		if distance > options.Range * loudness then
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

		local louder = heard == nil or loudness > heardLoudness
		local asLoudButNearer = heard ~= nil and loudness == heardLoudness and distance < heardDistance
		if louder or asLoudButNearer then
			heard = noise
			heardDistance = distance
			heardLoudness = loudness
		end
	end
	table.clear(buffer)

	if heard ~= nil then
		blackboard.HeardPosition = heard.Position
		blackboard.HeardAt = now
		blackboard.HeardLoudness = heardLoudness
		return
	end

	local heardAt = blackboard.HeardAt
	if type(heardAt) == "number" and now - heardAt > options.Memory then
		blackboard.HeardPosition = nil
		blackboard.HeardAt = nil
		blackboard.HeardLoudness = nil
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
	self._options = Options.Resolve("Hearing.Configure", self._options, patch :: any, nil) :: ResolvedOptions
	if self._options.Range < 0 then
		FormatMessage.Error("Hearing: Range must be zero or more", 3)
	end
end

return Hearing
