--!strict

--[[
	GraphVisual's pure part: turning a directed node list into the edges to draw. The drawing
	itself is play-tested.
]]

local Harness = require("../Support/Harness")

local roblox = require("@lune/roblox")
local Vector3 = roblox.Vector3

local function load()
	return Harness.Load("lib/Debug/GraphVisual.luau")
end

local function node(x: number, links: { any })
	return { Position = Vector3.new(x, 0, 0), Links = links }
end

return {
	["a link drawn both ways is one edge, lower index first"] = function(expect)
		local GraphVisual = load()
		local edges = GraphVisual.Edges({ node(0, { 2 }), node(16, { 1, 3 }), node(32, { 2 }) })
		expect.equal(#edges, 2)
		expect.equal(edges[1].From, 1)
		expect.equal(edges[1].To, 2)
		expect.equal(edges[2].From, 2)
		expect.equal(edges[2].To, 3)
	end,

	["a one-way link is still drawn, and a label on either direction is kept"] = function(expect)
		local GraphVisual = load()
		local door = { Name = "Door" }
		local edges = GraphVisual.Edges({
			node(0, { 2 }),
			node(16, { { To = 1, Label = "Door", Instance = door }, 3 }),
			node(32, {}),
		})
		expect.equal(#edges, 2)
		expect.equal(edges[1].Label, "Door", "the label came from the reverse direction")
		expect.equal(edges[2].From, 2)
		expect.equal(edges[2].To, 3)
		expect.equal(edges[2].Label, nil)
	end,

	["no links, no edges"] = function(expect)
		local GraphVisual = load()
		expect.equal(#GraphVisual.Edges({ node(0, {}) }), 0)
		expect.equal(#GraphVisual.Edges({}), 0)
	end,
}
