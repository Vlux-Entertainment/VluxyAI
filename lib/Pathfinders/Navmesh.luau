--!strict

--[[
	The PathfindingService pathfinder. Plans and nothing else: no parts, no movement, no target.
	`FindPath` computes a path between two positions and hands back the waypoints as Steps.

	The one decision worth knowing: `Simplify` drops interior Walk steps that lie on a straight
	line, so a mover turns fewer corners. It keeps every Jump, Custom or labelled step and the step
	right before a Jump, because those carry meaning a straight line does not. Both `Simplify` and
	`FromWaypoints` are pure so they are specced under Lune; the service call is play-tested.

	`Blocked` relays the Path instance's own `Blocked` event without the waypoint index, because
	`Simplify` renumbers the steps and the Navigator re-plans either way.
]]

local Options = require(script.Parent.Parent.Utility.Options)
local SafeAreas = require(script.Parent.Parent.World.SafeAreas)
local Signal = require(script.Parent.Parent.Utility.Signal)
local Types = require(script.Parent.Parent.Types)

------------------------------------------------------------------------------------------------------------------------

-- Two unit directions this close together count as the same line.
-- The default turn, in degrees, below which a waypoint is shaved off. Eight degrees is what the
-- original VluxyAI pathfinding used after a lot of play-testing: fine enough to keep every real
-- corner, coarse enough that a curve of 2-stud waypoints becomes a few long legs.
local DEFAULT_SIMPLIFY_ANGLE = 8
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
	SimplifyAngle = DEFAULT_SIMPLIFY_ANGLE,
	CollapseLabels = true,
	StopBefore = 3,
	Closest = 4,
})

--[=[
	@interface NavmeshOptions
	@within Navmesh

	.AgentRadius number? -- Passed to `CreatePath`. Default `2`.
	.AgentHeight number? -- Passed to `CreatePath`. Default `5`.
	.AgentCanJump boolean? -- Passed to `CreatePath`. Default `false`.
	.AgentCanClimb boolean? -- Passed to `CreatePath`. Default `false`.
	.WaypointSpacing number? -- Passed to `CreatePath`. Default `2`.
	.Costs { [string]: number }? -- Material and modifier costs passed to `CreatePath`. Default `{}`. The `VLUXYAI_SAFE` label of a [SafeAreas] area is always added at `math.huge` unless you set it yourself.
	.Simplify boolean? -- Run [Navmesh.Simplify] over every path. Default `true`.
	.SimplifyAngle number? -- Degrees: a waypoint whose turn is smaller than this is shaved off by [Navmesh.Simplify]. Default `8`.
	.CollapseLabels boolean? -- Run [Navmesh.CollapseLabels] over every path, so a `PathfindingModifier` volume that labels several waypoints in a row yields one labelled step, like a link. Default `true`.
	.StopBefore number? -- Run [Navmesh.StopBefore] with this many studs, so the agent stops at the waypoint before a doorway instead of inside the closed door. `0` turns it off. Default `3`.
	.Closest number? -- Accept a `ClosestNoPath` result whose last waypoint is within this many horizontal studs of the goal, such as a player standing closer to a wall than the agent's radius. `0` turns it off. Default `4`.
]=]
export type Options = {
	AgentRadius: number?,
	AgentHeight: number?,
	AgentCanJump: boolean?,
	AgentCanClimb: boolean?,
	WaypointSpacing: number?,
	Costs: { [string]: number }?,
	Simplify: boolean?,
	SimplifyAngle: number?,
	CollapseLabels: boolean?,
	StopBefore: number?,
	Closest: number?,
}

type ResolvedOptions = {
	AgentRadius: number,
	AgentHeight: number,
	AgentCanJump: boolean,
	AgentCanClimb: boolean,
	WaypointSpacing: number,
	Costs: { [string]: number },
	Simplify: boolean,
	SimplifyAngle: number,
	CollapseLabels: boolean,
	StopBefore: number,
	Closest: number,
}

type Closure = {
	Label: string?,
	Instance: Instance?,
	Position: Vector3,
	Until: number,
}

type self = {
	Name: string,
	Blocked: Types.Signal<()>,

	_options: ResolvedOptions,
	_path: Path,
	_blockedConnection: RBXScriptConnection,
	_closed: { Closure },
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

	`Name` is `"Navmesh"`, which [Ladder] uses in its reasons. `Blocked` fires whenever the
	`Path` instance reports its last computed path blocked, so a [Navigator] re-plans when a door
	closes or a part moves into the way instead of waiting for the mover's stuck check.
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
		Costs = Navmesh.WithSafeAreas(resolved.Costs),
	})

	local blocked = Signal.new()

	local self: self = {
		Name = "Navmesh",
		Blocked = blocked,

		_options = resolved,
		_path = path,
		_blockedConnection = path.Blocked:Connect(function()
			blocked:Fire()
		end),
		_closed = {},
		_destroyed = false,
	}

	return setmetatable(self, Navmesh) :: any
end

------------------------------------------------------------------------------------------------------------------------

--[[
	Is `middle` on the straight line from `before` to `after`, close enough to be dropped? A step
	on top of either neighbour is a duplicate and counts as on the line.
]]
local function isCollinear(before: Vector3, middle: Vector3, after: Vector3, minimumDot: number): boolean
	local into = middle - before
	local out = after - middle

	if into.Magnitude < ZERO_LENGTH or out.Magnitude < ZERO_LENGTH then
		return true
	end

	return into.Unit:Dot(out.Unit) > minimumDot
end

--[=[
	@within Navmesh
	@param path Path
	@param angle number? -- Degrees; a step turning less than this is dropped. Default `8`.
	@return Path -- A new path; the input is not modified.

	Shaves off interior Walk steps that turn less than `angle` from the line through the last kept
	step, so a mover walks a few long legs instead of stopping to turn at every 2-stud waypoint of
	a gentle curve. Pure.

	Always kept: the first and last step, every Jump or Custom step, every step with a Label, and
	the step immediately before a Jump (the jump origin matters). A path of two or fewer steps
	comes back as a copy.
]=]
function Navmesh.Simplify(path: Types.Path, angle: number?): Types.Path
	local minimumDot = math.cos(math.rad(angle or DEFAULT_SIMPLIFY_ANGLE))
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
		if removable and isCollinear(lastKept.Position, step.Position, nextStep.Position, minimumDot) then
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
	@param path Path
	@return Path -- A new path; the input is not modified.

	Merges each run of consecutive steps that share a `Label` into the first of them, keeping
	its position. A `PathfindingModifier` labels every waypoint inside its volume, and waypoints
	sit a couple of studs apart, so a doorway would otherwise be two or three "Door" steps and a
	handler would run at each. A run is broken by an unlabelled step or a different label. Pure.
]=]
function Navmesh.CollapseLabels(path: Types.Path): Types.Path
	local collapsed: Types.Path = {}
	local previousLabel: string? = nil

	for index, step in path do
		local label = step.Label
		local continues = label ~= nil and label == previousLabel and index > 1
		if not continues then
			table.insert(collapsed, step)
		end
		previousLabel = label
	end

	return collapsed
end

--[=[
	@within Navmesh
	@param costs { [string]: number }
	@return { [string]: number } -- A copy with the [SafeAreas] label at `math.huge`, unless `costs` already prices it.

	Why a navmesh never plans into an enabled safe area. Pure.
]=]
function Navmesh.WithSafeAreas(costs: { [string]: number }): { [string]: number }
	local merged = table.clone(costs)
	if merged[SafeAreas.LABEL] == nil then
		merged[SafeAreas.LABEL] = math.huge
	end
	return merged
end

--[=[
	@within Navmesh
	@param path Path
	@param distance number -- Studs. The step before must be at most this far from the labelled one.
	@return Path -- A new path; the input is not modified.

	Moves each label back onto the plain `Walk` step before it, when that step is within
	`distance`, so the agent stops outside a doorway rather than walking into the closed door to
	reach a waypoint inside it. The labelled step it came from becomes a plain `Walk`, kept so
	the agent still walks through. A step after a `Jump`, a labelled one, or one too far away
	keeps its label. Run it before [Navmesh.Simplify], whose dropped waypoints would otherwise be
	the ones to stop at. Pure.
]=]
function Navmesh.StopBefore(path: Types.Path, distance: number): Types.Path
	local moved: Types.Path = table.create(#path)
	for index, step in path do
		moved[index] = table.clone(step)
	end

	for index = 2, #moved do
		local step = moved[index]
		local before = moved[index - 1]
		local canMove = step.Label ~= nil
			and before.Label == nil
			and before.Action == "Walk"
			and (step.Position - before.Position).Magnitude <= distance
		if canMove then
			before.Label = step.Label
			before.Instance = step.Instance
			before.Action = step.Action
			step.Label = nil
			step.Instance = nil
			step.Action = "Walk"
		end
	end

	return moved
end

--[=[
	@within Navmesh
	@param path Path
	@param goal Vector3
	@param distance number -- Horizontal studs.
	@return boolean -- `true` when the path's last step is within `distance` of `goal`, ignoring height.

	Whether a partial path gets close enough to count. Pure.
]=]
function Navmesh.EndsNear(path: Types.Path, goal: Vector3, distance: number): boolean
	local last = path[#path]
	if last == nil then
		return false
	end
	local offset = last.Position - goal
	return Vector3.new(offset.X, 0, offset.Z).Magnitude <= distance
end

-- Material names, the label Roblox gives a waypoint nothing else labelled. Built on first use.
local materialNames: { [string]: boolean }? = nil

--[[
	Is `label` just the name of an `Enum.Material`?
]]
local function isMaterialName(label: string): boolean
	local names = materialNames
	if names == nil then
		local built: { [string]: boolean } = {}
		for _, item in Enum.Material:GetEnumItems() do
			built[item.Name] = true
		end
		materialNames = built
		names = built
	end
	return (names :: { [string]: boolean })[label] == true
end

--[=[
	@within Navmesh
	@param waypoints { PathWaypoint }
	@return Path

	Converts `Path:GetWaypoints()` output to Steps: `Action` is the waypoint action's name, and an
	empty `Label` or one that is only the floor's material name becomes `nil`. Roblox labels every
	waypoint with the material under it (`"Plastic"`, `"Grass"`) when no modifier or link labels
	it; kept, every step of an ordinary path would share a label and [Navmesh.CollapseLabels]
	would merge the whole path into its first step. A modifier label that happens to be a material
	name is dropped with them, so name modifier regions something else. Pure; any table shaped
	like a waypoint works.
]=]
function Navmesh.FromWaypoints(waypoints: { PathWaypoint }): Types.Path
	local path: Types.Path = table.create(#waypoints)

	for index, waypoint in waypoints do
		local label = waypoint.Label
		local meaningful = label ~= nil and label ~= "" and not isMaterialName(label)
		path[index] = {
			Position = waypoint.Position,
			Action = waypoint.Action.Name :: Types.StepAction,
			Label = if meaningful then label else nil,
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

	local steps: Types.Path
	if path.Status == Enum.PathStatus.Success then
		steps = Navmesh.FromWaypoints(path:GetWaypoints())
	elseif path.Status == Enum.PathStatus.ClosestNoPath and self._options.Closest > 0 then
		-- The goal is off the mesh (a player hugging a wall); the path to the nearest point is
		-- good enough when that point is close.
		steps = Navmesh.FromWaypoints(path:GetWaypoints())
		if not Navmesh.EndsNear(steps, to, self._options.Closest) then
			return nil, path.Status.Name
		end
	else
		return nil, path.Status.Name
	end

	if self._options.CollapseLabels then
		steps = Navmesh.CollapseLabels(steps)
	end
	if self._options.StopBefore > 0 then
		steps = Navmesh.StopBefore(steps, self._options.StopBefore)
	end
	if self._options.Simplify then
		steps = Navmesh.Simplify(steps, self._options.SimplifyAngle)
	end

	local closed = self:_closedStep(steps)
	if closed ~= nil then
		return nil, `closed {closed.Label or "step"} at {closed.Position}`
	end

	return steps, nil
end

-- A labelled waypoint this near a closed one is the same crossing.
local CLOSE_MATCH_DISTANCE = 4

--[[
	The first step of a path that crosses a closed labelled step, if any. Expired closures are
	dropped on the way.
]]
function Navmesh._closedStep(self: Navmesh, steps: Types.Path): Types.Step?
	if #self._closed == 0 then
		return nil
	end

	local now = os.clock()
	for index = #self._closed, 1, -1 do
		if now >= self._closed[index].Until then
			table.remove(self._closed, index)
		end
	end

	for _, step in steps do
		if step.Label == nil then
			continue
		end
		for _, closure in self._closed do
			local same = if closure.Instance ~= nil and step.Instance ~= nil
				then closure.Instance == step.Instance
				else closure.Label == step.Label
					and (closure.Position - step.Position).Magnitude <= CLOSE_MATCH_DISTANCE
			if same then
				return step
			end
		end
	end

	return nil
end

--[=[
	@within Navmesh
	@param step Step -- The step a handler refused.
	@param seconds number -- How long to refuse paths through it.

	The navmesh is Roblox's, so a link cannot be closed for one agent; instead, for `seconds`,
	any path this pathfinder computes that crosses a step with the same label within a few
	studs (or the same `Instance`) is reported as no path, `closed <label> at <position>`. The
	[Navigator] calls this when a step handler returns `false`.
]=]
function Navmesh.Close(self: Navmesh, step: Types.Step, seconds: number)
	table.insert(self._closed, {
		Label = step.Label,
		Instance = step.Instance,
		Position = step.Position,
		Until = os.clock() + seconds,
	})
end

--[=[
	@within Navmesh

	Destroys the `Path` instance and the `Blocked` signal. `FindPath` after this returns
	`nil, "destroyed"`.
]=]
function Navmesh.Destroy(self: Navmesh)
	if self._destroyed then
		return
	end

	self._destroyed = true
	self._blockedConnection:Disconnect()
	self._path:Destroy()
	self.Blocked:Destroy()
end

return Navmesh
