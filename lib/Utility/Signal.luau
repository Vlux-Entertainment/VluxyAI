--!strict

--[[
	A small signal in plain Luau so the core never needs a BindableEvent. Handlers run through
	`task.spawn`, so one handler erroring or yielding never blocks the others or the firer, which is
	how RBXScriptSignal behaves. Trove accepts the connections it returns.
]]

local Types = require(script.Parent.Parent.Types)

------------------------------------------------------------------------------------------------------------------------

type Handler = {
	Callback: (...any) -> (),
	Connection: Types.Connection,
}

type self = {
	_handlers: { Handler },
	_waiting: { thread },
	_destroyed: boolean,
}

local Signal = {}
Signal.__index = Signal

--[[
	Removes a handler from the list if it is there. Used by Disconnect and by Once after its first
	fire.
]]
local function removeHandler(self: self, handler: Handler)
	local index = table.find(self._handlers, handler)
	if index then
		table.remove(self._handlers, index)
	end
	handler.Connection.Connected = false
end

--[[
	Adds a handler and returns its connection.
]]
local function addHandler(self: self, callback: (...any) -> ()): Types.Connection
	if self._destroyed then
		error("VluxyAI: cannot connect to a destroyed signal", 3)
	end

	local handler: Handler
	local connection: Types.Connection = {
		Connected = true,
		Disconnect = function(_connection)
			removeHandler(self, handler)
		end,
	}
	handler = { Callback = callback, Connection = connection }

	table.insert(self._handlers, handler)

	return connection
end

--[=[
	@class Signal

	A small signal with the same surface as `RBXScriptSignal`, written in plain Luau so the core
	runs outside Roblox. Every [Types.Signal] the package exposes is one of these; you can make your
	own for a [Hearing] noise source with `VluxyAI.Signal.new()`.
]=]

--[=[
	@within Signal
	@return Signal<T...>

	Creates a signal.
]=]
function Signal.new<T...>(): Types.Signal<T...>
	local self: self = {
		_handlers = {},
		_waiting = {},
		_destroyed = false,
	}

	return setmetatable(self, Signal) :: any
end

--[=[
	@within Signal
	@param handler (T...) -> ()
	@return Connection

	Runs `handler` on every fire until disconnected.
]=]
function Signal.Connect(self: self, handler: (...any) -> ()): Types.Connection
	return addHandler(self, handler)
end

--[=[
	@within Signal
	@param handler (T...) -> ()
	@return Connection

	Runs `handler` on the next fire only.
]=]
function Signal.Once(self: self, handler: (...any) -> ()): Types.Connection
	local connection: Types.Connection
	connection = addHandler(self, function(...)
		connection:Disconnect()
		handler(...)
	end)

	return connection
end

--[=[
	@within Signal
	@yields
	@return T...

	Yields the calling thread until the next fire and returns what was fired. If the signal is
	destroyed while waiting, returns nothing, so a state that waited on `Arrived` wakes up when
	its agent is destroyed and can check `agent:IsDestroyed()`.
]=]
function Signal.Wait(self: self): ...any
	if self._destroyed then
		return nil
	end

	local thread = coroutine.running()
	table.insert(self._waiting, thread)

	Signal.Once(self, function(...)
		local index = table.find(self._waiting, thread)
		if index then
			table.remove(self._waiting, index)
		end
		task.spawn(thread, ...)
	end)

	return coroutine.yield()
end

--[=[
	@within Signal
	@param ... T...

	Fires every connected handler with the arguments, each in its own thread. Handlers connected or
	disconnected during a fire take effect on the next one.
]=]
function Signal.Fire(self: self, ...: any)
	if self._destroyed then
		return
	end

	local snapshot = table.clone(self._handlers)
	for _, handler in snapshot do
		if handler.Connection.Connected then
			task.spawn(handler.Callback, ...)
		end
	end
end

--[=[
	@within Signal

	Drops every handler. The signal stays usable.
]=]
function Signal.DisconnectAll(self: self)
	for _, handler in self._handlers do
		handler.Connection.Connected = false
	end
	table.clear(self._handlers)
end

--[=[
	@within Signal

	Drops every handler and refuses new connections. Fires after this do nothing.
]=]
function Signal.Destroy(self: self)
	Signal.DisconnectAll(self)
	self._destroyed = true

	-- Nobody will fire again; let the waiters go rather than hang forever.
	local waiting = self._waiting
	self._waiting = {}
	for _, thread in waiting do
		task.spawn(thread)
	end
end

return Signal
