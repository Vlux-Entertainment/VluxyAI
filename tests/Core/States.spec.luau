--!strict

--[[
	The ready-made states, run inside a real Agent with a fake pathfinder and mover: which point
	each one walks to next, when it moves on, and what it leaves in Data. A manual clock drives
	the timers and the fake mover is told when it arrived.
]]

local Fakes = require("../Support/Fakes")
local Harness = require("../Support/Harness")

local roblox = require("@lune/roblox")
local Vector3 = roblox.Vector3

local NEXT = "Next"

--[[
	An agent whose brain is the state under test plus a "Next" state that records its entry.
]]
local function setup(state: any, data: { [string]: any }?, blackboard: { [string]: any }?, plan: any?)
	local clock = Harness.ManualClock(100)
	local Agent = Harness.Load("lib/Agent.luau", {
		globals = { os = clock.os },
		services = { RunService = { Heartbeat = Harness.ManualHeartbeat() } },
	})

	local log = {}
	local mover = Fakes.Mover(Vector3.new(0, 0, 0))
	local agent = Agent.new({
		Entity = Fakes.Entity(),
		Brain = {
			Initial = "Test",
			States = {
				Test = state,
				[NEXT] = {
					Enter = function()
						table.insert(log, "next")
					end,
				},
			},
		},
		Pathfinder = Fakes.Pathfinder(plan),
		Mover = mover,
		Data = data,
		Blackboard = blackboard,
	})

	local s = {
		agent = agent,
		mover = mover,
		clock = clock,
		log = log,
	}

	--[[
		The last target the navigator was sent to.
	]]
	function s.target(_self): any
		local path = mover.Followed[#mover.Followed]
		return if path then path[#path].Position else nil
	end

	--[[
		The fake mover reaches the end of its path, right on the target.
	]]
	function s.arrive(self)
		mover.Position = self:target()
		mover:Finish(true)
	end

	return s
end

local function loadStates()
	return Harness.Load("lib/Brain/States.luau")
end

local function flat(a: any, b: any): number
	return (Vector3.new(a.X, 0, a.Z) - Vector3.new(b.X, 0, b.Z)).Magnitude
end

return {
	["RandomPoint stays within the radius at the centre's height"] = function(expect)
		local States = loadStates()
		local random = Harness.FakeRandom.new(3)
		local centre = Vector3.new(10, 5, -4)
		for _ = 1, 50 do
			local point = States.RandomPoint(random, centre, 12)
			expect.truthy(flat(point, centre) <= 12 + 1e-6, "inside the radius")
			expect.equal(point.Y, 5)
		end
	end,

	["Patrol walks the points in a loop and resumes its leg after leaving"] = function(expect)
		local States = loadStates()
		local nodes = { Vector3.new(10, 0, 0), Vector3.new(20, 0, 0), Vector3.new(30, 0, 0) }
		local s = setup(States.Patrol({ Points = "Nodes", Speed = 7 }), { Nodes = nodes })

		s.agent:Start(true)
		expect.equal(s:target(), nodes[1])
		expect.equal(s.mover.Speed, 7, "Speed set on entry")

		s.agent:Step(0.1)
		expect.equal(#s.mover.Followed, 1, "still walking")
		s:arrive()
		s.agent:Step(0.1)
		expect.equal(s:target(), nodes[2])
		s:arrive()
		s.agent:Step(0.1)
		expect.equal(s:target(), nodes[3])
		s:arrive()
		s.agent:Step(0.1)
		expect.equal(s:target(), nodes[1], "looped")
		expect.equal(s.agent.Data.Patrol.Index, 1)

		s.agent:SetState(NEXT)
		s.agent:SetState("Test")
		expect.equal(s:target(), nodes[1], "re-entering resumes the current leg")
	end,

	["Patrol skips a point the navigator cannot reach"] = function(expect)
		local States = loadStates()
		local nodes = { Vector3.new(10, 0, 0), Vector3.new(20, 0, 0) }
		local s = setup(States.Patrol({ Points = nodes }), nil, nil, function(from, to)
			if to == nodes[1] then
				return nil, "inside a wall"
			end
			return { { Position = from, Action = "Walk" }, { Position = to, Action = "Walk" } }
		end)

		s.agent:Start(true)
		expect.equal(s.agent:GetPathStatus(), "Failed")
		s.agent:Step(0.1)
		expect.equal(s:target(), nodes[2], "moved on to the next point")
		expect.equal(s.agent:GetPathStatus(), "Moving")
	end,

	["Patrol with PingPong turns around at the ends"] = function(expect)
		local States = loadStates()
		local nodes = { Vector3.new(10, 0, 0), Vector3.new(20, 0, 0), Vector3.new(30, 0, 0) }
		local s = setup(States.Patrol({ Points = nodes, Order = "PingPong" }))

		s.agent:Start(true)
		local visited = { s:target() }
		for _ = 1, 5 do
			s:arrive()
			s.agent:Step(0.1)
			table.insert(visited, s:target())
		end
		expect.sequence(visited, { nodes[1], nodes[2], nodes[3], nodes[2], nodes[1], nodes[2] })
	end,

	["Patrol with Random order never picks the point it is at"] = function(expect)
		local States = loadStates()
		local nodes = { Vector3.new(10, 0, 0), Vector3.new(20, 0, 0), Vector3.new(30, 0, 0) }
		local s = setup(States.Patrol({ Points = nodes, Order = "Random" }), { Random = Harness.FakeRandom.new(9) })

		s.agent:Start(true)
		local previous = s:target()
		for _ = 1, 12 do
			s:arrive()
			s.agent:Step(0.1)
			local current = s:target()
			expect.truthy(current ~= previous, "a different point each time")
			previous = current
		end
	end,

	["Patrol pauses at each point for Pause seconds"] = function(expect)
		local States = loadStates()
		local nodes = { Vector3.new(10, 0, 0), Vector3.new(20, 0, 0) }
		local s = setup(States.Patrol({ Points = nodes, Pause = 2 }))

		s.agent:Start(true)
		s:arrive()
		s.agent:Step(0.1)
		expect.equal(#s.mover.Followed, 1, "standing at the first point")
		s.clock:Advance(1.9)
		s.agent:Step(0.1)
		expect.equal(#s.mover.Followed, 1, "still pausing")
		s.clock:Advance(0.2)
		s.agent:Step(0.1)
		expect.equal(s:target(), nodes[2], "moved on after the pause")
	end,

	["Patrol accepts a function for its points and requires them"] = function(expect)
		local States = loadStates()
		local s = setup(
			States.Patrol({
				Points = function(agent)
					return { agent.Data.Only }
				end,
			}),
			{ Only = Vector3.new(4, 0, 4) }
		)
		s.agent:Start(true)
		expect.equal(s:target(), Vector3.new(4, 0, 4))

		local message = expect.errors(function()
			States.Patrol({} :: any)
		end)
		expect.includes(message, "Points is required")
		message = expect.errors(function()
			States.Patrol({ Points = {}, Speeed = 3 } :: any)
		end)
		expect.includes(message, 'unknown option "Speeed"')
	end,

	["Investigate goes to the blackboard position, lingers, then moves on"] = function(expect)
		local States = loadStates()
		local s = setup(
			States.Investigate({ Target = "HeardPosition", Linger = 1, Then = NEXT, Acknowledge = "HeardAt" }),
			nil,
			{ HeardPosition = Vector3.new(15, 0, 0), HeardAt = 99 }
		)

		s.agent:Start(true)
		expect.equal(s:target(), Vector3.new(15, 0, 0))
		expect.falsy(s.agent:IsNew("HeardAt"), "acknowledged on entry")

		s.agent:Step(0.1)
		expect.equal(s.agent:GetState(), "Test")
		s:arrive()
		s.agent:Step(0.1)
		expect.equal(s.agent:GetState(), "Test", "lingering")
		s.clock:Advance(1.1)
		s.agent:Step(0.1)
		expect.equal(s.agent:GetState(), NEXT)
	end,

	["Investigate with no position to go to moves on at once"] = function(expect)
		local States = loadStates()
		local s = setup(States.Investigate({ Target = "HeardPosition", Then = NEXT }))

		s.agent:Start(true)
		expect.equal(#s.mover.Followed, 0)
		s.agent:Step(0.1)
		expect.equal(s.agent:GetState(), NEXT)
	end,

	["Search walks random points around the spot until the time is up"] = function(expect)
		local States = loadStates()
		local centre = Vector3.new(50, 0, 50)
		local s = setup(
			States.Search({ Around = "SeenPosition", Radius = 10, Points = 3, Duration = 5, Then = NEXT }),
			{ Random = Harness.FakeRandom.new(4) },
			{ SeenPosition = centre }
		)

		s.agent:Start(true)
		local points = s.agent.Data.Search.Points
		expect.equal(#points, 3)
		for _, point in points do
			expect.truthy(flat(point, centre) <= 10 + 1e-6, "within the radius")
		end
		expect.equal(s:target(), points[1])

		s:arrive()
		s.agent:Step(0.1)
		expect.equal(s:target(), points[2])
		s:arrive()
		s.agent:Step(0.1)
		expect.equal(s:target(), points[3])
		s:arrive()
		s.agent:Step(0.1)
		expect.equal(s:target(), points[1], "cycles")

		s.clock:Advance(5.1)
		s.agent:Step(0.1)
		expect.equal(s.agent:GetState(), NEXT)
	end,

	["Search without a spot searches around the agent"] = function(expect)
		local States = loadStates()
		local s = setup(States.Search({ Radius = 4, Points = 2 }), { Random = Harness.FakeRandom.new(1) })
		s.mover.Position = Vector3.new(7, 0, 7)

		s.agent:Start(true)
		expect.equal(s.agent.Data.Search.Centre, Vector3.new(7, 0, 7))
	end,

	["Wander drifts around home and pauses between points"] = function(expect)
		local States = loadStates()
		local s = setup(States.Wander({ Radius = 6, Pause = 1 }), { Random = Harness.FakeRandom.new(2) })
		s.mover.Position = Vector3.new(3, 0, 3)

		s.agent:Start(true)
		expect.equal(s.agent.Data.Wander.Home, Vector3.new(3, 0, 3), "home is where it first stood")
		local first = s:target()
		expect.truthy(flat(first, s.agent.Data.Wander.Home) <= 6 + 1e-6)

		s:arrive()
		s.agent:Step(0.1)
		expect.equal(#s.mover.Followed, 1, "pausing")
		s.clock:Advance(1.1)
		s.agent:Step(0.1)
		expect.equal(#s.mover.Followed, 2, "next point")
		expect.truthy(flat(s:target(), s.agent.Data.Wander.Home) <= 6 + 1e-6)
	end,

	["Wander with a Home key keeps to it"] = function(expect)
		local States = loadStates()
		local s = setup(States.Wander({ Home = "Home", Radius = 2 }), { Home = Vector3.new(100, 0, 100) })

		s.agent:Start(true)
		expect.truthy(flat(s:target(), Vector3.new(100, 0, 100)) <= 2 + 1e-6)
	end,

	["Wait stops the mover and moves on after Duration"] = function(expect)
		local States = loadStates()
		local s = setup(States.Wait({ Duration = 3, Then = NEXT }))
		s.agent:Start(true)
		-- Give it a path to stop first.
		s.agent:SetState(NEXT)
		s.agent:MoveTo(Vector3.new(9, 0, 9))
		expect.truthy(s.mover.Moving)
		s.agent:SetState("Test")
		expect.falsy(s.mover.Moving, "stopped on entry")

		s.agent:Step(0.1)
		expect.equal(s.agent:GetState(), "Test")
		s.clock:Advance(3.1)
		s.agent:Step(0.1)
		expect.equal(s.agent:GetState(), NEXT)
	end,

	["the hooks and Transitions are honoured"] = function(expect)
		local States = loadStates()
		local log = {}
		local s = setup(States.Wait({
			Enter = function()
				table.insert(log, "enter")
			end,
			Exit = function()
				table.insert(log, "exit")
			end,
			Transitions = {
				{
					To = NEXT,
					When = function(agent)
						return agent.Blackboard.Go == true
					end,
				},
			},
		}))

		s.agent:Start(true)
		s.agent:Step(0.1)
		expect.equal(s.agent:GetState(), "Test")
		s.agent.Blackboard.Go = true
		s.agent:Step(0.1)
		expect.equal(s.agent:GetState(), NEXT)
		expect.sequence(log, { "enter", "exit" })
	end,

	["Roam walks the best interest point, lingers, marks it visited and moves on"] = function(expect)
		local States = loadStates()
		local Interest = Harness.Load("lib/Interest.luau")
		local interest = Interest.new({ Decay = 0, Visited = 100 })
		interest:Add("near", { Position = Vector3.new(10, 0, 0) })
		interest:Add("far", { Position = Vector3.new(30, 0, 0) })
		local s = setup(States.Roam({ Interest = interest, Linger = 1, Then = NEXT }))

		s.agent:Start(true)
		expect.equal(s:target(), Vector3.new(10, 0, 0), "nearest first")
		s:arrive()
		s.agent:Step(0.1)
		expect.equal(#s.mover.Followed, 1, "lingering")
		s.clock:Advance(1.1)
		s.agent:Step(0.1)
		expect.equal(s:target(), Vector3.new(30, 0, 0), "the near point is visited; the far one is next")
		expect.equal(interest:SinceVisit(s.agent, "near") < 5, true)

		s:arrive()
		s.agent:Step(0.1)
		s.clock:Advance(1.1)
		s.agent:Step(0.1)
		expect.equal(s.agent:GetState(), NEXT, "nothing left worth a look")
	end,

	["Roam leaves on Duration and needs an Interest"] = function(expect)
		local States = loadStates()
		local Interest = Harness.Load("lib/Interest.luau")
		local interest = Interest.new()
		interest:Add("a", { Position = Vector3.new(10, 0, 0) })
		local s = setup(States.Roam({ Interest = interest, Duration = 5, Then = NEXT }))

		s.agent:Start(true)
		s.agent:Step(0.1)
		expect.equal(s.agent:GetState(), "Test")
		s.clock:Advance(5.1)
		s.agent:Step(0.1)
		expect.equal(s.agent:GetState(), NEXT)

		expect.includes(
			expect.errors(function()
				States.Roam({ Then = NEXT } :: any)
			end),
			"Interest must be an Interest map"
		)
	end,
}
