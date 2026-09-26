--!strict

--[[
	Draws a Graph's nodes as balls and its links as thin bars, so the authored (or generated)
	node map can be checked by eye. Opt-in debug, like PathVisual, and in the same shared
	`VluxyAI_Debug` folder in Workspace.

	The one decision: every part is non-colliding and non-queryable, so the view never blocks a
	sight ray, a straight-line check or a navmesh bake it is meant to explain. A link drawn both
	ways is drawn once; `Edges` is the pure helper that works that out.
]]

local Cleaner = require(script.Parent.Parent.Utility.Cleaner)
local Options = require(script.Parent.Parent.Utility.Options)

------------------------------------------------------------------------------------------------------------------------

local FOLDER_NAME = "VluxyAI_Debug"

local DEFAULT_OPTIONS = table.freeze({
	Color = Color3.fromRGB(170, 90, 255),
	Transparency = 0.5,
	NodeSize = 1.2,
	LinkThickness = 0.2,
	Nodes = true,
	Links = true,
	Height = 0.6,
})

type ResolvedOptions = {
	Color: Color3,
	Transparency: number,
	NodeSize: number,
	LinkThickness: number,
	Nodes: boolean,
	Links: boolean,
	Height: number,
}

--[=[
	@interface GraphVisualOptions
	@within GraphVisual

	.Color Color3? -- Colour of the nodes and links. Default purple.
	.Transparency number? -- Default `0.5`.
	.NodeSize number? -- Diameter of a node ball in studs. Default `1.2`.
	.LinkThickness number? -- Width of a link bar in studs. Default `0.2`.
	.Nodes boolean? -- Draw the nodes. Turn it off when the nodes are visible parts already. Default `true`.
	.Links boolean? -- Draw the links. Default `true`.
	.Height number? -- Studs above each node's floor position to draw at. Default `0.6`.
]=]
export type GraphVisualOptions = {
	Color: Color3?,
	Transparency: number?,
	NodeSize: number?,
	LinkThickness: number?,
	Nodes: boolean?,
	Links: boolean?,
	Height: number?,
}

--[=[
	@interface GraphEdge
	@within GraphVisual

	.From number -- The lower node index.
	.To number -- The higher node index.
	.Label string? -- The link's label, when either direction has one (a door).
]=]
export type GraphEdge = {
	From: number,
	To: number,
	Label: string?,
}

type Node = { Position: Vector3, Links: { any } }

type self = {
	_cleaner: Cleaner.Cleaner,
}

local GraphVisual = {}
GraphVisual.__index = GraphVisual

export type GraphVisual = typeof(setmetatable({} :: self, GraphVisual))

--[=[
	@class GraphVisual

	Debug view of a [Graph]: a ball per node and a bar per link, purple and see-through by
	default. Pass the graph itself or its node list.

	```lua
	local graph = VluxyAI.Pathfinders.Graph.new(nodes)
	VluxyAI.Debug.GraphVisual.new(graph)
	```
]=]

--[[
	The shared debug folder, made once.
]]
local function debugFolder(): Folder
	local Workspace = game:GetService("Workspace")
	local existing = Workspace:FindFirstChild(FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
	folder.Parent = Workspace
	return folder
end

--[=[
	@within GraphVisual
	@param nodes { GraphNode }
	@return { GraphEdge } -- Each connected pair once, lower index first, in node order.

	The undirected edges of a directed node list: a link from 3 to 7 and one from 7 to 3 are one
	edge. A label on either direction is kept. Pure.
]=]
function GraphVisual.Edges(nodes: { Node }): { GraphEdge }
	local edges: { GraphEdge } = {}
	local seen: { [string]: GraphEdge } = {}

	for from, node in nodes do
		for _, link in node.Links do
			local to = if type(link) == "number" then link else link.To
			local label = if type(link) == "table" then link.Label else nil
			local low, high = math.min(from, to), math.max(from, to)
			local key = `{low}:{high}`
			local edge = seen[key]
			if edge == nil then
				edge = { From = low, To = high, Label = label }
				seen[key] = edge
				table.insert(edges, edge)
			elseif edge.Label == nil then
				edge.Label = label
			end
		end
	end

	return edges
end

--[[
	A non-colliding, non-queryable debug part.
]]
local function makePart(
	name: string,
	shape: Enum.PartType,
	size: Vector3,
	cframe: CFrame,
	options: ResolvedOptions
): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Shape = shape
	part.Size = size
	part.CFrame = cframe
	part.Color = options.Color
	part.Transparency = options.Transparency
	part.Material = Enum.Material.Neon
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	return part
end

--[=[
	@within GraphVisual
	@param graph Pathfinder | { GraphNode } -- A [Graph] (anything with `GetNodes`) or the node list itself.
	@param options GraphVisualOptions?
	@return GraphVisual
	@error "unknown option" -- A key that is not in `GraphVisualOptions`.

	Draws the graph once. The nodes of a [Graph] do not move, so there is nothing to redraw;
	destroy it and make another after changing the node list.
]=]
function GraphVisual.new(graph: any, options: GraphVisualOptions?): GraphVisual
	local resolved = Options.Resolve("GraphVisual.new", DEFAULT_OPTIONS, options :: any) :: ResolvedOptions
	local nodes: { Node } = if type(graph) == "table" and type(graph.GetNodes) == "function"
		then graph:GetNodes()
		else graph

	local cleaner = Cleaner.new()
	local model = Instance.new("Model")
	model.Name = "Graph"
	cleaner:Add(model)

	local lift = Vector3.new(0, resolved.Height, 0)
	if resolved.Nodes then
		for index, node in nodes do
			local size = Vector3.one * resolved.NodeSize
			makePart(`Node{index}`, Enum.PartType.Ball, size, CFrame.new(node.Position + lift), resolved).Parent = model
		end
	end

	if resolved.Links then
		for _, edge in GraphVisual.Edges(nodes) do
			local a = nodes[edge.From].Position + lift
			local b = nodes[edge.To].Position + lift
			local length = (b - a).Magnitude
			if length > 1e-3 then
				local size = Vector3.new(resolved.LinkThickness, resolved.LinkThickness, length)
				local name = if edge.Label
					then `Link{edge.From}_{edge.To}_{edge.Label}`
					else `Link{edge.From}_{edge.To}`
				makePart(name, Enum.PartType.Block, size, CFrame.lookAt((a + b) / 2, b), resolved).Parent = model
			end
		end
	end

	model.Parent = debugFolder()

	local self: self = { _cleaner = cleaner }
	return setmetatable(self, GraphVisual)
end

--[=[
	@within GraphVisual

	Removes the drawing.
]=]
function GraphVisual.Destroy(self: GraphVisual)
	self._cleaner:Destroy()
end

return GraphVisual
