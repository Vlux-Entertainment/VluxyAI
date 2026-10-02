--!strict

--[[
	The node graph: A* over links, nearest-node entry with an optional line-of-sight filter, the
	path it emits, path length, and validation of the node table.
]]

local Fakes = require("../Support/Fakes")
local Harness = require("../Support/Harness")

local roblox = require("@lune/roblox")
local CFrame = roblox.CFrame
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

		local lifted = graph:FindPath(Vector3.new(-2, 0, 8), Vector3.new(21, 3, 1), Fakes.Agent())
		expect.equal(lifted[#lifted].Position.Y, 0, "a root-height target is lowered to the exit node's floor")
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

	["Trim drops the nodes the agent is already past, and the target is past"] = function(expect)
		local Graph = load()
		local nodes = {
			{ Position = Vector3.new(0, 0, 0), Links = { 2 } },
			{ Position = Vector3.new(30, 0, 0), Links = { 1, 3 } },
			{ Position = Vector3.new(60, 0, 0), Links = { 2 } },
		}
		local route = Graph.AStar(nodes, 1, 3) :: { number }
		expect.sequence(
			Graph.Trim(nodes, route, Vector3.new(12, 0, 0), Vector3.new(75, 0, 0)),
			{ 2, 3 },
			"entry behind"
		)
		expect.sequence(Graph.Trim(nodes, route, Vector3.new(-5, 0, 0), Vector3.new(45, 0, 0)), { 1, 2 }, "exit behind")
		expect.sequence(
			Graph.Trim(nodes, route, Vector3.new(-5, 0, 0), Vector3.new(65, 0, 0)),
			{ 1, 2, 3 },
			"nothing to trim"
		)
		expect.equal(
			#Graph.Trim(nodes, { 1 }, Vector3.new(10, 0, 0), Vector3.new(14, 0, 0)),
			0,
			"a node behind both is a detour"
		)
		expect.sequence(
			Graph.Trim(nodes, { 2 }, Vector3.new(20, 0, 0), Vector3.new(40, 0, 0)),
			{ 2 },
			"a node between them is kept"
		)

		local walled = Graph.Trim(nodes, route, Vector3.new(12, 0, 0), Vector3.new(75, 0, 0), function()
			return false
		end)
		expect.sequence(walled, { 1, 2, 3 }, "no trimming without line of sight")
	end,

	["FindPath does not walk the agent back to a node behind it"] = function(expect)
		local Graph = load()
		local graph = Graph.new({
			{ Position = Vector3.new(0, 0, 0), Links = { 2 } },
			{ Position = Vector3.new(30, 0, 0), Links = { 1 } },
		})
		local path = graph:FindPath(Vector3.new(12, 0, 0), Vector3.new(60, 0, 0), Fakes.Agent())
		expect.equal(#path, 2)
		expect.near(path[1].Position.X, 30)
		expect.near(path[2].Position.X, 60)

		local short = graph:FindPath(Vector3.new(10, 0, 0), Vector3.new(14, 0, 0), Fakes.Agent())
		expect.equal(#short, 1, "same node for both ends and it is behind: straight to the target")
		expect.near(short[1].Position.X, 14)
		expect.near(graph:PathLength(Vector3.new(12, 0, 0), Vector3.new(60, 0, 0)) :: number, 48)
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

	["a labelled link puts its Action, Label and Instance on the step it leaves from"] = function(expect)
		local Graph = load()
		local door = { Name = "Door" }
		local nodes = square()
		nodes[2].Links = { 1, 3, { To = 5, Action = "Custom", Label = "Door", Instance = door } }
		local graph = Graph.new(nodes)

		local path = graph:FindPath(Vector3.new(0, 0, 0), Vector3.new(20, 0, 0), Fakes.Agent())
		local labels = {}
		for _, step in path do
			table.insert(labels, `{step.Position.X}:{step.Action}{if step.Label then ":" .. step.Label else ""}`)
		end
		expect.sequence(labels, { "0:Walk", "10:Custom:Door", "20:Walk", "20:Walk" })
		expect.equal(path[2].Instance, door)

		local back = graph:FindPath(Vector3.new(20, 0, 0), Vector3.new(0, 0, 0), Fakes.Agent())
		expect.equal(back[1].Label, nil, "the reverse link is a plain walk")

		expect.equal(Graph.LinkTarget(7), 7)
		expect.equal(Graph.LinkTarget({ To = 3 }), 3)
		expect.equal(#Graph.AStar(nodes, 1, 5), 3, "AStar reads labelled links")

		local message = expect.errors(function()
			Graph.new({ { Position = Vector3.new(), Links = { { To = 9 } } } })
		end)
		expect.includes(message, "links to node 9, which does not exist")
	end,

	["FromInstances reads Action and Label attributes and an Instance child off a Link"] = function(expect)
		local Graph = load()
		local doorPart = { Name = "DoorPart" }
		local nodes = {}
		local function node(name: string, x: number)
			local links = {}
			local instance = {
				Name = name,
				Position = Vector3.new(x, 1, 0),
				CFrame = CFrame.new(Vector3.new(x, 1, 0)),
				Size = Vector3.new(2, 2, 2),
				Links = links,
			}
			function instance.IsA(_self, className: string)
				return className == "BasePart"
			end
			function instance.GetChildren(_self)
				return links
			end
			function instance.GetFullName(_self)
				return `Workspace.NavGraph.{name}`
			end
			function instance.GetAttribute(_self, _attribute: string)
				return nil
			end
			function instance.GetAttributes(_self)
				return {}
			end
			table.insert(nodes, instance)
			return instance
		end
		local function linkValue(target, attributes: { [string]: any }?, doorTarget)
			local value = {
				Name = "Link",
				Value = target,
				Attributes = attributes or {},
			}
			function value.IsA(_self, className: string)
				return className == "ObjectValue"
			end
			function value.GetAttribute(self, attribute: string)
				return self.Attributes[attribute]
			end
			function value.FindFirstChild(_self, childName: string)
				if childName == "Instance" and doorTarget then
					return {
						Value = doorTarget,
						IsA = function(_self2, className: string)
							return className == "ObjectValue"
						end,
					}
				end
				return nil
			end
			function value.GetFullName(_self)
				return "Workspace.NavGraph.Link"
			end
			return value
		end

		local a = node("A", 0)
		local b = node("B", 10)
		local c = node("C", 20)
		table.insert(a.Links, linkValue(b))
		table.insert(b.Links, linkValue(c, { Action = "Custom", Label = "Door" }, doorPart))
		table.insert(c.Links, linkValue(b))
		local container = {
			GetChildren = function()
				return nodes
			end,
			GetFullName = function()
				return "Workspace.NavGraph"
			end,
		}

		local graph = Graph.FromInstances(container, { AutoLink = false })
		local built = graph:GetNodes()
		expect.equal(built[1].Position.Y, 0, "lowered to the bottom face")
		expect.equal(built[1].Links[1], 2, "a plain link is an index")
		expect.equal(built[2].Links[1].To, 3)
		expect.equal(built[2].Links[1].Label, "Door")
		expect.equal(built[2].Links[1].Action, "Custom")
		expect.equal(built[2].Links[1].Instance, doorPart)

		local path = graph:FindPath(Vector3.new(0, 0, 0), Vector3.new(20, 0, 0), Fakes.Agent())
		expect.equal(path[2].Label, "Door")
		expect.equal(path[2].Instance, doorPart)
	end,

	["Close shuts a link for a while so A* goes round, by Instance or by label at the node"] = function(expect)
		local clock = Harness.ManualClock(100)
		local Graph = Harness.Load("lib/Pathfinders/Graph.luau", { globals = { os = clock.os } })
		local door = { Name = "Door" }
		local nodes = square()
		-- 2 -> 3 is a door; the long way round is 2 -> 1 -> 4 -> 3.
		nodes[2].Links = { 1, { To = 3, Label = "Door", Instance = door }, 5 }
		local graph = Graph.new(nodes)

		local path = graph:FindPath(Vector3.new(10, 0, 0), Vector3.new(10, 0, 10), Fakes.Agent())
		expect.equal(#path, 3, "through the door: node 2, node 3, target")

		graph:Close({ Position = Vector3.new(10, 0, 0), Action = "Custom", Label = "Door", Instance = door }, 5)
		path = graph:FindPath(Vector3.new(10, 0, 0), Vector3.new(10, 0, 10), Fakes.Agent())
		expect.equal(#path, 5, "round the square: 2, 1, 4, 3, target")
		expect.truthy(graph:PathLength(Vector3.new(10, 0, 0), Vector3.new(10, 0, 10)) > 20, "PathLength honours it")

		clock:Advance(6)
		path = graph:FindPath(Vector3.new(10, 0, 0), Vector3.new(10, 0, 10), Fakes.Agent())
		expect.equal(#path, 3, "open again")

		graph:Close({ Position = Vector3.new(10, 0, 0), Action = "Custom", Label = "Door" }, 5)
		path = graph:FindPath(Vector3.new(10, 0, 0), Vector3.new(10, 0, 10), Fakes.Agent())
		expect.equal(#path, 5, "no Instance: matched by label at the node")

		expect.truthy(
			Graph.AStar(nodes, 2, 3, function(from, to)
				return from == 2 and to == 3
			end) :: any,
			"AStar takes a blocked predicate"
		)
	end,

	["FromInstances reads Instance attributes as links, and a labelled node labels every link into it"] = function(
		expect
	)
		local warnings = {}
		local Graph = Harness.Load("lib/Pathfinders/Graph.luau", {
			warn = function(message)
				table.insert(warnings, tostring(message))
			end,
		})
		local door = { Name = "Door" }
		local stray = {
			Name = "Stray",
			GetFullName = function()
				return "Workspace.Stray"
			end,
		}
		-- An Instance attribute reads back as a handle whose Get returns the instance.
		local function handle(target)
			return {
				Get = function()
					return target
				end,
			}
		end
		local nodes = {}
		local function node(name: string, x: number)
			local instance = {
				Name = name,
				Position = Vector3.new(x, 1, 0),
				CFrame = CFrame.new(Vector3.new(x, 1, 0)),
				Size = Vector3.new(2, 2, 2),
				Attributes = {} :: { [string]: any },
			}
			function instance.IsA(_self, className: string)
				return className == "BasePart"
			end
			function instance.GetChildren(_self)
				return {}
			end
			function instance.GetFullName(_self)
				return `Workspace.NavGraph.{name}`
			end
			function instance.GetAttribute(self, attribute: string)
				return self.Attributes[attribute]
			end
			function instance.GetAttributes(self)
				return self.Attributes
			end
			table.insert(nodes, instance)
			return instance
		end

		local a = node("A", 0)
		local doorway = node("Doorway", 8)
		local b = node("B", 16)
		a.Attributes.Link1 = handle(doorway)
		doorway.Attributes.West = handle(a)
		doorway.Attributes.East = handle(b)
		b.Attributes.Link1 = handle(doorway)
		b.Attributes.Oops = handle(stray)
		b.Attributes.Colour = "red"
		doorway.Attributes.Label = "Door"
		doorway.Attributes.Instance = handle(door)

		local container = {
			GetChildren = function()
				return nodes
			end,
			GetFullName = function()
				return "Workspace.NavGraph"
			end,
		}
		local graph = Graph.FromInstances(container, { AutoLink = false })
		local built = graph:GetNodes()

		expect.equal(#built[1].Links, 1)
		expect.equal(built[1].Links[1].To, 2, "A links into the doorway node")
		expect.equal(built[1].Links[1].Label, "Door", "the doorway's Label is on every link into it")
		expect.equal(built[1].Links[1].Action, "Custom")
		expect.equal(built[1].Links[1].Instance, door, "and its Instance attribute is the door")
		expect.equal(#built[2].Links, 2, "Label and Instance are the node's own, not links")
		for _, link in built[2].Links do
			expect.equal(type(link), "number", "links out of the doorway are plain")
		end
		expect.equal(#built[3].Links, 1, "a text attribute is not a link")
		expect.equal(#warnings, 1)
		expect.includes(warnings[1], "Oops")
		expect.includes(warnings[1], "Workspace.Stray")

		local path = graph:FindPath(Vector3.new(0, 0, 0), Vector3.new(16, 0, 0), Fakes.Agent())
		local labelled = nil
		for _, step in path do
			if step.Label == "Door" then
				labelled = step
			end
		end
		expect.truthy(labelled, "a route through the doorway carries a Door step")
		expect.equal(labelled.Instance, door)
		expect.equal(labelled.Position, Vector3.new(0, 0, 0), "on the node before the doorway")
	end,

	["Avoid keeps a route out of avoided nodes, and an avoided goal has no path"] = function(expect)
		local Graph = load()
		-- A square: 1-2-3 along the top, 1-4-3 along the bottom. Node 2 is in a safe room.
		local nodes = {
			{ Position = Vector3.new(0, 0, 0), Links = { 2, 4 } },
			{ Position = Vector3.new(10, 0, 0), Links = { 1, 3 } },
			{ Position = Vector3.new(20, 0, 0), Links = { 2, 4 } },
			{ Position = Vector3.new(10, 0, 30), Links = { 1, 3 } },
		}
		local function inRoom(position)
			return (position - Vector3.new(10, 0, 0)).Magnitude < 3
		end
		local graph = Graph.new(nodes, { Avoid = inRoom })

		local path = graph:FindPath(Vector3.new(0, 0, 0), Vector3.new(20, 0, 0), Fakes.Agent())
		for _, step in path do
			expect.falsy(inRoom(step.Position), "never through the safe room")
		end
		local detoured = false
		for _, step in path do
			if step.Position == Vector3.new(10, 0, 30) then
				detoured = true
			end
		end
		expect.truthy(detoured, "the long way round")

		local none, reason = graph:FindPath(Vector3.new(0, 0, 0), Vector3.new(10, 0, 1), Fakes.Agent())
		expect.equal(none, nil)
		expect.includes(reason, "avoided")
	end,
	["FromInstances with ResolveByName takes a link outside the container to the node of that name"] = function(expect)
		local warnings = {}
		local Graph = Harness.Load("lib/Pathfinders/Graph.luau", {
			warn = function(message)
				table.insert(warnings, tostring(message))
			end,
		})
		local function handle(target)
			return {
				Get = function()
					return target
				end,
			}
		end
		local function fake(name: string, x: number, parent: string)
			local instance = {
				Name = name,
				Position = Vector3.new(x, 1, 0),
				CFrame = CFrame.new(Vector3.new(x, 1, 0)),
				Size = Vector3.new(2, 2, 2),
				Attributes = {} :: { [string]: any },
				Children = {} :: { any },
			}
			function instance.IsA(_self, className: string)
				return className == "BasePart"
			end
			function instance.GetChildren(self)
				return self.Children
			end
			function instance.GetFullName(_self)
				return `{parent}.{name}`
			end
			function instance.GetAttribute(self, attribute: string)
				return self.Attributes[attribute]
			end
			function instance.GetAttributes(self)
				return self.Attributes
			end
			return instance
		end

		-- The published original, detached: what a package copy's attributes still point at.
		local originalC2 = fake("C2", 8, "LaundromatPackage")
		local originalTwin = fake("Twin", 16, "LaundromatPackage")
		local c1 = fake("C1", 0, "Workspace.Copy")
		local c2 = fake("C2", 8, "Workspace.Copy")
		local twinA = fake("Twin", 16, "Workspace.Copy")
		local twinB = fake("Twin", 24, "Workspace.Copy")
		c1.Attributes.Link1 = handle(originalC2)
		c1.Attributes.Link2 = handle(originalTwin)
		local value = {
			Name = "Link",
			Value = originalC2,
			IsA = function(_self, className: string)
				return className == "ObjectValue"
			end,
			GetAttribute = function()
				return nil
			end,
			FindFirstChild = function()
				return nil
			end,
			GetFullName = function()
				return "Workspace.Copy.Twin.Link"
			end,
		}
		table.insert(twinA.Children, value)

		local nodes = { c1, c2, twinA, twinB }
		local container = {
			GetChildren = function()
				return nodes
			end,
			GetFullName = function()
				return "Workspace.Copy"
			end,
		}

		local strict = Graph.FromInstances(container, { AutoLink = false }):GetNodes()
		expect.equal(#strict[1].Links, 0, "without the option a link outside the container is skipped")
		expect.equal(#warnings, 3)

		table.clear(warnings)
		local built = Graph.FromInstances(container, { AutoLink = false, ResolveByName = true }):GetNodes()
		expect.equal(#built[1].Links, 1, "the shared name Twin is not resolved")
		expect.equal(built[1].Links[1], 2, "the Instance attribute reaches the copy's own C2")
		expect.equal(built[3].Links[1], 2, "so does a Link ObjectValue")
		expect.equal(#warnings, 1)
		expect.includes(warnings[1], "more than one node")
	end,
}
