--!strict

--[[
	The cleanup bag: what it accepts, the reverse order it releases in, Extend, Remove, and how
	an erroring release does not stop the rest.
]]

local Harness = require("../Support/Harness")

local roblox = require("@lune/roblox")
local task = require("@lune/task")

local function load(warnings: { string }?)
	return Harness.Load("lib/Utility/Cleaner.luau", {
		warn = function(message)
			if warnings then
				table.insert(warnings, tostring(message))
			end
		end,
	})
end

return {
	["releases every kind, newest first"] = function(expect)
		local Cleaner = load()
		local Signal = Harness.Load("lib/Utility/Signal.luau")
		local cleaner = Cleaner.new()
		local log = {}

		local part = cleaner:Add(roblox.Instance.new("Part"))
		part.Parent = roblox.Instance.new("Folder")
		cleaner:Add(function()
			table.insert(log, "function")
		end)
		cleaner:Add({
			Destroy = function()
				table.insert(log, "destroyable")
			end,
		})
		cleaner:Add({
			Disconnect = function()
				table.insert(log, "disconnectable")
			end,
		})
		local signal = Signal.new()
		local fired = 0
		cleaner:Connect(signal, function()
			fired += 1
		end)
		local thread = task.spawn(function()
			task.wait(60)
			table.insert(log, "thread woke")
		end)
		cleaner:Add(thread)
		cleaner:Add({
			Close = function()
				table.insert(log, "custom")
			end,
		}, "Close")

		cleaner:Destroy()
		expect.sequence(log, { "custom", "disconnectable", "destroyable", "function" })
		expect.equal(part.Parent, nil, "the instance was destroyed")
		signal:Fire()
		expect.equal(fired, 0, "the connection was disconnected")
		expect.equal(coroutine.status(thread), "dead", "the thread was cancelled")
	end,

	["Add returns the object and refuses what it cannot release"] = function(expect)
		local Cleaner = load()
		local cleaner = Cleaner.new()
		local fn = function() end
		expect.equal(cleaner:Add(fn), fn)

		local message = expect.errors(function()
			cleaner:Add({} :: any)
		end)
		expect.includes(message, "needs Destroy or Disconnect")

		message = expect.errors(function()
			cleaner:Add({ Destroy = function() end }, "Close")
		end)
		expect.includes(message, 'no method "Close"')
	end,

	["Clean keeps the cleaner usable and Destroy refuses new objects"] = function(expect)
		local Cleaner = load()
		local cleaner = Cleaner.new()
		local count = 0
		cleaner:Add(function()
			count += 1
		end)

		cleaner:Clean()
		expect.equal(count, 1)
		cleaner:Add(function()
			count += 1
		end)
		cleaner:Clean()
		expect.equal(count, 2)

		cleaner:Destroy()
		cleaner:Destroy()
		local message = expect.errors(function()
			cleaner:Add(function() end)
		end)
		expect.includes(message, "destroyed cleaner")
	end,

	["Extend makes a child cleaned with its parent, and usable alone before that"] = function(expect)
		local Cleaner = load()
		local cleaner = Cleaner.new()
		local child = cleaner:Extend()
		local log = {}

		child:Add(function()
			table.insert(log, "child 1")
		end)
		child:Clean()
		child:Add(function()
			table.insert(log, "child 2")
		end)
		cleaner:Add(function()
			table.insert(log, "parent")
		end)

		cleaner:Destroy()
		expect.sequence(log, { "child 1", "parent", "child 2" })
	end,

	["Remove takes one object out and releases it"] = function(expect)
		local Cleaner = load()
		local cleaner = Cleaner.new()
		local log = {}
		local first = function()
			table.insert(log, "first")
		end
		cleaner:Add(first)
		cleaner:Add(function()
			table.insert(log, "second")
		end)

		expect.truthy(cleaner:Remove(first))
		expect.falsy(cleaner:Remove(first), "gone already")
		expect.sequence(log, { "first" })
		cleaner:Destroy()
		expect.sequence(log, { "first", "second" })
	end,

	["an object that errors on release does not stop the rest"] = function(expect)
		local warnings = {}
		local Cleaner = load(warnings)
		local cleaner = Cleaner.new()
		local released = false
		cleaner:Add(function()
			released = true
		end)
		cleaner:Add(function()
			error("broken")
		end)

		cleaner:Destroy()
		expect.truthy(released)
		expect.equal(#warnings, 1)
		expect.includes(warnings[1], "broken")
	end,

	["Clean from inside a release does not recurse"] = function(expect)
		local Cleaner = load()
		local cleaner = Cleaner.new()
		local calls = 0
		cleaner:Add(function()
			calls += 1
			cleaner:Clean()
		end)
		cleaner:Clean()
		expect.equal(calls, 1)
	end,
}
