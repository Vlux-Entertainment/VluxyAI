--!strict

--[[
	A hand-placed node graph with A* over it. Nodes are floor positions with links to other
	nodes; a path is the nearest node to the start, the nearest node to the goal, and the shortest
	chain of links between them, followed by the goal itself. Doors, one-way edges and anything
	else the navmesh cannot express are authored as links.

	A link is a node index, or a table with `To` plus an `Action`, `Label` and `Instance`: the
	step emitted for the node the link leaves from carries them, so an agent walking A to B
	through a door reaches A, its "Door" handler runs, and it walks on to B.

	The graph can be built from data (`new`) for tests and generated maps, or read out of the
	place (`FromInstances`): parts or attachments under a folder are nodes, `ObjectValue` children
	named Link are explicit edges, and nodes within `LinkRadius` with a clear ray between them are
	linked automatically. `AStar` and `Nearest` are pure and specced.
]]

local FormatMessage = require(script.Parent.Parent.Utility.FormatMessage)
local Options = require(script.Parent.Parent.Utility.Options)
local Tables = require(script.Parent.Parent.Utility.Tables)
local Types = require(script.Parent.Parent.Types)

------------------------------------------------------------------------------------------------------------------------

local DEFAULT_OPTIONS = table.freeze({
	-- A start or goal further than this from every node has no path.
	NearestLimit = 60,
})

local BUILD_DEFAULTS = table.freeze({
	LinkRadius = 24,
	AutoLink = true,
	Ignore = {} :: { Instance },
	CanLink = nil :: ((a: Vector3, b: Vector3) -> boolean)?,
})

--[=[
	@interface GraphLink
	@within Graph

	.To number -- The index of the node this link goes to.
	.Action StepAction? -- Emitted on the step for the node the link leaves from. `"Custom"` for a door.
	.Label string? -- Emitted with it; a [Types.StepHandler] registered for it runs there.
	.Instance Instance? -- Emitted with it: the door itself.

	A link with something to do on the way. A plain number is a walk.
]=]
export type GraphLink = {
	To: number,
	Action: Types.StepAction?,
	Label: string?,
	Instance: Instance?,
}

--[=[
	@interface GraphNode
	@within Graph

	.Position Vector3 -- A floor position.
	.Links { number | GraphLink } -- The nodes this one connects to, by index or as a [Graph.GraphLink]. Directed: add both ways for a two-way link.

	One node of a [Graph].
]=]
export type GraphNode = {
	Position: Vector3,
	Links: { number | GraphLink },
}

--[[
	The index a link points at, whichever form it takes.
]]
local function linkTarget(link: number | GraphLink): number
	return if type(link) == "number" then link else link.To
end

--[[
	The link from one node to another, if there is one.
]]
local function linkBetween(nodes: { GraphNode }, from: number, to: number): (number | GraphLink)?
	for _, link in nodes[from].Links do
		if linkTarget(link) == to then
			return link
		end
	end
	return nil
end

--[=[
	@interface GraphOptions
	@within Graph

	.NearestLimit number? -- Studs; a start or goal further than this from every node has no path. Default `60`.
	.LineOfSight ((from: Vector3, to: Vector3) -> boolean)? -- When given, the entry and exit nodes are the nearest ones this returns `true` for, so a route never starts through a wall.
]=]
export type GraphOptions = {
	NearestLimit: number?,
	LineOfSight: ((from: Vector3, to: Vector3) -> boolean)?,
}

--[=[
	@interface GraphBuildOptions
	@within Graph

	.LinkRadius number? -- Studs within which two nodes are linked automatically when the link test passes. Default `24`.
	.AutoLink boolean? -- Turn the automatic linking off to use only explicit links. Default `true`.
	.Ignore { Instance }? -- Instances the linking rays pass through (the node parts themselves always are).
	.CanLink ((a: Vector3, b: Vector3) -> boolean)? -- Replaces the ray test: return `true` when an agent can walk from `a` to `b`. Ask your navmesh here for anything but flat floors.
	.Graph GraphOptions? -- Options for the graph itself (`NearestLimit`, `LineOfSight`).
]=]
export type GraphBuildOptions = {
	LinkRadius: number?,
	AutoLink: boolean?,
	Ignore: { Instance }?,
	CanLink: ((a: Vector3, b: Vector3) -> boolean)?,
	Graph: GraphOptions?,
}

type ResolvedOptions = {
	NearestLimit: number,
	LineOfSight: ((from: Vector3, to: Vector3) -> boolean)?,
}

type self = {
	Name: string,
	_nodes: { GraphNode },
	_options: ResolvedOptions,
}

local Graph = {}
Graph.__index = Graph

type GraphClass = typeof(setmetatable({} :: self, Graph))

--[=[
	@within Graph
	@function LinkTarget
	@param link number | GraphLink
	@return number -- The index the link points at.
]=]
Graph.LinkTarget = linkTarget

--[=[
	@class Graph

	A [Types.Pathfinder] over hand-placed nodes with A*. Use it for the long legs of a level a
	navmesh cannot plan across (doors, one-way drops), and compose it with a local pathfinder
	through [Hybrid]. `Name` is `"Graph"`.

	```lua
	local graph = VluxyAI.Pathfinders.Graph.FromInstances(workspace.NavGraph)
	local pathfinder = VluxyAI.Pathfinders.Hybrid.new({
		Graph = graph,
		Local = VluxyAI.Pathfinders.Navmesh.new(),
	})
	```
]=]

--[=[
	@within Graph
	@param nodes { GraphNode }
	@param options GraphOptions?
	@return Pathfinder
	@error string -- No nodes, or a link to an index that does not exist.
]=]
function Graph.new(nodes: { GraphNode }, options: GraphOptions?): Types.Pathfinder
	local resolved = Options.Resolve("Graph.new", DEFAULT_OPTIONS, options :: any, { "LineOfSight" }) :: ResolvedOptions

	if type(nodes) ~= "table" or #nodes == 0 then
		FormatMessage.Error("Graph.new: needs at least one node", 2)
	end
	for index, node in nodes do
		if typeof(node.Position) ~= "Vector3" then
			FormatMessage.Error(`Graph.new: node {index} has no Vector3 Position`, 2)
		end
		if node.Links then
			for _, link in node.Links do
				local target = if type(link) == "number" then link elseif type(link) == "table" then link.To else nil
				if type(target) ~= "number" or nodes[target] == nil then
					FormatMessage.Error(
						`Graph.new: node {index} links to node {tostring(target)}, which does not exist`,
						2
					)
				end
			end
		end
	end

	local copy: { GraphNode } = {}
	for index, node in nodes do
		local links: { number | GraphLink } = {}
		local given: { number | GraphLink } = node.Links or {}
		for _, link in given do
			table.insert(links, if type(link) == "number" then link else table.clone(link))
		end
		copy[index] = { Position = node.Position, Links = links }
	end

	local self: self = {
		Name = "Graph",
		_nodes = copy,
		_options = resolved,
	}

	return setmetatable(self, Graph) :: any
end

------------------------------------------------------------------------------------------------------------------------

--[=[
	@within Graph
	@param nodes { GraphNode }
	@param start number -- Index of the start node.
	@param goal number -- Index of the goal node.
	@return { number }? -- Node indices from `start` to `goal` inclusive, or `nil` when unreachable.

	A* over the links with straight-line distance as the heuristic. Pure.
]=]
function Graph.AStar(nodes: { GraphNode }, start: number, goal: number): { number }?
	if nodes[start] == nil or nodes[goal] == nil then
		return nil
	end
	if start == goal then
		return { start }
	end

	local goalPosition = nodes[goal].Position
	local cameFrom: { [number]: number } = {}
	local costSoFar: { [number]: number } = { [start] = 0 }
	local open: { number } = { start }
	local inOpen: { [number]: boolean } = { [start] = true }
	local closed: { [number]: boolean } = {}

	local function estimate(index: number): number
		return costSoFar[index] + (nodes[index].Position - goalPosition).Magnitude
	end

	while #open > 0 do
		-- Smallest estimate first. The lists are small (a level's worth of nodes), so a scan is fine.
		local bestSlot = 1
		for slot = 2, #open do
			if estimate(open[slot]) < estimate(open[bestSlot]) then
				bestSlot = slot
			end
		end
		local current = table.remove(open, bestSlot) :: number
		inOpen[current] = nil

		if current == goal then
			local route = { goal }
			local step = goal
			while cameFrom[step] ~= nil do
				step = cameFrom[step]
				table.insert(route, 1, step)
			end
			return route
		end

		closed[current] = true
		local currentPosition = nodes[current].Position

		for _, link in nodes[current].Links do
			local neighbour = linkTarget(link)
			if closed[neighbour] then
				continue
			end
			local cost = costSoFar[current] + (nodes[neighbour].Position - currentPosition).Magnitude
			local known = costSoFar[neighbour]
			if known == nil or cost < known then
				costSoFar[neighbour] = cost
				cameFrom[neighbour] = current
				if not inOpen[neighbour] then
					table.insert(open, neighbour)
					inOpen[neighbour] = true
				end
			end
		end
	end

	return nil
end

--[=[
	@within Graph
	@param nodes { GraphNode }
	@param position Vector3
	@param limit number -- Studs; nodes further away are ignored.
	@param accept ((node: GraphNode) -> boolean)? -- Skip nodes this returns `false` for.
	@return number? -- The index of the nearest acceptable node within `limit`.

	Pure.
]=]
function Graph.Nearest(
	nodes: { GraphNode },
	position: Vector3,
	limit: number,
	accept: ((node: GraphNode) -> boolean)?
): number?
	local best: number? = nil
	local bestDistance = limit

	for index, node in nodes do
		local distance = (node.Position - position).Magnitude
		if distance <= bestDistance and (accept == nil or accept(node)) then
			best = index
			bestDistance = distance
		end
	end

	return best
end

------------------------------------------------------------------------------------------------------------------------

--[=[
	@within Graph
	@param nodes { GraphNode }
	@param route { number } -- From [Graph.AStar].
	@param from Vector3
	@param to Vector3
	@param accept ((from: Vector3, to: Vector3) -> boolean)? -- The LineOfSight test, if any.
	@return { number } -- The route without the nodes the agent is already past, possibly empty.

	The entry node is the nearest to `from`, which may be behind an agent already on its way, and
	likewise the exit node behind the target. Drops leading nodes while `from` is nearer the next
	node than the first node is (and `accept` allows going straight there), and trailing nodes
	the same way from the target's side. Pure.
]=]
function Graph.Trim(
	nodes: { GraphNode },
	route: { number },
	from: Vector3,
	to: Vector3,
	accept: ((from: Vector3, to: Vector3) -> boolean)?
): { number }
	local trimmed = table.clone(route)

	while #trimmed >= 2 do
		local first = nodes[trimmed[1]].Position
		local second = nodes[trimmed[2]].Position
		local skip = Tables.FlatDistance(from, second) < Tables.FlatDistance(first, second)
			and (accept == nil or accept(from, second))
		if not skip then
			break
		end
		table.remove(trimmed, 1)
	end

	while #trimmed >= 2 do
		local last = nodes[trimmed[#trimmed]].Position
		local previous = nodes[trimmed[#trimmed - 1]].Position
		local skip = Tables.FlatDistance(to, previous) < Tables.FlatDistance(last, previous)
			and (accept == nil or accept(previous, to))
		if not skip then
			break
		end
		table.remove(trimmed)
	end

	-- One node left: keep it only if it is on the way.
	if #trimmed == 1 then
		local node = nodes[trimmed[1]].Position
		local onTheWay = Tables.FlatDistance(from, node) + Tables.FlatDistance(node, to)
				<= Tables.FlatDistance(from, to) + 1e-3
			or (accept ~= nil and not accept(from, to))
		if not onTheWay then
			table.remove(trimmed)
		end
	end

	return trimmed
end

--[=[
	@within Graph
	@param container Instance -- A folder of nodes.
	@param options GraphBuildOptions?
	@return Pathfinder
	@error string -- No nodes under the container.

	Reads a graph out of the place. Every `BasePart` or `Attachment` directly under `container`
	is a node at its position (a part's position is lowered to its bottom face, rotation taken
	into account). An `ObjectValue` named `Link` under a node whose value is another node is a
	one-way link; add the reverse for two-way; a value outside the container is warned about and
	skipped. A `Link` with an `Action` or `Label` attribute, or an `ObjectValue` child named
	`Instance`, becomes a [Graph.GraphLink]: set `Label = "Door"` and point `Instance` at the door,
	and the step at that node carries both. With `AutoLink`, nodes within `LinkRadius` of each other are linked both ways when
	`CanLink` says so, or, without it, when a ray 1.5 studs up between them is clear. The ray test
	is a line-of-sight test, not a walkability test: it links across a pit and refuses a staircase,
	so on anything but flat floors give `CanLink` a real answer.
]=]
function Graph.FromInstances(container: Instance, options: GraphBuildOptions?): Types.Pathfinder
	local resolved =
		Options.Resolve("Graph.FromInstances", BUILD_DEFAULTS, options :: any, { "CanLink", "Graph" }) :: typeof(BUILD_DEFAULTS) & { Graph: GraphOptions? }

	local instances: { Instance } = {}
	local positions: { Vector3 } = {}
	local indexOf: { [Instance]: number } = {}

	for _, child in container:GetChildren() do
		local position: Vector3? = nil
		if child:IsA("BasePart") then
			-- The bottom face in world space, whatever the part's rotation.
			local cframe = child.CFrame
			local size = child.Size
			local halfHeight = math.abs(cframe.UpVector.Y) * size.Y / 2
				+ math.abs(cframe.RightVector.Y) * size.X / 2
				+ math.abs(cframe.LookVector.Y) * size.Z / 2
			position = child.Position - Vector3.new(0, halfHeight, 0)
		elseif child:IsA("Attachment") then
			position = child.WorldPosition
		end
		if position then
			table.insert(instances, child)
			table.insert(positions, position)
			indexOf[child] = #instances
		end
	end

	if #instances == 0 then
		FormatMessage.Error(`Graph.FromInstances: no parts or attachments under {container:GetFullName()}`, 2)
	end

	local nodes: { GraphNode } = {}
	for index, position in positions do
		nodes[index] = { Position = position, Links = {} }
	end

	local function link(a: number, b: number | GraphLink)
		local target = linkTarget(b)
		if a ~= target and linkBetween(nodes, a, target) == nil then
			table.insert(nodes[a].Links, b)
		end
	end

	for index, instance in instances do
		for _, value in instance:GetChildren() do
			if value:IsA("ObjectValue") and value.Name == "Link" and value.Value ~= nil then
				local target = indexOf[value.Value :: Instance]
				if target then
					local action = value:GetAttribute("Action")
					local label = value:GetAttribute("Label")
					local door = value:FindFirstChild("Instance")
					if action ~= nil or label ~= nil or door then
						link(index, {
							To = target,
							Action = if type(action) == "string" then action :: Types.StepAction else nil,
							Label = if type(label) == "string" then label else nil,
							Instance = if door and door:IsA("ObjectValue") then door.Value else nil,
						})
					else
						link(index, target)
					end
				else
					FormatMessage.Warn(
						`Graph.FromInstances: {value:GetFullName()} points at {(value.Value :: Instance):GetFullName()}, which is not a node under {container:GetFullName()}`
					)
				end
			end
		end
	end

	if resolved.AutoLink then
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		local ignore = table.clone(resolved.Ignore)
		table.insert(ignore, container)
		params.FilterDescendantsInstances = ignore

		local lift = Vector3.new(0, 1.5, 0)
		local canLink = resolved.CanLink
		for a = 1, #nodes do
			for b = a + 1, #nodes do
				local from = nodes[a].Position
				local to = nodes[b].Position
				if (to - from).Magnitude > resolved.LinkRadius then
					continue
				end
				local walkable = if canLink
					then canLink(from, to)
					else workspace:Raycast(from + lift, (to + lift) - (from + lift), params) == nil
				if walkable then
					link(a, b)
					link(b, a)
				end
			end
		end
	end

	return Graph.new(nodes, resolved.Graph)
end

------------------------------------------------------------------------------------------------------------------------

--[[
	The nearest node to a position that the LineOfSight option accepts, if there is one.
]]
function Graph._entry(self: GraphClass, position: Vector3): number?
	local lineOfSight = self._options.LineOfSight
	local accept = if lineOfSight
		then function(node: GraphNode)
			return lineOfSight(position, node.Position)
		end
		else nil

	return Graph.Nearest(self._nodes, position, self._options.NearestLimit, accept)
end

--[=[
	@within Graph
	@param from Vector3
	@param to Vector3
	@param agent Agent
	@return Path? -- The route's node positions as Walk steps, trimmed of nodes already behind the agent or the target, then `to` lowered to the exit node's floor.
	@return string? -- `no node near <from|to>` or `no route`.
]=]
function Graph.FindPath(self: GraphClass, from: Vector3, to: Vector3, agent: Types.Agent): (Types.Path?, string?)
	local _ = agent

	local start = self:_entry(from)
	if start == nil then
		return nil, `no node near {from}`
	end
	local goal = self:_entry(to)
	if goal == nil then
		return nil, `no node near {to}`
	end

	local route = Graph.AStar(self._nodes, start, goal)
	if route == nil then
		return nil, "no route"
	end
	route = Graph.Trim(self._nodes, route, from, to, self._options.LineOfSight)

	local path: Types.Path = {}
	for position, index in route do
		local step: Types.Step = { Position = self._nodes[index].Position, Action = "Walk" }
		local next = route[position + 1]
		local link = if next then linkBetween(self._nodes, index, next) else nil
		if type(link) == "table" then
			step.Action = link.Action or "Walk"
			step.Label = link.Label
			step.Instance = link.Instance
		end
		table.insert(path, step)
	end
	-- Steps are floor positions; the target is usually a root. The exit node's floor is the best
	-- estimate of the floor under it.
	local floorY = self._nodes[goal].Position.Y
	table.insert(path, { Position = Vector3.new(to.X, floorY, to.Z), Action = "Walk" })

	return path, nil
end

--[=[
	@within Graph
	@param from Vector3
	@param to Vector3
	@return number? -- Length in studs of the route through the graph, or `nil` when there is none.

	The "distance through the level" a chase or tension system wants, rather than a straight line
	through a wall.
]=]
function Graph.PathLength(self: GraphClass, from: Vector3, to: Vector3): number?
	local path = self:FindPath(from, to, nil :: any)
	if path == nil then
		return nil
	end

	local length = Tables.FlatDistance(from, path[1].Position)
	for index = 2, #path do
		length += (path[index].Position - path[index - 1].Position).Magnitude
	end

	return length
end

--[=[
	@within Graph
	@return { GraphNode } -- A copy of the nodes.
]=]
function Graph.GetNodes(self: GraphClass): { GraphNode }
	local copy = {}
	for index, node in self._nodes do
		copy[index] = { Position = node.Position, Links = table.clone(node.Links) }
	end
	return copy
end

--[=[
	@within Graph

	Nothing to release; present so the pathfinder contract is complete.
]=]
function Graph.Destroy(self: GraphClass)
	local _ = self
end

return Graph
