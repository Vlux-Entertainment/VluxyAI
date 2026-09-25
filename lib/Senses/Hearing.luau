--!strict

--[[
	What the agent heard. Any code fires a [Types.Signal] with a world position and an optional
	loudness (`1` by default); the sense buffers those between ticks and, on each tick, keeps the
	loudest noise close enough to hear, then drops the rest. A noise carries to `Range * loudness`
	studs, so a gunshot at loudness 3 is heard three times as far as a footstep at 1.

	Writes to the blackboard:

	- `HeardPosition` Vector3? -- Where the last heard noise was.
	- `HeardAt` number? -- `os.clock()` of that tick.
	- `HeardLoudness` number? -- Its loudness. `nil` when nothing is remembered: it is not a
	  distance, so there is no `math.huge` sentinel.

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
local Types = require(script.Parent.Parent.Types)

------------------------------------------------------------------------------------------------------------------------

local DEFAULT_OPTIONS = table.freeze({
	Range = 30,
	Memory = 5,
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
]=]
export type HearingOptions = {
	Range: number?,
	Memory: number?,
}

type ResolvedOptions = {
	Range: number,
	Memory: number,
}

type Noise = {
	Position: Vector3,
	Loudness: number,
}

type self = {
	_options: ResolvedOptions,
	_buffers: { [Types.Agent]: { Noise } },
	_connection: Types.Connection?,
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

	Distances are `math.huge` when there is nothing to measure; Hearing writes none, and
	`HeardLoudness` is `nil` when nothing is remembered because a loudness is not a distance.
]=]

--[=[
	@within Hearing
	@param noises Signal<(Vector3, number?)> -- Fired with a position and an optional loudness (default `1`).
	@param options HearingOptions?
	@return Hearing
	@error "unknown option" -- A key not in [HearingOptions].
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
		_connection = nil,
	}

	local hearing = setmetatable(self, Hearing)

	self._connection = noises:Connect(function(position: Vector3, loudness: number?)
		hearing:_onNoise(position, loudness)
	end)

	return hearing :: any
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
	local blackboard = agent.Blackboard

	local buffer = self._buffers[agent]
	if buffer == nil then
		buffer = {}
		self._buffers[agent] = buffer
	end

	local origin = Perception.PositionOf(agent)
	local now = os.clock()

	local heard: Noise? = nil
	local heardDistance = math.huge
	for _, noise in buffer do
		local distance = (noise.Position - origin).Magnitude
		if distance > options.Range * noise.Loudness then
			continue
		end

		local louder = heard == nil or noise.Loudness > heard.Loudness
		local asLoudButNearer = heard ~= nil and noise.Loudness == heard.Loudness and distance < heardDistance
		if louder or asLoudButNearer then
			heard = noise
			heardDistance = distance
		end
	end
	table.clear(buffer)

	if heard ~= nil then
		blackboard.HeardPosition = heard.Position
		blackboard.HeardAt = now
		blackboard.HeardLoudness = heard.Loudness
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
function Hearing.Destroy(self: Hearing)
	local connection = self._connection
	if connection ~= nil then
		connection:Disconnect()
		self._connection = nil
	end

	table.clear(self._buffers)
end

return Hearing
