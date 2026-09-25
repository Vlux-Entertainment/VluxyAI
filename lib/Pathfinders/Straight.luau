--!strict

--[[
	The "can I go straight there" leg. Sweeps a sphere the size of the agent's body from `from` to
	`to`; if nothing is in the way (and, with `FloorCheck`, there is floor under the whole segment)
	the path is the two endpoints and no planning happened.

	The one decision worth knowing: `from` and `to` may be at any height (a mover reports its root,
	a target is often a player's root, a node is on the floor), so with `FloorCheck` on both are
	projected onto the floor by a downward ray that may go a body's height plus `MaxDrop` below
	them, and the path holds those floor positions, which is what a [Types.Step] promises. The
	sweep then runs between the two body centres, `AgentHeight / 2` above the floor points. The
	samples between sit on the projected floor line, so their rays only go `MaxDrop` below them,
	every `AgentRadius` studs at most so no gap the body could fall through slips between two
	samples, and each floor hit may be at most `MaxDrop` below the previous one. With `FloorCheck`
	off the positions are used as given. `Sample` is pure and specced; the casts run under a fake
	workspace in the spec and are play-tested for real.
]]

local FormatMessage = require(script.Parent.Parent.Utility.FormatMessage)
local Options = require(script.Parent.Parent.Utility.Options)
local Types = require(script.Parent.Parent.Types)

------------------------------------------------------------------------------------------------------------------------

-- A segment shorter than this is not swept; the floor is still checked at `to`.
local ZERO_LENGTH = 1e-4

local DEFAULT_OPTIONS = table.freeze({
	AgentRadius = 2,
	AgentHeight = 5,
	FloorCheck = true,
	FloorSpacing = 4,
	MaxDrop = 6,
	Ignore = nil :: ((agent: Types.Agent) -> { Instance })?,
})

-- Keys with no default value, so the resolver still accepts them.
local OPTIONAL_KEYS = { "Ignore" }

--[=[
	@interface StraightOptions
	@within Straight

	.AgentRadius number? -- Radius of the swept sphere, the agent's half width. Must be below `AgentHeight / 2` or the sweep scrapes the floor. Default `2`.
	.AgentHeight number? -- The agent's height; the sweep runs `AgentHeight / 2` above the floor. Default `5`.
	.FloorCheck boolean? -- Require floor under the segment and project the endpoints onto it. Default `true`.
	.FloorSpacing number? -- Studs between floor samples along the segment, capped at `AgentRadius` so a gap the body could fall through is always sampled. Default `4`, which with the default radius means a ray every 2 studs; a long straight leg costs that many rays per plan.
	.MaxDrop number? -- Studs the floor may be below a sample, and below the previous sample's floor. Default `6`.
	.Ignore ((agent: Agent) -> { Instance })? -- Instances the casts pass through. Default: [Straight.DefaultIgnore], the agent's entity and every player's character.
]=]
export type Options = {
	AgentRadius: number?,
	AgentHeight: number?,
	FloorCheck: boolean?,
	FloorSpacing: number?,
	MaxDrop: number?,
	Ignore: ((agent: Types.Agent) -> { Instance })?,
}

type ResolvedOptions = {
	AgentRadius: number,
	AgentHeight: number,
	FloorCheck: boolean,
	FloorSpacing: number,
	MaxDrop: number,
	Ignore: ((agent: Types.Agent) -> { Instance })?,
}

type self = {
	Name: string,

	_options: ResolvedOptions,
}

local Straight = {}
Straight.__index = Straight

export type Straight = typeof(setmetatable({} :: self, Straight))

------------------------------------------------------------------------------------------------------------------------

--[=[
	@class Straight

	A [Types.Pathfinder] that only succeeds when the agent can walk straight to the target: a
	`Spherecast` the width of the body from `from` to `to`, and optionally a floor ray every few
	studs along the way. Meant as the first rung of a [Ladder], so a target in plain sight costs no
	navmesh query.

	`Name` is `"Straight"`, which [Ladder] uses in its reasons.
]=]

--[=[
	@within Straight
	@param options StraightOptions?
	@return Straight
	@error "unknown option" -- A key that is not in `StraightOptions`.
]=]
function Straight.new(options: Options?): Types.Pathfinder
	local resolved = Options.Resolve("Straight.new", DEFAULT_OPTIONS, options :: any, OPTIONAL_KEYS) :: ResolvedOptions

	if resolved.AgentRadius >= resolved.AgentHeight / 2 then
		FormatMessage.Warn(
			`Straight.new: AgentRadius ({resolved.AgentRadius}) is not below AgentHeight / 2 ({resolved.AgentHeight / 2}), so the sweep touches the floor`
		)
	end

	local self: self = {
		Name = "Straight",

		_options = resolved,
	}

	return setmetatable(self, Straight) :: any
end

------------------------------------------------------------------------------------------------------------------------

--[=[
	@within Straight
	@param from Vector3
	@param to Vector3
	@param spacing number -- Must be positive.
	@return { Vector3 } -- Points every `spacing` studs after `from`, ending with `to` itself.
	@error "spacing must be positive"

	The floor sample points along a segment. `from` is never included; `to` always is, exactly
	once, so a zero-length segment gives `{ to }`. Pure.
]=]
function Straight.Sample(from: Vector3, to: Vector3, spacing: number): { Vector3 }
	if spacing <= 0 then
		FormatMessage.Error(`Straight.Sample: spacing must be positive, got {spacing}`, 2)
	end

	local offset = to - from
	local distance = offset.Magnitude
	local points = {}

	if distance > ZERO_LENGTH then
		local direction = offset / distance
		local travelled = spacing
		while travelled < distance - ZERO_LENGTH do
			table.insert(points, from + direction * travelled)
			travelled += spacing
		end
	end

	table.insert(points, to)

	return points
end

--[=[
	@within Straight
	@param agent Agent
	@return { Instance } -- The agent's entity and every player's character.

	The default `Ignore`. Call it from your own `Ignore` to extend the list rather than replace it.
]=]
function Straight.DefaultIgnore(agent: Types.Agent): { Instance }
	local Players = game:GetService("Players")

	local ignore: { Instance } = { agent.Entity }
	for _, player in Players:GetPlayers() do
		local character = player.Character
		if character then
			table.insert(ignore, character)
		end
	end

	return ignore
end

------------------------------------------------------------------------------------------------------------------------

--[=[
	@within Straight
	@param from Vector3 -- Any height; the floor under it is used.
	@param to Vector3 -- Any height; the floor under it is used.
	@param agent Agent -- Handed to `Ignore`.
	@return Path? -- Two Walk steps, the floor positions under `from` and `to`, when the way is clear.
	@return string? -- `blocked by <full name>` when the sweep hits or the body already overlaps something, `no floor at <point>` when a floor ray misses, `floor drops <studs> at <point>` when the floor falls more than `MaxDrop` between two samples.
]=]
function Straight.FindPath(self: Straight, from: Vector3, to: Vector3, agent: Types.Agent): (Types.Path?, string?)
	local options = self._options

	local ignore = if options.Ignore then options.Ignore(agent) else Straight.DefaultIgnore(agent)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	params.IgnoreWater = true

	local lift = Vector3.yAxis * (options.AgentHeight / 2)
	-- An endpoint may be a root, so from half a body above it the ray goes a body's height plus
	-- the allowed drop: the floor may be MaxDrop below the endpoint's own feet.
	local endpointReach = Vector3.yAxis * -(options.AgentHeight + options.MaxDrop)
	-- A sample sits on the projected floor line, so its ray goes only the allowed drop below it.
	local sampleReach = Vector3.yAxis * -(options.AgentHeight / 2 + options.MaxDrop)

	local function floorUnder(point: Vector3, reach: Vector3): Vector3?
		local hit = workspace:Raycast(point + lift, reach, params)
		return if hit then hit.Position else nil
	end

	local floorFrom = from
	local floorTo = to

	if options.FloorCheck then
		local underFrom = floorUnder(from, endpointReach)
		if underFrom == nil then
			return nil, `no floor at {from}`
		end
		local underTo = floorUnder(to, endpointReach)
		if underTo == nil then
			return nil, `no floor at {to}`
		end
		floorFrom = underFrom
		floorTo = underTo
	end

	local start = floorFrom + lift
	local offset = (floorTo + lift) - start

	if offset.Magnitude > ZERO_LENGTH then
		-- A sweep ignores what its sphere already overlaps, so a body pressed against a wall would
		-- sweep straight through it. Check the start on its own first.
		local overlap = OverlapParams.new()
		overlap.FilterType = Enum.RaycastFilterType.Exclude
		overlap.FilterDescendantsInstances = ignore
		local touching = workspace:GetPartBoundsInRadius(start, options.AgentRadius * 0.9, overlap)
		if #touching > 0 then
			return nil, `blocked by {touching[1]:GetFullName()} at the start`
		end

		local hit = workspace:Spherecast(start, options.AgentRadius, offset, params)
		if hit then
			return nil, `blocked by {hit.Instance:GetFullName()}`
		end
	end

	if options.FloorCheck then
		local spacing = if options.AgentRadius > 0
			then math.min(options.FloorSpacing, options.AgentRadius)
			else options.FloorSpacing
		local samples = Straight.Sample(floorFrom, floorTo, spacing)
		local previous = floorFrom

		-- The last sample is `to`, whose floor was found above; it still takes the drop check.
		for index, sample in samples do
			local floor = if index == #samples then floorTo else floorUnder(sample, sampleReach)
			if floor == nil then
				return nil, `no floor at {sample}`
			end

			local drop = previous.Y - floor.Y
			if drop > options.MaxDrop then
				return nil, `floor drops {drop} at {sample}`
			end
			previous = floor
		end
	end

	local path: Types.Path = {
		{ Position = floorFrom, Action = "Walk" },
		{ Position = floorTo, Action = "Walk" },
	}

	return path, nil
end

--[=[
	@within Straight

	Nothing to release; present so the pathfinder contract is complete.
]=]
function Straight.Destroy(self: Straight)
	local _ = self
end

return Straight
