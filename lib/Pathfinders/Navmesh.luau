--!strict

--[[
	The PathfindingService pathfinder. Plans and nothing else: no parts, no movement, no target.
	`FindPath` computes a path between two positions and hands back the waypoints as Steps.

	The one decision worth knowing: `Simplify` drops interior Walk steps that lie on a straight
	line, so a mover turns fewer corners. It keeps every Jump, Custom or labelled step and the step
	right before a Jump, because those carry meaning a straight line does not. Both `Simplify` and
	`FromWaypoints` are pure so they are specced under Lune; the service call is play-tested.
]]

local Options = require(script.Parent.Parent.Utility.Options)
local Types = require(script.Parent.Parent.Types)

------------------------------------------------------------------------------------------------------------------------

-- Two unit directions this close together count as the same line.
local COLLINEAR_DOT = 0.999
-- Below this, a segment has no direction; a step that close to its neighbour is a duplicate.
local ZERO_LENGTH = 1e-4

local DEFAULT_OPTIONS = table.freeze({
	AgentRadius = 2,
	AgentHeight = 5,
	AgentCanJump = false,
	AgentCanClimb = false,
	WaypointSpacing = 2,
	Costs = {} :: { [string]: number },
	Simplify = true,
})

--[=[
	@interface NavmeshOptions
	@within Navmesh

	.AgentRadius number? -- Passed to `CreatePath`. Default `2`.
	.AgentHeight number? -- Passed to `CreatePath`. Default `5`.
	.AgentCanJump boolean? -- Passed to `CreatePath`. Default `false`.
	.AgentCanClimb boolean? -- Passed to `CreatePath`. Default `false`.
	.WaypointSpacing number? -- Passed to `CreatePath`. Default `2`.
	.Costs { [string]: number }? -- Material and modifier costs passed to `CreatePath`. Default `{}`.
	.Simplify boolean? -- Run [Navmesh.Simplify] over every path. Default `true`.
]=]
export type Options = {
	AgentRadius: number?,
	AgentHeight: number?,
	AgentCanJump: boolean?,
	AgentCanClimb: boolean?,
	WaypointSpacing: number?,
	Costs: { [string]: number }?,
	Simplify: boolean?,
}

type ResolvedOptions = {
	AgentRadius: number,
	AgentHeight: number,
	AgentCanJump: boolean,
	AgentCanClimb: boolean,
	WaypointSpacing: number,
	Costs: { [string]: number },
	Simplify: boolean,
}

type self = {
	Name: string,

	_options: ResolvedOptions,
	_path: Path,
	_destroyed: boolean,
}

local Navmesh = {}
Navmesh.__index = Navmesh

export type Navmesh = typeof(setmetatable({} :: self, Navmesh))

------------------------------------------------------------------------------------------------------------------------

--[=[
	@class Navmesh

	A [Types.Pathfinder] over Roblox's `PathfindingService`. One `Path` instance per navmesh, created
	in `new` with the agent parameters and reused for every `FindPath`, so make one per agent rather
	than one per plan. Never share one between agents: `ComputeAsync` yields, so a second agent's
	plan would overwrite the waypoints the first is about to read.

	`Name` is `"Navmesh"`, which [Ladder] uses in its reasons.
]=]

--[=[
	@within Navmesh
	@param options NavmeshOptions?
	@return Navmesh
	@error "unknown option" -- A key that is not in `NavmeshOptions`.

	Creates the `Path` instance through `PathfindingService:CreatePath`.
]=]
function Navmesh.new(options: Options?): Types.Pathfinder
	local resolved = Options.Resolve("Navmesh.new", DEFAULT_OPTIONS, options :: any) :: ResolvedOptions

	local PathfindingService = game:GetService("PathfindingService")
	local path = PathfindingService:CreatePath({
		AgentRadius = resolved.AgentRadius,
		AgentHeight = resolved.AgentHeight,
		AgentCanJump = resolved.AgentCanJump,
		AgentCanClimb = resolved.AgentCanClimb,
		WaypointSpacing = resolved.WaypointSpacing,
		Costs = resolved.Costs,
	})

	local self: self = {
		Name = "Navmesh",

		_options = resolved,
		_path = path,
		_destroyed = false,
	}

	return setmetatable(self, Navmesh) :: any
end

------------------------------------------------------------------------------------------------------------------------

--[[
	Is `middle` on the straight line from `before` to `after`, close enough to be dropped? A step
	on top of either neighbour is a duplicate and counts as on the line.
]]
local function isCollinear(before: Vector3, middle: Vector3, after: Vector3): boolean
	local into = middle - before
	local out = after - middle

	if into.Magnitude < ZERO_LENGTH or out.Magnitude < ZERO_LENGTH then
		return true
	end

	return into.Unit:Dot(out.Unit) > COLLINEAR_DOT
end

--[=[
	@within Navmesh
	@param path Path
	@return Path -- A new path; the input is not modified.

	Removes interior Walk steps that lie on the straight line between the last kept step and the
	next one, so a mover walks one long segment instead of many short collinear ones. Pure.

	Always kept: the first and last step, every Jump or Custom step, every step with a Label, and
	the step immediately before a Jump (the jump origin matters). A path of two or fewer steps
	comes back as a copy.
]=]
function Navmesh.Simplify(path: Types.Path): Types.Path
	local count = #path
	if count <= 2 then
		return table.clone(path)
	end

	local kept = { path[1] }
	local lastKept = path[1]

	for index = 2, count - 1 do
		local step = path[index]
		local nextStep = path[index + 1]

		local removable = step.Action == "Walk" and step.Label == nil and nextStep.Action ~= "Jump"
		if removable and isCollinear(lastKept.Position, step.Position, nextStep.Position) then
			continue
		end

		table.insert(kept, step)
		lastKept = step
	end

	table.insert(kept, path[count])

	return kept
end

--[=[
	@within Navmesh
	@param waypoints { PathWaypoint }
	@return Path

	Converts `Path:GetWaypoints()` output to Steps: `Action` is the waypoint action's name and an
	empty `Label` becomes `nil`. Pure; any table shaped like a waypoint works.
]=]
function Navmesh.FromWaypoints(waypoints: { PathWaypoint }): Types.Path
	local path: Types.Path = table.create(#waypoints)

	for index, waypoint in waypoints do
		local label = waypoint.Label
		path[index] = {
			Position = waypoint.Position,
			Action = waypoint.Action.Name :: Types.StepAction,
			Label = if label ~= nil and label ~= "" then label else nil,
		}
	end

	return path
end

------------------------------------------------------------------------------------------------------------------------

--[=[
	@within Navmesh
	@yields
	@param from Vector3
	@param to Vector3
	@param agent Agent -- Unused; part of the [Types.Pathfinder] contract.
	@return Path? -- The steps, simplified when `Simplify` is on.
	@return string? -- On failure: the `ComputeAsync` error text, the `PathStatus` name (`NoPath`, `ClosestNoPath`, ...) or `destroyed`.
]=]
function Navmesh.FindPath(self: Navmesh, from: Vector3, to: Vector3, agent: Types.Agent): (Types.Path?, string?)
	local _ = agent
	if self._destroyed then
		return nil, "destroyed"
	end

	local path = self._path

	local ok, err = pcall(function()
		path:ComputeAsync(from, to)
	end)
	if not ok then
		return nil, tostring(err)
	end

	if path.Status ~= Enum.PathStatus.Success then
		return nil, path.Status.Name
	end

	local steps = Navmesh.FromWaypoints(path:GetWaypoints())
	if self._options.Simplify then
		steps = Navmesh.Simplify(steps)
	end

	return steps, nil
end

--[=[
	@within Navmesh

	Destroys the `Path` instance. `FindPath` after this returns `nil, "destroyed"`.
]=]
function Navmesh.Destroy(self: Navmesh)
	if self._destroyed then
		return
	end

	self._destroyed = true
	self._path:Destroy()
end

return Navmesh
