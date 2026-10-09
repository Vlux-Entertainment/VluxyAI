--!strict

--[[
	Voice lines: an agent says a random line from a pool for its current state every so often, and
	sometimes as it enters a state. Added as a sense, so it runs every tick whatever the brain is
	doing, and no state has to remember to speak.

	The one decision: the line is played on the server, in a Sound under the rig's root. A Sound
	played on the server is heard by every client at the same moment, so every player hears the
	same line from the same place; and the line is also announced with Agent:Emit, for subtitles.
	A game that wants the audio on the client passes its own `Play`.

	Nothing touches Roblox at module scope. `Pick` and `NextDelay` are pure and specced.
]]

local FormatMessage = require(script.Parent.Parent.Utility.FormatMessage)
local Options = require(script.Parent.Parent.Utility.Options)
local Types = require(script.Parent.Parent.Types)

------------------------------------------------------------------------------------------------------------------------

-- The pool used in any state that has none of its own.
local ANY_STATE = "*"

local DEFAULT_OPTIONS = table.freeze({
	Interval = { 6, 14 } :: { number },
	OnEnter = 0.5,
	Volume = 0.8,
	PitchVariation = 0.08,
	RollOffMin = 8,
	RollOffMax = 80,
	Emit = "Voice",
})

local ALLOWED = { "Lines", "Play", "Random" }

export type VoiceLine = number | string

--[=[
	@interface VoiceOptions
	@within Voice

	.Lines { [string]: { number | string } } -- Line pools by state name: asset ids (or `rbxasset://` strings). `"*"` is the pool for any state without its own; a state with neither is silent.
	.Interval { number }? -- `{ min, max }` seconds between lines while in a state. Default `{ 6, 14 }`.
	.OnEnter (number | { [string]: number })? -- Chance, `0` to `1`, of a line as the agent enters a state that has lines; or chances by state name, `"*"` for the rest (a state missing from the table gets `0.5`). Default `0.5`.
	.Volume number? -- Default `0.8`.
	.PitchVariation number? -- Random spread of `PlaybackSpeed` around `1`, so a repeated line does not sound stamped. Default `0.08`.
	.RollOffMin number? -- Studs heard at full volume. Default `8`.
	.RollOffMax number? -- Studs until silent. Default `80`.
	.Emit string? -- Announced with [Agent:Emit] as each line plays, `{ Line, State }` as the payload, for subtitles. `""` announces nothing. Default `"Voice"`.
	.Play ((agent: Agent, line: number | string) -> number?)? -- Plays a line your way instead (on the client, through your sound system) and returns its length in seconds. Default: a Sound under the rig's root, on the server.
	.Random Random? -- Default `agent.Data.Random`, else a new one.
]=]
export type VoiceOptions = {
	Lines: { [string]: { VoiceLine } },
	Interval: { number }?,
	OnEnter: (number | { [string]: number })?,
	Volume: number?,
	PitchVariation: number?,
	RollOffMin: number?,
	RollOffMax: number?,
	Emit: string?,
	Play: ((agent: Types.Agent, line: VoiceLine) -> number?)?,
	Random: Random?,
}

type ResolvedOptions = {
	Lines: { [string]: { VoiceLine } },
	Interval: { number },
	OnEnter: number | { [string]: number },
	Volume: number,
	PitchVariation: number,
	RollOffMin: number,
	RollOffMax: number,
	Emit: string,
	Play: ((agent: Types.Agent, line: VoiceLine) -> number?)?,
	Random: Random?,
}

type self = {
	_options: ResolvedOptions,
	_state: string?,
	_nextAt: number,
	_quietUntil: number,
	_last: VoiceLine?,
	_sound: Sound?,
}

local Voice = {}
Voice.__index = Voice

export type Voice = typeof(setmetatable({} :: self, Voice))

--[=[
	@class Voice

	Random voice lines by state. Make one per agent and add it as a sense:

	```lua
	:AddSense(VluxyAI.Voice.new({
		Lines = {
			Patrol = { 9113636490, 9113636491 }, -- low groans while it wanders
			Hunt = { 105926319962443 },          -- a growl now and then while it chases
			["*"] = { 9113636681 },              -- anything else
		},
		Interval = { 5, 12 },
	}))
	```

	A line never repeats twice in a row when the pool has another, never talks over the line
	before it, and waits `Interval` between lines.
]=]

--[=[
	@within Voice
	@param options VoiceOptions
	@return Sense
	@error "unknown option"
	@error "Lines needs at least one pool"
	@error "Interval must be { min, max } with 0 <= min <= max"
]=]
function Voice.new(options: VoiceOptions): Types.Sense
	local resolved = Options.Resolve("Voice.new", DEFAULT_OPTIONS :: any, options :: any, ALLOWED) :: ResolvedOptions

	if type(resolved.Lines) ~= "table" or next(resolved.Lines) == nil then
		FormatMessage.Error("Voice.new: Lines needs at least one pool, keyed by state name", 2)
	end
	local interval = resolved.Interval
	if type(interval) ~= "table" or #interval ~= 2 or interval[1] < 0 or interval[2] < interval[1] then
		FormatMessage.Error("Voice.new: Interval must be { min, max } with 0 <= min <= max", 2)
	end

	local self: self = {
		_options = resolved,
		_state = nil,
		_nextAt = math.huge,
		_quietUntil = -math.huge,
		_last = nil,
		_sound = nil,
	}
	return setmetatable(self, Voice) :: any
end

--[=[
	@within Voice
	@param pool { number | string }
	@param last (number | string)?
	@param random Random
	@return (number | string)? -- A random line from `pool`, never `last` when there is another, `nil` for an empty pool.

	Pure.
]=]
function Voice.Pick(pool: { VoiceLine }, last: VoiceLine?, random: Random): VoiceLine?
	local count = #pool
	if count == 0 then
		return nil
	end
	if count == 1 then
		return pool[1]
	end
	local index = random:NextInteger(1, count)
	if pool[index] == last then
		-- Step to a neighbour instead of rolling again, so the choice stays one draw.
		index = index % count + 1
	end
	return pool[index]
end

--[=[
	@within Voice
	@param interval { number } -- `{ min, max }`.
	@param random Random
	@return number -- Seconds until the next line.

	Pure.
]=]
function Voice.NextDelay(interval: { number }, random: Random): number
	return random:NextNumber(interval[1], interval[2])
end

--[[
	The chance of a line on entering `state`.
]]
local function enterChance(onEnter: number | { [string]: number }, state: string): number
	if type(onEnter) == "number" then
		return onEnter
	end
	local chances = onEnter :: { [string]: number }
	return chances[state] or chances[ANY_STATE] or DEFAULT_OPTIONS.OnEnter
end

--[[
	The Random to draw with: the option, the agent's own, or a new one.
]]
local function randomOf(self: Voice, agent: Types.Agent): Random
	local given = self._options.Random or agent.Data.Random
	if typeof(given) == "Random" or (type(given) == "table" and type((given :: any).NextNumber) == "function") then
		return given :: Random
	end
	local made = Random.new()
	self._options.Random = made
	return made
end

--[[
	The default playback: one Sound under the rig's root, reused for every line. Returns how long
	the line runs, a guess when it has not loaded yet.
]]
function Voice._playOnRig(self: Voice, agent: Types.Agent, line: VoiceLine, random: Random): number
	local options = self._options
	if (agent.Entity :: Model?) == nil then
		FormatMessage.Error(`{agent.Name}: Voice has no rig to play from on a headless agent; give it a Play option`, 0)
	end
	local root = agent.Entity.PrimaryPart
	if root == nil then
		return 0
	end

	local sound = self._sound
	if sound == nil or sound.Parent ~= root then
		local created = Instance.new("Sound")
		created.Name = "VluxyAI_Voice"
		created.RollOffMode = Enum.RollOffMode.InverseTapered
		created.RollOffMinDistance = options.RollOffMin
		created.RollOffMaxDistance = options.RollOffMax
		created.Parent = root
		self._sound = created
		sound = created
	end

	local playing = sound :: Sound
	playing.SoundId = if type(line) == "number" then `rbxassetid://{line}` else line
	playing.Volume = options.Volume
	local spread = options.PitchVariation
	playing.PlaybackSpeed = if spread > 0 then 1 + random:NextNumber(-spread, spread) else 1
	playing:Play()

	local length = playing.TimeLength
	return if length > 0 then length / playing.PlaybackSpeed else 3
end

--[[
	Says a line from `pool`: plays it, announces it, and keeps quiet until it is over.
]]
function Voice._say(self: Voice, agent: Types.Agent, pool: { VoiceLine }, state: string, now: number, random: Random)
	local line = Voice.Pick(pool, self._last, random)
	if line == nil then
		return
	end
	self._last = line

	local options = self._options
	local length: number? = nil
	if options.Play then
		length = options.Play(agent, line)
	else
		length = self:_playOnRig(agent, line, random)
	end
	self._quietUntil = now + (length or 0)

	if options.Emit ~= "" then
		agent:Emit(options.Emit, { Line = line, State = state })
	end
end

--[=[
	@within Voice
	@param agent Agent
	@param deltaTime number

	Checks the agent's state: on entering one with lines it may speak at once (`OnEnter`), and
	while in it speaks every `Interval`, never over its own last line.
]=]
function Voice.Tick(self: Voice, agent: Types.Agent, deltaTime: number)
	local _ = deltaTime
	local options = self._options
	local state = agent:GetState()
	local pool = if state ~= nil then options.Lines[state] or options.Lines[ANY_STATE] else nil
	local now = os.clock()
	local random = randomOf(self, agent)

	if state ~= self._state then
		self._state = state
		if pool == nil or #pool == 0 then
			self._nextAt = math.huge
			return
		end
		self._nextAt = now + Voice.NextDelay(options.Interval, random)
		if now >= self._quietUntil and random:NextNumber() < enterChance(options.OnEnter, state :: string) then
			self:_say(agent, pool, state :: string, now, random)
		end
		return
	end

	if pool == nil or #pool == 0 or now < self._nextAt then
		return
	end
	if now < self._quietUntil then
		-- Still talking: try again once the line is over.
		self._nextAt = self._quietUntil
		return
	end
	self:_say(agent, pool, state :: string, now, random)
	self._nextAt = now + Voice.NextDelay(options.Interval, random)
end

--[=[
	@within Voice

	Removes the rig's voice Sound.
]=]
function Voice.Destroy(self: Voice)
	if self._sound then
		self._sound:Destroy()
		self._sound = nil
	end
end

return Voice
