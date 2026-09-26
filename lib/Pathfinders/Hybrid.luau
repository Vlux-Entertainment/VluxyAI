--!strict

--[[
	The plan's hybrid: a node graph owns connectivity across the level, a local pathfinder owns
	geometry nearby. Up to `LocalRadius` the local pathfinder is tried first; beyond it the graph
	gives the chain of nodes and the local pathfinder refines the first leg (from the agent to the
	first node) and the last leg (from the last node to the target), so the ends cope with
	furniture while the middle trusts the authored nodes. Every fallback is deterministic: when the
	graph has no route the local pathfinder is tried anyway, and when a leg cannot be refined the
	node itself is the step.

	`Blocked` is the local pathfinder's own signal, shared rather than forwarded: the graph never
	blocks, and a [Navmesh] local only knows about the last leg it computed, which is the tail of
	a long route or the whole of a short one.
]]

local FormatMessage = require(script.Parent.Parent.Utility.FormatMessage)
local Options = require(script.Parent.Parent.Utility.Options)
local Tables = require(script.Parent.Parent.Utility.Tables)
local Types = require(script.Parent.Parent.Types)

------------------------------------------------------------------------------------------------------------------------

local DEFAULT_OPTIONS = table.freeze({
	-- Within this horizontal distance the local pathfinder is tried before the graph.
	LocalRadius = 40,
	-- Refine the first and last legs with the local pathfinder.
	RefineEnds = true,
})

--[=[
	@interface HybridOptions
	@within Hybrid

	.Graph Pathfinder -- The long-range pathfinder, usually a [Graph].
	.Local Pathfinder -- The short-range one, usually a [Navmesh] or a [Ladder] of Straight and Navmesh.
	.LocalRadius number? -- Studs within which the local pathfinder is tried first. Default `40`.
	.RefineEnds boolean? -- Plan the first and last legs locally. Default `true`.
]=]
export type HybridOptions = {
	Graph: Types.Pathfinder,
	Local: Types.Pathfinder,
	LocalRadius: number?,
	RefineEnds: boolean?,
}

type ResolvedOptions = {
	LocalRadius: number,
	RefineEnds: boolean,
}

type self = {
	Name: string,
	Blocked: Types.Signal<()>?,
	_graph: Types.Pathfinder,
	_local: Types.Pathfinder,
	_options: ResolvedOptions,
}

local Hybrid = {}
Hybrid.__index = Hybrid

type HybridClass = typeof(setmetatable({} :: self, Hybrid))

--[=[
	@class Hybrid

	A [Types.Pathfinder] that composes a [Graph] for the level and a local pathfinder for the
	geometry, the way the design plan lays it out. `Name` is `"Hybrid"`. `Blocked` is the local
	pathfinder's `Blocked` when it has one, so a blocked local leg re-plans the whole route.
]=]

--[=[
	@within Hybrid
	@param options HybridOptions
	@return Pathfinder
	@error string -- `Graph` or `Local` missing.
]=]
function Hybrid.new(options: HybridOptions): Types.Pathfinder
	if type(options) ~= "table" then
		FormatMessage.Error("Hybrid.new: options are required", 2)
	end
	local graph = options.Graph
	local localPathfinder = options.Local
	if graph == nil or type(graph.FindPath) ~= "function" then
		FormatMessage.Error("Hybrid.new: Graph must be a pathfinder", 2)
	end
	if localPathfinder == nil or type(localPathfinder.FindPath) ~= "function" then
		FormatMessage.Error("Hybrid.new: Local must be a pathfinder", 2)
	end

	local given = table.clone(options :: any) :: { [string]: any }
	given.Graph = nil
	given.Local = nil
	local resolved = Options.Resolve("Hybrid.new", DEFAULT_OPTIONS, given) :: ResolvedOptions

	local self: self = {
		Name = "Hybrid",
		Blocked = (localPathfinder :: any).Blocked,
		_graph = graph,
		_local = localPathfinder,
		_options = resolved,
	}

	return setmetatable(self, Hybrid) :: any
end

--[[
	A local path between two points, or nil.
]]
function Hybrid._leg(self: HybridClass, from: Vector3, to: Vector3, agent: Types.Agent): Types.Path?
	local path = self._local:FindPath(from, to, agent)
	if path == nil or #path == 0 then
		return nil
	end
	return path
end

--[=[
	@within Hybrid
	@param from Vector3
	@param to Vector3
	@param agent Agent
	@return Path?
	@return string? -- Both pathfinders' reasons when neither found a way.
]=]
function Hybrid.FindPath(self: HybridClass, from: Vector3, to: Vector3, agent: Types.Agent): (Types.Path?, string?)
	local localReason: string? = nil

	if Tables.FlatDistance(from, to) <= self._options.LocalRadius then
		local path, reason = self._local:FindPath(from, to, agent)
		if path ~= nil and #path > 0 then
			return path, nil
		end
		localReason = reason
	end

	local route, graphReason = self._graph:FindPath(from, to, agent)
	if route == nil or #route == 0 then
		-- No route through the graph: the local pathfinder is the last word.
		local path, reason = self._local:FindPath(from, to, agent)
		if path ~= nil and #path > 0 then
			return path, nil
		end
		return nil, `Graph: {graphReason or "no route"}; Local: {reason or localReason or "no path"}`
	end

	if not self._options.RefineEnds or #route < 2 then
		return route, nil
	end

	-- The graph path ends with the target itself; the last node is the one before it.
	local firstNode = route[1].Position
	local lastNode = route[#route - 1].Position
	local path: Types.Path = {}

	-- Legs start where the previous one ended; the shared point is one step, not two.
	local function append(step: Types.Step)
		local previous = path[#path]
		if previous and (previous.Position - step.Position).Magnitude < 1e-3 then
			return
		end
		table.insert(path, step)
	end

	local head = self:_leg(from, firstNode, agent)
	if head then
		for _, step in head do
			append(step)
		end
	else
		append(route[1])
	end

	for index = 2, #route - 2 do
		append(route[index])
	end

	local tail = self:_leg(lastNode, to, agent)
	if tail then
		for _, step in tail do
			append(step)
		end
	else
		if #route >= 3 then
			append(route[#route - 1])
		end
		append(route[#route])
	end

	return path, nil
end

--[=[
	@within Hybrid
	@param step Step
	@param seconds number

	Passes the closure to the graph and the local pathfinder, whichever has `Close`.
]=]
function Hybrid.Close(self: HybridClass, step: Types.Step, seconds: number)
	for _, pathfinder in { self._graph, self._local } do
		local close = (pathfinder :: any).Close
		if type(close) == "function" then
			close(pathfinder, step, seconds)
		end
	end
end

--[=[
	@within Hybrid

	Destroys both pathfinders. Make one `Local` per agent; a [Graph] may be shared since its
	`Destroy` releases nothing.
]=]
function Hybrid.Destroy(self: HybridClass)
	for _, pathfinder in { self._graph, self._local } do
		local destroy = pathfinder.Destroy
		if destroy then
			destroy(pathfinder)
		end
	end
end

return Hybrid
