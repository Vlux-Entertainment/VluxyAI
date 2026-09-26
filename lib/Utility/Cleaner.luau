--!strict

--[[
	A cleanup bag: everything the package needs to release goes in one, and `Clean` or `Destroy`
	releases it in reverse order. Pure Luau, no dependency, and the whole of what the package
	used a third-party cleanup library for.

	What it accepts: an `Instance` (destroyed), a function (called), a thread (cancelled), a
	connection (disconnected), a table with `Destroy` or `Disconnect` (called), and a
	[Types.Signal] connection. A child made with `Extend` is cleaned with its parent.
]]

local FormatMessage = require(script.Parent.FormatMessage)

------------------------------------------------------------------------------------------------------------------------

type Entry = {
	Object: any,
	Method: string?,
}

type self = {
	_entries: { Entry },
	_cleaning: boolean,
	_destroyed: boolean,
}

local Cleaner = {}
Cleaner.__index = Cleaner

export type Cleaner = typeof(setmetatable({} :: self, Cleaner))

--[[
	Releases one object the way its kind is released.
]]
local function release(entry: Entry)
	local object = entry.Object
	local kind = typeof(object)

	if entry.Method then
		object[entry.Method](object)
	elseif kind == "Instance" then
		object:Destroy()
	elseif kind == "RBXScriptConnection" then
		object:Disconnect()
	elseif kind == "function" then
		object()
	elseif kind == "thread" then
		task.cancel(object)
	elseif kind == "table" then
		if type(object.Destroy) == "function" then
			object:Destroy()
		elseif type(object.Disconnect) == "function" then
			object:Disconnect()
		end
	end
end

--[=[
	@class Cleaner

	The package's cleanup bag. Add what must be released, and `Destroy` releases it all in
	reverse order: instances, connections, threads, functions, and anything with `Destroy` or
	`Disconnect`. Your own cleanup helper works with the package too, as long as it calls
	`Destroy`.
]=]

--[=[
	@within Cleaner
	@return Cleaner
]=]
function Cleaner.new(): Cleaner
	local self: self = {
		_entries = {},
		_cleaning = false,
		_destroyed = false,
	}

	return setmetatable(self, Cleaner)
end

--[=[
	@within Cleaner
	@param object T -- An Instance, connection, function, thread, or a table with `Destroy` or `Disconnect`.
	@param method string? -- The method to call instead of the usual one, for a table with an unusual name.
	@return T -- The same object, so `local part = cleaner:Add(Instance.new("Part"))` reads well.
	@error string -- The object is of a kind the cleaner cannot release, or the cleaner was destroyed.
]=]
function Cleaner.Add<T>(self: Cleaner, object: T, method: string?): T
	if self._destroyed then
		FormatMessage.Error("Cleaner: cannot Add to a destroyed cleaner", 2)
	end

	local kind = typeof(object)
	local releasable = method ~= nil
		or kind == "Instance"
		or kind == "RBXScriptConnection"
		or kind == "function"
		or kind == "thread"
		or (
			kind == "table"
			and (type((object :: any).Destroy) == "function" or type((object :: any).Disconnect) == "function")
		)
	if not releasable then
		FormatMessage.Error(`Cleaner: cannot release a {kind}; it needs Destroy or Disconnect`, 2)
	end
	if method ~= nil and type((object :: any)[method]) ~= "function" then
		FormatMessage.Error(`Cleaner: the object has no method "{method}"`, 2)
	end

	table.insert(self._entries, { Object = object, Method = method })
	return object
end

--[=[
	@within Cleaner
	@param signal any -- Anything with `Connect`: an `RBXScriptSignal` or a [Types.Signal].
	@param handler (...any) -> ()
	@return any -- The connection, already added.
]=]
function Cleaner.Connect(self: Cleaner, signal: any, handler: (...any) -> ()): any
	return self:Add(signal:Connect(handler))
end

--[=[
	@within Cleaner
	@return Cleaner -- A child cleaner, cleaned with this one, usable on its own before that.
]=]
function Cleaner.Extend(self: Cleaner): Cleaner
	return self:Add(Cleaner.new())
end

--[=[
	@within Cleaner
	@param object any
	@return boolean -- `true` when it was held.

	Takes an object back out and releases it.
]=]
function Cleaner.Remove(self: Cleaner, object: any): boolean
	for index = #self._entries, 1, -1 do
		local entry = self._entries[index]
		if entry.Object == object then
			table.remove(self._entries, index)
			release(entry)
			return true
		end
	end

	return false
end

--[=[
	@within Cleaner

	Releases everything, newest first, and leaves the cleaner usable. An object that errors on
	release is warned about and the rest are still released.
]=]
function Cleaner.Clean(self: Cleaner)
	if self._cleaning then
		return
	end
	self._cleaning = true

	local entries = self._entries
	self._entries = {}
	for index = #entries, 1, -1 do
		local ok, err = pcall(release :: any, entries[index])
		if not ok then
			FormatMessage.Warn(`Cleaner: releasing a {typeof(entries[index].Object)} errored: {tostring(err)}`)
		end
	end

	self._cleaning = false
end

--[=[
	@within Cleaner

	`Clean`, then refuse anything new.
]=]
function Cleaner.Destroy(self: Cleaner)
	if self._destroyed then
		return
	end
	self:Clean()
	self._destroyed = true
end

return Cleaner
