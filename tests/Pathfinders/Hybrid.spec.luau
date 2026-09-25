--!strict

--[[
	The hybrid pathfinder with fake graph and local pathfinders: local first up close, the graph
	beyond that with both ends refined locally, and every fallback.
]]

local Fakes = require("../Support/Fakes")
local Harness = require("../Support/Harness")

local roblox = require("@lune/roblox")
local Vector3 = roblox.Vector3

local function walk(x: number, z: number, label: string?)
	return { Position = Vector3.new(x, 0, z), Action = "Walk", Label = label }
end

--[[
	A pathfinder that answers from a function and records its calls.
]]
local function fakePathfinder(name: string, plan)
	local pathfinder = { Name = name, Calls = {} :: { any }, Destroyed = false }
	function pathfinder.FindPath(self, from, to, _agent)
		table.insert(self.Calls, { From = from, To = to })
		return plan(from, to)
	end
	function pathfinder.Destroy(self)
		self.Destroyed = true
	end
	return pathfinder
end

local function labels(path): { string }
	local out = {}
	for _, step in path do
		table.insert(out, step.Label or `{step.Position.X},{step.Position.Z}`)
	end
	return out
end

local function setup(options: any?)
	local Hybrid = Harness.Load("lib/Pathfinders/Hybrid.luau")
	local graph = fakePathfinder("Graph", function(_from, to)
		-- Two authored nodes then the target.
		return { walk(50, 0, "n1"), walk(100, 0, "n2"), { Position = to, Action = "Walk", Label = "goal" } }
	end)
	local localPathfinder = fakePathfinder("Local", function(from, to)
		return {
			{ Position = from, Action = "Walk", Label = "L:from" },
			{ Position = to, Action = "Walk", Label = "L:to" },
		}
	end)
	local resolved = options or {}
	resolved.Graph = graph
	resolved.Local = localPathfinder
	return {
		hybrid = Hybrid.new(resolved),
		Hybrid = Hybrid,
		graph = graph,
		localPathfinder = localPathfinder,
	}
end

return {
	["within LocalRadius the local pathfinder answers and the graph is not asked"] = function(expect)
		local s = setup({ LocalRadius = 40 })
		local path = s.hybrid:FindPath(Vector3.new(0, 0, 0), Vector3.new(30, 0, 0), Fakes.Agent())
		expect.sequence(labels(path), { "L:from", "L:to" })
		expect.equal(#s.graph.Calls, 0)
	end,

	["beyond LocalRadius the graph plans and both ends are refined locally"] = function(expect)
		local s = setup({ LocalRadius = 40 })
		local path = s.hybrid:FindPath(Vector3.new(0, 0, 0), Vector3.new(120, 0, 0), Fakes.Agent())
		-- head leg from -> n1, then n2 is walked to directly, then tail leg n2 -> target.
		expect.sequence(labels(path), { "L:from", "L:to", "L:from", "L:to" })
		expect.equal(#s.localPathfinder.Calls, 2)
		expect.near(s.localPathfinder.Calls[1].To.X, 50, 1e-6, "head leg ends at the first node")
		expect.near(s.localPathfinder.Calls[2].From.X, 100, 1e-6, "tail leg starts at the last node")
		expect.near(s.localPathfinder.Calls[2].To.X, 120, 1e-6)
	end,

	["middle nodes are kept as steps"] = function(expect)
		local Hybrid = Harness.Load("lib/Pathfinders/Hybrid.luau")
		local graph = fakePathfinder("Graph", function(_from, to)
			return {
				walk(50, 0, "n1"),
				walk(75, 0, "n2"),
				walk(100, 0, "n3"),
				{ Position = to, Action = "Walk", Label = "goal" },
			}
		end)
		local localPathfinder = fakePathfinder("Local", function(_from, to)
			return { { Position = to, Action = "Walk", Label = "L" } }
		end)
		local hybrid = Hybrid.new({ Graph = graph, Local = localPathfinder, LocalRadius = 10 })
		local path = hybrid:FindPath(Vector3.new(0, 0, 0), Vector3.new(120, 0, 0), Fakes.Agent())
		expect.sequence(labels(path), { "L", "n2", "L" })
	end,

	["a leg the local pathfinder cannot plan falls back to the node itself"] = function(expect)
		local Hybrid = Harness.Load("lib/Pathfinders/Hybrid.luau")
		local graph = fakePathfinder("Graph", function(_from, to)
			return { walk(50, 0, "n1"), walk(100, 0, "n2"), { Position = to, Action = "Walk", Label = "goal" } }
		end)
		local localPathfinder = fakePathfinder("Local", function()
			return nil, "blocked"
		end)
		local hybrid = Hybrid.new({ Graph = graph, Local = localPathfinder, LocalRadius = 10 })
		local path = hybrid:FindPath(Vector3.new(0, 0, 0), Vector3.new(120, 0, 0), Fakes.Agent())
		expect.sequence(labels(path), { "n1", "n2", "goal" })
	end,

	["RefineEnds off returns the graph path as is"] = function(expect)
		local s = setup({ LocalRadius = 10, RefineEnds = false })
		local path = s.hybrid:FindPath(Vector3.new(0, 0, 0), Vector3.new(120, 0, 0), Fakes.Agent())
		expect.sequence(labels(path), { "n1", "n2", "goal" })
		expect.equal(#s.localPathfinder.Calls, 0)
	end,

	["with no graph route the local pathfinder is the last word, and both reasons are joined"] = function(expect)
		local Hybrid = Harness.Load("lib/Pathfinders/Hybrid.luau")
		local graph = fakePathfinder("Graph", function()
			return nil, "no route"
		end)
		local localCalls = 0
		local localPathfinder = fakePathfinder("Local", function(_from, to)
			localCalls += 1
			if localCalls == 1 then
				return { { Position = to, Action = "Walk", Label = "L" } }
			end
			return nil, "no path"
		end)
		local hybrid = Hybrid.new({ Graph = graph, Local = localPathfinder, LocalRadius = 10 })

		local path = hybrid:FindPath(Vector3.new(0, 0, 0), Vector3.new(120, 0, 0), Fakes.Agent())
		expect.sequence(labels(path), { "L" })

		local none, reason = hybrid:FindPath(Vector3.new(0, 0, 0), Vector3.new(120, 0, 0), Fakes.Agent())
		expect.equal(none, nil)
		expect.equal(reason, "Graph: no route; Local: no path")
	end,

	["a local failure up close falls through to the graph"] = function(expect)
		local Hybrid = Harness.Load("lib/Pathfinders/Hybrid.luau")
		local graph = fakePathfinder("Graph", function(_from, to)
			return { walk(5, 0, "n1"), { Position = to, Action = "Walk", Label = "goal" } }
		end)
		local localPathfinder = fakePathfinder("Local", function()
			return nil, "blocked"
		end)
		local hybrid = Hybrid.new({ Graph = graph, Local = localPathfinder, LocalRadius = 40 })
		local path = hybrid:FindPath(Vector3.new(0, 0, 0), Vector3.new(10, 0, 0), Fakes.Agent())
		expect.sequence(labels(path), { "n1", "goal" })
	end,

	["Destroy destroys both and new checks its arguments"] = function(expect)
		local s = setup()
		s.hybrid:Destroy()
		expect.truthy(s.graph.Destroyed)
		expect.truthy(s.localPathfinder.Destroyed)

		local message = expect.errors(function()
			s.Hybrid.new({ Graph = s.graph })
		end)
		expect.includes(message, "Local must be a pathfinder")
		message = expect.errors(function()
			s.Hybrid.new({ Graph = s.graph, Local = s.localPathfinder, Radius = 5 })
		end)
		expect.includes(message, 'unknown option "Radius"')
		expect.equal(s.hybrid.Name, "Hybrid")
	end,
}
