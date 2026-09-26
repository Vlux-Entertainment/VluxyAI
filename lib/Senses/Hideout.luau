--!strict

--[[
	Hideout: where an agent that vanishes should come back. Once every `Every` seconds it picks
	the most interesting point of an Interest map that nobody can see and that is not in a safe
	area, and writes it; a state that burrows, teleports or respawns reads it. Now and then
	(`Stray`) it ignores the map and picks any unseen point, so the agent is not predictable.

	The one decision: it never reads where a player is. It only knows what the map says is worth a
	look and whether a point is in someone's view, which is the question to ask before appearing.
]]

local Options = require(script.Parent.Parent.Utility.Options)
local Perception = require(script.Parent.Perception)
local SafeAreas = require(script.Parent.Parent.World.SafeAreas)
local Tables = require(script.Parent.Parent.Utility.Tables)
local Types = require(script.Parent.Parent.Types)

------------------------------------------------------------------------------------------------------------------------

local DEFAULT_OPTIONS = table.freeze({
	Key = "Hideout",
	Every = 1,
	Stray = 0,
	Height = 3,
	Prefix = "",
})

local ALLOWED = { "Accept", "Random" }

--[=[
	@interface HideoutOptions
	@within Hideout

	.Key string? -- The blackboard key written. Default `"Hideout"`.
	.Every number? -- Seconds between picks. Default `1`.
	.Stray number? -- Chance, `0` to `1`, that a pick ignores how interesting a point is. Default `0`.
	.Height number? -- Studs above a point's floor that "seen" is judged at, about where the body will be. Default `3`.
	.Accept ((position: Vector3) -> boolean)? -- Extra rule a point must pass, such as "far enough from where I am".
	.Random Random? -- Default `agent.Data.Random`, else a new one.
	.Prefix string? -- Prepended to the key. Default `""`.
]=]
export type HideoutOptions = {
	Key: string?,
	Every: number?,
	Stray: number?,
	Height: number?,
	Accept: ((position: Vector3) -> boolean)?,
	Random: Random?,
	Prefix: string?,
}

type ResolvedOptions = {
	Key: string,
	Every: number,
	Stray: number,
	Height: number,
	Accept: ((position: Vector3) -> boolean)?,
	Random: Random?,
	Prefix: string,
}

type self = {
	_interest: any,
	_options: ResolvedOptions,
	_clock: number,
}

local Hideout = {}
Hideout.__index = Hideout

export type Hideout = typeof(setmetatable({} :: self, Hideout))

--[=[
	@class Hideout

	A [Types.Sense] that picks where an agent should reappear: the most interesting point of an
	[Interest] map that no player can see ([Perception.SeenByAnyone]) and that is not in a
	[SafeAreas] area. Writes it under `Key`, `nil` when every point is in view. [States.Burrow]
	reads it.

	```lua
	:AddSense(VluxyAI.Senses.Hideout.new(interest, { Key = "Hideout", Stray = 0.25 }))
	-- in the brain
	Burrow = VluxyAI.States.Burrow({ To = "Hideout", Then = "Dormant" }),
	```
]=]

--[=[
	@within Hideout
	@param interest Interest
	@param options HideoutOptions?
	@return Hideout
	@error "unknown option"
]=]
function Hideout.new(interest: any, options: HideoutOptions?): Types.Sense
	local resolved = Options.Resolve("Hideout.new", DEFAULT_OPTIONS, options :: any, ALLOWED) :: ResolvedOptions
	local self: self = { _interest = interest, _options = resolved, _clock = math.huge }
	return setmetatable(self, Hideout) :: any
end

--[=[
	@within Hideout
	@param agent Agent
	@param deltaTime number

	Picks again every `Every` seconds and writes the point under `Key`.
]=]
function Hideout.Tick(self: Hideout, agent: Types.Agent, deltaTime: number)
	self._clock += deltaTime
	local options = self._options
	if self._clock < options.Every then
		return
	end
	self._clock = 0

	local random = options.Random or agent.Data.Random
	if random == nil then
		random = Random.new()
		options.Random = random
	end
	local draw = random :: Random

	-- A stray pick ignores the map; otherwise a little noise so equal points take turns.
	local stray = options.Stray > 0 and draw:NextNumber() < options.Stray
	local lift = Vector3.new(0, options.Height, 0)
	local best: Vector3? = nil
	local bestScore = -math.huge
	for _, point in self._interest:Points() do
		local score = if stray then draw:NextNumber() else point.Strength + draw:NextNumber(0, 0.25)
		if score <= bestScore then
			continue
		end
		local body = point.Position + lift
		if options.Accept ~= nil and not options.Accept(point.Position) then
			continue
		end
		if SafeAreas.Contains(body) or Perception.SeenByAnyone(body) then
			continue
		end
		best = point.Position
		bestScore = score
	end

	Tables.Prefixed(agent.Blackboard, options.Prefix)[options.Key] = best
end

--[=[
	@within Hideout

	Nothing to release.
]=]
function Hideout.Destroy(self: Hideout)
	local _ = self
end

return Hideout
