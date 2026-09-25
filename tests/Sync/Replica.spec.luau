--!strict

--[[
	The client replica: visual states following SetState, event dispatch, puppet smoothing toward
	streamed positions, and mirror mode leaving the rig alone.
]]

local Harness = require("../Support/Harness")

local roblox = require("@lune/roblox")
local task = require("@lune/task")
local CFrame = roblox.CFrame
local Vector3 = roblox.Vector3

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

local function setup(options: any?, visuals: any?)
	local heartbeat = Harness.ManualHeartbeat()
	local Replica = Harness.Load("lib/Sync/Replica.luau", {
		services = { RunService = { Heartbeat = heartbeat } },
	})
	local pivot = fakePivot(Vector3.new(0, 0, 0))
	local resolved = options or {}
	resolved.Entity = pivot
	resolved.Visuals = visuals
	local replica = Replica.new(resolved)
	return { Replica = Replica, replica = replica, pivot = pivot, heartbeat = heartbeat }
end

return {
	["SetState runs Exit then Enter of the matching visuals and fires StateChanged"] = function(expect)
		local log = {}
		local s = setup(nil, {
			Idle = {
				Enter = function()
					table.insert(log, "enter Idle")
				end,
				Exit = function()
					table.insert(log, "exit Idle")
				end,
			},
			Hunt = {
				Enter = function(replica)
					table.insert(log, `enter Hunt as {replica:GetState()}`)
				end,
			},
		})
		local changes = {}
		s.replica.StateChanged:Connect(function(new, old)
			table.insert(changes, `{tostring(old)}->{new}`)
		end)

		s.replica:SetState("Idle")
		s.replica:SetState("Hunt")
		s.replica:SetState("Nothing")
		expect.sequence(log, { "enter Idle", "exit Idle", "enter Hunt as Hunt" })
		expect.sequence(changes, { "nil->Idle", "Idle->Hunt", "Hunt->Nothing" })
		expect.equal(s.replica:GetState(), "Nothing", "a state with no visuals is tracked")
	end,

	["Update runs each frame for the current visual state only"] = function(expect)
		local updates = 0
		local s = setup(nil, {
			Hunt = {
				Update = function(_replica, deltaTime)
					updates += deltaTime
				end,
			},
		})

		s.heartbeat:Fire(0.1)
		s.replica:SetState("Hunt")
		s.heartbeat:Fire(0.1)
		s.heartbeat:Fire(0.2)
		s.replica:SetState("Idle")
		s.heartbeat:Fire(0.1)
		expect.near(updates, 0.3)
	end,

	["On handlers receive events and Events fires for all of them"] = function(expect)
		local s = setup()
		local got = {}
		s.replica.Events:Connect(function(name, payload)
			table.insert(got, `any:{name}:{payload.X}`)
		end)
		local connection = s.replica:On("Kill", function(payload)
			table.insert(got, `kill:{payload.X}`)
		end)

		s.replica:Receive("Kill", { X = 1 })
		s.replica:Receive("Scream", { X = 2 })
		connection:Disconnect()
		s.replica:Receive("Kill", { X = 3 })
		task.wait()
		table.sort(got)
		expect.sequence(got, { "any:Kill:1", "any:Kill:3", "any:Scream:2", "kill:1" })
	end,

	["mirror mode never moves the rig"] = function(expect)
		local s = setup()
		s.replica:SetPosition(Vector3.new(10, 0, 0), 0)
		s.heartbeat:Fire(0.1)
		s.heartbeat:Fire(1)
		expect.equal(s.pivot.Moves, 0)
	end,

	["puppet mode smooths toward the latest sample and turns to its yaw"] = function(expect)
		local s = setup({ Puppet = true, Smoothing = 10, TurnSmoothing = math.pi, HeightOffset = 3 })

		s.replica:SetPosition(Vector3.new(20, 0, 0), math.pi / 2)
		s.heartbeat:Fire(0.5)
		local position = s.pivot:GetPivot().Position
		expect.near(position.Magnitude, 5, 1e-4, "10 studs per second for half a second, toward the lifted target")
		expect.truthy(position.Y > 0, "HeightOffset lifts the target")

		local look = s.pivot:GetPivot().LookVector
		local yaw = math.atan2(-look.X, -look.Z)
		expect.near(yaw, math.pi / 2, 1e-3, "pi per second for half a second reaches pi/2")

		s.heartbeat:Fire(5)
		expect.near(s.pivot:GetPivot().Position.X, 20, 1e-4, "arrives and stops")
	end,

	["puppet mode with no smoothing snaps"] = function(expect)
		local s = setup({ Puppet = true, Smoothing = 0, TurnSmoothing = 0 })
		s.replica:SetPosition(Vector3.new(50, 0, 7), 1)
		s.heartbeat:Fire(0.01)
		local position = s.pivot:GetPivot().Position
		expect.near(position.X, 50, 1e-4)
		expect.near(position.Z, 7, 1e-4)
	end,

	["ApplySnapshot places a puppet at once and sets the state"] = function(expect)
		local log = {}
		local s = setup({ Puppet = true }, {
			Hunt = {
				Enter = function()
					table.insert(log, "enter Hunt")
				end,
			},
		})
		s.replica:ApplySnapshot({ State = "Hunt", Position = Vector3.new(30, 0, 0), Yaw = 0 })
		expect.near(s.pivot:GetPivot().Position.X, 30, 1e-4)
		expect.sequence(log, { "enter Hunt" })
	end,

	["Destroy exits the current visual state and ignores everything after"] = function(expect)
		local log = {}
		local s = setup(nil, {
			Hunt = {
				Enter = function()
					table.insert(log, "enter")
				end,
				Exit = function()
					table.insert(log, "exit")
				end,
			},
		})
		s.replica:SetState("Hunt")
		s.replica:Destroy()
		s.replica:SetState("Hunt")
		s.replica:Receive("Kill", {})
		expect.sequence(log, { "enter", "exit" })
		expect.equal(s.heartbeat:Count(), 0)
	end,

	["SetState from inside Exit does not run that Exit again, and an erroring Exit still moves on"] = function(expect)
		local warnings = {}
		local heartbeat = Harness.ManualHeartbeat()
		local Replica = Harness.Load("lib/Sync/Replica.luau", {
			services = { RunService = { Heartbeat = heartbeat } },
			warn = function(message)
				table.insert(warnings, tostring(message))
			end,
		})
		local log = {}
		local replica
		replica = Replica.new({
			Entity = fakePivot(Vector3.new()),
			Visuals = {
				A = {
					Exit = function()
						table.insert(log, "exit A")
						replica:SetState("C")
					end,
				},
				B = {
					Enter = function()
						table.insert(log, "enter B")
					end,
				},
				C = {
					Enter = function()
						table.insert(log, "enter C")
					end,
					Exit = function()
						error("broken")
					end,
				},
			},
		})

		replica:SetState("A")
		replica:SetState("B")
		expect.equal(replica:GetState(), "B", "the outer SetState still lands on B")
		expect.sequence(log, { "exit A", "enter C", "enter B" })

		replica:SetState("C")
		replica:SetState("A")
		expect.equal(replica:GetState(), "A", "an erroring Exit does not stick the replica")
		expect.equal(#warnings, 1)
		expect.includes(warnings[1], "broken")
	end,

	["a handler disconnected by an earlier handler in the same dispatch does not run"] = function(expect)
		local s = setup()
		local log = {}
		local second
		s.replica:On("Kill", function()
			table.insert(log, "first")
			second:Disconnect()
		end)
		second = s.replica:On("Kill", function()
			table.insert(log, "second")
		end)
		s.replica:Receive("Kill", {})
		task.wait()
		expect.sequence(log, { "first" })
	end,

	["an unknown option or a bad entity is refused"] = function(expect)
		local s = setup()
		local message = expect.errors(function()
			s.Replica.new({ Entity = s.pivot, Smoothng = 1 })
		end)
		expect.includes(message, 'Replica.new: unknown option "Smoothng"')

		message = expect.errors(function()
			s.Replica.new({ Entity = {} })
		end)
		expect.includes(message, "GetPivot and PivotTo")
	end,
}
