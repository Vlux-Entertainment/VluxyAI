--!strict

--[[
	The navigator: when it plans, when it does not, and how it reports. A manual clock drives the
	cadence and a fake mover reports arrivals, so every case is exact and instant.
]]

local Fakes = require("../Support/Fakes")
local Harness = require("../Support/Harness")

local roblox = require("@lune/roblox")
local task = require("@lune/task")
local Vector3 = roblox.Vector3

local function setup(options: { plan: any?, navigation: any?, warnings: { string }? }?)
	local resolved = options or {}
	local clock = Harness.ManualClock(100)
	local Navigator = Harness.Load("lib/Navigator.luau", {
		globals = { os = clock.os },
		warn = function(message)
			if resolved.warnings then
				table.insert(resolved.warnings, tostring(message))
			end
		end,
	})

	local pathfinder = Fakes.Pathfinder(resolved.plan)
	local mover = Fakes.Mover(Vector3.new(0, 0, 0))
	local agent = Fakes.Agent()
	local navigator = Navigator.new(pathfinder, mover, agent, resolved.navigation)

	local arrivals = {}
	navigator.Arrived:Connect(function(reached)
		table.insert(arrivals, reached)
	end)

	return {
		navigator = navigator,
		pathfinder = pathfinder,
		mover = mover,
		clock = clock,
		arrivals = arrivals,
	}
end

return {
	["a new target plans at once and follows the path"] = function(expect)
		local s = setup()
		local target = Vector3.new(10, 0, 0)

		s.navigator:MoveTo(target)
		expect.equal(#s.pathfinder.Calls, 1)
		expect.equal(s.pathfinder.Calls[1].To, target)
		expect.equal(#s.mover.Followed, 1)
		expect.equal(s.navigator:GetStatus(), "Moving")
		expect.equal(s.navigator:GetTarget(), target)
		expect.equal(s.navigator:GetPath(), s.mover.Followed[1])
	end,

	["the same target again does not re-plan"] = function(expect)
		local s = setup()
		local target = Vector3.new(10, 0, 0)

		s.navigator:MoveTo(target)
		s.clock:Advance(5)
		s.navigator:MoveTo(target)
		s.navigator:Step(0.1)
		expect.equal(#s.pathfinder.Calls, 1)
	end,

	["a target that moved within RepathDistance does not re-plan"] = function(expect)
		local s = setup({ navigation = { RepathDistance = 3 } })

		s.navigator:MoveTo(Vector3.new(10, 0, 0))
		s.clock:Advance(5)
		s.navigator:MoveTo(Vector3.new(12, 0, 0))
		expect.equal(#s.pathfinder.Calls, 1)
	end,

	["a target that moved past RepathDistance re-plans only after RepathInterval"] = function(expect)
		local s = setup({ navigation = { RepathDistance = 2, RepathInterval = 0.5 } })

		s.navigator:MoveTo(Vector3.new(10, 0, 0))
		s.clock:Advance(0.2)
		s.navigator:MoveTo(Vector3.new(20, 0, 0))
		expect.equal(#s.pathfinder.Calls, 1, "too soon")

		s.clock:Advance(0.4)
		s.navigator:MoveTo(Vector3.new(20, 0, 0))
		expect.equal(#s.pathfinder.Calls, 2, "interval elapsed")
		expect.equal(s.pathfinder.Calls[2].To, Vector3.new(20, 0, 0))
		expect.equal(#s.mover.Followed, 2, "the new path replaced the old one")
	end,

	["a failed plan reports Failed and Arrived(false) with a warning"] = function(expect)
		local warnings = {}
		local s = setup({
			plan = function()
				return nil, "no floor"
			end,
			warnings = warnings,
		})

		s.navigator:MoveTo(Vector3.new(10, 0, 0))
		expect.equal(s.navigator:GetStatus(), "Failed")
		expect.equal(#s.mover.Followed, 0)
		expect.sequence(s.arrivals, { false })
		expect.equal(#warnings, 1)
		expect.includes(warnings[1], "no floor")
		expect.equal(s.navigator:GetPath(), nil)
	end,

	["a failure warns once per target, not once per retry"] = function(expect)
		local warnings = {}
		local s = setup({
			plan = function()
				return nil, "blocked"
			end,
			warnings = warnings,
			navigation = { RepathInterval = 0.5 },
		})
		local target = Vector3.new(10, 0, 0)

		s.navigator:MoveTo(target)
		s.clock:Advance(1)
		s.navigator:MoveTo(target)
		s.clock:Advance(1)
		s.navigator:MoveTo(target)
		expect.equal(#s.pathfinder.Calls, 3)
		expect.equal(#warnings, 1)

		s.clock:Advance(1)
		s.navigator:MoveTo(Vector3.new(50, 0, 0))
		expect.equal(#warnings, 2, "a different target warns again")
	end,

	["an empty path counts as a failure"] = function(expect)
		local s = setup({
			plan = function()
				return {}
			end,
		})
		s.navigator:MoveTo(Vector3.new(10, 0, 0))
		expect.equal(s.navigator:GetStatus(), "Failed")
	end,

	["a failed plan is retried on the cadence while MoveTo keeps coming"] = function(expect)
		local attempts = 0
		local s = setup({
			plan = function(_from, to)
				attempts += 1
				if attempts == 1 then
					return nil, "blocked"
				end
				return { { Position = to, Action = "Walk" } }
			end,
			navigation = { RepathInterval = 0.5 },
		})
		local target = Vector3.new(10, 0, 0)

		s.navigator:MoveTo(target)
		expect.equal(s.navigator:GetStatus(), "Failed")
		s.clock:Advance(0.2)
		s.navigator:MoveTo(target)
		expect.equal(attempts, 1, "not yet")
		s.clock:Advance(0.4)
		s.navigator:MoveTo(target)
		expect.equal(attempts, 2)
		expect.equal(s.navigator:GetStatus(), "Moving")
	end,

	["reaching the end of the path near the target arrives once"] = function(expect)
		local s = setup()
		local target = Vector3.new(10, 0, 0)

		s.navigator:MoveTo(target)
		s.mover.Position = Vector3.new(9.5, 3, 0)
		s.mover:Finish(true)
		expect.equal(s.navigator:GetStatus(), "Arrived")
		expect.sequence(s.arrivals, { true })

		s.navigator:MoveTo(target)
		s.navigator:Step(0.1)
		expect.sequence(s.arrivals, { true }, "still arrived, no second fire")
		expect.equal(#s.pathfinder.Calls, 1, "no re-plan while at the target")
	end,

	["arrival ignores height"] = function(expect)
		local s = setup({ navigation = { ArriveDistance = 1 } })
		s.mover.Position = Vector3.new(0, 2.5, 0)

		s.navigator:MoveTo(Vector3.new(0.5, -10, 0))
		expect.equal(s.navigator:GetStatus(), "Arrived")
		expect.equal(#s.pathfinder.Calls, 0, "already there horizontally, no plan needed")
	end,

	["reaching the end of the path away from the target re-plans on the cadence"] = function(expect)
		local s = setup({ navigation = { RepathInterval = 0.5 } })
		local target = Vector3.new(10, 0, 0)

		s.navigator:MoveTo(target)
		s.mover.Position = Vector3.new(5, 0, 0)
		s.mover:Finish(true)
		expect.equal(s.navigator:GetStatus(), "Moving", "not there yet")

		s.navigator:Step(0.1)
		expect.equal(#s.pathfinder.Calls, 1, "within the interval")
		s.clock:Advance(0.6)
		s.navigator:Step(0.1)
		expect.equal(#s.pathfinder.Calls, 2, "re-planned from Step without another MoveTo")
	end,

	["a stuck mover re-plans on the cadence"] = function(expect)
		local s = setup({ navigation = { RepathInterval = 0.5 } })

		s.navigator:MoveTo(Vector3.new(10, 0, 0))
		s.mover:Finish(false)
		expect.equal(s.navigator:GetStatus(), "Moving")
		expect.sequence(s.arrivals, {}, "a stuck mover is not a give-up")

		s.clock:Advance(0.6)
		s.navigator:Step(0.1)
		expect.equal(#s.pathfinder.Calls, 2)
	end,

	["leaving the target after arriving re-plans"] = function(expect)
		local s = setup({ navigation = { RepathInterval = 0.5, RepathDistance = 5, ArriveDistance = 1 } })
		local target = Vector3.new(10, 0, 0)

		s.navigator:MoveTo(target)
		s.mover.Position = target
		s.mover:Finish(true)
		expect.equal(s.navigator:GetStatus(), "Arrived")

		s.clock:Advance(1)
		s.navigator:MoveTo(Vector3.new(12, 0, 0))
		expect.equal(#s.pathfinder.Calls, 2, "moved past ArriveDistance but within RepathDistance still re-plans")
		expect.equal(s.navigator:GetStatus(), "Moving")
	end,

	["Stop halts the mover, clears the target and fires Arrived(false)"] = function(expect)
		local s = setup()

		s.navigator:MoveTo(Vector3.new(10, 0, 0))
		s.navigator:Stop()
		expect.equal(s.mover.Stops, 1)
		expect.falsy(s.mover:IsMoving())
		expect.equal(s.navigator:GetStatus(), "Idle")
		expect.equal(s.navigator:GetTarget(), nil)
		expect.equal(s.navigator:GetPath(), nil)
		expect.sequence(s.arrivals, { false }, "the mover's own Arrived(false) from Stop is not doubled")

		s.navigator:Stop()
		expect.equal(s.mover.Stops, 1, "a second Stop does nothing")
	end,

	["Stop after arriving does not fire Arrived again"] = function(expect)
		local s = setup()
		local target = Vector3.new(10, 0, 0)

		s.navigator:MoveTo(target)
		s.mover.Position = target
		s.mover:Finish(true)
		s.navigator:Stop()
		expect.sequence(s.arrivals, { true })
	end,

	["a plan that finishes after Stop is thrown away"] = function(expect)
		local s = setup({
			plan = function(_from, to)
				task.wait()
				return { { Position = to, Action = "Walk" } }
			end,
		})

		s.navigator:MoveTo(Vector3.new(10, 0, 0))
		expect.equal(s.navigator:GetStatus(), "Planning")
		s.navigator:Stop()
		task.wait()
		task.wait()
		expect.equal(#s.mover.Followed, 0)
		expect.equal(s.navigator:GetStatus(), "Idle")
	end,

	["a plan that finishes after a newer plan is thrown away"] = function(expect)
		local calls = 0
		local s = setup({
			plan = function(_from, to)
				calls += 1
				if calls == 1 then
					task.wait()
					task.wait()
				end
				return { { Position = to, Action = "Walk", Label = tostring(calls) } }
			end,
			navigation = { RepathInterval = 0.1 },
		})

		s.navigator:MoveTo(Vector3.new(10, 0, 0))
		s.clock:Advance(1)
		-- The first plan is still in flight, so this MoveTo does not start another (status Planning).
		s.navigator:MoveTo(Vector3.new(50, 0, 0))
		expect.equal(calls, 1)
		task.wait()
		task.wait()
		task.wait()
		expect.equal(#s.mover.Followed, 1)
		-- Then the target has moved, so the cadence triggers a second plan.
		s.clock:Advance(1)
		s.navigator:Step(0.1)
		expect.equal(calls, 2)
		expect.equal(s.mover.Followed[2][1].Label, "2")
	end,

	["a MoveTo within ArriveDistance arrives without planning"] = function(expect)
		local s = setup()

		s.navigator:MoveTo(Vector3.new(0.5, 0, 0))
		expect.equal(s.navigator:GetStatus(), "Arrived")
		expect.equal(#s.pathfinder.Calls, 0)
		expect.sequence(s.arrivals, { true })
	end,

	["StepReached is forwarded from the mover"] = function(expect)
		local s = setup()
		local reached = {}
		s.navigator.StepReached:Connect(function(index, step)
			table.insert(reached, `{index}:{step.Label}`)
		end)

		s.mover.StepReached:Fire(2, { Position = Vector3.new(), Action = "Walk", Label = "door" })
		expect.sequence(reached, { "2:door" })
	end,

	["FindPath receives the mover position, the target and the agent"] = function(expect)
		local seen = {}
		local s = setup({
			plan = function(from, to, agent)
				seen.from = from
				seen.to = to
				seen.agent = agent
				return { { Position = to, Action = "Walk" } }
			end,
		})
		s.mover.Position = Vector3.new(1, 2, 3)

		s.navigator:MoveTo(Vector3.new(10, 0, 0))
		expect.equal(seen.from, Vector3.new(1, 2, 3))
		expect.equal(seen.to, Vector3.new(10, 0, 0))
		expect.equal(seen.agent.Name, "Fake")
	end,

	["Destroy stops, disconnects and ignores later calls"] = function(expect)
		local s = setup()

		s.navigator:MoveTo(Vector3.new(10, 0, 0))
		s.navigator:Destroy()
		expect.equal(s.navigator:GetStatus(), "Idle")
		expect.sequence(s.arrivals, { false })

		s.navigator:MoveTo(Vector3.new(20, 0, 0))
		expect.equal(#s.pathfinder.Calls, 1)
		s.mover:Finish(true)
		expect.equal(s.navigator:GetStatus(), "Idle")
		s.navigator:Destroy()
	end,

	["a mover reporting the replaced path from inside Follow does not trigger a re-plan"] = function(expect)
		local s = setup({ navigation = { RepathInterval = 0.5, RepathDistance = 1 } })
		local originalFollow = s.mover.Follow
		s.mover.Follow = function(mover, path)
			if mover.Moving then
				mover.Moving = false
				mover.Arrived:Fire(false)
			end
			originalFollow(mover, path)
		end

		s.navigator:MoveTo(Vector3.new(10, 0, 0))
		s.clock:Advance(1)
		s.navigator:MoveTo(Vector3.new(20, 0, 0))
		expect.equal(#s.pathfinder.Calls, 2)
		expect.equal(s.navigator:GetStatus(), "Moving")

		s.clock:Advance(1)
		s.navigator:Step(0.1)
		expect.equal(#s.pathfinder.Calls, 2, "the replaced path's Arrived(false) was not taken as stuck")
	end,

	["PathChanged fires with each new path and with nil when it is gone"] = function(expect)
		local s = setup({ navigation = { RepathInterval = 0.5 } })
		local changes = {}
		s.navigator.PathChanged:Connect(function(path)
			table.insert(changes, if path then #path else "nil")
		end)

		s.navigator:MoveTo(Vector3.new(10, 0, 0))
		s.clock:Advance(1)
		s.navigator:MoveTo(Vector3.new(30, 0, 0))
		s.navigator:Stop()
		expect.sequence(changes, { 2, 2, "nil" })
	end,

	["the default options are as documented"] = function(expect)
		local s = setup()
		s.navigator:MoveTo(Vector3.new(10, 0, 0))
		s.clock:Advance(0.49)
		s.navigator:MoveTo(Vector3.new(13, 0, 0))
		expect.equal(#s.pathfinder.Calls, 1, "0.5 second interval")
		s.clock:Advance(0.02)
		s.navigator:MoveTo(Vector3.new(12, 0, 0))
		expect.equal(#s.pathfinder.Calls, 1, "2 stud distance")
		s.navigator:MoveTo(Vector3.new(12.5, 0, 0))
		expect.equal(#s.pathfinder.Calls, 2)
	end,
}
