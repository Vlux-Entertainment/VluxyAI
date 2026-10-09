--!strict

--[[
	The Record mover: a pivot in a table, moved only by Step. Loaded without any RunService, so a
	Record that reached for Heartbeat would fail here rather than in a game.
]]

local Harness = require("../Support/Harness")

local roblox = require("@lune/roblox")
local Vector3 = roblox.Vector3

local function load()
	return Harness.Load("lib/Movers/Record.luau")
end

local function step(x: number, y: number, z: number)
	return { Position = Vector3.new(x, y, z), Action = "Walk" }
end

local function expectVector(expect, actual: any, x: number, y: number, z: number, label: string)
	expect.near(actual.X, x, 1e-4, `{label}.X`)
	expect.near(actual.Y, y, 1e-4, `{label}.Y`)
	expect.near(actual.Z, z, 1e-4, `{label}.Z`)
end

return {
	["new needs a Position"] = function(expect)
		local Record = load()
		local message = expect.errors(function()
			Record.new({} :: any)
		end)
		expect.includes(message, "[VluxyAI]")
		expect.includes(message, "Record.new: options.Position (a Vector3) is required")
	end,

	["new refuses Manual and unknown options"] = function(expect)
		local Record = load()
		local manual = expect.errors(function()
			Record.new({ Position = Vector3.new(0, 0, 0), Manual = false } :: any)
		end)
		expect.includes(manual, "Manual is always on")

		local typo = expect.errors(function()
			Record.new({ Position = Vector3.new(0, 0, 0), Speeed = 3 } :: any)
		end)
		expect.includes(typo, 'unknown option "Speeed"')
	end,

	["the pivot starts at Position facing Yaw"] = function(expect)
		local Record = load()
		local mover = Record.new({ Position = Vector3.new(1, 2, 3), Yaw = math.pi / 2 }) :: any
		local pivot = mover:GetPivot()
		expectVector(expect, pivot.Position, 1, 2, 3, "position")
		expectVector(expect, mover:GetPosition(), 1, 2, 3, "GetPosition")
		-- Yaw pi/2 turns -Z toward -X.
		expectVector(expect, pivot.LookVector, -1, 0, 0, "look")
	end,

	["it only moves when stepped, and reports on a later step"] = function(expect)
		local Record = load()
		local mover = Record.new({ Position = Vector3.new(0, 0, 0), Speed = 10 }) :: any
		expect.equal(type(mover.Step), "function")

		local events = {}
		mover.Arrived:Connect(function(reached)
			table.insert(events, `arrived {tostring(reached)}`)
		end)
		mover.StepReached:Connect(function(index)
			table.insert(events, `step {index}`)
		end)

		mover:Follow({ step(5, 0, 0), step(10, 0, 0) })
		expect.equal(#events, 0, "nothing from inside Follow")
		expectVector(expect, mover:GetPosition(), 0, 0, 0, "unmoved before Step")
		expect.truthy(mover:IsMoving())

		mover:Step(0.5)
		expectVector(expect, mover:GetPosition(), 5, 0, 0, "half a second at 10")
		mover:Step(0.5)
		expectVector(expect, mover:GetPosition(), 10, 0, 0, "the end")
		expect.sequence(events, { "step 1", "step 2", "arrived true" })
		expect.falsy(mover:IsMoving())
	end,

	["HeightOffset defaults to 0, so the pivot rides the floor steps"] = function(expect)
		local Record = load()
		local mover = Record.new({ Position = Vector3.new(0, 3, 0), Speed = 100 }) :: any
		mover:Follow({ step(4, 0, 0) })
		mover:Step(1)
		expectVector(expect, mover:GetPosition(), 4, 0, 0, "on the floor step")
	end,

	["walking turns the yaw toward the direction of travel"] = function(expect)
		local Record = load()
		local mover = Record.new({ Position = Vector3.new(0, 0, 0), Speed = 1, TurnSpeed = 100 }) :: any
		mover:Follow({ step(10, 0, 0) })
		mover:Step(0.1)
		expectVector(expect, mover:GetPivot().LookVector, 1, 0, 0, "facing +X")
	end,

	["Face turns in place on Step while no path runs"] = function(expect)
		local Record = load()
		local mover = Record.new({ Position = Vector3.new(0, 0, 0), TurnSpeed = 100 }) :: any
		mover:Face(Vector3.new(0, 0, 10))
		mover:Step(0.1)
		expectVector(expect, mover:GetPivot().LookVector, 0, 0, 1, "facing +Z")
		expectVector(expect, mover:GetPosition(), 0, 0, 0, "did not move")
	end,

	["Teleport drops the path and keeps the facing"] = function(expect)
		local Record = load()
		local mover = Record.new({ Position = Vector3.new(0, 0, 0), Yaw = math.pi }) :: any
		local results = {}
		mover.Arrived:Connect(function(reached)
			table.insert(results, reached)
		end)
		mover:Follow({ step(10, 0, 0) })
		mover:Teleport(Vector3.new(50, 0, 50))

		expect.sequence(results, { false })
		expectVector(expect, mover:GetPosition(), 50, 0, 50, "teleported")
		expectVector(expect, mover:GetPivot().LookVector, 0, 0, 1, "still facing +Z")
		mover:Step(1)
		expectVector(expect, mover:GetPosition(), 50, 0, 50, "no path left")
	end,

	["a destroyed Record ignores Step"] = function(expect)
		local Record = load()
		local mover = Record.new({ Position = Vector3.new(0, 0, 0) }) :: any
		mover:Follow({ step(10, 0, 0) })
		mover:Destroy()
		mover:Step(1)
		expectVector(expect, mover:GetPosition(), 0, 0, 0, "unmoved")
	end,

	["a CFrameMover on Heartbeat has no Step, so an agent never moves it twice"] = function(expect)
		local CFrameMover = Harness.Load("lib/Movers/CFrameMover.luau", {
			services = { RunService = { Heartbeat = Harness.ManualHeartbeat() } },
		})
		local holder = {
			Pivot = roblox.CFrame.new(0, 0, 0),
			GetPivot = function(self)
				return self.Pivot
			end,
			PivotTo = function(self, cframe)
				self.Pivot = cframe
			end,
		}
		local mover = CFrameMover.new(holder :: any) :: any
		expect.equal(mover.Step, nil)
		expect.equal(type(mover.GetPivot), "function")
	end,
}
