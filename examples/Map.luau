--!strict

--[[
	Builds the playground from an ASCII grid so the test map is reproducible from a fresh
	`rojo build` with no Studio-authored parts. One character is one 4-stud cell.

	  #  wall            .  open floor
	  S  player spawn    N  noise pad (touching it makes a loud noise)
	  1-6 enemy spawns   A-D patrol nodes, walked in letter order
]]

local CELL = 4
local WALL_HEIGHT = 12
local ORIGIN = Vector3.new(0, 0, 0)

local GRID = {
	"##############################",
	"#............#...............#",
	"#..1.........#....A......B...#",
	"#............#...............#",
	"#.....####...#####.....#######",
	"#.....#..........#...........#",
	"#..S..#..........#.....2.....#",
	"#.....#....N.....#...........#",
	"#.....####.......###....######",
	"#................#...........#",
	"#.........3......#...........#",
	"#................#......6....#",
	"######....########...........#",
	"#................#####..######",
	"#...D............#...........#",
	"#........4.......#.....5.....#",
	"#................#...........#",
	"#....C...........#...........#",
	"##############################",
}

export type BuiltMap = {
	Folder: Folder,
	Floor: BasePart,
	Spawns: { [string]: Vector3 },
	PatrolNodes: { Vector3 },
	NoisePads: { BasePart },
	PlayerSpawn: SpawnLocation,
	Bounds: { Min: Vector3, Max: Vector3 },
}

local Map = {}

local function cellCenter(column: number, row: number): Vector3
	return ORIGIN + Vector3.new((column - 0.5) * CELL, 0, (row - 0.5) * CELL)
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
	Builds the map under a `Playground` folder in `parent` and returns where everything is.
]]
function Map.Build(parent: Instance): BuiltMap
	local folder = Instance.new("Folder")
	folder.Name = "Playground"

	local rows = #GRID
	local columns = #GRID[1]
	local width = columns * CELL
	local depth = rows * CELL

	local floor = makePart(
		"Floor",
		Vector3.new(width, 1, depth),
		ORIGIN + Vector3.new(width / 2, -0.5, depth / 2),
		Color3.fromRGB(70, 70, 75),
		folder
	)
	floor.Material = Enum.Material.Concrete

	local spawns: { [string]: Vector3 } = {}
	local patrolByLetter: { [string]: Vector3 } = {}
	local noisePads: { BasePart } = {}
	local playerSpawn: SpawnLocation? = nil

	for row = 1, rows do
		local line = GRID[row]
		for column = 1, columns do
			local symbol = string.sub(line, column, column)
			local center = cellCenter(column, row)

			if symbol == "#" then
				makePart(
					"Wall",
					Vector3.new(CELL, WALL_HEIGHT, CELL),
					center + Vector3.new(0, WALL_HEIGHT / 2, 0),
					Color3.fromRGB(120, 120, 130),
					folder
				)
			elseif string.match(symbol, "%d") then
				spawns[symbol] = center
			elseif string.match(symbol, "[A-D]") then
				patrolByLetter[symbol] = center
			elseif symbol == "N" then
				local pad = makePart(
					"NoisePad",
					Vector3.new(CELL, 0.2, CELL),
					center + Vector3.new(0, 0.1, 0),
					Color3.fromRGB(230, 120, 40),
					folder
				)
				pad.Material = Enum.Material.Neon
				table.insert(noisePads, pad)
			elseif symbol == "S" then
				local spawn = Instance.new("SpawnLocation")
				spawn.Name = "PlayerSpawn"
				spawn.Size = Vector3.new(CELL, 0.2, CELL)
				spawn.Position = center + Vector3.new(0, 0.1, 0)
				spawn.Anchored = true
				spawn.Color = Color3.fromRGB(60, 160, 220)
				spawn.Duration = 0
				spawn.Parent = folder
				playerSpawn = spawn
			end
		end
	end

	local patrolNodes = {}
	for _, letter in { "A", "B", "C", "D" } do
		local node = patrolByLetter[letter]
		if node then
			table.insert(patrolNodes, node)
			local marker = makePart(
				`Patrol{letter}`,
				Vector3.new(1.5, 0.2, 1.5),
				node + Vector3.new(0, 0.1, 0),
				Color3.fromRGB(240, 220, 80),
				folder
			)
			marker.CanCollide = false
			marker.CanQuery = false
		end
	end

	folder.Parent = parent

	return {
		Folder = folder,
		Floor = floor,
		Spawns = spawns,
		PatrolNodes = patrolNodes,
		NoisePads = noisePads,
		PlayerSpawn = playerSpawn :: SpawnLocation,
		Bounds = {
			Min = ORIGIN + Vector3.new(CELL, 0, CELL),
			Max = ORIGIN + Vector3.new(width - CELL, 0, depth - CELL),
		},
	}
end

--[[
	A random open-ish point inside the map. It may land in a wall; the navmesh says no and the
	caller picks again, which is a useful thing for an example to show.
]]
function Map.RandomPoint(map: BuiltMap, random: Random): Vector3
	return Vector3.new(
		random:NextNumber(map.Bounds.Min.X, map.Bounds.Max.X),
		0,
		random:NextNumber(map.Bounds.Min.Z, map.Bounds.Max.Z)
	)
end

return Map
