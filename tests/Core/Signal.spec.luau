--!strict

--[[
	The signal the package is built on. Fire runs handlers in their own threads, so these cases
	assert after Fire returns, which is when synchronous handlers have already run.
]]

local Harness = require("../Support/Harness")

local task = require("@lune/task")

local function load()
	return Harness.Load("lib/Utility/Signal.luau")
end

return {
	["Connect receives every fire with its arguments"] = function(expect)
		local Signal = load()
		local signal = Signal.new()
		local received = {}

		signal:Connect(function(a, b)
			table.insert(received, `{a}:{b}`)
		end)
		signal:Fire("x", 1)
		signal:Fire("y", 2)

		expect.sequence(received, { "x:1", "y:2" })
	end,

	["Disconnect stops delivery and flips Connected"] = function(expect)
		local Signal = load()
		local signal = Signal.new()
		local count = 0

		local connection = signal:Connect(function()
			count += 1
		end)
		signal:Fire()
		expect.truthy(connection.Connected)
		connection:Disconnect()
		expect.falsy(connection.Connected)
		signal:Fire()

		expect.equal(count, 1)
	end,

	["Once fires a single time"] = function(expect)
		local Signal = load()
		local signal = Signal.new()
		local count = 0

		local connection = signal:Once(function()
			count += 1
		end)
		signal:Fire()
		signal:Fire()

		expect.equal(count, 1)
		expect.falsy(connection.Connected)
	end,

	["a handler disconnecting another during a fire still lets that fire finish"] = function(expect)
		local Signal = load()
		local signal = Signal.new()
		local log = {}
		local second

		signal:Connect(function()
			table.insert(log, "first")
			second:Disconnect()
		end)
		second = signal:Connect(function()
			table.insert(log, "second")
		end)

		signal:Fire()
		signal:Fire()
		expect.sequence(log, { "first", "first" }, "the disconnected handler is skipped even within the same fire")
	end,

	["a handler that errors does not stop the others"] = function(expect)
		local Signal = load()
		local signal = Signal.new()
		local reached = false

		signal:Connect(function()
			error("boom")
		end)
		signal:Connect(function()
			reached = true
		end)
		signal:Fire()

		expect.truthy(reached)
	end,

	["Wait yields until the next fire and returns the arguments"] = function(expect)
		local Signal = load()
		local signal = Signal.new()
		local got = nil

		task.spawn(function()
			got = { signal:Wait() }
		end)
		expect.equal(got, nil, "still waiting")
		signal:Fire("done", 3)
		task.wait()

		expect.truthy(got)
		expect.equal((got :: any)[1], "done")
		expect.equal((got :: any)[2], 3)
	end,

	["DisconnectAll drops every handler but keeps the signal usable"] = function(expect)
		local Signal = load()
		local signal = Signal.new()
		local count = 0

		local connection = signal:Connect(function()
			count += 1
		end)
		signal:DisconnectAll()
		expect.falsy(connection.Connected)
		signal:Fire()
		expect.equal(count, 0)

		signal:Connect(function()
			count += 1
		end)
		signal:Fire()
		expect.equal(count, 1)
	end,

	["Destroy drops handlers, ignores fires and refuses connections"] = function(expect)
		local Signal = load()
		local signal = Signal.new()
		local count = 0

		signal:Connect(function()
			count += 1
		end)
		signal:Destroy()
		signal:Fire()
		expect.equal(count, 0)

		local message = expect.errors(function()
			signal:Connect(function() end)
		end)
		expect.includes(message, "destroyed signal")
	end,
}
