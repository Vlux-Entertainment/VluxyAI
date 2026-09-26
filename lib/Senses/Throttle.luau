--!strict

--[[
	A sense that ticks another sense less often. Sight costs raycasts per tick and twenty
	enemies at 0.1 seconds add up; wrapping it in a Throttle runs it every `Interval` seconds
	while the brain and the cheap senses keep the full tick. The wrapped sense receives the time
	that really passed since it last ran. Time is kept per agent in a weak-keyed table, so one
	throttled sense serves many agents. Pure Luau.
]]

local FormatMessage = require(script.Parent.Parent.Utility.FormatMessage)
local Types = require(script.Parent.Parent.Types)

------------------------------------------------------------------------------------------------------------------------

type self = {
	_inner: Types.Sense,
	_interval: number,
	_elapsed: { [Types.Agent]: number },
}

local Throttle = {}
Throttle.__index = Throttle

export type Throttle = typeof(setmetatable({} :: self, Throttle))

--[=[
	@class Throttle

	Wraps a [Types.Sense] so it ticks every `interval` seconds instead of every agent tick. The
	first tick runs at once. Exposed as `VluxyAI.Senses.Throttle`.

	```lua
	:AddSense(VluxyAI.Senses.Throttle.new(VluxyAI.Senses.Sight.new({ Range = 40 }), 0.3))
	```

	The wrapped sense's blackboard keys keep their last values between runs, so a memory such as
	`SeenPosition` still ages by the wrapped sense's own clock.
]=]

--[=[
	@within Throttle
	@param sense Sense -- The sense to slow down.
	@param interval number -- Seconds between its ticks. Must be above `0`.
	@return Throttle
	@error string -- `sense` has no `Tick`, or `interval` is not above `0`.
]=]
function Throttle.new(sense: Types.Sense, interval: number): Types.Sense
	if type(sense) ~= "table" or type(sense.Tick) ~= "function" then
		FormatMessage.Error("Throttle.new: needs a sense with Tick", 2)
	end
	if type(interval) ~= "number" or interval <= 0 then
		FormatMessage.Error(`Throttle.new: interval must be above 0, got {tostring(interval)}`, 2)
	end

	local self: self = {
		_inner = sense,
		_interval = interval,
		_elapsed = setmetatable({}, { __mode = "k" }) :: any,
	}

	return setmetatable(self, Throttle) :: any
end

--[=[
	@within Throttle
	@param agent Agent
	@param deltaTime number

	Adds `deltaTime` to this agent's clock and ticks the wrapped sense with the time gathered
	once it reaches the interval.
]=]
function Throttle.Tick(self: Throttle, agent: Types.Agent, deltaTime: number)
	local elapsed = self._elapsed[agent]
	if elapsed == nil then
		-- The first tick runs at once, so the blackboard is never empty on the first brain tick.
		self._elapsed[agent] = 0
		self._inner:Tick(agent, deltaTime)
		return
	end

	elapsed += deltaTime
	if elapsed < self._interval then
		self._elapsed[agent] = elapsed
		return
	end

	self._elapsed[agent] = 0
	self._inner:Tick(agent, elapsed)
end

--[=[
	@within Throttle
	@param agent Agent?

	Forgets the agent's clock (or all of them) and forwards to the wrapped sense's `Destroy`.
]=]
function Throttle.Destroy(self: Throttle, agent: Types.Agent?)
	if agent ~= nil then
		self._elapsed[agent] = nil
	else
		table.clear(self._elapsed)
	end

	local destroy = self._inner.Destroy
	if destroy then
		destroy(self._inner, agent)
	end
end

return Throttle
