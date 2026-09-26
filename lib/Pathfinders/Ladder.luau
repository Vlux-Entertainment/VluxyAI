--!strict

--[[
	Composition: tries each pathfinder in order and returns the first path. The usual stack is
	`{ Straight, Navmesh }`: a target in plain sight costs nothing, and only a blocked one asks the
	navmesh. Pure Luau, so it is fully specced.

	The one decision worth knowing: an empty path counts as a failure and the next rung is tried,
	because the Navigator treats an empty path as a failure anyway and a later rung may still know
	the way. `Blocked` is forwarded only from the rung whose path is the current one: a Navmesh
	rung that lost to Straight still holds an older path, and a block on that is not news.
]]

local FormatMessage = require(script.Parent.Parent.Utility.FormatMessage)
local Signal = require(script.Parent.Parent.Utility.Signal)
local Types = require(script.Parent.Parent.Types)

------------------------------------------------------------------------------------------------------------------------

type self = {
	Name: string,
	Blocked: Types.Signal<()>,

	_pathfinders: { Types.Pathfinder },
	_current: Types.Pathfinder?,
	_connections: { Types.Connection },
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

	`Blocked` fires when the rung that produced the last path fires its own `Blocked`; other
	rungs' signals are ignored.
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

	local blocked = Signal.new()

	local self: self = {
		Name = "Ladder",
		Blocked = blocked,

		_pathfinders = table.clone(pathfinders),
		_current = nil,
		_connections = {},
	}

	for _, pathfinder in self._pathfinders do
		local signal = (pathfinder :: any).Blocked
		if type(signal) == "table" and type(signal.Connect) == "function" then
			table.insert(
				self._connections,
				signal:Connect(function()
					if self._current == pathfinder then
						blocked:Fire()
					end
				end)
			)
		end
	end

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

	self._current = nil

	for index, pathfinder in self._pathfinders do
		local path, reason = pathfinder:FindPath(from, to, agent)
		if path ~= nil and #path > 0 then
			self._current = pathfinder
			return path, nil
		end

		local why = if path ~= nil then "empty path" else reason or "no reason"
		table.insert(reasons, `{nameOf(pathfinder, index)}: {why}`)
	end

	return nil, table.concat(reasons, "; ")
end

--[=[
	@within Ladder
	@param step Step
	@param seconds number

	Passes the closure to every rung that has `Close`, since any of them might plan through
	the same door next time.
]=]
function Ladder.Close(self: Ladder, step: Types.Step, seconds: number)
	for _, pathfinder in self._pathfinders do
		local close = (pathfinder :: any).Close
		if type(close) == "function" then
			close(pathfinder, step, seconds)
		end
	end
end

--[=[
	@within Ladder

	Calls `Destroy` on every rung that has one, in order, then drops the `Blocked` signal.
]=]
function Ladder.Destroy(self: Ladder)
	for _, connection in self._connections do
		connection:Disconnect()
	end
	table.clear(self._connections)
	self._current = nil

	for _, pathfinder in self._pathfinders do
		local destroy = pathfinder.Destroy
		if destroy then
			destroy(pathfinder)
		end
	end

	self.Blocked:Destroy()
end

return Ladder
