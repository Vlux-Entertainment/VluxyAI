--!strict

--[[
	What is around the agent, from a ring of horizontal rays: how close the nearest obstacle is
	and which way is most open. The 0.1 Spatial agent, as a sense. Steering, keeping off walls,
	and choosing a direction to flee all read from this rather than casting rays of their own.

	Writes:
	- `ObstacleDistance` number -- Distance to the nearest hit, `math.huge` when nothing is within range.
	- `ObstacleDirection` Vector3? -- Unit direction toward that hit.
	- `OpenDirection` Vector3 -- The ray direction with the most room; the agent's facing on a tie.
	- `OpenDistance` number -- How far that direction is clear, up to `Distance`.

	The ring maths is pure and specced; the casts run against `workspace` and are play-tested.
]]

local Options = require(script.Parent.Parent.Utility.Options)
local Perception = require(script.Parent.Perception)
local Types = require(script.Parent.Parent.Types)

------------------------------------------------------------------------------------------------------------------------

local DEFAULT_OPTIONS = table.freeze({
	-- Rays around the agent, evenly spaced.
	Rays = 8,
	-- How far each ray reaches, in studs.
	Distance = 12,
	-- Height above the agent's position the rays are cast from, so they clear low steps.
	Height = 0,
})

--[=[
	@interface SurroundingsOptions
	@within Surroundings

	.Rays number? -- Rays around the agent, evenly spaced. Default `8`.
	.Distance number? -- Reach of each ray in studs. Default `12`.
	.Height number? -- Cast height above the agent's position. Default `0`.
	.Ignore ((agent: Agent) -> { Instance })? -- Instances the rays pass through. Default: the agent's entity.
]=]
export type SurroundingsOptions = {
	Rays: number?,
	Distance: number?,
	Height: number?,
	Ignore: ((agent: Types.Agent) -> { Instance })?,
}

type ResolvedOptions = {
	Rays: number,
	Distance: number,
	Height: number,
	Ignore: ((agent: Types.Agent) -> { Instance })?,
}

type self = {
	_options: ResolvedOptions,
	_directions: { Vector3 },
}

local Surroundings = {}
Surroundings.__index = Surroundings

type SurroundingsClass = typeof(setmetatable({} :: self, Surroundings))

--[=[
	@class Surroundings

	A [Types.Sense] that casts a ring of rays and writes the nearest obstacle and the most open
	direction. Distances are `math.huge` when there is nothing to measure.
]=]

--[=[
	@within Surroundings
	@param count number
	@return { Vector3 } -- `count` unit directions around Y, starting along -Z and going clockwise.

	Pure.
]=]
function Surroundings.Directions(count: number): { Vector3 }
	local directions = {}
	for index = 0, count - 1 do
		local angle = index / count * math.pi * 2
		table.insert(directions, Vector3.new(-math.sin(angle), 0, -math.cos(angle)))
	end
	return directions
end

--[=[
	@within Surroundings
	@param directions { Vector3 } -- From [Surroundings.Directions], rotated to the agent's facing.
	@param distances { number? } -- Hit distance per direction, `nil` for a clear ray.
	@param reach number -- The rays' reach, what a clear ray counts as.
	@return { ObstacleDistance: number, ObstacleDirection: Vector3?, OpenDirection: Vector3, OpenDistance: number }

	Summarises a ring of results. Pure.
]=]
function Surroundings.Evaluate(
	directions: { Vector3 },
	distances: { number? },
	reach: number
): {
	ObstacleDistance: number,
	ObstacleDirection: Vector3?,
	OpenDirection: Vector3,
	OpenDistance: number,
}
	local obstacleDistance = math.huge
	local obstacleDirection: Vector3? = nil
	local openDirection = directions[1]
	local openDistance = -1

	for index, direction in directions do
		local hit = distances[index]
		local free = if hit then hit else reach

		if hit and hit < obstacleDistance then
			obstacleDistance = hit
			obstacleDirection = direction
		end
		if free > openDistance then
			openDistance = free
			openDirection = direction
		end
	end

	return {
		ObstacleDistance = obstacleDistance,
		ObstacleDirection = obstacleDirection,
		OpenDirection = openDirection,
		OpenDistance = math.max(openDistance, 0),
	}
end

--[=[
	@within Surroundings
	@param options SurroundingsOptions?
	@return Sense
]=]
function Surroundings.new(options: SurroundingsOptions?): Types.Sense
	local resolved =
		Options.Resolve("Surroundings.new", DEFAULT_OPTIONS, options :: any, { "Ignore" }) :: ResolvedOptions
	if resolved.Rays < 1 then
		resolved.Rays = 1
	end

	local self: self = {
		_options = resolved,
		_directions = Surroundings.Directions(resolved.Rays),
	}

	return setmetatable(self, Surroundings) :: any
end

--[=[
	@within Surroundings
	@param agent Agent
	@param deltaTime number
]=]
function Surroundings.Tick(self: SurroundingsClass, agent: Types.Agent, deltaTime: number)
	local _ = deltaTime
	local options = self._options

	local ignore = if options.Ignore then options.Ignore(agent) else Perception.IgnoreList(agent)
	local params = Perception.RaycastParams(ignore)

	local pivot = agent.Entity:GetPivot()
	local origin = agent:GetPosition() + Vector3.new(0, options.Height, 0)
	local yaw = math.atan2(-pivot.LookVector.X, -pivot.LookVector.Z)
	local rotation = CFrame.Angles(0, yaw, 0)

	local directions: { Vector3 } = {}
	local distances: { number? } = {}
	for index, base in self._directions do
		local direction = rotation:VectorToWorldSpace(base)
		directions[index] = direction
		local hit = workspace:Raycast(origin, direction * options.Distance, params)
		distances[index] = if hit then hit.Distance else nil
	end

	local summary = Surroundings.Evaluate(directions, distances, options.Distance)
	local blackboard = agent.Blackboard
	blackboard.ObstacleDistance = summary.ObstacleDistance
	blackboard.ObstacleDirection = summary.ObstacleDirection
	blackboard.OpenDirection = summary.OpenDirection
	blackboard.OpenDistance = summary.OpenDistance
end

--[=[
	@within Surroundings

	Nothing to release.
]=]
function Surroundings.Destroy(self: SurroundingsClass)
	local _ = self
end

return Surroundings
