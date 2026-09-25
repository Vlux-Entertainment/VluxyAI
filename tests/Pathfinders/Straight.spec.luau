--!strict

--[[
	The straight-line pathfinder: `Sample` is pure and exact; `FindPath` runs against a fake
	`workspace` and `RaycastParams` so the sweep geometry, the floor samples and the reason strings
	are pinned down. Whether the real casts agree with the world is a play-test.
]]

local Fakes = require("../Support/Fakes")
local Harness = require("../Support/Harness")

local roblox = require("@lune/roblox")
local Vector3 = roblox.Vector3

local function load(options: { warnings: { string }? }?)
	local resolved = options or {}
	return Harness.Load("lib/Pathfinders/Straight.luau", {
		warn = function(message)
			if resolved.warnings then
				table.insert(resolved.warnings, tostring(message))
			end
		end,
	})
end

local function coordinates(points: { any }): { string }
	local out = {}
	for _, point in points do
		table.insert(out, `{point.X},{point.Y},{point.Z}`)
	end
	return out
end

--[[
	A fake workspace whose Spherecast and Raycast answer from the spec, recording every call.
]]
local function fakeWorld(options: { sweepHit: any?, floorAt: ((point: any) -> boolean)? })
	local world = {
		Sweeps = {} :: { { Origin: any, Radius: number, Direction: any, Params: any } },
		Rays = {} :: { { Origin: any, Direction: any, Params: any } },
	}

	function world.Spherecast(_self, origin, radius, direction, params)
		table.insert(world.Sweeps, { Origin = origin, Radius = radius, Direction = direction, Params = params })
		return options.sweepHit
	end

	function world.Raycast(_self, origin, direction, params)
		table.insert(world.Rays, { Origin = origin, Direction = direction, Params = params })
		local floorAt = options.floorAt
		if floorAt == nil or floorAt(origin) then
			-- The floor is the plane y = 0 wherever it exists.
			return { Instance = { Name = "Floor" }, Position = Vector3.new(origin.X, 0, origin.Z) }
		end
		return nil
	end

	return world
end

local function setup(options: {
	sweepHit: any?,
	floorAt: ((point: any) -> boolean)?,
	straight: any?,
	players: { any }?,
}?)
	local resolved = options or {}
	local world = fakeWorld({ sweepHit = resolved.sweepHit, floorAt = resolved.floorAt })
	local params = {}

	local Straight = Harness.Load("lib/Pathfinders/Straight.luau", {
		globals = {
			workspace = world,
			RaycastParams = {
				new = function()
					local created = {}
					table.insert(params, created)
					return created
				end,
			},
		},
		services = {
			Players = {
				GetPlayers = function()
					return resolved.players or {}
				end,
			},
		},
	})

	local agent = Fakes.Agent()
	agent.Entity = Fakes.Entity("Rig")

	return {
		Straight = Straight,
		straight = Straight.new(resolved.straight),
		world = world,
		params = params,
		agent = agent,
	}
end

return {
	["Sample gives the points after from, every spacing, ending with to"] = function(expect)
		local Straight = load()
		local points = Straight.Sample(Vector3.new(0, 0, 0), Vector3.new(10, 0, 0), 4)
		expect.sequence(coordinates(points), { "4,0,0", "8,0,0", "10,0,0" })
	end,

	["Sample includes to exactly once when the length divides evenly"] = function(expect)
		local Straight = load()
		local points = Straight.Sample(Vector3.new(0, 0, 0), Vector3.new(10, 0, 0), 5)
		expect.sequence(coordinates(points), { "5,0,0", "10,0,0" })
	end,

	["Sample of a segment shorter than spacing is just to"] = function(expect)
		local Straight = load()
		local points = Straight.Sample(Vector3.new(1, 2, 3), Vector3.new(2, 2, 3), 4)
		expect.sequence(coordinates(points), { "2,2,3" })
	end,

	["Sample of a zero-length segment is just to"] = function(expect)
		local Straight = load()
		local points = Straight.Sample(Vector3.new(1, 2, 3), Vector3.new(1, 2, 3), 4)
		expect.sequence(coordinates(points), { "1,2,3" })
	end,

	["Sample follows the segment direction in three dimensions"] = function(expect)
		local Straight = load()
		local points = Straight.Sample(Vector3.new(0, 0, 0), Vector3.new(0, 3, 4), 2.5)
		expect.equal(#points, 2)
		expect.near(points[1].Y, 1.5)
		expect.near(points[1].Z, 2)
		expect.equal(points[2], Vector3.new(0, 3, 4))
	end,

	["Sample rejects a non-positive spacing"] = function(expect)
		local Straight = load()
		local err = expect.errors(function()
			Straight.Sample(Vector3.new(), Vector3.new(1, 0, 0), 0)
		end)
		expect.includes(err, "[VluxyAI]")
		expect.includes(err, "spacing")
	end,

	["new rejects an unknown option and warns about a radius that scrapes the floor"] = function(expect)
		local warnings = {}
		local Straight = load({ warnings = warnings })

		local err = expect.errors(function()
			Straight.new({ Radiu = 3 } :: any)
		end)
		expect.includes(err, "Radiu")

		Straight.new({ Radius = 2.5 })
		expect.equal(#warnings, 1)
		expect.includes(warnings[1], "Radius")

		Straight.new({
			Ignore = function()
				return {}
			end,
		})
		expect.equal(#warnings, 1, "Ignore is a known option")
	end,

	["FindPath sweeps a sphere between the body centres and returns the two floor steps"] = function(expect)
		local s = setup()
		local from = Vector3.new(0, 0, 0)
		local to = Vector3.new(10, 0, 0)

		local path, reason = s.straight:FindPath(from, to, s.agent)
		expect.equal(reason, nil)
		expect.equal(#path, 2)
		expect.equal(path[1].Position, from)
		expect.equal(path[1].Action, "Walk")
		expect.equal(path[2].Position, to)
		expect.equal(path[2].Action, "Walk")

		expect.equal(#s.world.Sweeps, 1)
		expect.equal(s.world.Sweeps[1].Origin, Vector3.new(0, 2.5, 0), "lifted by Height / 2 above the floor")
		expect.equal(s.world.Sweeps[1].Radius, 2)
		expect.equal(s.world.Sweeps[1].Direction, Vector3.new(10, 0, 0))
	end,

	["FindPath projects root-height positions onto the floor"] = function(expect)
		local s = setup()

		local path = s.straight:FindPath(Vector3.new(0, 2.5, 0), Vector3.new(10, 3, 0), s.agent)
		expect.equal(path[1].Position, Vector3.new(0, 0, 0), "the mover's root projects to the floor")
		expect.equal(path[2].Position, Vector3.new(10, 0, 0), "a player's root projects to the floor")
		expect.equal(s.world.Sweeps[1].Origin, Vector3.new(0, 2.5, 0), "the sweep sits at body height regardless")
		expect.equal(s.world.Sweeps[1].Direction, Vector3.new(10, 0, 0))
		expect.equal(s.world.Rays[1].Origin, Vector3.new(0, 5, 0), "the floor ray starts half a body above the input")
	end,

	["FindPath builds exclude params from the default ignore list"] = function(expect)
		local character = { Name = "PlayerCharacter" }
		local s = setup({ players = { { Character = character }, { Character = nil } } })

		s.straight:FindPath(Vector3.new(0, 0, 0), Vector3.new(10, 0, 0), s.agent)
		expect.equal(#s.params, 1)
		local params = s.params[1]
		expect.equal(params.FilterType, roblox.Enum.RaycastFilterType.Exclude)
		expect.equal(params.IgnoreWater, true)
		expect.equal(#params.FilterDescendantsInstances, 2)
		expect.equal(params.FilterDescendantsInstances[1], s.agent.Entity)
		expect.equal(params.FilterDescendantsInstances[2], character)
		expect.equal(s.world.Sweeps[1].Params, params, "the same params go to the sweep")
		expect.equal(s.world.Rays[1].Params, params, "and to the floor rays")
	end,

	["FindPath uses a custom Ignore and hands it the agent"] = function(expect)
		local seen = nil
		local extra = { Name = "Door" }
		local s = setup({
			straight = {
				Ignore = function(agent)
					seen = agent
					return { extra }
				end,
			},
		})

		s.straight:FindPath(Vector3.new(0, 0, 0), Vector3.new(10, 0, 0), s.agent)
		expect.equal(seen, s.agent)
		expect.equal(#s.params[1].FilterDescendantsInstances, 1)
		expect.equal(s.params[1].FilterDescendantsInstances[1], extra)
	end,

	["FindPath reports what the sweep hit"] = function(expect)
		local s = setup({
			sweepHit = {
				Instance = {
					GetFullName = function()
						return "Workspace.Map.Wall"
					end,
				},
			},
		})

		local path, reason = s.straight:FindPath(Vector3.new(0, 0, 0), Vector3.new(10, 0, 0), s.agent)
		expect.equal(path, nil)
		expect.equal(reason, "blocked by Workspace.Map.Wall")
		expect.equal(#s.world.Rays, 2, "only the endpoint floor rays ran before the blocked sweep")
	end,

	["FindPath checks the floor every FloorSpacing studs down to MaxDrop"] = function(expect)
		local s = setup({ straight = { FloorSpacing = 4, MaxDrop = 6, Height = 5 } })

		s.straight:FindPath(Vector3.new(0, 0, 0), Vector3.new(10, 0, 0), s.agent)
		expect.equal(#s.world.Rays, 4)
		expect.equal(s.world.Rays[1].Origin, Vector3.new(0, 2.5, 0), "from first")
		expect.equal(s.world.Rays[2].Origin, Vector3.new(10, 2.5, 0), "then to")
		expect.equal(s.world.Rays[3].Origin, Vector3.new(4, 2.5, 0), "then the samples between")
		expect.equal(s.world.Rays[4].Origin, Vector3.new(8, 2.5, 0))
		expect.equal(s.world.Rays[1].Direction, Vector3.new(0, -11, 0), "Height + MaxDrop")
	end,

	["FindPath reports the first point without floor"] = function(expect)
		local s = setup({
			floorAt = function(origin)
				return origin.X < 7
			end,
		})

		local path, reason = s.straight:FindPath(Vector3.new(0, 0, 0), Vector3.new(8, 0, 0), s.agent)
		expect.equal(path, nil)
		expect.equal(reason, `no floor at {Vector3.new(8, 0, 0)}`, "the endpoint is checked before the samples")
		expect.equal(#s.world.Rays, 2, "stops at the first miss")

		s = setup({
			floorAt = function(origin)
				return origin.X < 7 or origin.X > 9
			end,
		})
		path, reason = s.straight:FindPath(Vector3.new(0, 0, 0), Vector3.new(10, 0, 0), s.agent)
		expect.equal(path, nil)
		expect.equal(reason, `no floor at {Vector3.new(8, 0, 0)}`, "a gap in the middle is found by the samples")
		expect.equal(#s.world.Rays, 4, "from, to, 4, then 8 misses")
	end,

	["FindPath with FloorCheck off never raycasts"] = function(expect)
		local s = setup({
			straight = { FloorCheck = false },
			floorAt = function()
				return false
			end,
		})

		local path = s.straight:FindPath(Vector3.new(0, 0, 0), Vector3.new(10, 0, 0), s.agent)
		expect.equal(#path, 2)
		expect.equal(#s.world.Rays, 0)
	end,

	["FindPath to the same position skips the sweep but still wants floor"] = function(expect)
		local s = setup({
			floorAt = function()
				return false
			end,
		})

		local path, reason = s.straight:FindPath(Vector3.new(3, 0, 3), Vector3.new(3, 0, 3), s.agent)
		expect.equal(#s.world.Sweeps, 0)
		expect.equal(path, nil)
		expect.equal(reason, `no floor at {Vector3.new(3, 0, 3)}`)
	end,

	["Destroy exists and is harmless"] = function(expect)
		local s = setup()
		s.straight:Destroy()
		s.straight:Destroy()
		expect.equal(s.straight.Name, "Straight")
	end,
}
