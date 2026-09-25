--!strict

--[[
	The node graph: A* over links, nearest-node entry with an optional line-of-sight filter, the
	path it emits, path length, and validation of the node table.
]]

local Fakes = require("../Support/Fakes")
local Harness = require("../Support/Harness")

local roblox = require("@lune/roblox")
local Vector3 = roblox.Vector3

local function load()
	return Harness.Load("lib/Pathfinders/Graph.luau")
end

--[[
	A square of four nodes with a fifth off to the side reachable only from node 2, and a sixth
	that links nowhere:

	  1 --- 2 --- 5
	  |     |
	  4 --- 3        6
]]
local function square()
	return {
		{ Position = Vector3.new(0, 0, 0), Links = { 2, 4 } },
		{ Position = Vector3.new(10, 0, 0), Links = { 1, 3, 5 } },
		{ Position = Vector3.new(10, 0, 10), Links = { 2, 4 } },
		{ Position = Vector3.new(0, 0, 10), Links = { 1, 3 } },
		{ Position = Vector3.new(20, 0, 0), Links = { 2 } },
		{ Position = Vector3.new(40, 0, 40), Links = {} },
	}
end

return {
	["AStar finds the shortest chain of links"] = function(expect)
		local Graph = load()
		local route = Graph.AStar(square(), 1, 3) :: any
		expect.equal(#route, 3, "either way round is two hops")
		expect.equal(route[1], 1)
		expect.equal(route[3], 3)
		local far = Graph.AStar(square(), 4, 5) :: any
		expect.equal(#far, 4)
		expect.equal(far[4], 5)
		expect.sequence(Graph.AStar(square(), 2, 2) :: any, { 2 })
	end,

	["AStar respects one-way links and reports unreachable"] = function(expect)
		local Graph = load()
		local nodes = square()
		expect.equal(Graph.AStar(nodes, 1, 6), nil, "nothing links to 6")
		expect.equal(Graph.AStar(nodes, 6, 1), nil, "6 links nowhere")

		local oneWay = {
			{ Position = Vector3.new(0, 0, 0), Links = { 2 } },
			{ Position = Vector3.new(10, 0, 0), Links = {} },
		}
		expect.sequence(Graph.AStar(oneWay, 1, 2) :: any, { 1, 2 })
		expect.equal(Graph.AStar(oneWay, 2, 1), nil)
		expect.equal(Graph.AStar(oneWay, 1, 9), nil, "unknown index")
	end,

	["AStar prefers the geometrically shorter route"] = function(expect)
		local Graph = load()
		-- Two routes to node 4: via 2 (20 + 14.1) or via 3 (7.1 + 7.1).
		local nodes = {
			{ Position = Vector3.new(0, 0, 0), Links = { 2, 3 } },
			{ Position = Vector3.new(0, 0, 20), Links = { 4 } },
			{ Position = Vector3.new(5, 0, 5), Links = { 4 } },
			{ Position = Vector3.new(10, 0, 10), Links = {} },
		}
		local route = Graph.AStar(nodes, 1, 4) :: any
		expect.sequence(route, { 1, 3, 4 })
	end,

	["Nearest picks within the limit and honours the filter"] = function(expect)
		local Graph = load()
		local nodes = square()
		expect.equal(Graph.Nearest(nodes, Vector3.new(1, 0, 1), 60), 1)
		expect.equal(Graph.Nearest(nodes, Vector3.new(100, 0, 100), 10), nil, "too far")
		expect.equal(
			Graph.Nearest(nodes, Vector3.new(1, 0, 1), 60, function(node)
				return node.Position.X > 5
			end),
			2,
			"the nearest the filter accepts"
		)
	end,

	["FindPath returns the route's nodes then the target"] = function(expect)
		local Graph = load()
		local graph = Graph.new(square())
		local path, reason = graph:FindPath(Vector3.new(-2, 0, 8), Vector3.new(21, 0, 1), Fakes.Agent())
		expect.equal(reason, nil)
		local xs = {}
		for _, step in path do
			table.insert(xs, `{step.Position.X},{step.Position.Z}`)
		end
		expect.equal(#xs, 5, "four nodes then the target")
		expect.equal(xs[1], "0,10", "enters at the nearest node")
		expect.equal(xs[4], "20,0", "leaves from the node nearest the target")
		expect.equal(xs[5], "21,1", "ends at the target itself")
		expect.equal(path[1].Action, "Walk")
	end,

	["FindPath fails with a reason when no node is near or there is no route"] = function(expect)
		local Graph = load()
		local graph = Graph.new(square(), { NearestLimit = 5 })
		local path, reason = graph:FindPath(Vector3.new(50, 0, 50), Vector3.new(1, 0, 1), Fakes.Agent())
		expect.equal(path, nil)
		expect.includes(reason, "no node near")

		path, reason = Graph.new(square()):FindPath(Vector3.new(0, 0, 0), Vector3.new(40, 0, 40), Fakes.Agent())
		expect.equal(path, nil)
		expect.equal(reason, "no route")
	end,

	["LineOfSight chooses the entry and exit nodes"] = function(expect)
		local Graph = load()
		local graph = Graph.new(square(), {
			LineOfSight = function(_from, to)
				return to.X >= 10
			end,
		})
		local path = graph:FindPath(Vector3.new(1, 0, 1), Vector3.new(1, 0, 9), Fakes.Agent())
		expect.near(path[1].Position.X, 10, 1e-6, "the nearest node with line of sight, not the nearest")
	end,

	["PathLength is the length of the route through the graph"] = function(expect)
		local Graph = load()
		local graph = Graph.new(square())
		local length = graph:PathLength(Vector3.new(0, 0, 0), Vector3.new(20, 0, 0)) :: number
		expect.near(length, 20, 1e-6)
		expect.equal(graph:PathLength(Vector3.new(0, 0, 0), Vector3.new(40, 0, 40)), nil)
	end,

	["new validates the nodes and copies them"] = function(expect)
		local Graph = load()
		local message = expect.errors(function()
			Graph.new({})
		end)
		expect.includes(message, "at least one node")

		message = expect.errors(function()
			Graph.new({ { Position = Vector3.new(), Links = { 7 } } })
		end)
		expect.includes(message, "links to node 7, which does not exist")

		local nodes = square()
		local graph = Graph.new(nodes)
		table.insert(nodes[1].Links, 3)
		expect.equal(#graph:GetNodes()[1].Links, 2, "the graph keeps its own copy")
		expect.equal(graph.Name, "Graph")
	end,
}
