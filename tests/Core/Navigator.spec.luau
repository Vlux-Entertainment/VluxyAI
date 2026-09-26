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

	["MaxPathAge re-plans a target that has not moved, on the cadence"] = function(expect)
		local s = setup({ navigation = { MaxPathAge = 2, RepathInterval = 0.5 } })
		local target = Vector3.new(10, 0, 0)

		s.navigator:MoveTo(target)
		s.clock:Advance(1.9)
		s.navigator:Step(0.1)
		expect.equal(#s.pathfinder.Calls, 1, "younger than MaxPathAge")

		s.clock:Advance(0.2)
		s.navigator:Step(0.1)
		expect.equal(#s.pathfinder.Calls, 2, "aged out without a MoveTo")
		expect.equal(#s.mover.Followed, 2, "the fresh path replaced the old one")
		expect.equal(s.navigator:GetStatus(), "Moving")

		s.clock:Advance(1)
		s.navigator:MoveTo(target)
		expect.equal(#s.pathfinder.Calls, 2, "the age counts from the last plan")
		s.clock:Advance(1.1)
		s.navigator:MoveTo(target)
		expect.equal(#s.pathfinder.Calls, 3)
	end,

	["MaxPathAge does not re-plan after arriving"] = function(expect)
		local s = setup({ navigation = { MaxPathAge = 1, ArriveDistance = 2 } })
		local target = Vector3.new(10, 0, 0)

		s.navigator:MoveTo(target)
		s.mover.Position = Vector3.new(9, 0, 0)
		s.mover:Finish(true)
		expect.equal(s.navigator:GetStatus(), "Arrived")

		s.clock:Advance(5)
		s.navigator:Step(0.1)
		s.navigator:MoveTo(target)
		expect.equal(#s.pathfinder.Calls, 1, "an arrived target is not re-planned by age")
	end,

	["a pathfinder's Blocked signal re-plans on the cadence"] = function(expect)
		local s = setup({ navigation = { RepathInterval = 0.5 } })
		s.pathfinder.Blocked = Fakes.Signal().new()
		local navigator = Harness.Load("lib/Navigator.luau", { globals = { os = s.clock.os } })
			.new(s.pathfinder, s.mover, Fakes.Agent(), { RepathInterval = 0.5 })
		local target = Vector3.new(10, 0, 0)

		navigator:MoveTo(target)
		s.clock:Advance(0.2)
		s.pathfinder.Blocked:Fire()
		expect.equal(#s.pathfinder.Calls, 1, "too soon after the last plan")
		expect.equal(navigator:GetStatus(), "Moving")

		s.clock:Advance(0.4)
		navigator:Step(0.1)
		expect.equal(#s.pathfinder.Calls, 2, "re-planned once the interval elapsed, with no MoveTo")
		expect.equal(#s.mover.Followed, 2)

		s.clock:Advance(1)
		s.pathfinder.Blocked:Fire()
		expect.equal(#s.pathfinder.Calls, 3, "a block after the interval re-plans at once")

		s.mover.Position = Vector3.new(10, 0, 0)
		s.mover:Finish(true)
		expect.equal(navigator:GetStatus(), "Arrived")
		s.clock:Advance(1)
		s.pathfinder.Blocked:Fire()
		navigator:Step(0.1)
		expect.equal(#s.pathfinder.Calls, 3, "a block after arriving is ignored")

		navigator:Destroy()
		s.clock:Advance(1)
		s.pathfinder.Blocked:Fire()
		expect.equal(#s.pathfinder.Calls, 3, "Destroy disconnects from Blocked")
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

	["arrival allows a height difference up to ArriveHeight and no more"] = function(expect)
		local s = setup({ navigation = { ArriveDistance = 1, ArriveHeight = 8 } })
		s.mover.Position = Vector3.new(0, 2.5, 0)

		s.navigator:MoveTo(Vector3.new(0.5, -3, 0))
		expect.equal(s.navigator:GetStatus(), "Arrived", "a floor node under a root is reached")
		expect.equal(#s.pathfinder.Calls, 0, "already there horizontally, no plan needed")

		s = setup({ navigation = { ArriveDistance = 1, ArriveHeight = 8 } })
		s.mover.Position = Vector3.new(0, 2.5, 0)
		s.navigator:MoveTo(Vector3.new(0.5, 30, 0))
		expect.equal(s.navigator:GetStatus(), "Moving", "a target on the floor above is not reached")
		expect.equal(#s.pathfinder.Calls, 1)
	end,

	["reaching the end of the path after the target moved re-plans on the cadence"] = function(expect)
		local s = setup({ navigation = { RepathInterval = 0.5, RepathDistance = 2 } })

		s.navigator:MoveTo(Vector3.new(10, 0, 0))
		s.navigator._target = Vector3.new(16, 0, 0) -- the target moved after the plan
		s.mover.Position = Vector3.new(10, 0, 0)
		s.mover:Finish(true)
		expect.equal(s.navigator:GetStatus(), "Moving", "not there yet")

		s.navigator:Step(0.1)
		expect.equal(#s.pathfinder.Calls, 1, "within the interval")
		s.clock:Advance(0.6)
		s.navigator:Step(0.1)
		expect.equal(#s.pathfinder.Calls, 2, "re-planned from Step without another MoveTo")
	end,

	["a path that ends short of a target that did not move fails instead of looping"] = function(expect)
		local warnings = {}
		local s = setup({ navigation = { RepathInterval = 0.5 }, warnings = warnings })
		local target = Vector3.new(10, 0, 0)

		s.navigator:MoveTo(target)
		s.mover.Position = Vector3.new(6, 0, 0)
		s.mover:Finish(true)
		expect.equal(s.navigator:GetStatus(), "Failed")
		expect.sequence(s.arrivals, { false })
		expect.equal(#warnings, 1)
		expect.includes(warnings[1], "ends 4 studs short")

		for _ = 1, 5 do
			s.clock:Advance(1)
			s.navigator:MoveTo(target)
			s.mover.Position = Vector3.new(6, 0, 0)
			s.mover:Finish(true)
		end
		expect.equal(#warnings, 1, "warned once")
	end,

	["a new target after arriving leaves Arrived at once"] = function(expect)
		local s = setup({ navigation = { RepathInterval = 0.5, RepathDistance = 2 } })

		s.navigator:MoveTo(Vector3.new(10, 0, 0))
		s.mover.Position = Vector3.new(10, 0, 0)
		s.mover:Finish(true)
		expect.equal(s.navigator:GetStatus(), "Arrived")

		s.navigator:MoveTo(Vector3.new(90, 0, 0))
		expect.equal(s.navigator:GetStatus(), "Moving", "no wait for the cadence")
		expect.equal(#s.pathfinder.Calls, 2)
		expect.sequence(s.arrivals, { true })

		s.mover.Position = Vector3.new(90, 0, 0)
		s.mover:Finish(true)
		expect.sequence(s.arrivals, { true, true }, "the second target arrives in its own right")
	end,

	["a target that drifts out of reach after arriving is chased at once"] = function(expect)
		local s = setup({ navigation = { RepathInterval = 0.5, RepathDistance = 2, ArriveDistance = 2.5 } })

		s.navigator:MoveTo(Vector3.new(10, 0, 0))
		s.mover.Position = Vector3.new(7.6, 0, 0)
		s.mover:Finish(true)
		expect.equal(s.navigator:GetStatus(), "Arrived")

		-- Moved less than RepathDistance, but now 4.4 studs away: not arrived any more.
		s.navigator:MoveTo(Vector3.new(12, 0, 0))
		expect.equal(s.navigator:GetStatus(), "Idle", "Arrived is dropped at once")
		expect.equal(#s.pathfinder.Calls, 1, "the plan waits for the cadence")

		s.clock:Advance(0.6)
		s.navigator:MoveTo(Vector3.new(12, 0, 0))
		expect.equal(s.navigator:GetStatus(), "Moving")
		expect.equal(#s.pathfinder.Calls, 2)
	end,

	["a target jittering across ArriveDistance is one arrival and no plan spam"] = function(expect)
		local s = setup({ navigation = { RepathInterval = 0.5, RepathDistance = 2, ArriveDistance = 2.5 } })

		s.navigator:MoveTo(Vector3.new(10, 0, 0))
		s.mover.Position = Vector3.new(10, 0, 0)
		s.mover:Finish(true)
		expect.sequence(s.arrivals, { true })

		for index = 1, 10 do
			local offset = if index % 2 == 0 then 2.4 else 2.6
			s.navigator:MoveTo(Vector3.new(10 + offset, 0, 0))
		end
		expect.equal(#s.pathfinder.Calls, 1, "no plan within the cadence")
		expect.equal(s.mover.Stops, 0, "nothing to stop: the mover finished its path on its own")
		expect.sequence(s.arrivals, { true }, "one arrival")
	end,

	["a target hovering above the end of the path is an ends-short failure, not a loop"] = function(expect)
		local warnings = {}
		local s = setup({ navigation = { RepathInterval = 0.5, ArriveHeight = 8 }, warnings = warnings })

		s.navigator:MoveTo(Vector3.new(10, 0, 0))
		s.mover.Position = Vector3.new(10, 20, 0)
		s.mover:Finish(true)
		expect.equal(s.navigator:GetStatus(), "Failed")
		expect.equal(#warnings, 1)
	end,

	["a path that reached what it planned while the target shuffled re-plans instead of failing"] = function(expect)
		local warnings = {}
		local s = setup({
			navigation = { RepathInterval = 0.5, RepathDistance = 2, ArriveDistance = 2.5 },
			warnings = warnings,
		})

		s.navigator:MoveTo(Vector3.new(10, 0, 0))
		-- The target shuffled 1.9 studs (under RepathDistance) and the path ended 1 stud short of
		-- where it was planned to: we got where we were going, the target just moved.
		s.navigator._target = Vector3.new(11.9, 0, 0)
		s.mover.Position = Vector3.new(9, 0, 0)
		s.mover:Finish(true)
		expect.equal(s.navigator:GetStatus(), "Moving")
		expect.equal(#warnings, 0)
		expect.sequence(s.arrivals, {})

		s.clock:Advance(0.6)
		s.navigator:Step(0.1)
		expect.equal(#s.pathfinder.Calls, 2, "re-planned on the cadence")
	end,

	["an unreachable target that jitters warns once"] = function(expect)
		local warnings = {}
		local s = setup({
			plan = function()
				return nil, "blocked"
			end,
			navigation = { RepathInterval = 0.5, RepathDistance = 2 },
			warnings = warnings,
		})

		for index = 1, 10 do
			s.clock:Advance(1)
			s.navigator:MoveTo(Vector3.new(10 + index * 0.1, 0, 0))
		end
		expect.equal(#warnings, 1)
	end,

	["a far new target after a failure plans at once"] = function(expect)
		local calls = 0
		local s = setup({
			plan = function(_from, to)
				calls += 1
				if calls == 1 then
					return nil, "blocked"
				end
				return { { Position = to, Action = "Walk" } }
			end,
			navigation = { RepathInterval = 0.5 },
		})

		s.navigator:MoveTo(Vector3.new(10, 0, 0))
		expect.equal(s.navigator:GetStatus(), "Failed")
		s.navigator:MoveTo(Vector3.new(100, 0, 0))
		expect.equal(s.navigator:GetStatus(), "Moving", "no wait for the cadence")
		expect.equal(calls, 2)
	end,

	["a new target already within reach after arriving arrives again"] = function(expect)
		local s = setup({ navigation = { RepathDistance = 2, ArriveDistance = 1 } })

		s.navigator:MoveTo(Vector3.new(10, 0, 0))
		s.mover.Position = Vector3.new(10, 0, 0)
		s.mover:Finish(true)
		s.mover.Position = Vector3.new(50, 0, 0)
		s.navigator:MoveTo(Vector3.new(50.5, 0, 0))
		expect.equal(s.navigator:GetStatus(), "Arrived")
		expect.sequence(s.arrivals, { true, true })
		expect.equal(#s.pathfinder.Calls, 1, "no plan needed for a target under our feet")
	end,

	["a pathfinder that errors is a failed plan, not a navigator stuck in Planning"] = function(expect)
		local warnings = {}
		local calls = 0
		local s = setup({
			plan = function(_from, to)
				calls += 1
				if calls == 1 then
					error("boom")
				end
				return { { Position = to, Action = "Walk" } }
			end,
			navigation = { RepathInterval = 0.5 },
			warnings = warnings,
		})
		local target = Vector3.new(10, 0, 0)

		s.navigator:MoveTo(target)
		expect.equal(s.navigator:GetStatus(), "Failed")
		expect.sequence(s.arrivals, { false })
		expect.equal(#warnings, 1)
		expect.includes(warnings[1], "FindPath errored")
		expect.includes(warnings[1], "boom")

		s.clock:Advance(1)
		s.navigator:MoveTo(target)
		expect.equal(s.navigator:GetStatus(), "Moving", "the cadence retried")
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

	["Stop during Planning then MoveTo never has two plans in flight"] = function(expect)
		local inFlight = 0
		local peak = 0
		local s = setup({
			plan = function(_from, to)
				inFlight += 1
				peak = math.max(peak, inFlight)
				task.wait()
				task.wait()
				inFlight -= 1
				return { { Position = to, Action = "Walk" } }
			end,
		})

		s.navigator:MoveTo(Vector3.new(10, 0, 0))
		s.navigator:Stop()
		s.navigator:MoveTo(Vector3.new(90, 0, 0))
		expect.equal(s.navigator:GetStatus(), "Idle", "waiting for the old plan to come back")
		for _ = 1, 8 do
			task.wait()
		end
		expect.equal(peak, 1, "one FindPath at a time")
		expect.equal(#s.pathfinder.Calls, 2, "the new target was planned once the old plan returned")
		expect.equal(s.navigator:GetStatus(), "Moving")
		expect.near(s.mover.Followed[1][1].Position.X, 90, 1e-6, "and it is the new target that is followed")
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

	["a labelled step with a handler holds the walk, runs it, then follows the rest of the path"] = function(expect)
		local calls = {}
		local statuses = {}
		local door = { Name = "Door" }
		local s = setup({
			plan = function(from, to)
				return {
					{ Position = from, Action = "Walk" },
					{ Position = Vector3.new(5, 0, 0), Action = "Custom", Label = "Door", Instance = door },
					{ Position = Vector3.new(8, 0, 0), Action = "Walk" },
					{ Position = to, Action = "Walk" },
				}
			end,
		})
		local Navigator = Harness.Load("lib/Navigator.luau", { globals = { os = s.clock.os } })
		local navigator = Navigator.new(s.pathfinder, s.mover, Fakes.Agent(), nil, {
			Door = function(agent, step, index)
				table.insert(calls, { agent = agent, step = step, index = index })
				task.wait(0.02)
			end,
		})
		local reached = {}
		navigator.StepReached:Connect(function(index, step)
			table.insert(reached, `{index}{if step.Label then " " .. step.Label else ""}`)
		end)
		navigator.Arrived:Connect(function(ok)
			table.insert(statuses, `arrived {tostring(ok)}`)
		end)

		navigator:MoveTo(Vector3.new(10, 0, 0))
		local path = s.mover.Followed[1]
		s.mover.StepReached:Fire(1, path[1])
		expect.equal(#calls, 0, "a plain step is not handled")

		s.mover.StepReached:Fire(2, path[2])
		expect.equal(#calls, 1)
		expect.equal(calls[1].step.Instance, door)
		expect.equal(calls[1].index, 2)
		expect.equal(navigator:GetStatus(), "Interacting")
		expect.falsy(s.mover.Moving, "the mover was stopped at the step")
		expect.equal(#statuses, 0, "the stop is not a give-up")

		navigator:MoveTo(Vector3.new(10, 0, 0))
		s.clock:Advance(1)
		navigator:Step(0.1)
		expect.equal(#s.pathfinder.Calls, 1, "the same target keeps waiting, with no re-plan")

		task.wait(0.05)
		expect.equal(navigator:GetStatus(), "Moving")
		expect.equal(#s.mover.Followed, 2, "the rest of the path was handed to the mover")
		local rest = s.mover.Followed[2]
		expect.equal(#rest, 2)
		expect.equal(rest[1].Position, Vector3.new(8, 0, 0))
		expect.equal(navigator:GetPath(), path, "GetPath is still the whole path")

		s.mover.StepReached:Fire(1, rest[1])
		s.mover.StepReached:Fire(2, rest[2])
		expect.sequence(reached, { "1", "2 Door", "3", "4" }, "indices are in the original path's numbering")

		s.mover.Position = Vector3.new(10, 0, 0)
		s.mover:Finish(true)
		expect.equal(navigator:GetStatus(), "Arrived")
		expect.sequence(statuses, { "arrived true" })
		navigator:Destroy()
	end,

	["a handled last step arrives when the handler returns"] = function(expect)
		local s = setup({
			plan = function(from, to)
				return {
					{ Position = from, Action = "Walk" },
					{ Position = to, Action = "Custom", Label = "Door" },
				}
			end,
		})
		local Navigator = Harness.Load("lib/Navigator.luau", { globals = { os = s.clock.os } })
		local navigator = Navigator.new(s.pathfinder, s.mover, Fakes.Agent(), nil, {
			Door = function() end,
		})
		local arrivals = {}
		navigator.Arrived:Connect(function(ok)
			table.insert(arrivals, ok)
		end)

		navigator:MoveTo(Vector3.new(10, 0, 0))
		s.mover.Position = Vector3.new(10, 0, 0)
		s.mover.StepReached:Fire(2, s.mover.Followed[1][2])
		expect.equal(navigator:GetStatus(), "Arrived", "the handler returned at once; nothing left to walk")
		expect.sequence(arrivals, { true })
		navigator:Destroy()
	end,

	["Stop or a new target during a handler abandons the path, and an erroring handler warns"] = function(expect)
		local warnings = {}
		local s = setup({
			plan = function(from, to)
				return {
					{ Position = from, Action = "Walk" },
					{ Position = Vector3.new(5, 0, 0), Action = "Custom", Label = "Door" },
					{ Position = to, Action = "Walk" },
				}
			end,
			warnings = warnings,
		})
		local Navigator = Harness.Load("lib/Navigator.luau", {
			globals = { os = s.clock.os },
			warn = function(message)
				table.insert(warnings, tostring(message))
			end,
		})
		local navigator = Navigator.new(s.pathfinder, s.mover, Fakes.Agent(), nil, {
			Door = function()
				task.wait(0.02)
				error("stuck door")
			end,
		})
		local arrivals = {}
		navigator.Arrived:Connect(function(ok)
			table.insert(arrivals, ok)
		end)

		navigator:MoveTo(Vector3.new(10, 0, 0))
		s.mover.StepReached:Fire(2, s.mover.Followed[1][2])
		expect.equal(navigator:GetStatus(), "Interacting")
		navigator:Stop()
		expect.sequence(arrivals, { false }, "Stop during a handler reports the path given up")
		task.wait(0.05)
		expect.equal(#warnings, 1)
		expect.includes(warnings[1], "stuck door")
		expect.equal(#s.mover.Followed, 1, "the rest of the abandoned path was not followed")
		expect.equal(navigator:GetStatus(), "Idle")

		navigator:MoveTo(Vector3.new(10, 0, 0))
		s.mover.StepReached:Fire(2, s.mover.Followed[2][2])
		s.clock:Advance(1)
		navigator:MoveTo(Vector3.new(40, 0, 0))
		expect.equal(#s.pathfinder.Calls, 3, "a new target re-plans at once")
		task.wait(0.05)
		expect.equal(#s.mover.Followed, 3, "the old path's rest was not followed after the new plan")
		navigator:Destroy()
	end,
}
