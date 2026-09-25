--!strict

--[[
	Composition: tries each pathfinder in order and returns the first path. The usual stack is
	`{ Straight, Navmesh }`: a target in plain sight costs nothing, and only a blocked one asks the
	navmesh. Pure Luau, so it is fully specced.

	The one decision worth knowing: an empty path counts as a failure and the next rung is tried,
	because the Navigator treats an empty path as a failure anyway and a later rung may still know
	the way.
]]

local FormatMessage = require(script.Parent.Parent.Utility.FormatMessage)
local Types = require(script.Parent.Parent.Types)

------------------------------------------------------------------------------------------------------------------------

type self = {
	Name: string,

	_pathfinders: { Types.Pathfinder },
}

local Ladder = {}
Ladder.__index = Ladder

export type Ladder = typeof(setmetatable({} :: self, Ladder))

------------------------------------------------------------------------------------------------------------------------

--[=[
	@class Ladder

	A [Types.Pathfinder] made of other pathfinders, tried in order. The first path wins; when every
	rung fails the reasons are joined, each prefixed with the rung's `Name` or its index:
	`Straight: blocked by Workspace.Wall; Navmesh: NoPath`.

	`Name` is `"Ladder"`, so ladders nest. Make one per agent when a rung is: a [Navmesh] holds a
	`Path` of its own and its `Destroy` releases it, so a ladder shared by two agents dies with the
	first. Keep the rungs' `AgentRadius` and `AgentHeight` in step with each other, since each rung
	measures the body on its own.
]=]

--[=[
	@within Ladder
	@param pathfinders { Pathfinder } -- Tried in this order. The list is copied.
	@return Ladder
	@error "needs at least one pathfinder"
]=]
function Ladder.new(pathfinders: { Types.Pathfinder }): Types.Pathfinder
	if #pathfinders == 0 then
		FormatMessage.Error("Ladder.new: needs at least one pathfinder", 2)
	end

	local self: self = {
		Name = "Ladder",

		_pathfinders = table.clone(pathfinders),
	}

	return setmetatable(self, Ladder) :: any
end

------------------------------------------------------------------------------------------------------------------------

--[[
	What a rung is called in a joined reason: its `Name` field, or its position in the list.
]]
local function nameOf(pathfinder: Types.Pathfinder, index: number): string
	local name = (pathfinder :: any).Name
	if type(name) == "string" and name ~= "" then
		return name
	end
	return tostring(index)
end

--[=[
	@within Ladder
	@yields
	@param from Vector3
	@param to Vector3
	@param agent Agent
	@return Path? -- The first rung's path that is not `nil` or empty.
	@return string? -- Every rung's reason, `<name>: <reason>` joined with `; `.

	Yields whenever a rung does; rungs are tried one after another, never at once.
]=]
function Ladder.FindPath(self: Ladder, from: Vector3, to: Vector3, agent: Types.Agent): (Types.Path?, string?)
	local reasons = {}

	for index, pathfinder in self._pathfinders do
		local path, reason = pathfinder:FindPath(from, to, agent)
		if path ~= nil and #path > 0 then
			return path, nil
		end

		local why = if path ~= nil then "empty path" else reason or "no reason"
		table.insert(reasons, `{nameOf(pathfinder, index)}: {why}`)
	end

	return nil, table.concat(reasons, "; ")
end

--[=[
	@within Ladder

	Calls `Destroy` on every rung that has one, in order.
]=]
function Ladder.Destroy(self: Ladder)
	for _, pathfinder in self._pathfinders do
		local destroy = pathfinder.Destroy
		if destroy then
			destroy(pathfinder)
		end
	end
end

return Ladder
