--!strict

--[[
	Table helpers the core shares. Pure.
]]

local Tables = {}

--[=[
	@class Tables

	Small table helpers the package shares: deep copy, sorted keys, a flat distance and a
	prefixed view. Exposed as `VluxyAI.Tables`.
]=]

--[[
	Deep-copies plain tables. Anything with a metatable (a class instance, a signal, a cleaner) is
	shared, not copied: those are objects, and copying them would break their identity. Roblox
	values like Vector3 are immutable and copy by reference anyway.
]]
function Tables.DeepCopy<T>(value: T): T
	if type(value) ~= "table" or getmetatable(value :: any) ~= nil then
		return value
	end

	local copy = {}
	for key, item in value :: any do
		copy[key] = Tables.DeepCopy(item)
	end

	return copy :: any
end

--[[
	Returns the keys of a table as a sorted list of strings, for messages that list what was
	expected.
]]
function Tables.SortedKeys(value: { [string]: any }): { string }
	local keys = {}
	for key in value do
		table.insert(keys, key)
	end
	table.sort(keys)

	return keys
end

--[[
	Horizontal distance between two positions, ignoring height. Arrival checks use this because a
	humanoid's root and a floor waypoint sit at different heights.
]]
--[=[
	@within Tables
	@param target { [string]: any }
	@param prefix string
	@return { [string]: any } -- `target` itself when `prefix` is empty, else a view whose reads and writes go to `prefix .. key`.

	A prefixed view of a table, so a sense given `Prefix = "Peripheral"` writes
	`PeripheralSeenTarget` without knowing. Costs one small table per call; nothing at all when
	the prefix is empty, which is the default everywhere.
]=]
function Tables.Prefixed(target: { [string]: any }, prefix: string): { [string]: any }
	if prefix == "" then
		return target
	end

	return setmetatable({}, {
		__index = function(_view, key: string)
			return target[prefix .. key]
		end,
		__newindex = function(_view, key: string, value: any)
			target[prefix .. key] = value
		end,
	}) :: any
end

--[=[
	@within Tables
	@param a string
	@param b string
	@return number -- The edit distance: insertions, deletions and substitutions to turn `a` into `b`.
]=]
function Tables.EditDistance(a: string, b: string): number
	local lengthA, lengthB = #a, #b
	if lengthA == 0 then
		return lengthB
	end
	if lengthB == 0 then
		return lengthA
	end

	local previous = table.create(lengthB + 1)
	for j = 0, lengthB do
		previous[j + 1] = j
	end
	for i = 1, lengthA do
		local current = table.create(lengthB + 1)
		current[1] = i
		local charA = string.sub(a, i, i)
		for j = 1, lengthB do
			local cost = if charA == string.sub(b, j, j) then 0 else 1
			current[j + 1] = math.min(previous[j + 1] + 1, current[j] + 1, previous[j] + cost)
		end
		previous = current
	end
	return previous[lengthB + 1]
end

function Tables.FlatDistance(a: Vector3, b: Vector3): number
	local dx = a.X - b.X
	local dz = a.Z - b.Z

	return math.sqrt(dx * dx + dz * dz)
end

return Tables
