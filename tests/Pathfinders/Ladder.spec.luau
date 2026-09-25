--!strict

--[[
	The ladder pathfinder: order, first success wins, joined reasons, Destroy propagation and
	yielding rungs. Entirely pure, so every case is exact.
]]

local Fakes = require("../Support/Fakes")
local Harness = require("../Support/Harness")

local roblox = require("@lune/roblox")
local task = require("@lune/task")
local Vector3 = roblox.Vector3

local FROM = Vector3.new(0, 0, 0)
local TO = Vector3.new(10, 0, 0)

local function load()
	return Harness.Load("lib/Pathfinders/Ladder.luau")
end

--[[
	A rung that logs its name when asked, fails with `reason`, or succeeds with a one-step path
	labelled with its name.
]]
local function rung(name: string?, log: { string }, reason: string?)
	local pathfinder = Fakes.Pathfinder(function(_from, to)
		table.insert(log, name or "?")
		if reason then
			return nil, reason
		end
		return { { Position = to, Action = "Walk", Label = name } }
	end)
	if name then
		(pathfinder :: any).Name = name
	end
	return pathfinder
end

return {
	["new rejects an empty list"] = function(expect)
		local Ladder = load()
		local err = expect.errors(function()
			Ladder.new({})
		end)
		expect.includes(err, "[VluxyAI]")
		expect.includes(err, "at least one pathfinder")
	end,

	["the first rung that finds a path wins and later rungs are not asked"] = function(expect)
		local Ladder = load()
		local log = {}
		local ladder = Ladder.new({
			rung("Straight", log, "blocked by Wall"),
			rung("Navmesh", log),
			rung("Graph", log),
		})

		local path, reason = ladder:FindPath(FROM, TO, Fakes.Agent())
		expect.equal(reason, nil)
		expect.equal(#path, 1)
		expect.equal(path[1].Label, "Navmesh")
		expect.sequence(log, { "Straight", "Navmesh" })
	end,

	["rungs are tried in the order given"] = function(expect)
		local Ladder = load()
		local log = {}
		local ladder = Ladder.new({ rung("C", log, "no"), rung("A", log, "no"), rung("B", log) })

		ladder:FindPath(FROM, TO, Fakes.Agent())
		expect.sequence(log, { "C", "A", "B" })
	end,

	["every rung receives from, to and the agent"] = function(expect)
		local Ladder = load()
		local seen = {}
		local agent = Fakes.Agent()
		local first = Fakes.Pathfinder(function(from, to, given)
			table.insert(seen, { from, to, given })
			return nil, "no"
		end)
		local second = Fakes.Pathfinder(function(from, to, given)
			table.insert(seen, { from, to, given })
			return { { Position = to, Action = "Walk" } }
		end)

		Ladder.new({ first, second }):FindPath(FROM, TO, agent)
		expect.equal(#seen, 2)
		for _, call in seen do
			expect.equal(call[1], FROM)
			expect.equal(call[2], TO)
			expect.equal(call[3], agent)
		end
	end,

	["when every rung fails the reasons are joined with names"] = function(expect)
		local Ladder = load()
		local log = {}
		local ladder =
			Ladder.new({ rung("Straight", log, "blocked by Workspace.Wall"), rung("Navmesh", log, "NoPath") })

		local path, reason = ladder:FindPath(FROM, TO, Fakes.Agent())
		expect.equal(path, nil)
		expect.equal(reason, "Straight: blocked by Workspace.Wall; Navmesh: NoPath")
	end,

	["a rung without a Name is named by its index"] = function(expect)
		local Ladder = load()
		local log = {}
		local ladder = Ladder.new({ rung(nil, log, "first"), rung("Navmesh", log, "second"), rung(nil, log, "third") })

		local _, reason = ladder:FindPath(FROM, TO, Fakes.Agent())
		expect.equal(reason, "1: first; Navmesh: second; 3: third")
	end,

	["a rung that fails without a reason and one that returns an empty path are named too"] = function(expect)
		local Ladder = load()
		local silent = Fakes.Pathfinder(function()
			return nil
		end)
		local empty = Fakes.Pathfinder(function()
			return {}
		end)
		local ladder = Ladder.new({ silent, empty })

		local path, reason = ladder:FindPath(FROM, TO, Fakes.Agent())
		expect.equal(path, nil)
		expect.equal(reason, "1: no reason; 2: empty path")
	end,

	["an empty path from one rung falls through to the next"] = function(expect)
		local Ladder = load()
		local log = {}
		local empty = Fakes.Pathfinder(function()
			return {}
		end)
		local ladder = Ladder.new({ empty, rung("Navmesh", log) })

		local path = ladder:FindPath(FROM, TO, Fakes.Agent())
		expect.equal(#path, 1)
		expect.sequence(log, { "Navmesh" })
	end,

	["a single rung works"] = function(expect)
		local Ladder = load()
		local log = {}
		local ladder = Ladder.new({ rung("Only", log, "nope") })

		local path, reason = ladder:FindPath(FROM, TO, Fakes.Agent())
		expect.equal(path, nil)
		expect.equal(reason, "Only: nope")
	end,

	["the list is copied so later edits to it do not change the ladder"] = function(expect)
		local Ladder = load()
		local log = {}
		local list = { rung("A", log, "no") }
		local ladder = Ladder.new(list)
		table.insert(list, rung("B", log))

		local path = ladder:FindPath(FROM, TO, Fakes.Agent())
		expect.equal(path, nil)
		expect.sequence(log, { "A" })
	end,

	["Destroy calls Destroy on every rung that has one"] = function(expect)
		local Ladder = load()
		local log = {}
		local first = rung("A", log)
		local bare = {
			FindPath = function()
				return nil, "no"
			end,
		}
		local last = rung("C", log)
		local ladder = Ladder.new({ first, bare, last })

		ladder:Destroy()
		expect.truthy(first.Destroyed)
		expect.truthy(last.Destroyed)
	end,

	["a yielding rung is waited for and the next rung runs after it"] = function(expect)
		local Ladder = load()
		local log = {}
		local slow = Fakes.Pathfinder(function()
			table.insert(log, "slow start")
			task.wait()
			table.insert(log, "slow end")
			return nil, "slow says no"
		end)
		local ladder = Ladder.new({ slow, rung("Navmesh", log) })

		local result = nil
		task.spawn(function()
			result = { ladder:FindPath(FROM, TO, Fakes.Agent()) }
		end)
		expect.equal(result, nil, "still yielding")
		expect.sequence(log, { "slow start" })

		task.wait()
		task.wait()
		expect.truthy(result, "resolved after the yield")
		expect.sequence(log, { "slow start", "slow end", "Navmesh" })
		expect.equal((result :: any)[1][1].Label, "Navmesh")
	end,

	["a ladder nests inside another ladder"] = function(expect)
		local Ladder = load()
		local log = {}
		local inner = Ladder.new({ rung("Straight", log, "blocked") })
		local outer = Ladder.new({ inner, rung("Graph", log, "unreachable") })

		local _, reason = outer:FindPath(FROM, TO, Fakes.Agent())
		expect.equal(reason, "Ladder: Straight: blocked; Graph: unreachable")
	end,
}
