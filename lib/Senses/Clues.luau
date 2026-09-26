--!strict

--[[
	Clues: what an agent sees becomes something every agent sharing the same Interest map knows is
	worth a look. While it sees someone, the points around them grow hot; once it has lost them,
	the points where they were heading do. Other agents never learn where anyone is from this, only
	where to go and look, so a group searches toward a sighting without being told the answer.

	It writes nothing of its own; it reads Sight's keys and raises the map.
]]

local Options = require(script.Parent.Parent.Utility.Options)
local Tables = require(script.Parent.Parent.Utility.Tables)
local Types = require(script.Parent.Parent.Types)

------------------------------------------------------------------------------------------------------------------------

local DEFAULT_OPTIONS = table.freeze({
	Radius = 20,
	SeenHeat = 4,
	HeadingHeat = 2,
	SightPrefix = "",
})

--[=[
	@interface CluesOptions
	@within Clues

	.Radius number? -- Studs around the sighting that are raised. Default `20`.
	.SeenHeat number? -- Per second while someone is in view, at the centre. Default `4`.
	.HeadingHeat number? -- Per second at `PredictedPosition` once they are lost. Default `2`.
	.SightPrefix string? -- The `Prefix` of the [Sight] whose keys are read. Default `""`.
]=]
export type CluesOptions = {
	Radius: number?,
	SeenHeat: number?,
	HeadingHeat: number?,
	SightPrefix: string?,
}

type ResolvedOptions = {
	Radius: number,
	SeenHeat: number,
	HeadingHeat: number,
	SightPrefix: string,
}

type Map = {
	BumpNear: (self: any, position: Vector3, radius: number, amount: number) -> number,
}

type self = {
	_interest: Map,
	_options: ResolvedOptions,
}

local Clues = {}
Clues.__index = Clues

export type Clues = typeof(setmetatable({} :: self, Clues))

--[=[
	@class Clues

	A [Types.Sense] that turns an agent's sightings into clues on a shared [Interest] map. Add it
	after [Sight], give every agent of a group the same map, and roam it with [States.Roam]: one
	enemy spotting a player warms that part of the map for all of them.

	```lua
	:AddSense(VluxyAI.Senses.Sight.new({ Range = 45 }))
	:AddSense(VluxyAI.Senses.Clues.new(interest))
	```
]=]

--[=[
	@within Clues
	@param interest Interest -- The shared map.
	@param options CluesOptions?
	@return Clues
	@error "unknown option"
]=]
function Clues.new(interest: any, options: CluesOptions?): Types.Sense
	local resolved = Options.Resolve("Clues.new", DEFAULT_OPTIONS, options :: any) :: ResolvedOptions
	local self: self = { _interest = interest, _options = resolved }
	return setmetatable(self, Clues) :: any
end

--[=[
	@within Clues
	@param agent Agent
	@param deltaTime number

	Raises the map around the current sighting, or around where the lost target was heading.
]=]
function Clues.Tick(self: Clues, agent: Types.Agent, deltaTime: number)
	local options = self._options
	local sight = Tables.Prefixed(agent.Blackboard, options.SightPrefix)
	local seenPosition = sight.SeenPosition
	local predicted = sight.PredictedPosition
	if sight.SeenTarget ~= nil and typeof(seenPosition) == "Vector3" then
		self._interest:BumpNear(seenPosition, options.Radius, options.SeenHeat * deltaTime)
	elseif typeof(predicted) == "Vector3" then
		self._interest:BumpNear(predicted, options.Radius, options.HeadingHeat * deltaTime)
	end
end

--[=[
	@within Clues

	Nothing to release.
]=]
function Clues.Destroy(self: Clues)
	local _ = self
end

return Clues
