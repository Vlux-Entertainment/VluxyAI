--!strict

--[[
	Builds the playground: a maze carved by recursive backtracking on a grid of cells, then a
	second pass that removes a fraction of the remaining interior walls so the maze has loops and
	the pathfinders have real choices. Reproducible from a seed, from a fresh `rojo build`, with
	no Studio-authored parts.

	Cells are 16 studs wide with 1-stud walls between them, so there is room to move and to be
	seen. There is no floor part and no border: the place's baseplate at y = 0 is the floor, and
	the maze stands on it. Every position the map hands out is at floor height.
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
}

export type MapOptions = {
	Seed: number?,
	Columns: number?,
	Rows: number?,
	Openness: number?,
}

export type BuiltMap = {
	Folder: Folder,
	Seed: number,
	Spawns: { [string]: Vector3 },
	PatrolNodes: { Vector3 },
	NoisePads: { BasePart },
	PlayerSpawn: SpawnLocation,
	Bounds: { Min: Vector3, Max: Vector3 },
}

type Cell = { Column: number, Row: number }

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

	-- Interior walls still standing after both passes.
	for row = 1, rows do
		for column = 1, columns do
			if column < columns and east[row][column] then
				makePart(
					"Wall",
					Vector3.new(WALL, WALL_HEIGHT, CELL + WALL),
					ORIGIN + Vector3.new(column * CELL, wallY, (row - 0.5) * CELL),
					wallColor,
					folder
				)
			end
			if row < rows and south[row][column] then
				makePart(
					"Wall",
					Vector3.new(CELL + WALL, WALL_HEIGHT, WALL),
					ORIGIN + Vector3.new((column - 0.5) * CELL, wallY, row * CELL),
					wallColor,
					folder
				)
			end
		end
	end

	-- Placements: the player in the first cell, the four enemies spread out, a patrol node per
	-- quadrant, the noise pad somewhere near the middle.
	local playerCell: Cell = { Column = 1, Row = 1 }
	local enemyCells = pickSpread(columns, rows, 4, 4, { playerCell }, random)

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
