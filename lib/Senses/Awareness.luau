--!strict

--[[
	The detection meter. Reads what the other senses wrote this tick and turns it into one number
	that rises while something is in view or a noise arrives, and drains when nothing is, with
	two thresholds on the way up: Suspicious and Alerted. It also keeps one last known position,
	whichever sense saw or heard it last, so a brain has a single place to go and look.

	Writes to the blackboard:

	- `Awareness` number -- `0` to `1`.
	- `AwarenessLevel` "Calm" | "Suspicious" | "Alerted".
	- `LastKnownPosition` Vector3? -- The latest position any source gave. `nil` once calm again.
	- `LastKnownAt` number? -- `os.clock()` of that.
	- `LastKnownSource` string? -- The `Name` of the source that gave it.

	A source is either a `While` key (present every tick something is there, such as
	`SeenTarget`: the meter rises at `Rise * Weight` per second) or an `At` key (a timestamp
	that changes once per event, such as `HeardAt`: the meter jumps by `Weight` once per new
	value). Which `At` values were already counted is kept in `agent.Data.Awareness`, so one
	instance serves many agents. Must tick after the senses it reads. Pure Luau.
]]

local FormatMessage = require(script.Parent.Parent.Utility.FormatMessage)
local Options = require(script.Parent.Parent.Utility.Options)
local Types = require(script.Parent.Parent.Types)

------------------------------------------------------------------------------------------------------------------------

--[=[
	@interface AwarenessSource
	@within Awareness

	.Name string -- Written to `LastKnownSource` when this source is the latest.
	.While string? -- A blackboard key that is non-nil every tick the stimulus is present, such as `SeenTarget`. The meter rises at `Rise * Weight` per second.
	.At string? -- A blackboard key holding a timestamp that changes per event, such as `HeardAt`. The meter jumps by `Weight` once per new value.
	.Position string? -- The blackboard key holding where it is, copied to `LastKnownPosition`.
	.Weight number? -- Default `1`.
]=]
export type AwarenessSource = {
	Name: string,
	While: string?,
	At: string?,
	Position: string?,
	Weight: number?,
}

local DEFAULT_SOURCES: { AwarenessSource } = {
	{ Name = "Sight", While = "SeenTarget", Position = "SeenPosition", Weight = 1 } :: AwarenessSource,
	{ Name = "Hearing", At = "HeardAt", Position = "HeardPosition", Weight = 0.5 } :: AwarenessSource,
	{ Name = "Sound", At = "HeardSoundAt", Position = "HeardSoundPosition", Weight = 0.3 } :: AwarenessSource,
}
table.freeze(DEFAULT_SOURCES)

local DEFAULT_OPTIONS = table.freeze({
	Rise = 1,
	Fall = 0.25,
	Suspicious = 0.3,
	Alerted = 1,
	Sources = DEFAULT_SOURCES,
	Key = "Awareness",
})

--[=[
	@interface AwarenessOptions
	@within Awareness

	.Rise number | (agent: Agent) -> number? -- How much the meter rises per second per unit of `While` weight, or a function of the agent (closer means faster, say). Default `1`.
	.Fall number? -- How much it drains per second when no source is present. Default `0.25`.
	.Suspicious number? -- The level at which `AwarenessLevel` becomes `"Suspicious"`. Default `0.3`.
	.Alerted number? -- The level at which it becomes `"Alerted"`. Default `1`.
	.Sources { AwarenessSource }? -- What feeds the meter. Default: `SeenTarget` at weight 1, `HeardAt` at 0.5, `HeardSoundAt` at 0.3.
	.Key string? -- The `agent.Data` key for the counted timestamps. Default `"Awareness"`.
]=]
export type AwarenessOptions = {
	Rise: (number | (agent: Types.Agent) -> number)?,
	Fall: number?,
	Suspicious: number?,
	Alerted: number?,
	Sources: { AwarenessSource }?,
	Key: string?,
}

type ResolvedOptions = {
	Rise: number | (agent: Types.Agent) -> number,
	Fall: number,
	Suspicious: number,
	Alerted: number,
	Sources: { AwarenessSource },
	Key: string,
}

type self = {
	_options: ResolvedOptions,
}

local Awareness = {}
Awareness.__index = Awareness

export type Awareness = typeof(setmetatable({} :: self, Awareness))

--[=[
	@class Awareness

	A [Types.Sense] that turns sightings and noises into a detection meter, the way a stealth
	game does it: a player who steps into view is not hunted at once but makes the enemy
	suspicious, then alerted if they stay; a noise nudges the meter; silence drains it. Exposed
	as `VluxyAI.Senses.Awareness`. Add it after [Sight], [Hearing] and [Sounds], since it reads
	what they wrote.

	```lua
	:AddSense(VluxyAI.Senses.Sight.new({ Range = 40 }))
	:AddSense(VluxyAI.Senses.Hearing.new(noises))
	:AddSense(VluxyAI.Senses.Awareness.new({ Rise = 0.8, Fall = 0.2 }))

	Interrupts = {
		{ To = "Hunt", When = When.Equals("AwarenessLevel", "Alerted"), Except = { "Hunt", "Attack" } },
		{ To = "Investigate", When = When.Equals("AwarenessLevel", "Suspicious"), Except = { "Hunt", "Attack", "Investigate" } },
	},
	Investigate = States.Investigate({ Target = "LastKnownPosition", Then = "Patrol" }),
	```
]=]

--[=[
	@within Awareness
	@param options AwarenessOptions?
	@return Awareness
	@error "unknown option"
	@error string -- A source without a `Name`, or with neither `While` nor `At`.
]=]
function Awareness.new(options: AwarenessOptions?): Types.Sense
	local resolved = Options.Resolve("Awareness.new", DEFAULT_OPTIONS, options :: any) :: ResolvedOptions

	for index, source in resolved.Sources do
		if type(source.Name) ~= "string" then
			FormatMessage.Error(`Awareness.new: Sources[{index}].Name must be a string`, 3)
		end
		if source.While == nil and source.At == nil then
			FormatMessage.Error(`Awareness.new: Sources[{index}] ({source.Name}) needs a While or an At key`, 3)
		end
	end

	local self: self = {
		_options = resolved,
	}

	return setmetatable(self, Awareness) :: any
end

------------------------------------------------------------------------------------------------------------------------

--[[
	The level name for a meter value.
]]
local function levelOf(value: number, options: ResolvedOptions): string
	if value >= options.Alerted then
		return "Alerted"
	end
	if value >= options.Suspicious then
		return "Suspicious"
	end
	return "Calm"
end

--[=[
	@within Awareness
	@param agent Agent
	@param deltaTime number

	Reads the sources, moves the meter and writes the keys listed above to `agent.Blackboard`.
]=]
function Awareness.Tick(self: Awareness, agent: Types.Agent, deltaTime: number)
	local options = self._options
	local blackboard = agent.Blackboard

	local counted = agent.Data[options.Key]
	if type(counted) ~= "table" then
		counted = {}
		agent.Data[options.Key] = counted
	end

	local current = blackboard.Awareness
	if type(current) ~= "number" then
		current = 0
	end

	local rise = options.Rise
	local riseRate = if type(rise) == "function" then rise(agent) else rise
	local now = os.clock()

	local present = false
	local latestPosition: Vector3? = nil
	local latestSource: string? = nil

	for _, source in options.Sources do
		local weight = source.Weight or 1
		local stimulated = false

		if source.While ~= nil and blackboard[source.While] ~= nil then
			current += riseRate * weight * deltaTime
			stimulated = true
		end

		if source.At ~= nil then
			local stamp = blackboard[source.At]
			if stamp ~= nil and stamp ~= counted[source.At] then
				counted[source.At] = stamp
				current += weight
				stimulated = true
			elseif stamp == nil then
				counted[source.At] = nil
			end
		end

		if stimulated then
			present = true
			local position = if source.Position then blackboard[source.Position] else nil
			if typeof(position) == "Vector3" then
				latestPosition = position
				latestSource = source.Name
			end
		end
	end

	if not present then
		current -= options.Fall * deltaTime
	end
	current = math.clamp(current, 0, 1)

	blackboard.Awareness = current
	blackboard.AwarenessLevel = levelOf(current, options)

	if latestPosition ~= nil then
		blackboard.LastKnownPosition = latestPosition
		blackboard.LastKnownAt = now
		blackboard.LastKnownSource = latestSource
	elseif current <= 0 then
		blackboard.LastKnownPosition = nil
		blackboard.LastKnownAt = nil
		blackboard.LastKnownSource = nil
	end
end

return Awareness
