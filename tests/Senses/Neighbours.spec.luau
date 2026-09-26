--!strict

--[[
	Neighbours: the group is whoever ticks the instance, the keys it writes, the speed ease
	through the agent's speed scale, the nudge through the mover, and leaving on destroy.
]]

local Fakes = require("../Support/Fakes")
local Harness = require("../Support/Harness")

local roblox = require("@lune/roblox")
local Vector3 = roblox.Vector3

local function load()
	return Harness.Load("lib/Senses/Neighbours.luau")
end

--[[
	An agent at a position with the pieces the sense touches: a speed scale, a mover with a
	nudge, a Destroyed signal and IsDestroyed.
]]
local function agent(name: string, position: any, withMover: boolean?)
	local Signal = Fakes.Signal()
	local self = {
		Name = name,
		Blackboard = {},
		Data = {},
		Position = position,
		Scale = 1,
		Dead = false,
		Destroyed = Signal.new(),
		Mover = nil :: any,
	}
	if withMover ~= false then
		self.Mover = { Nudges = {} :: { any } }
		function self.Mover.SetNudge(mover, offset)
			table.insert(mover.Nudges, if offset == nil then "nil" else offset)
		end
	end
	function self.GetPosition(this)
		return this.Position
	end
	function self.SetSpeedScale(this, scale)
		this.Scale = scale
	end
	function self.IsDestroyed(this)
		return this.Dead
	end
	function self.Destroy(this)
		this.Dead = true
		this.Destroyed:Fire()
	end
	return self
end

return {
	["agents that tick the same instance see each other, nearest first, within Range"] = function(expect)
		local Neighbours = load()
		local sense = Neighbours.new({ Range = 10 })
		local a = agent("A", Vector3.new(0, 0, 0))
		local b = agent("B", Vector3.new(4, 5, 0))
		local c = agent("C", Vector3.new(0, 0, -8))
		local far = agent("Far", Vector3.new(50, 0, 0))

		sense:Tick(a, 0.1)
		expect.equal(#a.Blackboard.NearbyAgents, 0, "alone on the first tick")
		expect.equal(a.Blackboard.NearestAgentDistance, math.huge)
		expect.equal(a.Blackboard.Crowding, 0)
		expect.equal(a.Blackboard.SeparationDirection, nil)

		sense:Tick(b, 0.1)
		sense:Tick(c, 0.1)
		sense:Tick(far, 0.1)
		sense:Tick(a, 0.1)
		expect.sequence(a.Blackboard.NearbyAgents, { b, c }, "height is ignored; Far is out of range")
		expect.equal(a.Blackboard.NearestAgent, b)
		expect.near(a.Blackboard.NearestAgentDistance, 4)
		expect.truthy(a.Blackboard.Crowding > 0 and a.Blackboard.Crowding <= 1)
		local away = a.Blackboard.SeparationDirection
		expect.truthy(away.X < 0 and away.Z > 0, "away from both B (+X) and C (-Z)")
		expect.near(away.Magnitude, 1)
		expect.equal(a.Scale, 1, "no Slow: the speed is untouched")
		expect.equal(#a.Mover.Nudges, 0, "no Avoid: no nudge")
	end,

	["Slow eases the speed scale on the nearest neighbour and restores it"] = function(expect)
		local Neighbours = load()
		local sense = Neighbours.new({ Range = 10, Slow = { Distance = 5, Min = 0.5 } })
		local a = agent("A", Vector3.new(0, 0, 0))
		local b = agent("B", Vector3.new(2.5, 0, 0))
		sense:Tick(b, 0.1)

		sense:Tick(a, 0.1)
		expect.near(a.Scale, 0.75, 1e-6, "halfway in, halfway between Min and 1")
		b.Position = Vector3.new(0, 0, 0)
		sense:Tick(a, 0.1)
		expect.near(a.Scale, 0.5, 1e-6, "on top: Min")
		b.Position = Vector3.new(7, 0, 0)
		sense:Tick(a, 0.1)
		expect.equal(a.Scale, 1, "past Distance: no ease")

		local shaped = Neighbours.new({
			Slow = {
				Distance = 4,
				Min = 0,
				Curve = function(t)
					return t * t
				end,
			},
		})
		local x = agent("X", Vector3.new(0, 0, 0))
		local y = agent("Y", Vector3.new(2, 0, 0))
		shaped:Tick(y, 0.1)
		shaped:Tick(x, 0.1)
		expect.near(x.Scale, 0.25, 1e-6, "the curve shapes it")
	end,

	["Avoid nudges the mover away, capped at the radius, and clears when alone"] = function(expect)
		local Neighbours = load()
		local sense = Neighbours.new({ Range = 10, Avoid = { Radius = 4, Strength = 1 } })
		local a = agent("A", Vector3.new(0, 0, 0))
		local b = agent("B", Vector3.new(3, 0, 0))
		sense:Tick(b, 0.1)

		sense:Tick(a, 0.1)
		local nudge = a.Mover.Nudges[1]
		expect.near(nudge.X, -1, 1e-6, "one stud of the four left, away from B")
		expect.near(nudge.Z, 0, 1e-6)

		b.Position = Vector3.new(0.5, 0, 0)
		sense:Tick(a, 0.1)
		expect.near(a.Mover.Nudges[2].X, -3.5, 1e-6)

		b.Position = Vector3.new(6, 0, 0)
		sense:Tick(a, 0.1)
		expect.equal(a.Mover.Nudges[3], "nil", "outside the radius clears the nudge")

		local walker = agent("Walker", Vector3.new(0, 0, 0), false)
		sense:Tick(walker, 0.1)
		expect.truthy(true, "no mover is fine")
	end,

	["Filter and Others decide who counts"] = function(expect)
		local Neighbours = load()
		local a = agent("A", Vector3.new(0, 0, 0))
		local b = agent("B", Vector3.new(2, 0, 0))
		local c = agent("C", Vector3.new(3, 0, 0))

		local filtered = Neighbours.new({
			Filter = function(_agent, other)
				return other.Name ~= "B"
			end,
		})
		filtered:Tick(b, 0.1)
		filtered:Tick(c, 0.1)
		filtered:Tick(a, 0.1)
		expect.sequence(a.Blackboard.NearbyAgents, { c })

		local listed = Neighbours.new({
			Others = function()
				return { b, a }
			end,
		})
		listed:Tick(a, 0.1)
		expect.sequence(a.Blackboard.NearbyAgents, { b }, "itself is skipped")
	end,

	["a destroyed agent leaves the group; Destroy undoes the ease and nudge"] = function(expect)
		local Neighbours = load()
		local sense = Neighbours.new({ Slow = { Distance = 5 }, Avoid = { Radius = 4 } })
		local a = agent("A", Vector3.new(0, 0, 0))
		local b = agent("B", Vector3.new(1, 0, 0))
		sense:Tick(a, 0.1)
		sense:Tick(b, 0.1)
		sense:Tick(a, 0.1)
		expect.truthy(a.Scale < 1)

		b:Destroy()
		sense:Tick(a, 0.1)
		expect.equal(#a.Blackboard.NearbyAgents, 0, "B is gone")
		expect.equal(a.Scale, 1)

		sense:Tick(b, 0.1)
		local c = agent("C", Vector3.new(0.5, 0, 0))
		sense:Tick(c, 0.1)
		sense:Tick(a, 0.1)
		expect.truthy(a.Scale < 1)
		sense:Destroy(a)
		expect.equal(a.Scale, 1, "eased back on leaving")
		expect.equal(a.Mover.Nudges[#a.Mover.Nudges], "nil", "nudge cleared on leaving")
		sense:Tick(c, 0.1)
		expect.equal(#c.Blackboard.NearbyAgents, 0, "A left the group")

		sense:Destroy()
		sense:Tick(c, 0.1)
		expect.equal(#c.Blackboard.NearbyAgents, 0)
	end,

	["new and Configure check the options"] = function(expect)
		local Neighbours = load()
		expect.includes(
			expect.errors(function()
				Neighbours.new({ Slow = { Min = 0.5 } } :: any)
			end),
			"Slow.Distance must be a number of 0 or more"
		)
		expect.includes(
			expect.errors(function()
				Neighbours.new({ Avoid = { Radius = -1 } })
			end),
			"Avoid.Radius must be a number of 0 or more"
		)

		local off = Neighbours.new({ Slow = { Distance = 0 }, Avoid = { Radius = 0 } })
		local a = agent("A", Vector3.new(0, 0, 0))
		local b = agent("B", Vector3.new(0.5, 0, 0))
		off:Tick(b, 0.1)
		off:Tick(a, 0.1)
		expect.equal(a.Scale, 1, "zero distance is off")
		expect.equal(#a.Mover.Nudges, 0, "zero radius is off")
		expect.equal(a.Blackboard.NearestAgent, b, "the keys are still written")
		expect.includes(
			expect.errors(function()
				Neighbours.new({ Radius = 3 } :: any)
			end),
			'unknown option "Radius"'
		)

		local sense = Neighbours.new()
		sense:Configure({ Range = 20 })
		expect.includes(
			expect.errors(function()
				sense:Configure({ Range = -1 })
			end),
			"Range must be zero or more"
		)
	end,
}
