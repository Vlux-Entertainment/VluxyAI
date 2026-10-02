--!strict

--[[
	Builds the playground: a maze carved by recursive backtracking on a grid of cells, then a
	second pass that removes a fraction of the remaining interior walls so the maze has loops and
	the pathfinders have real choices. Reproducible from a seed, from a fresh `rojo build`, with
	no Studio-authored parts.

	Cells are 16 studs wide with 1-stud walls between them, so there is room to move and to be
	seen. There is no floor part and no border: the place's baseplate at y = 0 is the floor, and
	the maze stands on it. Every position the map hands out is at floor height.

	Three cells are safe rooms: the player's spawn and two far corners. Each is one part tagged
	VLUXYAI_SAFE filling the cell, green and see-through, with a glowing floor, a sign and a switch on
	the wall; VluxyAI.SafeAreas keeps every enemy out while it is on. Enemies, patrol points and
	the noise pad are never placed in one.

	A few standing walls get a doorway: a door part tagged VLUXYAI_DOOR with a PassThrough
	PathfindingModifier (off while locked), inside an invisible zone labelled "Door" so a
	waypoint always lands in the doorway. Doors are picked with their own Random, so adding them moved nothing else.
]]

local CELL = 16
local WALL = 1
local WALL_HEIGHT = 6
local FLOOR_TOP = 0
local ORIGIN = Vector3.new(0, 0, 0)

local DEFAULT_OPTIONS = {
	Seed = 7,
	Columns = 12,
	Rows = 9,
	-- Fraction of the interior walls left by the maze that the second pass removes.
	Openness = 0.3,
	-- Standing walls that get a door, and how many of those start locked.
	Doors = 6,
	LockedDoors = 1,
}

local SAFE_COLOR = Color3.fromRGB(70, 220, 120) -- green, drawn half see-through
local NODE_SIZE = 1.2
local NODE_COLOR = Color3.fromRGB(170, 90, 255) -- purple, drawn half see-through
local DOOR_WIDTH = 6 -- wide enough for a navmesh agent of radius 2
local DOOR_ZONE_DEPTH = 4

export type MapOptions = {
	Seed: number?,
	Columns: number?,
	Rows: number?,
	Openness: number?,
	Doors: number?,
	LockedDoors: number?,
}

export type BuiltMap = {
	Folder: Folder,
	Seed: number,
	Spawns: { [string]: Vector3 },
	PatrolNodes: { Vector3 },
	NoisePads: { BasePart },
	-- The safe rooms' zone parts (tagged VLUXYAI_SAFE), each with a SafeSwitch part beside it.
	SafeRooms: { SafeRoom },
	Doors: { BasePart },
	-- The A* node map as parts, for VluxyAI's Graph.FromInstances: nodes linked by Instance
	-- attributes, doorway nodes labelled "Door".
	NavGraph: Folder,
	-- Every cell centre, for anything that wants open floor to stand on.
	CellCentres: { Vector3 },
	PlayerSpawn: SpawnLocation,
	Bounds: { Min: Vector3, Max: Vector3 },
}

type Cell = { Column: number, Row: number }

export type SafeRoom = { Zone: BasePart, Floor: BasePart, Switch: BasePart, Sign: TextLabel }

local Map = {}

------------------------------------------------------------------------------------------------------------------------

local function cellCenter(column: number, row: number): Vector3
	return ORIGIN + Vector3.new((column - 0.5) * CELL, FLOOR_TOP, (row - 0.5) * CELL)
end

local function makePart(name: string, size: Vector3, position: Vector3, color: Color3, parent: Instance): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Position = position
	part.Color = color
	part.Anchored = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent

	return part
end

--[[
	A doorway in place of a wall: two wall segments, the door between them, and an invisible zone
	across the doorway that labels its waypoints "Door". `along` is the axis the wall runs along.
]]
local function makeDoorway(center: Vector3, along: Vector3, locked: boolean, color: Color3, parent: Instance): Part
	local across = Vector3.new(along.Z, 0, along.X)
	local length = CELL + WALL
	local segment = (length - DOOR_WIDTH) / 2
	local function sized(alongSize: number, acrossSize: number, height: number): Vector3
		return along * alongSize + across * acrossSize + Vector3.new(0, height, 0)
	end

	local offset = DOOR_WIDTH / 2 + segment / 2
	makePart("Wall", sized(segment, WALL, WALL_HEIGHT), center + along * offset, color, parent)
	makePart("Wall", sized(segment, WALL, WALL_HEIGHT), center - along * offset, color, parent)

	local door = makePart(
		"Door",
		sized(DOOR_WIDTH, WALL * 0.6, WALL_HEIGHT - 0.5),
		center - Vector3.new(0, 0.25, 0),
		if locked then Color3.fromRGB(150, 40, 40) else Color3.fromRGB(150, 100, 60),
		parent
	)
	door.Material = Enum.Material.Wood
	door:SetAttribute("VLUXYAI_DOOR/Open", false)
	door:SetAttribute("VLUXYAI_DOOR/Locked", locked)
	door:SetAttribute("VLUXYAI_DOOR/OpenTime", 0.4)
	game:GetService("CollectionService"):AddTag(door, "VLUXYAI_DOOR")

	-- The only thing that says whether an enemy may go through: passable while unlocked, a wall
	-- while locked (DoorScript keeps it in step with the attribute). No label, because the door
	-- swings and a label would move with it; the zone below does the labelling.
	local passThrough = Instance.new("PathfindingModifier")
	passThrough.PassThrough = not locked
	passThrough.Parent = door

	local zone =
		makePart("DoorZone", sized(DOOR_WIDTH, DOOR_ZONE_DEPTH, WALL_HEIGHT), center, Color3.new(1, 1, 1), parent)
	zone.Transparency = 1
	zone.CanCollide = false
	zone.CanQuery = false
	zone.CanTouch = false
	local label = Instance.new("PathfindingModifier")
	label.Label = "Door"
	label.Parent = zone

	return door
end

--[[
	A safe room filling the cell at `center`: the zone part tagged VLUXYAI_SAFE (green, see-through,
	reaching half a stud under the floor so a floor position inside counts), a glowing floor, a
	"SAFE ROOM" sign above and a switch on one side. The zone never blocks a ray; VluxyAI's
	SafeAreas makes it solid to enemy rigs only.
]]
local function makeSafeRoom(center: Vector3, parent: Instance): SafeRoom
	local inner = CELL - WALL - 0.2
	local zone = makePart(
		"SafeRoom",
		Vector3.new(inner, WALL_HEIGHT + 1, inner),
		center + Vector3.new(0, (WALL_HEIGHT + 1) / 2 - 0.5, 0),
		SAFE_COLOR,
		parent
	)
	zone.Transparency = 0.8
	zone.Material = Enum.Material.SmoothPlastic
	zone.CanQuery = false
	zone.CanTouch = false
	zone.CastShadow = false
	zone:SetAttribute("VLUXYAI_SAFE/Enabled", true)
	game:GetService("CollectionService"):AddTag(zone, "VLUXYAI_SAFE")

	local floor =
		makePart("SafeFloor", Vector3.new(inner, 0.1, inner), center + Vector3.new(0, 0.05, 0), SAFE_COLOR, parent)
	floor.Material = Enum.Material.Neon
	floor.Transparency = 0.5
	floor.CanCollide = false
	floor.CanQuery = false
	floor.CanTouch = false

	local sign = Instance.new("BillboardGui")
	sign.Size = UDim2.fromOffset(180, 44)
	sign.StudsOffsetWorldSpace = Vector3.new(0, WALL_HEIGHT + 2, 0)
	sign.MaxDistance = 90
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.TextScaled = true
	label.Font = Enum.Font.GothamBold
	label.TextColor3 = SAFE_COLOR
	label.TextStrokeTransparency = 0.4
	label.Text = "SAFE ROOM"
	label.Parent = sign
	sign.Parent = zone

	local switch =
		makePart("SafeSwitch", Vector3.new(1, 1.4, 1), center + Vector3.new(inner / 2 - 1, 3, 0), SAFE_COLOR, parent)
	switch.Material = Enum.Material.Neon
	switch.CanCollide = false

	return { Zone = zone, Floor = floor, Switch = switch, Sign = label }
end

--[[
	Carves passages through every cell with a depth-first walk that backtracks when it runs out
	of unvisited neighbours. Returns which walls are still standing: `east[row][column]` between a
	cell and the one to its right, `south[row][column]` between a cell and the one below.
]]
local function carve(columns: number, rows: number, random: Random): ({ { boolean } }, { { boolean } })
	local east: { { boolean } } = {}
	local south: { { boolean } } = {}
	local visited: { { boolean } } = {}
	for row = 1, rows do
		east[row] = {}
		south[row] = {}
		visited[row] = {}
		for column = 1, columns do
			east[row][column] = true
			south[row][column] = true
			visited[row][column] = false
		end
	end

	local stack: { Cell } = { { Column = 1, Row = 1 } }
	visited[1][1] = true

	while #stack > 0 do
		local current = stack[#stack]
		local neighbours: { { Cell: Cell, Open: () -> () } } = {}

		local column, row = current.Column, current.Row
		if column > 1 and not visited[row][column - 1] then
			table.insert(neighbours, {
				Cell = { Column = column - 1, Row = row },
				Open = function()
					east[row][column - 1] = false
				end,
			})
		end
		if column < columns and not visited[row][column + 1] then
			table.insert(neighbours, {
				Cell = { Column = column + 1, Row = row },
				Open = function()
					east[row][column] = false
				end,
			})
		end
		if row > 1 and not visited[row - 1][column] then
			table.insert(neighbours, {
				Cell = { Column = column, Row = row - 1 },
				Open = function()
					south[row - 1][column] = false
				end,
			})
		end
		if row < rows and not visited[row + 1][column] then
			table.insert(neighbours, {
				Cell = { Column = column, Row = row + 1 },
				Open = function()
					south[row][column] = false
				end,
			})
		end

		if #neighbours == 0 then
			table.remove(stack)
			continue
		end

		local choice = neighbours[random:NextInteger(1, #neighbours)]
		choice.Open()
		visited[choice.Cell.Row][choice.Cell.Column] = true
		table.insert(stack, choice.Cell)
	end

	return east, south
end

--[[
	The second pass: knocks out a fraction of the walls the maze left, so there are loops and
	more than one way round.
]]
local function open(
	east: { { boolean } },
	south: { { boolean } },
	columns: number,
	rows: number,
	openness: number,
	random: Random
)
	for row = 1, rows do
		for column = 1, columns do
			if column < columns and east[row][column] and random:NextNumber() < openness then
				east[row][column] = false
			end
			if row < rows and south[row][column] and random:NextNumber() < openness then
				south[row][column] = false
			end
		end
	end
end

--[[
	Picks `count` cells at least `spacing` cells apart from each other and from `avoid`, from a
	shuffled list, so the enemies start spread out. Falls back to any cell if the maze is too
	small to satisfy the spacing.
]]
local function pickSpread(
	columns: number,
	rows: number,
	count: number,
	spacing: number,
	avoid: { Cell },
	random: Random
): { Cell }
	local cells: { Cell } = {}
	for row = 1, rows do
		for column = 1, columns do
			table.insert(cells, { Column = column, Row = row })
		end
	end
	for index = #cells, 2, -1 do
		local swap = random:NextInteger(1, index)
		cells[index], cells[swap] = cells[swap], cells[index]
	end

	local chosen: { Cell } = {}
	local taken = table.clone(avoid)

	local function farEnough(cell: Cell): boolean
		for _, other in taken do
			if math.abs(other.Column - cell.Column) + math.abs(other.Row - cell.Row) < spacing then
				return false
			end
		end
		return true
	end

	for _, cell in cells do
		if #chosen >= count then
			break
		end
		if farEnough(cell) then
			table.insert(chosen, cell)
			table.insert(taken, cell)
		end
	end
	for _, cell in cells do
		if #chosen >= count then
			break
		end
		if not table.find(taken, cell) then
			table.insert(chosen, cell)
			table.insert(taken, cell)
		end
	end

	return chosen
end

------------------------------------------------------------------------------------------------------------------------

--[[
	The maze as data, for tests and for anything that wants the layout without the parts: the
	backtracking carve, then the opening pass. `east[row][column]` is true where a wall stands
	between a cell and the one to its right, `south[row][column]` between a cell and the one below.
]]
function Map.Carve(columns: number, rows: number, random: Random, openness: number): ({ { boolean } }, { { boolean } })
	local east, south = carve(columns, rows, random)
	open(east, south, columns, rows, openness, random)
	return east, south
end

--[[
	Builds the map under a `Playground` folder in `parent` and returns where everything is.
]]
function Map.Build(parent: Instance, options: MapOptions?): BuiltMap
	local resolved = table.clone(DEFAULT_OPTIONS)
	for key, value in (options or {}) :: { [string]: any } do
		(resolved :: any)[key] = value
	end

	local columns, rows = resolved.Columns, resolved.Rows
	local random = Random.new(resolved.Seed)

	local east, south = Map.Carve(columns, rows, random, resolved.Openness)

	local folder = Instance.new("Folder")
	folder.Name = "Playground"

	local width = columns * CELL
	local depth = rows * CELL
	local wallColor = Color3.fromRGB(120, 120, 130)

	local wallY = FLOOR_TOP + WALL_HEIGHT / 2

	-- Which standing walls become doorways, from a Random of their own.
	local standing: { string } = {}
	for row = 1, rows do
		for column = 1, columns do
			if column < columns and east[row][column] then
				table.insert(standing, `e{row}:{column}`)
			end
			if row < rows and south[row][column] then
				table.insert(standing, `s{row}:{column}`)
			end
		end
	end
	local doorRandom = Random.new(resolved.Seed + 1)
	local doorways: { [string]: boolean } = {}
	for index = 1, math.min(resolved.Doors, #standing) do
		local pick = doorRandom:NextInteger(index, #standing)
		standing[index], standing[pick] = standing[pick], standing[index]
		doorways[standing[index]] = index <= resolved.LockedDoors
	end

	local doors: { BasePart } = {}
	local doorAt: { [string]: BasePart } = {}

	-- Interior walls still standing after both passes.
	for row = 1, rows do
		for column = 1, columns do
			if column < columns and east[row][column] then
				local center = ORIGIN + Vector3.new(column * CELL, wallY, (row - 0.5) * CELL)
				local locked = doorways[`e{row}:{column}`]
				if locked ~= nil then
					local door = makeDoorway(center, Vector3.zAxis, locked, wallColor, folder)
					table.insert(doors, door)
					doorAt[`e{row}:{column}`] = door
				else
					makePart("Wall", Vector3.new(WALL, WALL_HEIGHT, CELL + WALL), center, wallColor, folder)
				end
			end
			if row < rows and south[row][column] then
				local center = ORIGIN + Vector3.new((column - 0.5) * CELL, wallY, row * CELL)
				local locked = doorways[`s{row}:{column}`]
				if locked ~= nil then
					local door = makeDoorway(center, Vector3.xAxis, locked, wallColor, folder)
					table.insert(doors, door)
					doorAt[`s{row}:{column}`] = door
				else
					makePart("Wall", Vector3.new(CELL + WALL, WALL_HEIGHT, WALL), center, wallColor, folder)
				end
			end
		end
	end

	-- The A* node map, as parts a level designer could have placed by hand: a node at every cell
	-- centre, linked to each open neighbour by an Instance attribute, and a node in every unlocked
	-- doorway labelled "Door" whose Instance attribute is the door, so a route through it carries a
	-- Door step. A door locked when the map is built gets no doorway node; one locked later is
	-- refused and closed on the graph for a while. VluxyAI's Graph.FromInstances reads it back.
	local navGraph = Instance.new("Folder")
	navGraph.Name = "NavGraph"
	navGraph.Parent = folder

	local cellNodes: { { BasePart } } = {}
	local cellCentres: { Vector3 } = {}
	local function makeNode(name: string, floor: Vector3): BasePart
		local node =
			makePart(name, Vector3.one * NODE_SIZE, floor + Vector3.new(0, NODE_SIZE / 2, 0), NODE_COLOR, navGraph)
		node.Shape = Enum.PartType.Ball
		node.Material = Enum.Material.Neon
		node.Transparency = 0.5
		node.CanCollide = false
		node.CanQuery = false
		node.CanTouch = false
		node.CastShadow = false
		return node
	end
	for row = 1, rows do
		cellNodes[row] = {}
		for column = 1, columns do
			cellNodes[row][column] = makeNode(`Cell_{row}_{column}`, cellCenter(column, row))
			table.insert(cellCentres, cellCenter(column, row))
		end
	end

	local function link(from: BasePart, to: BasePart)
		local count = 1
		while from:GetAttribute(`Link{count}`) ~= nil do
			count += 1
		end
		from:SetAttribute(`Link{count}`, to)
	end
	local function join(a: BasePart, b: BasePart, wallKey: string, walled: boolean)
		if not walled then
			link(a, b)
			link(b, a)
			return
		end
		local door: BasePart? = doorAt[wallKey]
		if not door or doorways[wallKey] == true then
			return
		end
		local doorway = makeNode(`Doorway_{wallKey}`, (a.Position + b.Position) / 2 - Vector3.new(0, NODE_SIZE / 2, 0))
		doorway:SetAttribute("Label", "Door")
		doorway:SetAttribute("Instance", door)
		link(a, doorway)
		link(doorway, a)
		link(b, doorway)
		link(doorway, b)
	end
	for row = 1, rows do
		for column = 1, columns do
			if column < columns then
				join(cellNodes[row][column], cellNodes[row][column + 1], `e{row}:{column}`, east[row][column])
			end
			if row < rows then
				join(cellNodes[row][column], cellNodes[row + 1][column], `s{row}:{column}`, south[row][column])
			end
		end
	end

	-- Placements: the player in the first cell, the four enemies spread out, a patrol node per
	-- quadrant, the noise pad somewhere near the middle.
	local playerCell: Cell = { Column = 1, Row = 1 }
	local safeCells: { Cell } = { playerCell, { Column = columns, Row = rows }, { Column = columns, Row = 1 } }
	local function isSafe(column: number, row: number): boolean
		for _, cell in safeCells do
			if cell.Column == column and cell.Row == row then
				return true
			end
		end
		return false
	end

	local safeRooms: { SafeRoom } = {}
	for _, cell in safeCells do
		table.insert(safeRooms, makeSafeRoom(cellCenter(cell.Column, cell.Row), folder))
	end

	local enemyCells = pickSpread(columns, rows, 4, 4, safeCells, random)

	local spawns: { [string]: Vector3 } = {}
	for index, cell in enemyCells do
		spawns[tostring(index)] = cellCenter(cell.Column, cell.Row)
	end

	local patrolNodes: { Vector3 } = {}
	local halfColumns = math.max(1, math.floor(columns / 2))
	local halfRows = math.max(1, math.floor(rows / 2))
	local quadrants = {
		{ 1, halfColumns, 1, halfRows },
		{ halfColumns + 1, columns, 1, halfRows },
		{ halfColumns + 1, columns, halfRows + 1, rows },
		{ 1, halfColumns, halfRows + 1, rows },
	}
	for index, quadrant in quadrants do
		local column = random:NextInteger(quadrant[1], math.max(quadrant[1], quadrant[2]))
		local row = random:NextInteger(quadrant[3], math.max(quadrant[3], quadrant[4]))
		for _ = 1, 20 do
			if not isSafe(column, row) then
				break
			end
			column = random:NextInteger(quadrant[1], math.max(quadrant[1], quadrant[2]))
			row = random:NextInteger(quadrant[3], math.max(quadrant[3], quadrant[4]))
		end
		local node = cellCenter(column, row)
		table.insert(patrolNodes, node)

		local marker = makePart(
			`Patrol{string.char(64 + index)}`,
			Vector3.new(1.5, 0.2, 1.5),
			node + Vector3.new(0, 0.1, 0),
			Color3.fromRGB(240, 220, 80),
			folder
		)
		marker.CanCollide = false
		marker.CanQuery = false
	end

	local padCell: Cell = {
		Column = random:NextInteger(math.max(1, halfColumns - 1), math.min(columns, halfColumns + 2)),
		Row = random:NextInteger(math.max(1, halfRows - 1), math.min(rows, halfRows + 2)),
	}
	local padCenter = cellCenter(padCell.Column, padCell.Row)
	local pad = makePart(
		"NoisePad",
		Vector3.new(CELL - 2, 0.2, CELL - 2),
		padCenter + Vector3.new(0, 0.1, 0),
		Color3.fromRGB(230, 120, 40),
		folder
	)
	pad.Material = Enum.Material.Neon

	local playerCenter = cellCenter(playerCell.Column, playerCell.Row)
	local playerSpawn = Instance.new("SpawnLocation")
	playerSpawn.Name = "PlayerSpawn"
	playerSpawn.Size = Vector3.new(CELL - 2, 0.2, CELL - 2)
	playerSpawn.Position = playerCenter + Vector3.new(0, 0.1, 0)
	playerSpawn.Anchored = true
	playerSpawn.Color = Color3.fromRGB(60, 160, 220)
	playerSpawn.Duration = 0
	playerSpawn.Parent = folder

	folder.Parent = parent

	return {
		Folder = folder,
		Seed = resolved.Seed,
		Spawns = spawns,
		PatrolNodes = patrolNodes,
		NoisePads = { pad },
		SafeRooms = safeRooms,
		Doors = doors,
		NavGraph = navGraph,
		CellCentres = cellCentres,
		PlayerSpawn = playerSpawn,
		Bounds = {
			Min = ORIGIN + Vector3.new(WALL, FLOOR_TOP, WALL),
			Max = ORIGIN + Vector3.new(width - WALL, FLOOR_TOP, depth - WALL),
		},
	}
end

--[[
	A random point on the floor. It may land inside a wall; the navmesh says no and the caller
	picks again, which is a useful thing for an example to show.
]]
function Map.RandomPoint(map: BuiltMap, random: Random): Vector3
	return Vector3.new(
		random:NextNumber(map.Bounds.Min.X, map.Bounds.Max.X),
		FLOOR_TOP,
		random:NextNumber(map.Bounds.Min.Z, map.Bounds.Max.Z)
	)
end

return Map
