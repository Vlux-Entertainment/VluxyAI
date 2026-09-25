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
	A fake workspace whose Spherecast and Raycast answer from the spec, recording every call. The
	floor is a horizontal plane at `floorHeight(origin)` (default y = 0) wherever `floorAt(origin)`
	holds, and a ray only hits it when the plane lies within the ray's own length, so a ray that is
	too short misses like a real one.
]]
local function fakeWorld(options: {
	sweepHit: any?,
	floorAt: ((point: any) -> boolean)?,
	floorHeight: ((point: any) -> number)?,
})
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
		if floorAt ~= nil and not floorAt(origin) then
			return nil
		end

		local height = if options.floorHeight then options.floorHeight(origin) else 0
		local bottom = origin.Y + direction.Y
		if height > origin.Y or height < bottom then
			return nil
		end

		return { Instance = { Name = "Floor" }, Position = Vector3.new(origin.X, height, origin.Z) }
	end

	return world
end

local function setup(options: {
	sweepHit: any?,
	floorAt: ((point: any) -> boolean)?,
	floorHeight: ((point: any) -> number)?,
	straight: any?,
	players: { any }?,
	touching: { any }?,
}?)
	local resolved = options or {}
	local world = fakeWorld({
		sweepHit = resolved.sweepHit,
		floorAt = resolved.floorAt,
		floorHeight = resolved.floorHeight,
	})
	world.Overlaps = {} :: { any }
	world.Touching = resolved.touching or {}
	function world.GetPartBoundsInRadius(_self, position, radius, params)
		table.insert(world.Overlaps, { Position = position, Radius = radius, Params = params })
		return world.Touching
	end
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
			OverlapParams = {
				new = function()
					return {}
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
		expect.includes(err, "[VluxyAI]")
		expect.includes(
			err,
			'Straight.new: unknown option "Radiu"; expected one of AgentHeight, AgentRadius, FloorCheck, FloorSpacing, Ignore, MaxDrop'
		)

		Straight.new({ AgentRadius = 2.5 })
		expect.equal(#warnings, 1)
		expect.includes(warnings[1], "AgentRadius (2.5)")
		expect.includes(warnings[1], "AgentHeight / 2 (2.5)")

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
		expect.equal(s.world.Sweeps[1].Origin, Vector3.new(0, 2.5, 0), "lifted by AgentHeight / 2 above the floor")
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

	["a body already overlapping a wall is blocked before the sweep"] = function(expect)
		local s = setup({
			touching = {
				{
					GetFullName = function()
						return "Workspace.Map.Wall"
					end,
				},
			},
		})

		local path, reason = s.straight:FindPath(Vector3.new(0, 0, 0), Vector3.new(10, 0, 0), s.agent)
		expect.equal(path, nil)
		expect.equal(reason, "blocked by Workspace.Map.Wall at the start")
		expect.equal(#s.world.Sweeps, 0)
		expect.equal(#s.world.Overlaps, 1)
		expect.equal(s.world.Overlaps[1].Position, Vector3.new(0, 2.5, 0), "checked at the body centre")
		expect.near(s.world.Overlaps[1].Radius, 1.8, 1e-6, "a little inside the body radius")
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

	["FindPath checks the floor every min(FloorSpacing, AgentRadius) studs down to MaxDrop"] = function(expect)
		local s = setup({ straight = { FloorSpacing = 4, AgentRadius = 2, MaxDrop = 6, AgentHeight = 5 } })

		s.straight:FindPath(Vector3.new(0, 0, 0), Vector3.new(10, 0, 0), s.agent)
		expect.equal(#s.world.Rays, 6)
		expect.equal(s.world.Rays[1].Origin, Vector3.new(0, 2.5, 0), "from first")
		expect.equal(s.world.Rays[2].Origin, Vector3.new(10, 2.5, 0), "then to")
		expect.equal(s.world.Rays[3].Origin, Vector3.new(2, 2.5, 0), "then the samples between, every AgentRadius")
		expect.equal(s.world.Rays[4].Origin, Vector3.new(4, 2.5, 0))
		expect.equal(s.world.Rays[5].Origin, Vector3.new(6, 2.5, 0))
		expect.equal(s.world.Rays[6].Origin, Vector3.new(8, 2.5, 0))
		expect.equal(
			s.world.Rays[1].Direction,
			Vector3.new(0, -11, 0),
			"an endpoint may be a root: AgentHeight + MaxDrop"
		)
		expect.equal(s.world.Rays[2].Direction, Vector3.new(0, -11, 0))
		expect.equal(
			s.world.Rays[3].Direction,
			Vector3.new(0, -8.5, 0),
			"a sample is on the floor: AgentHeight / 2 + MaxDrop"
		)
		expect.equal(s.world.Rays[6].Direction, Vector3.new(0, -8.5, 0))

		s = setup({ straight = { FloorSpacing = 1, AgentRadius = 2 } })
		s.straight:FindPath(Vector3.new(0, 0, 0), Vector3.new(4, 0, 0), s.agent)
		expect.equal(#s.world.Rays, 5, "a FloorSpacing below AgentRadius is used as given: from, to, 1, 2, 3")
		expect.equal(s.world.Rays[3].Origin, Vector3.new(1, 2.5, 0))
	end,

	["FindPath detects a 3-stud gap between samples with AgentRadius 2"] = function(expect)
		local gap = function(origin)
			return origin.X <= 5 or origin.X >= 8
		end

		local s = setup({ straight = { FloorSpacing = 4, AgentRadius = 2 }, floorAt = gap })
		local path, reason = s.straight:FindPath(Vector3.new(0, 0, 0), Vector3.new(10, 0, 0), s.agent)
		expect.equal(path, nil)
		expect.equal(reason, `no floor at {Vector3.new(6, 0, 0)}`, "the sample at 6 falls in the gap")

		s = setup({ straight = { FloorSpacing = 4, AgentRadius = 4, AgentHeight = 10 }, floorAt = gap })
		path = s.straight:FindPath(Vector3.new(0, 0, 0), Vector3.new(10, 0, 0), s.agent)
		expect.equal(#path, 2, "a body of radius 4 spans the gap, and samples at 4 and 8 both find floor")
	end,

	["FindPath calls a floor more than MaxDrop below a sample no floor"] = function(expect)
		local hole = function(origin)
			return if origin.X > 3 and origin.X < 7 then -7 else 0
		end

		local s = setup({ straight = { MaxDrop = 6 }, floorHeight = hole })
		local path, reason = s.straight:FindPath(Vector3.new(0, 0, 0), Vector3.new(10, 0, 0), s.agent)
		expect.equal(path, nil)
		expect.equal(reason, `no floor at {Vector3.new(4, 0, 0)}`, "the ray from 2.5 reaches -6, not -7")
		expect.equal(#s.world.Rays, 4, "from, to, 2, then 4 misses")

		s = setup({ straight = { MaxDrop = 7 }, floorHeight = hole })
		path, reason = s.straight:FindPath(Vector3.new(0, 0, 0), Vector3.new(10, 0, 0), s.agent)
		expect.equal(reason, nil)
		expect.equal(#path, 2, "a 7-stud drop is allowed with MaxDrop 7")
	end,

	["FindPath rejects a floor that drops more than MaxDrop below the previous sample's floor"] = function(expect)
		-- A bump to y = 2 then a dip to y = -5: each is within MaxDrop of the sample line, but the
		-- step down from the bump to the dip is 7.
		local bumpThenDip = function(origin)
			if origin.X > 3 and origin.X < 5 then
				return 2
			elseif origin.X > 5 and origin.X < 7 then
				return -5
			end
			return 0
		end

		local s = setup({ straight = { MaxDrop = 6 }, floorHeight = bumpThenDip })
		local path, reason = s.straight:FindPath(Vector3.new(0, 0, 0), Vector3.new(10, 0, 0), s.agent)
		expect.equal(path, nil)
		expect.equal(reason, `floor drops 7 at {Vector3.new(6, 0, 0)}`)
		expect.equal(#s.world.Rays, 5, "from, to, 2, 4, then 6 is rejected")

		s = setup({ straight = { MaxDrop = 7 }, floorHeight = bumpThenDip })
		path, reason = s.straight:FindPath(Vector3.new(0, 0, 0), Vector3.new(10, 0, 0), s.agent)
		expect.equal(reason, nil, "a rise is never a drop, and 7 is within MaxDrop 7")
		expect.equal(#path, 2)
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
		expect.equal(#s.world.Rays, 6, "from, to, 2, 4, 6, then 8 misses")
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
