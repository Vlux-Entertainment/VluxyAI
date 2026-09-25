--!strict

--[[
	Who is near, regardless of walls or which way anyone faces. The cheap sense: no raycasts, just
	distances from the agent's position.

	Writes to the blackboard:

	- `NearbyTargets` { BasePart } -- Every target within `Range`, nearest first. Empty when none.
	- `NearestTarget` BasePart? -- The nearest of those.
	- `NearestDistance` number -- Studs to `NearestTarget`, `math.huge` when there is none, so a
	  consideration can read it without a nil check.

	Parts are read duck-typed (`.Position` only), so a spec can pass plain tables through
	`Targets`.
]]

local FormatMessage = require(script.Parent.Parent.Utility.FormatMessage)
local Options = require(script.Parent.Parent.Utility.Options)
local Perception = require(script.Parent.Perception)
local Types = require(script.Parent.Parent.Types)

------------------------------------------------------------------------------------------------------------------------

local DEFAULT_OPTIONS = table.freeze({
	Range = 100,
})

--[=[
	@interface ProximityOptions
	@within Proximity

	.Range number? -- Studs within which a target counts as nearby. Default `100`.
	.Targets ((agent: Agent) -> { BasePart })? -- What to measure. Default [Perception.AliveRoots], every alive player's root.
]=]
export type ProximityOptions = {
	Range: number?,
	Targets: ((agent: Types.Agent) -> { BasePart })?,
}

type ResolvedOptions = {
	Range: number,
	Targets: (agent: Types.Agent) -> { BasePart },
}

type self = {
	_options: ResolvedOptions,
}

local Proximity = {}
Proximity.__index = Proximity

export type Proximity = typeof(setmetatable({} :: self, Proximity))

------------------------------------------------------------------------------------------------------------------------

--[=[
	@class Proximity

	A [Types.Sense] that writes who is within `Range` of the agent, nearest first, with no regard
	for sight. Writes `NearbyTargets`, `NearestTarget` and `NearestDistance`. Distances are
	`math.huge` when there is nothing to measure.
]=]

--[=[
	@within Proximity
	@param options ProximityOptions?
	@return Proximity
	@error "unknown option" -- A key not in `ProximityOptions`.
	@error "Range must be zero or more"
]=]
function Proximity.new(options: ProximityOptions?): Types.Sense
	local resolved = Options.Resolve("Proximity.new", DEFAULT_OPTIONS, options :: any, { "Targets" }) :: ResolvedOptions
	resolved.Targets = resolved.Targets or Perception.AliveRoots

	if resolved.Range < 0 then
		FormatMessage.Error("Proximity: Range must be zero or more", 3)
	end

	local self: self = {
		_options = resolved,
	}

	return setmetatable(self, Proximity) :: any
end

--[=[
	@within Proximity
	@param agent Agent
	@param deltaTime number

	Measures, and writes the keys listed above to `agent.Blackboard`.
]=]
function Proximity.Tick(self: Proximity, agent: Types.Agent, deltaTime: number)
	local _ = deltaTime
	local options = self._options
	local blackboard = agent.Blackboard

	local origin = Perception.PositionOf(agent)

	local nearby: { BasePart } = {}
	for _, target in options.Targets(agent) do
		if (target.Position - origin).Magnitude <= options.Range then
			table.insert(nearby, target)
		end
	end

	nearby = Perception.SortByDistance(origin, nearby)
	local nearest: BasePart? = nearby[1]

	blackboard.NearbyTargets = nearby
	blackboard.NearestTarget = nearest
	blackboard.NearestDistance = if nearest ~= nil then (nearest.Position - origin).Magnitude else math.huge
end

--[=[
	@within Proximity

	Nothing to release; present so the sense satisfies [Types.Sense] and any cleanup helper.
]=]
function Proximity.Destroy(self: Proximity)
	local _ = self
end

return Proximity
