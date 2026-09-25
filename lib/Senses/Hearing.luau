--!strict

--[[
	What the agent heard. Any code fires a [Types.Signal] with a world position and an optional
	loudness (`1` by default); the sense buffers those between ticks and, on each tick, keeps the
	loudest noise close enough to hear, then drops the rest. A noise carries to `Range * loudness`
	studs, so a gunshot at loudness 3 is heard three times as far as a footstep at 1.

	Writes to the blackboard:

	- `HeardPosition` Vector3? -- Where the last heard noise was.
	- `HeardAt` number? -- `os.clock()` of that tick.
	- `HeardLoudness` number? -- Its loudness.

	All three are memory: they stay for `Memory` seconds after the last heard noise, then go
	`nil` together. They live on the blackboard, not in the sense, so a state may clear them
	early.

	The buffer is the only thing the sense keeps between ticks, and it is emptied every tick,
	heard or not. The signal is connected in `new` and disconnected in `Destroy`.
]]

local FormatMessage = require(script.Parent.Parent.Utility.FormatMessage)
local Perception = require(script.Parent.Perception)
local Types = require(script.Parent.Parent.Types)

------------------------------------------------------------------------------------------------------------------------

local DEFAULT_OPTIONS = table.freeze({
	Range = 30,
	Memory = 5,
})

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

type Options = {
	Range: number,
	Memory: number,
}

type Noise = {
	Position: Vector3,
	Loudness: number,
}

type self = {
	_options: Options,
	_buffer: { Noise },
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
	which stay for `Memory` seconds and then clear.
]=]

--[=[
	@within Hearing
	@param noises Signal<(Vector3, number?)> -- Fired with a position and an optional loudness (default `1`).
	@param options HearingOptions?
	@return Hearing
]=]
function Hearing.new(noises: Types.Signal<(Vector3, number?)>, options: HearingOptions?): Types.Sense
	local resolved = table.clone(DEFAULT_OPTIONS) :: any
	for key, value in (options or {}) :: any do
		resolved[key] = value
	end

	if resolved.Range < 0 then
		FormatMessage.Error("Hearing: Range must be zero or more", 3)
	end

	local self: self = {
		_options = resolved,
		_buffer = {},
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
	Buffers a noise until the next tick. A bad position is dropped with a warning rather than
	breaking the tick later.
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

	table.insert(self._buffer, { Position = position, Loudness = resolvedLoudness })
end

------------------------------------------------------------------------------------------------------------------------

--[=[
	@within Hearing
	@param agent Agent
	@param deltaTime number

	Judges every noise buffered since the last tick, writes the keys listed above to
	`agent.Blackboard` and empties the buffer.
]=]
function Hearing.Tick(self: Hearing, agent: Types.Agent, deltaTime: number)
	local _ = deltaTime
	local options = self._options
	local blackboard = agent.Blackboard

	local origin = Perception.PositionOf(agent)
	local now = os.clock()

	local heard: Noise? = nil
	local heardDistance = math.huge
	for _, noise in self._buffer do
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
	table.clear(self._buffer)

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

	Disconnects from the noise signal and drops anything buffered. The signal itself is yours; it
	is not destroyed.
]=]
function Hearing.Destroy(self: Hearing)
	local connection = self._connection
	if connection ~= nil then
		connection:Disconnect()
		self._connection = nil
	end

	table.clear(self._buffer)
end

return Hearing
