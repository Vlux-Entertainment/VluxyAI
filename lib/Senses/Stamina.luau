--!strict

--[[
	Stamina: a meter from 0 to 1 that drains while the agent moves faster than a threshold and
	recovers otherwise, measured from how far the agent actually moved, so a sprinting enemy tires
	whatever state or mover made it run. Brains read it to rest, to stop a chase, or to slow down.

	Pure Luau apart from the agent's position; specced.
]]

local FormatMessage = require(script.Parent.Parent.Utility.FormatMessage)
local Options = require(script.Parent.Parent.Utility.Options)
local Tables = require(script.Parent.Parent.Utility.Tables)
local Types = require(script.Parent.Parent.Types)

------------------------------------------------------------------------------------------------------------------------

local DEFAULT_OPTIONS = table.freeze({
	Key = "Stamina",
	Threshold = 10,
	Drain = 0.1,
	Regen = 0.2,
	Prefix = "",
})

--[=[
	@interface StaminaOptions
	@within Stamina

	.Threshold number? -- Studs per second above which the meter drains. Default `10`.
	.Drain number? -- Per second while above `Threshold`. `1 / Drain` seconds empties a full meter. Default `0.1`.
	.Regen number? -- Per second otherwise. Default `0.2`.
	.Key string? -- The blackboard key written, `0` to `1`. It starts at whatever the blackboard holds there, else `1`. Default `"Stamina"`.
	.Prefix string? -- Prepended to the key. Default `""`.
]=]
export type StaminaOptions = {
	Threshold: number?,
	Drain: number?,
	Regen: number?,
	Key: string?,
	Prefix: string?,
}

type ResolvedOptions = {
	Threshold: number,
	Drain: number,
	Regen: number,
	Key: string,
	Prefix: string,
}

type self = {
	_options: ResolvedOptions,
	_last: { [any]: Vector3 },
}

local Stamina = {}
Stamina.__index = Stamina

export type Stamina = typeof(setmetatable({} :: self, Stamina))

--[=[
	@class Stamina

	A [Types.Sense] for tiring: drains while the agent moves faster than `Threshold`, recovers
	otherwise, and writes the meter under `Key`. A brain rests at `0` and hunts again once it has
	recovered, and a sprint has a length the player can learn.

	```lua
	:AddSense(VluxyAI.Senses.Stamina.new({ Threshold = 10, Drain = 0.07, Regen = 0.2 }))
	-- in the brain
	{ To = "Rest", When = VluxyAI.When.Below("Stamina", 0.01) },
	```
]=]

--[=[
	@within Stamina
	@param options StaminaOptions?
	@return Stamina
	@error "unknown option"
	@error "Drain and Regen must be zero or more"
]=]
function Stamina.new(options: StaminaOptions?): Types.Sense
	local resolved = Options.Resolve("Stamina.new", DEFAULT_OPTIONS, options :: any) :: ResolvedOptions
	if resolved.Drain < 0 or resolved.Regen < 0 then
		FormatMessage.Error("Stamina: Drain and Regen must be zero or more", 3)
	end
	local self: self = { _options = resolved, _last = setmetatable({}, { __mode = "k" }) :: any }
	return setmetatable(self, Stamina) :: any
end

--[=[
	@within Stamina
	@param agent Agent
	@param deltaTime number

	Measures the speed since the last tick and moves the meter.
]=]
function Stamina.Tick(self: Stamina, agent: Types.Agent, deltaTime: number)
	local options = self._options
	local blackboard = Tables.Prefixed(agent.Blackboard, options.Prefix)
	local position = agent:GetPosition()
	local last: Vector3? = self._last[agent]
	self._last[agent] = position

	local current = blackboard[options.Key]
	local meter = if type(current) == "number" then current else 1
	if last and deltaTime > 0 then
		local speed = Tables.FlatDistance(position, last) / deltaTime
		if speed > options.Threshold then
			meter -= options.Drain * deltaTime
		else
			meter += options.Regen * deltaTime
		end
	end
	blackboard[options.Key] = math.clamp(meter, 0, 1)
end

--[=[
	@within Stamina

	Nothing to release.
]=]
function Stamina.Destroy(self: Stamina)
	local _ = self
end

return Stamina
