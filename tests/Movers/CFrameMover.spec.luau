--!strict

--[[
	The CFrame mover: `Advance` as pure maths with real CFrames from Lune's roblox library, then
	Follow, Stop and the Arrived/StepReached ordering end to end against a plain pivot table and a
	manual Heartbeat.
]]

local Harness = require("../Support/Harness")

local roblox = require("@lune/roblox")
local CFrame = roblox.CFrame
local Vector3 = roblox.Vector3

local function load(heartbeat: any?)
	return Harness.Load("lib/Movers/CFrameMover.luau", {
		services = { RunService = { Heartbeat = heartbeat or Harness.ManualHeartbeat() } },
	})
end

--[[
	A stand-in for anything with a pivot. Records every PivotTo.
]]
local function fakePivot(position: any)
	local pivot = { Pivot = CFrame.new(position), Moves = 0 }

	function pivot.GetPivot(self)
		return self.Pivot
	end

	function pivot.PivotTo(self, cframe)
		self.Pivot = cframe
		self.Moves += 1
	end

	return pivot
end

local function step(x: number, y: number, z: number, label: string?)
	return { Position = Vector3.new(x, y, z), Action = "Walk", Label = label }
end

local function setup(options: any?, position: any?)
	local heartbeat = Harness.ManualHeartbeat()
	local CFrameMover = load(heartbeat)
	local pivot = fakePivot(position or Vector3.new(0, 0, 0))
	local mover = CFrameMover.new(pivot, options)

	local events = {}
	mover.Arrived:Connect(function(reached)
		table.insert(events, `arrived {tostring(reached)}`)
	end)
	mover.StepReached:Connect(function(index, reachedStep)
		table.insert(events, `step {index}{if reachedStep.Label then " " .. reachedStep.Label else ""}`)
	end)

	return {
		CFrameMover = CFrameMover,
		heartbeat = heartbeat,
		pivot = pivot,
		mover = mover,
		events = events,
	}
end

local function expectVector(expect, actual: any, x: number, y: number, z: number, label: string)
	expect.near(actual.X, x, 1e-4, `{label}.X`)
	expect.near(actual.Y, y, 1e-4, `{label}.Y`)
	expect.near(actual.Z, z, 1e-4, `{label}.Z`)
end

return {
	------------------------------------------------------------------------------------------------------------------
	-- Advance
	------------------------------------------------------------------------------------------------------------------

	["Advance moves speed * dt toward the target"] = function(expect)
		local CFrameMover = load()
		local pivot, reached = CFrameMover.Advance(CFrame.new(0, 0, 0), Vector3.new(10, 0, 0), 8, 10, 0.5)
		expectVector(expect, pivot.Position, 4, 0, 0, "position")
		expect.falsy(reached)
	end,

	["Advance moves along a diagonal, including height"] = function(expect)
		local CFrameMover = load()
		local pivot, reached = CFrameMover.Advance(CFrame.new(0, 0, 0), Vector3.new(3, 4, 0), 1, 10, 1)
		expectVector(expect, pivot.Position, 0.6, 0.8, 0, "position")
		expect.falsy(reached)
	end,

	["Advance does not overshoot and lands exactly on the target"] = function(expect)
		local CFrameMover = load()
		local target = Vector3.new(10, 0, 0)
		local pivot, reached = CFrameMover.Advance(CFrame.new(0, 0, 0), target, 8, 10, 2)
		expect.equal(pivot.Position, target)
		expect.truthy(reached)
	end,

	["Advance reaches exactly when the remaining distance equals the reach"] = function(expect)
		local CFrameMover = load()
		local target = Vector3.new(4, 0, 0)
		local pivot, reached = CFrameMover.Advance(CFrame.new(0, 0, 0), target, 8, 10, 0.5)
		expect.equal(pivot.Position, target)
		expect.truthy(reached)
	end,

	["Advance handles a zero-length move and keeps the facing"] = function(expect)
		local CFrameMover = load()
		local start = CFrame.new(Vector3.new(1, 2, 3)) * CFrame.Angles(0, 1, 0)
		local pivot, reached = CFrameMover.Advance(start, Vector3.new(1, 2, 3), 8, 10, 0.1)
		expect.equal(pivot.Position, Vector3.new(1, 2, 3))
		expect.truthy(reached)
		expectVector(expect, pivot.LookVector, start.LookVector.X, 0, start.LookVector.Z, "look")
	end,

	["Advance with zero time goes nowhere and is not reached"] = function(expect)
		local CFrameMover = load()
		local pivot, reached = CFrameMover.Advance(CFrame.new(0, 0, 0), Vector3.new(10, 0, 0), 8, 10, 0)
		expect.equal(pivot.Position, Vector3.new(0, 0, 0))
		expect.falsy(reached)
	end,

	["Advance turns gradually by at most turnSpeed * dt"] = function(expect)
		local CFrameMover = load()
		-- Facing -Z (yaw 0); travelling +X wants yaw -pi/2. One radian per second for half a second.
		local pivot = CFrameMover.Advance(CFrame.new(0, 0, 0), Vector3.new(100, 0, 0), 1, 1, 0.5)
		expectVector(expect, pivot.LookVector, math.sin(0.5), 0, -math.cos(0.5), "look")
	end,

	["Advance faces the direction of travel once aligned"] = function(expect)
		local CFrameMover = load()
		local pivot = CFrameMover.Advance(CFrame.new(0, 0, 0), Vector3.new(100, 0, 100), 1, 10, 1)
		local wanted = Vector3.new(1, 0, 1).Unit
		expectVector(expect, pivot.LookVector, wanted.X, 0, wanted.Z, "look")
		expectVector(expect, pivot.UpVector, 0, 1, 0, "up")
	end,

	["Advance turns the short way round"] = function(expect)
		local CFrameMover = load()
		-- Facing yaw 3 rad; travelling toward yaw -3 rad is 0.283 rad further on, not 6 rad back.
		local start = CFrame.new(0, 0, 0) * CFrame.Angles(0, 3, 0)
		local target = Vector3.new(-math.sin(-3), 0, -math.cos(-3)) * 100
		local pivot = CFrameMover.Advance(start, target, 1, 1, 0.1)
		expectVector(expect, pivot.LookVector, -math.sin(3.1), 0, -math.cos(3.1), "look")
	end,

	["Advance ignores pitch and keeps the pivot upright"] = function(expect)
		local CFrameMover = load()
		local pitched = CFrame.new(0, 0, 0) * CFrame.Angles(0.7, 0, 0)
		local pivot = CFrameMover.Advance(pitched, Vector3.new(0, 0, -100), 1, 10, 0.1)
		expectVector(expect, pivot.LookVector, 0, 0, -1, "look")
		expectVector(expect, pivot.UpVector, 0, 1, 0, "up")
		expectVector(expect, pivot.Position, 0, 0, -0.1, "position")
	end,

	["Advance keeps the facing on a purely vertical move"] = function(expect)
		local CFrameMover = load()
		local start = CFrame.new(0, 0, 0) * CFrame.Angles(0, 1, 0)
		local pivot = CFrameMover.Advance(start, Vector3.new(0, 10, 0), 1, 10, 0.5)
		expectVector(expect, pivot.LookVector, start.LookVector.X, 0, start.LookVector.Z, "look")
		expectVector(expect, pivot.Position, 0, 0.5, 0, "position")
	end,

	------------------------------------------------------------------------------------------------------------------
	-- Follow, Stop and the signals
	------------------------------------------------------------------------------------------------------------------

	["the default options are as documented"] = function(expect)
		local s = setup()
		expect.equal(s.mover:GetSpeed(), 8)

		s.mover:Follow({ step(100, 0, 0) })
		s.heartbeat:Fire(1)
		expectVector(expect, s.pivot.Pivot.Position, 8, 0, 0, "8 studs per second, no height offset")

		s.mover:SetSpeed(2)
		expect.equal(s.mover:GetSpeed(), 2)
		s.heartbeat:Fire(1)
		expectVector(expect, s.pivot.Pivot.Position, 10, 0, 0, "SetSpeed applies")
	end,

	["Follow walks each step in order and fires Arrived(true) after the last, on a heartbeat"] = function(expect)
		local s = setup({ Speed = 10 })

		s.mover:Follow({ step(10, 0, 0, "a"), step(10, 0, 10, "b") })
		expect.sequence(s.events, {}, "nothing is reported from inside Follow")
		expect.truthy(s.mover:IsMoving())

		s.heartbeat:Fire(0.5)
		expect.sequence(s.events, {}, "half way to the first step")
		s.heartbeat:Fire(0.5)
		expect.sequence(s.events, { "step 1 a" })
		expectVector(expect, s.pivot.Pivot.Position, 10, 0, 0, "on the first step")

		s.heartbeat:Fire(1)
		expect.sequence(s.events, { "step 1 a", "step 2 b", "arrived true" })
		expect.falsy(s.mover:IsMoving())
		expect.equal(s.heartbeat:Count(), 0, "the heartbeat is disconnected once the path is done")
		expectVector(expect, s.mover:GetPosition(), 10, 0, 10, "GetPosition reads the pivot")
	end,

	["Follow fires Arrived(false) for the path it replaces before the new one starts"] = function(expect)
		local s = setup({ Speed = 1 })

		s.mover:Follow({ step(100, 0, 0, "old") })
		s.heartbeat:Fire(1)
		s.mover:Follow({ step(0, 0, 100, "new") })
		expect.sequence(s.events, { "arrived false" }, "the old path is reported, synchronously, and nothing else")
		expect.truthy(s.mover:IsMoving())
		expect.equal(s.heartbeat:Count(), 1, "one heartbeat connection, not two")

		s.heartbeat:Fire(100)
		expect.sequence(s.events, { "arrived false", "step 1 new", "arrived true" })
	end,

	["Stop fires Arrived(false) once and a second Stop does nothing"] = function(expect)
		local s = setup()

		s.mover:Follow({ step(100, 0, 0) })
		s.heartbeat:Fire(0.1)
		s.mover:Stop()
		expect.sequence(s.events, { "arrived false" })
		expect.falsy(s.mover:IsMoving())
		expect.equal(s.heartbeat:Count(), 0)

		s.mover:Stop()
		s.heartbeat:Fire(1)
		expect.sequence(s.events, { "arrived false" })
		expect.equal(s.pivot.Moves, 1, "no movement after Stop")
	end,

	["Stop before any heartbeat still reports the path"] = function(expect)
		local s = setup()
		s.mover:Follow({ step(100, 0, 0) })
		s.mover:Stop()
		expect.sequence(s.events, { "arrived false" })
	end,

	["a zero-step path fires Arrived(false) on the next heartbeat, never inside Follow"] = function(expect)
		local s = setup()

		s.mover:Follow({})
		expect.sequence(s.events, {})
		expect.truthy(s.mover:IsMoving())

		s.heartbeat:Fire(0.1)
		expect.sequence(s.events, { "arrived false" })
		expect.falsy(s.mover:IsMoving())
		expect.equal(s.pivot.Moves, 0)
	end,

	["HeightOffset is added to every step"] = function(expect)
		local s = setup({ HeightOffset = 2.5, Speed = 100 })

		s.mover:Follow({ step(5, 0, 0), step(10, 1, 0) })
		s.heartbeat:Fire(1)
		expectVector(expect, s.pivot.Pivot.Position, 5, 2.5, 0, "first step")
		s.heartbeat:Fire(1)
		expectVector(expect, s.pivot.Pivot.Position, 10, 3.5, 0, "second step")
		expect.sequence(s.events, { "step 1", "step 2", "arrived true" })
	end,

	["ArriveDistance counts a step as reached horizontally before the pivot lands on it"] = function(expect)
		local s = setup({ ArriveDistance = 1, Speed = 1 })

		s.mover:Follow({ step(2, 0, 0) })
		s.heartbeat:Fire(1)
		expect.sequence(s.events, { "step 1", "arrived true" })
		expectVector(expect, s.pivot.Pivot.Position, 1, 0, 0, "stopped a stud short")
	end,

	["a leading step at the pivot's own position is reached on the first heartbeat"] = function(expect)
		local s = setup({ Speed = 100 })

		s.mover:Follow({ step(0, 0, 0, "here"), step(10, 0, 0, "there") })
		s.heartbeat:Fire(0.01)
		expect.sequence(s.events, { "step 1 here" })
		s.heartbeat:Fire(1)
		expect.sequence(s.events, { "step 1 here", "step 2 there", "arrived true" })
	end,

	["the pivot turns toward the direction of travel over several heartbeats"] = function(expect)
		local s = setup({ Speed = 1, TurnSpeed = 1 })

		s.mover:Follow({ step(100, 0, 0) })
		s.heartbeat:Fire(0.5)
		expectVector(expect, s.pivot.Pivot.LookVector, math.sin(0.5), 0, -math.cos(0.5), "half a radian")
		s.heartbeat:Fire(0.5)
		s.heartbeat:Fire(0.5)
		s.heartbeat:Fire(0.5)
		expectVector(expect, s.pivot.Pivot.LookVector, 1, 0, 0, "aligned")
	end,

	["a StepReached handler may call Follow again without a double report"] = function(expect)
		local s = setup({ Speed = 100 })
		local replaced = false
		s.mover.StepReached:Connect(function(index)
			if index == 1 and not replaced then
				replaced = true
				s.mover:Follow({ step(50, 0, 0, "detour") })
			end
		end)

		s.mover:Follow({ step(10, 0, 0, "a"), step(20, 0, 0, "b") })
		s.heartbeat:Fire(1)
		expect.sequence(s.events, { "step 1 a", "arrived false" }, "the first path is replaced from its own step")
		s.heartbeat:Fire(1)
		expect.sequence(s.events, { "step 1 a", "arrived false", "step 1 detour", "arrived true" })
	end,

	["Destroy stops, reports the path and ignores later calls"] = function(expect)
		local s = setup()

		s.mover:Follow({ step(100, 0, 0) })
		s.mover:Destroy()
		expect.sequence(s.events, { "arrived false" })
		expect.equal(s.heartbeat:Count(), 0)

		s.mover:Follow({ step(100, 0, 0) })
		expect.falsy(s.mover:IsMoving())
		s.heartbeat:Fire(1)
		expect.equal(s.pivot.Moves, 0)
		s.mover:Destroy()
	end,

	["new refuses something without a pivot"] = function(expect)
		local CFrameMover = load()
		local message = expect.errors(function()
			CFrameMover.new({} :: any)
		end)
		expect.includes(message, "[VluxyAI]")
		expect.includes(message, "GetPivot")
	end,
}
