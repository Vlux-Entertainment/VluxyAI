--!strict

--[[
	Interest: points with a strength that decays back to base, bumps by id and by nearness,
	per-agent visits, and Best picking by strength, distance and freshness. A manual clock
	drives the decay.
]]

local Harness = require("../Support/Harness")

local roblox = require("@lune/roblox")
local Vector3 = roblox.Vector3

local function setup(options: any?)
	local clock = Harness.ManualClock(100)
	local Interest = Harness.Load("lib/Interest.luau", { globals = { os = clock.os } })
	return { Interest = Interest, interest = Interest.new(options), clock = clock }
end

local function agent(position: any)
	return {
		Name = "Seeker",
		Blackboard = {},
		Data = {},
		GetPosition = function()
			return position
		end,
	}
end

return {
	["points keep a base and decay back to it after a bump"] = function(expect)
		local s = setup({ Decay = 0.5 })
		s.interest:Add("locker", { Position = Vector3.new(10, 0, 0), Strength = 1 })

		s.interest:Bump("locker", 2)
		expect.near((s.interest:Get("locker") :: any).Strength, 3)
		s.clock:Advance(2)
		expect.near((s.interest:Get("locker") :: any).Strength, 2, 1e-6, "0.5 per second")
		s.clock:Advance(10)
		expect.near((s.interest:Get("locker") :: any).Strength, 1, 1e-6, "back at base, no lower")

		s.interest:Bump("locker", -5)
		expect.equal((s.interest:Get("locker") :: any).Strength, 0, "never below zero")
		s.clock:Advance(1)
		expect.near((s.interest:Get("locker") :: any).Strength, 0.5, 1e-6, "drifts up toward base too")

		s.interest:Set("locker", 4)
		expect.equal((s.interest:Get("locker") :: any).Base, 4)
		s.interest:Remove("locker")
		expect.equal(s.interest:Get("locker"), nil)
		expect.equal(s.interest:Get("nothing"), nil)
	end,

	["BumpNear raises points within the radius, more the nearer"] = function(expect)
		local s = setup({ Decay = 0 })
		s.interest:Add("a", { Position = Vector3.new(0, 0, 0) })
		s.interest:Add("b", { Position = Vector3.new(5, 0, 0) })
		s.interest:Add("c", { Position = Vector3.new(50, 0, 0) })

		expect.equal(s.interest:BumpNear(Vector3.new(0, 0, 0), 10, 2), 2)
		expect.near((s.interest:Get("a") :: any).Strength, 3, 1e-6, "full amount at the spot")
		expect.near((s.interest:Get("b") :: any).Strength, 2, 1e-6, "half at half the radius")
		expect.near((s.interest:Get("c") :: any).Strength, 1, 1e-6, "untouched")
		expect.equal(#s.interest:Points(), 3)
	end,

	["Best prefers strong, near, unvisited points and honours Tags, Exclude and Considerations"] = function(expect)
		local s = setup({ Decay = 0, Visited = 10 })
		s.interest:Add("near", { Position = Vector3.new(10, 0, 0), Strength = 1, Tags = { "Hiding" } })
		s.interest:Add("far", { Position = Vector3.new(60, 0, 0), Strength = 1, Tags = { "Hiding" } })
		s.interest:Add("door", { Position = Vector3.new(15, 0, 0), Strength = 1, Tags = { "Door" } })
		local seeker = agent(Vector3.new(0, 0, 0))

		local best = s.interest:Best(seeker, { Range = 100 })
		expect.equal((best :: any).Id, "near")

		s.interest:Bump("far", 5)
		best = s.interest:Best(seeker, { Range = 100 })
		expect.equal((best :: any).Id, "far", "strength wins over distance")

		s.interest:Visit(seeker, "far")
		best = s.interest:Best(seeker, { Range = 100 })
		expect.equal((best :: any).Id, "near", "just visited scores nothing; the nearest of the rest wins")
		expect.equal(s.interest:SinceVisit(seeker, "far"), 0)
		expect.equal(s.interest:SinceVisit(seeker, "door"), math.huge)

		best = s.interest:Best(seeker, { Range = 100, Tags = { "Hiding" } })
		expect.equal((best :: any).Id, "near", "tags filter")

		best = s.interest:Best(seeker, { Range = 100, Exclude = { "near", "door" } })
		expect.equal(best, nil, "far is visited, the rest excluded: nothing")

		s.clock:Advance(11)
		best = s.interest:Best(seeker, { Range = 100 })
		expect.equal((best :: any).Id, "far", "visits expire")

		best = s.interest:Best(seeker, {
			Range = 100,
			Considerations = {
				{
					Input = function(_agent, point)
						return if point.Id == "far" then 0 else 1
					end,
				},
			},
		})
		expect.equal((best :: any).Id, "near", "an extra consideration vetoes")

		local other = agent(Vector3.new(0, 0, 0))
		expect.equal((s.interest:Best(other, { Range = 100 }) :: any).Id, "far", "visits are per agent")

		local empty = setup()
		expect.equal(empty.interest:Best(seeker), nil)
	end,

	["Add needs a position and Destroy forgets the points"] = function(expect)
		local s = setup()
		expect.includes(
			expect.errors(function()
				s.interest:Add("x", { Strength = 1 } :: any)
			end),
			"needs a Vector3 Position"
		)
		s.interest:Add("x", { Position = Vector3.new() })
		s.interest:Destroy()
		expect.equal(#s.interest:Points(), 0)
	end,
}
