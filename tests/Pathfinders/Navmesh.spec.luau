--!strict

--[[
	The navmesh pathfinder's pure parts, `Simplify` and `FromWaypoints`, plus `FindPath` against a
	fake PathfindingService so the reason strings and the Simplify switch are exact. The real
	service is a play-test.
]]

local Harness = require("../Support/Harness")

local roblox = require("@lune/roblox")
local Enum = roblox.Enum
local Vector3 = roblox.Vector3

local function walk(x: number, y: number, z: number, label: string?)
	return { Position = Vector3.new(x, y, z), Action = "Walk", Label = label }
end

local function jump(x: number, y: number, z: number)
	return { Position = Vector3.new(x, y, z), Action = "Jump" }
end

local function positions(path: { any }): { string }
	local out = {}
	for _, step in path do
		table.insert(out, `{step.Position.X},{step.Position.Y},{step.Position.Z}`)
	end
	return out
end

local function load()
	return Harness.Load("lib/Pathfinders/Navmesh.luau")
end

--[[
	A fake Path instance, so `new` and `FindPath` run without Roblox.
]]
local function fakePath(status: any, waypoints: { any }?, computeError: string?)
	local path = {
		Status = status,
		Computed = {} :: { { any } },
		Destroyed = false,
	}

	function path.ComputeAsync(self, from, to)
		if computeError then
			error(computeError, 0)
		end
		table.insert(self.Computed, { from, to })
	end

	function path.GetWaypoints(_self)
		return waypoints or {}
	end

	function path.Destroy(self)
		self.Destroyed = true
	end

	return path
end

local function loadWithService(path: any)
	local created = {}
	local Navmesh = Harness.Load("lib/Pathfinders/Navmesh.luau", {
		services = {
			PathfindingService = {
				CreatePath = function(_self, parameters)
					table.insert(created, parameters)
					return path
				end,
			},
		},
	})
	return Navmesh, created
end

local function waypoint(x: number, y: number, z: number, action: string?, label: string?)
	return { Position = Vector3.new(x, y, z), Action = { Name = action or "Walk" }, Label = label or "" }
end

return {
	["Simplify returns a copy of a path with two or fewer steps"] = function(expect)
		local Navmesh = load()
		local path = { walk(0, 0, 0), walk(10, 0, 0) }

		local result = Navmesh.Simplify(path)
		expect.equal(#result, 2)
		expect.truthy(result ~= path, "a copy, not the same table")
		expect.equal(result[1], path[1])
		expect.equal(result[2], path[2])

		expect.equal(#Navmesh.Simplify({ walk(0, 0, 0) }), 1)
		expect.equal(#Navmesh.Simplify({}), 0)
	end,

	["Simplify drops interior Walk steps on a straight line"] = function(expect)
		local Navmesh = load()
		local path = { walk(0, 0, 0), walk(2, 0, 0), walk(4, 0, 0), walk(6, 0, 0), walk(8, 0, 0) }

		expect.sequence(positions(Navmesh.Simplify(path)), { "0,0,0", "8,0,0" })
		expect.equal(#path, 5, "the input is untouched")
	end,

	["Simplify keeps the corner and the first step"] = function(expect)
		local Navmesh = load()
		local path = { walk(0, 0, 0), walk(2, 0, 0), walk(4, 0, 0), walk(4, 0, 2), walk(4, 0, 4) }

		expect.sequence(positions(Navmesh.Simplify(path)), { "0,0,0", "4,0,0", "4,0,4" })
	end,

	["Simplify keeps a corner that is the second to last step"] = function(expect)
		local Navmesh = load()
		local path = { walk(0, 0, 0), walk(2, 0, 0), walk(4, 0, 0), walk(4, 0, 2) }

		expect.sequence(positions(Navmesh.Simplify(path)), { "0,0,0", "4,0,0", "4,0,2" })
	end,

	["Simplify compares against the last kept step, so a slow curve is not flattened"] = function(expect)
		local Navmesh = load()
		-- Each segment turns by about 2.3 degrees: neighbours look collinear, but the curve bends
		-- 20 degrees overall. Measured from the last kept step, the drift is caught.
		local path = { walk(0, 0, 0) }
		local angle = 0
		local position = Vector3.new(0, 0, 0)
		for _ = 1, 9 do
			angle += math.rad(2.3)
			position += Vector3.new(math.cos(angle), 0, math.sin(angle)) * 2
			table.insert(path, walk(position.X, position.Y, position.Z))
		end

		local result = Navmesh.Simplify(path)
		expect.truthy(#result > 2, `kept {#result} steps`)
		expect.truthy(#result < #path, `dropped some of {#path} steps`)
	end,

	["Simplify never removes a Jump or Custom step"] = function(expect)
		local Navmesh = load()
		local path = {
			walk(0, 0, 0),
			walk(2, 0, 0),
			jump(4, 0, 0),
			walk(6, 0, 0),
			{ Position = Vector3.new(8, 0, 0), Action = "Custom" },
			walk(10, 0, 0),
			walk(12, 0, 0),
		}

		local result = Navmesh.Simplify(path)
		expect.sequence(positions(result), { "0,0,0", "2,0,0", "4,0,0", "8,0,0", "12,0,0" })
		expect.equal(result[3].Action, "Jump")
		expect.equal(result[4].Action, "Custom")
	end,

	["Simplify keeps the step before a Jump"] = function(expect)
		local Navmesh = load()
		local path = { walk(0, 0, 0), walk(2, 0, 0), walk(4, 0, 0), jump(6, 0, 0), walk(8, 0, 0) }

		expect.sequence(positions(Navmesh.Simplify(path)), { "0,0,0", "4,0,0", "6,0,0", "8,0,0" })
	end,

	["Simplify keeps a labelled step"] = function(expect)
		local Navmesh = load()
		local path = { walk(0, 0, 0), walk(2, 0, 0, "door"), walk(4, 0, 0), walk(6, 0, 0) }

		local result = Navmesh.Simplify(path)
		expect.sequence(positions(result), { "0,0,0", "2,0,0", "6,0,0" })
		expect.equal(result[2].Label, "door")
	end,

	["Simplify drops a duplicate step"] = function(expect)
		local Navmesh = load()
		local path = { walk(0, 0, 0), walk(0, 0, 0), walk(4, 0, 0), walk(4, 0, 4) }

		expect.sequence(positions(Navmesh.Simplify(path)), { "0,0,0", "4,0,0", "4,0,4" })
	end,

	["FromWaypoints maps position, action name and label"] = function(expect)
		local Navmesh = load()
		local path = Navmesh.FromWaypoints({
			waypoint(0, 0, 0),
			waypoint(2, 1, 0, "Jump"),
			waypoint(4, 0, 0, "Custom", "Door"),
			waypoint(6, 0, 0, "Walk", "Water"),
		})

		expect.equal(#path, 4)
		expect.equal(path[1].Position, Vector3.new(0, 0, 0))
		expect.equal(path[1].Action, "Walk")
		expect.equal(path[1].Label, nil, "an empty label becomes nil")
		expect.equal(path[2].Action, "Jump")
		expect.equal(path[3].Action, "Custom")
		expect.equal(path[3].Label, "Door")
		expect.equal(path[4].Label, "Water")
	end,

	["FromWaypoints copes with a missing Label and an empty list"] = function(expect)
		local Navmesh = load()
		local path = Navmesh.FromWaypoints({ { Position = Vector3.new(1, 2, 3), Action = { Name = "Walk" } } })
		expect.equal(path[1].Label, nil)
		expect.equal(#Navmesh.FromWaypoints({}), 0)
	end,

	["new creates one Path with the agent parameters and the defaults"] = function(expect)
		local Navmesh, created = loadWithService(fakePath(Enum.PathStatus.Success))
		local navmesh = Navmesh.new({ AgentRadius = 3, Costs = { Water = 20 } })

		expect.equal(#created, 1)
		expect.equal(created[1].AgentRadius, 3)
		expect.equal(created[1].AgentHeight, 5)
		expect.equal(created[1].AgentCanJump, false)
		expect.equal(created[1].AgentCanClimb, false)
		expect.equal(created[1].WaypointSpacing, 2)
		expect.equal(created[1].Costs.Water, 20)
		expect.equal(created[1].Simplify, nil, "Simplify is not an agent parameter")
		expect.equal(navmesh.Name, "Navmesh")
	end,

	["new rejects an unknown option"] = function(expect)
		local Navmesh = loadWithService(fakePath(Enum.PathStatus.Success))
		local err = expect.errors(function()
			Navmesh.new({ AgentRadiu = 3 } :: any)
		end)
		expect.includes(err, "[VluxyAI]")
		expect.includes(err, "AgentRadiu")
	end,

	["FindPath computes, converts and simplifies"] = function(expect)
		local path = fakePath(Enum.PathStatus.Success, { waypoint(0, 0, 0), waypoint(2, 0, 0), waypoint(4, 0, 0) })
		local Navmesh = loadWithService(path)
		local navmesh = Navmesh.new()

		local result, reason = navmesh:FindPath(Vector3.new(0, 0, 0), Vector3.new(4, 0, 0), {} :: any)
		expect.equal(reason, nil)
		expect.equal(path.Computed[1][1], Vector3.new(0, 0, 0))
		expect.equal(path.Computed[1][2], Vector3.new(4, 0, 0))
		expect.sequence(positions(result), { "0,0,0", "4,0,0" })
	end,

	["FindPath with Simplify off keeps every waypoint"] = function(expect)
		local path = fakePath(Enum.PathStatus.Success, { waypoint(0, 0, 0), waypoint(2, 0, 0), waypoint(4, 0, 0) })
		local Navmesh = loadWithService(path)
		local navmesh = Navmesh.new({ Simplify = false })

		local result = navmesh:FindPath(Vector3.new(0, 0, 0), Vector3.new(4, 0, 0), {} :: any)
		expect.sequence(positions(result), { "0,0,0", "2,0,0", "4,0,0" })
	end,

	["FindPath reports the status name when the path did not succeed"] = function(expect)
		local Navmesh = loadWithService(fakePath(Enum.PathStatus.NoPath, { waypoint(0, 0, 0) }))
		local navmesh = Navmesh.new()

		local result, reason = navmesh:FindPath(Vector3.new(0, 0, 0), Vector3.new(4, 0, 0), {} :: any)
		expect.equal(result, nil)
		expect.equal(reason, "NoPath")
	end,

	["FindPath reports the ComputeAsync error"] = function(expect)
		local Navmesh = loadWithService(fakePath(Enum.PathStatus.Success, nil, "Unable to cast to Vector3"))
		local navmesh = Navmesh.new()

		local result, reason = navmesh:FindPath(Vector3.new(0, 0, 0), Vector3.new(4, 0, 0), {} :: any)
		expect.equal(result, nil)
		expect.equal(reason, "Unable to cast to Vector3")
	end,

	["Destroy destroys the Path instance once and FindPath then fails"] = function(expect)
		local path = fakePath(Enum.PathStatus.Success, { waypoint(0, 0, 0), waypoint(4, 0, 0) })
		local Navmesh = loadWithService(path)
		local navmesh = Navmesh.new()

		navmesh:Destroy()
		expect.truthy(path.Destroyed)
		path.Destroyed = false
		navmesh:Destroy()
		expect.falsy(path.Destroyed, "a second Destroy does nothing")

		local result, reason = navmesh:FindPath(Vector3.new(0, 0, 0), Vector3.new(4, 0, 0), {} :: any)
		expect.equal(result, nil)
		expect.equal(reason, "destroyed")
		expect.equal(#path.Computed, 0)
	end,
}
