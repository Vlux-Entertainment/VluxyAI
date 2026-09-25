--!strict

--[[
	The maze generator behind the playground: a backtracking carve is a spanning tree, so every
	cell is reachable and exactly one wall per cell beyond the first is gone; the opening pass
	removes more; the same seed gives the same maze.
]]

local Harness = require("../Support/Harness")

local function load()
	return Harness.Load("examples/Server/Map.luau")
end

local function reachable(east: { { boolean } }, south: { { boolean } }, columns: number, rows: number): number
	local seen: { [string]: boolean } = { ["1,1"] = true }
	local queue = { { 1, 1 } }
	local count = 0

	while #queue > 0 do
		local cell = table.remove(queue, 1) :: { number }
		count += 1
		local column, row = cell[1], cell[2]

		local function visit(nextColumn: number, nextRow: number)
			local key = `{nextColumn},{nextRow}`
			if not seen[key] then
				seen[key] = true
				table.insert(queue, { nextColumn, nextRow })
			end
		end

		if column > 1 and not east[row][column - 1] then
			visit(column - 1, row)
		end
		if column < columns and not east[row][column] then
			visit(column + 1, row)
		end
		if row > 1 and not south[row - 1][column] then
			visit(column, row - 1)
		end
		if row < rows and not south[row][column] then
			visit(column, row + 1)
		end
	end

	return count
end

local function standingWalls(east: { { boolean } }, south: { { boolean } }, columns: number, rows: number): number
	local count = 0
	for row = 1, rows do
		for column = 1, columns do
			if column < columns and east[row][column] then
				count += 1
			end
			if row < rows and south[row][column] then
				count += 1
			end
		end
	end
	return count
end

return {
	["every cell is reachable and the carve removes exactly one wall per extra cell"] = function(expect)
		local Map = load()
		local columns, rows = 12, 9
		local east, south = Map.Carve(columns, rows, Harness.FakeRandom.new(7), 0)

		expect.equal(reachable(east, south, columns, rows), columns * rows)

		local interior = (columns - 1) * rows + columns * (rows - 1)
		expect.equal(standingWalls(east, south, columns, rows), interior - (columns * rows - 1))
	end,

	["the opening pass removes more walls and keeps every cell reachable"] = function(expect)
		local Map = load()
		local columns, rows = 12, 9
		local closedEast, closedSouth = Map.Carve(columns, rows, Harness.FakeRandom.new(7), 0)
		local closed = standingWalls(closedEast, closedSouth, columns, rows)
		local east, south = Map.Carve(columns, rows, Harness.FakeRandom.new(7), 0.3)

		expect.truthy(standingWalls(east, south, columns, rows) < closed, "fewer walls")
		expect.equal(reachable(east, south, columns, rows), columns * rows)

		local allOpen, allOpenSouth = Map.Carve(columns, rows, Harness.FakeRandom.new(7), 1)
		expect.equal(standingWalls(allOpen, allOpenSouth, columns, rows), 0, "openness 1 clears the interior")
	end,

	["the same seed gives the same maze and a different seed a different one"] = function(expect)
		local Map = load()
		local function signature(seed: number): string
			local east, south = Map.Carve(8, 6, Harness.FakeRandom.new(seed), 0.3)
			local bits = {}
			for row = 1, 6 do
				for column = 1, 8 do
					table.insert(bits, if east[row][column] then "1" else "0")
					table.insert(bits, if south[row][column] then "1" else "0")
				end
			end
			return table.concat(bits)
		end

		expect.equal(signature(3), signature(3))
		expect.truthy(signature(3) ~= signature(4))
	end,

	["a one-cell maze has nothing to carve"] = function(expect)
		local Map = load()
		local east, south = Map.Carve(1, 1, Harness.FakeRandom.new(1), 0.5)
		expect.equal(reachable(east, south, 1, 1), 1)
	end,
}
