--!strict

--[[
	The brain runner: entering, ordered transitions before Update, Update naming the next state,
	and the edge cases around re-entry and unknown names.
]]

local Fakes = require("../Support/Fakes")
local Harness = require("../Support/Harness")

local function load(warnings: { string }?)
	return Harness.Load("lib/Brain/Runner.luau", {
		warn = function(message)
			if warnings then
				table.insert(warnings, tostring(message))
			end
		end,
	})
end

return {
	["Start enters the initial state and Step runs its Update"] = function(expect)
		local Runner = load()
		local log = {}
		local runner = Runner.new(Fakes.Brain("Idle", { "Idle" }, log), Fakes.Agent())

		expect.equal(runner:GetState(), nil, "state before Start")
		runner:Start()
		expect.equal(runner:GetState(), "Idle")
		runner:Step(0.1)
		expect.sequence(log, { "enter Idle", "update Idle" })
	end,

	["Start twice does not re-enter"] = function(expect)
		local Runner = load()
		local log = {}
		local runner = Runner.new(Fakes.Brain("Idle", { "Idle" }, log), Fakes.Agent())

		runner:Start()
		runner:Start()
		expect.sequence(log, { "enter Idle" })
	end,

	["Update returning a name exits the old state and enters the new one"] = function(expect)
		local Runner = load()
		local log = {}
		local changes = {}
		local brain = Fakes.Brain("Idle", { "Idle", "Chase" }, log, {
			Idle = function()
				return "Chase"
			end,
		})
		local runner = Runner.new(brain, Fakes.Agent(), function(new, old)
			table.insert(changes, `{tostring(old)}->{new}`)
		end)

		runner:Start()
		runner:Step(0.1)
		expect.sequence(log, { "enter Idle", "update Idle", "exit Idle", "enter Chase" })
		expect.sequence(changes, { "nil->Idle", "Idle->Chase" })
		expect.equal(runner:GetState(), "Chase")
	end,

	["Update returning the current name stays and does not re-enter"] = function(expect)
		local Runner = load()
		local log = {}
		local brain = Fakes.Brain("Idle", { "Idle" }, log, {
			Idle = function()
				return "Idle"
			end,
		})
		local runner = Runner.new(brain, Fakes.Agent())

		runner:Start()
		runner:Step(0.1)
		runner:Step(0.1)
		expect.sequence(log, { "enter Idle", "update Idle", "update Idle" })
	end,

	["transitions are checked in order before Update and the first true one wins"] = function(expect)
		local Runner = load()
		local log = {}
		local brain = Fakes.Brain("Idle", { "Idle", "A", "B" }, log)
		local flag = false
		brain.States.Idle.Transitions = {
			{
				To = "A",
				When = function()
					return flag
				end,
			},
			{
				To = "B",
				When = function()
					return true
				end,
			},
		}
		local runner = Runner.new(brain, Fakes.Agent())

		runner:Start()
		runner:Step(0.1)
		expect.equal(runner:GetState(), "B", "second transition wins when the first is false")
		expect.sequence(
			log,
			{ "enter Idle", "exit Idle", "enter B" },
			"Update was skipped on the tick a transition fired"
		)

		runner:Transition("Idle")
		flag = true
		runner:Step(0.1)
		expect.equal(runner:GetState(), "A", "first true transition wins")
	end,

	["When receives the agent"] = function(expect)
		local Runner = load()
		local agent = Fakes.Agent({ Seen = true })
		local received = nil
		local brain = Fakes.Brain("Idle", { "Idle", "Chase" }, {})
		brain.States.Idle.Transitions = {
			{
				To = "Chase",
				When = function(passed)
					received = passed
					return passed.Blackboard.Seen
				end,
			},
		}
		local runner = Runner.new(brain, agent)

		runner:Start()
		runner:Step(0.1)
		expect.equal(received, agent)
		expect.equal(runner:GetState(), "Chase")
	end,

	["Update receives the agent and the delta time"] = function(expect)
		local Runner = load()
		local agent = Fakes.Agent()
		local seen = {}
		local brain = {
			Initial = "Idle",
			States = {
				Idle = {
					Update = function(passed, deltaTime)
						seen.agent = passed
						seen.deltaTime = deltaTime
						return nil
					end,
				},
			},
		}
		local runner = Runner.new(brain, agent)

		runner:Start()
		runner:Step(0.25)
		expect.equal(seen.agent, agent)
		expect.equal(seen.deltaTime, 0.25)
	end,

	["an unknown name from Update warns and stays put"] = function(expect)
		local warnings = {}
		local Runner = load(warnings)
		local log = {}
		local brain = Fakes.Brain("Idle", { "Idle" }, log, {
			Idle = function()
				return "Nowhere"
			end,
		})
		local runner = Runner.new(brain, Fakes.Agent())

		runner:Start()
		runner:Step(0.1)
		expect.equal(runner:GetState(), "Idle")
		expect.equal(#warnings, 1)
		expect.includes(warnings[1], '"Nowhere" does not exist')
		expect.sequence(log, { "enter Idle", "update Idle" })
	end,

	["Transition to the current state re-enters it"] = function(expect)
		local Runner = load()
		local log = {}
		local runner = Runner.new(Fakes.Brain("Idle", { "Idle" }, log), Fakes.Agent())

		runner:Start()
		runner:Transition("Idle")
		expect.sequence(log, { "enter Idle", "exit Idle", "enter Idle" })
	end,

	["a transition made inside Enter wins over the one that called it"] = function(expect)
		local Runner = load()
		local log = {}
		local runner
		local brain = Fakes.Brain("Idle", { "Idle", "Middle", "Final" }, log, {
			Idle = function()
				return "Middle"
			end,
		})
		brain.States.Middle.Enter = function()
			table.insert(log, "enter Middle")
			runner:Transition("Final")
		end
		runner = Runner.new(brain, Fakes.Agent())

		runner:Start()
		runner:Step(0.1)
		expect.equal(runner:GetState(), "Final")
		expect.sequence(log, { "enter Idle", "update Idle", "exit Idle", "enter Middle", "exit Middle", "enter Final" })

		runner:Step(0.1)
		expect.sequence(log, {
			"enter Idle",
			"update Idle",
			"exit Idle",
			"enter Middle",
			"exit Middle",
			"enter Final",
			"update Final",
		}, "the next tick updates Final, not Middle")
	end,

	["a transition forced during Update is not stacked on by Update's return"] = function(expect)
		local Runner = load()
		local log = {}
		local runner
		local brain = Fakes.Brain("Idle", { "Idle", "Forced", "Returned" }, log)
		brain.States.Idle.Update = function()
			table.insert(log, "update Idle")
			runner:Transition("Forced")
			return "Returned"
		end
		runner = Runner.new(brain, Fakes.Agent())

		runner:Start()
		runner:Step(0.1)
		expect.equal(runner:GetState(), "Forced")
	end,

	["Stop exits the current state and Step does nothing afterwards"] = function(expect)
		local Runner = load()
		local log = {}
		local runner = Runner.new(Fakes.Brain("Idle", { "Idle" }, log), Fakes.Agent())

		runner:Start()
		runner:Stop()
		runner:Step(0.1)
		expect.equal(runner:GetState(), nil)
		expect.sequence(log, { "enter Idle", "exit Idle" })

		runner:Start()
		expect.equal(runner:GetState(), "Idle", "Start works again after Stop")
	end,

	["a state with only Update works"] = function(expect)
		local Runner = load()
		local ticks = 0
		local brain = {
			Initial = "Only",
			States = {
				Only = {
					Update = function()
						ticks += 1
						return nil
					end,
				},
			},
		}
		local runner = Runner.new(brain, Fakes.Agent())

		runner:Start()
		runner:Step(0.1)
		runner:Stop()
		expect.equal(ticks, 1)
	end,
}
