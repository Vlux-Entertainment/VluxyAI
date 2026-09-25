--!strict

--[[
	The ring-of-rays sense: the pure direction ring and summary, then a Tick against a fake
	workspace to prove the keys it writes.
]]

local Harness = require("../Support/Harness")
local SenseFakes = require("./SenseFakes")

local roblox = require("@lune/roblox")
local Vector3 = roblox.Vector3

local function load(hit: any?)
	return Harness.Load("lib/Senses/Surroundings.luau", {
		globals = SenseFakes.Globals({ hit = hit }),
	})
end

return {
	["Directions are unit vectors evenly spaced, starting forward"] = function(expect)
		local Surroundings = load()
		local directions = Surroundings.Directions(4)
		expect.equal(#directions, 4)
		expect.near(directions[1].Z, -1, 1e-6, "forward is -Z")
		expect.near(directions[2].X, -1, 1e-6, "then left")
		expect.near(directions[3].Z, 1, 1e-6, "then back")
		expect.near(directions[4].X, 1, 1e-6, "then right")
		for _, direction in directions do
			expect.near(direction.Magnitude, 1, 1e-6)
			expect.equal(direction.Y, 0)
		end
	end,

	["Evaluate reports the nearest hit and the most open direction"] = function(expect)
		local Surroundings = load()
		local directions = Surroundings.Directions(4)
		local summary = Surroundings.Evaluate(directions, { 3, nil, 8, 5 }, 12)
		expect.equal(summary.ObstacleDistance, 3)
		expect.equal(summary.ObstacleDirection, directions[1])
		expect.equal(summary.OpenDirection, directions[2], "the clear ray")
		expect.equal(summary.OpenDistance, 12)
	end,

	["Evaluate with nothing hit is open all round"] = function(expect)
		local Surroundings = load()
		local directions = Surroundings.Directions(8)
		local summary = Surroundings.Evaluate(directions, {}, 12)
		expect.equal(summary.ObstacleDistance, math.huge)
		expect.equal(summary.ObstacleDirection, nil)
		expect.equal(summary.OpenDirection, directions[1], "the first on a tie")
		expect.equal(summary.OpenDistance, 12)
	end,

	["Tick writes the four keys from the rays around the agent"] = function(expect)
		local cast = {}
		local Surroundings = load(function(ray)
			local direction = ray.Direction.Unit
			table.insert(cast, direction)
			-- A wall 4 studs ahead (-Z) only.
			if direction.Z < -0.9 then
				return { Distance = 4, Instance = { Name = "Wall" }, Position = ray.From + direction * 4 }
			end
			return nil
		end)
		local sense = Surroundings.new({ Rays = 4, Distance = 10 })
		local agent = SenseFakes.Agent(Vector3.new(0, 0, 0))

		sense:Tick(agent, 0.1)
		expect.equal(#cast, 4)
		expect.equal(agent.Blackboard.ObstacleDistance, 4)
		expect.near(agent.Blackboard.ObstacleDirection.Z, -1, 1e-6)
		expect.truthy(agent.Blackboard.OpenDirection.Z > -0.5, "the open direction is not toward the wall")
		expect.equal(agent.Blackboard.OpenDistance, 10, "and it is clear to full reach")
	end,

	["an unknown option is refused"] = function(expect)
		local Surroundings = load()
		local message = expect.errors(function()
			Surroundings.new({ Ray = 4 })
		end)
		expect.includes(message, 'Surroundings.new: unknown option "Ray"')
	end,
}
