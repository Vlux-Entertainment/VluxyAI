--!strict

--[[
	The validator: every rule in Types.luau has a case here that proves the error names the
	field path, and one good definition proves the rules let a correct one through.
]]

local Fakes = require("../Support/Fakes")
local Harness = require("../Support/Harness")

local roblox = require("@lune/roblox")

local function load()
	return Harness.Load("lib/Brain/Validate.luau")
end

local function goodBrain()
	return {
		Initial = "Idle",
		States = {
			Idle = {
				Update = function()
					return nil
				end,
				Transitions = {
					{
						To = "Chase",
						When = function()
							return false
						end,
					},
				},
			},
			Chase = {
				Enter = function() end,
				Exit = function() end,
			},
		},
	}
end

local function goodDefinition()
	return {
		Entity = Fakes.Entity(),
		Brain = goodBrain(),
		Pathfinder = Fakes.Pathfinder(),
		Mover = Fakes.Mover(),
		Senses = { Fakes.Sense("a", {}) },
		Blackboard = { Seen = false },
		Data = {},
		Tick = 0.2,
		Navigation = { RepathInterval = 0.3 },
		Name = "Test",
	}
end

local function failsWith(expect, mutate: (definition: any) -> (), wanted: string)
	local Validate = load()
	local definition = goodDefinition()
	mutate(definition)
	local message = expect.errors(function()
		Validate.Definition(definition)
	end)
	expect.includes(message, "[VluxyAI]")
	expect.includes(message, wanted)
end

return {
	["a correct definition passes"] = function(expect)
		local Validate = load()
		Validate.Definition(goodDefinition())
		expect.truthy(true)
	end,

	["a definition with only an entity and a brain passes"] = function(expect)
		local Validate = load()
		Validate.Definition({ Entity = Fakes.Entity(), Brain = goodBrain() })
		expect.truthy(true)
	end,

	["the definition must be a table"] = function(expect)
		local Validate = load()
		local message = expect.errors(function()
			Validate.Definition("nope")
		end)
		expect.includes(message, "Definition must be a table")
	end,

	["an unknown definition field is named with the expected ones"] = function(expect)
		failsWith(expect, function(definition)
			definition.Pathfindr = definition.Pathfinder
		end, "Definition.Pathfindr is not a field VluxyAI knows; expected one of Blackboard, Brain, Data")
	end,

	["Entity must exist"] = function(expect)
		failsWith(expect, function(definition)
			definition.Entity = nil
		end, "Definition.Entity must be a Model, got a nil")
	end,

	["a real Instance must be a Model"] = function(expect)
		failsWith(expect, function(definition)
			definition.Entity = roblox.Instance.new("Part")
		end, "Definition.Entity must be a Model, got a Part")
	end,

	["a real Model needs a PrimaryPart"] = function(expect)
		failsWith(expect, function(definition)
			local model = roblox.Instance.new("Model")
			model.Name = "Rig"
			definition.Entity = model
		end, "Definition.Entity (Rig) has no PrimaryPart")
	end,

	["Name must be a string"] = function(expect)
		failsWith(expect, function(definition)
			definition.Name = 5
		end, "Definition.Name must be a string, got 5")
	end,

	["Brain must exist"] = function(expect)
		failsWith(expect, function(definition)
			definition.Brain = nil
		end, "Definition.Brain must be a table, got a nil")
	end,

	["Brain.Initial must name a state"] = function(expect)
		failsWith(expect, function(definition)
			definition.Brain.Initial = "Sleep"
		end, 'Definition.Brain.Initial = "Sleep" names no state')
	end,

	["Brain.States must not be empty"] = function(expect)
		failsWith(expect, function(definition)
			definition.Brain.States = {}
		end, "Definition.Brain.States has no states")
	end,

	["the 0.1 state names are called out by their new names"] = function(expect)
		failsWith(expect, function(definition)
			definition.Brain.States.Idle.Start = function() end
		end, 'Definition.Brain.States.Idle.Start is the VluxyAI 0.1 name; it is called "Enter" now')

		failsWith(expect, function(definition)
			definition.Brain.States.Idle.End = function() end
		end, 'Definition.Brain.States.Idle.End is the VluxyAI 0.1 name; it is called "Exit" now')
	end,

	["an unknown state field is an error"] = function(expect)
		failsWith(
			expect,
			function(definition)
				definition.Brain.States.Idle.Transition = {}
			end,
			"Definition.Brain.States.Idle.Transition is not a field VluxyAI knows; expected one of Enter, Exit, Transitions, Update"
		)
	end,

	["state functions must be functions"] = function(expect)
		failsWith(expect, function(definition)
			definition.Brain.States.Chase.Enter = true
		end, "Definition.Brain.States.Chase.Enter must be a function, got true")
	end,

	["a transition must target a state"] = function(expect)
		failsWith(expect, function(definition)
			definition.Brain.States.Idle.Transitions[1].To = "Hunt"
		end, 'Definition.Brain.States.Idle.Transitions[1].To = "Hunt" names no state')
	end,

	["a transition needs a When function"] = function(expect)
		failsWith(expect, function(definition)
			definition.Brain.States.Idle.Transitions[1].When = nil
		end, "Definition.Brain.States.Idle.Transitions[1].When must be a function, got a nil")
	end,

	["transitions must be a list"] = function(expect)
		failsWith(expect, function(definition)
			definition.Brain.States.Idle.Transitions = {
				Chase = {
					To = "Chase",
					When = function()
						return true
					end,
				},
			}
		end, "Definition.Brain.States.Idle.Transitions[Chase] must be in a list, not keyed")
	end,

	["a transition with an unknown field is an error"] = function(expect)
		failsWith(expect, function(definition)
			definition.Brain.States.Idle.Transitions[1].If = function()
				return true
			end
		end, "Definition.Brain.States.Idle.Transitions[1].If is not a field VluxyAI knows; expected one of To, When")
	end,

	["a Pathfinder without a Mover is an error"] = function(expect)
		failsWith(expect, function(definition)
			definition.Mover = nil
		end, "Definition.Mover is missing; a Pathfinder needs a Mover to go with it")
	end,

	["a Mover without a Pathfinder is an error"] = function(expect)
		failsWith(expect, function(definition)
			definition.Pathfinder = nil
		end, "Definition.Pathfinder is missing; a Mover needs a Pathfinder to go with it")
	end,

	["a Pathfinder needs FindPath"] = function(expect)
		failsWith(expect, function(definition)
			definition.Pathfinder = {}
		end, "Definition.Pathfinder.FindPath must be a function, got a nil")
	end,

	["a Mover needs every method"] = function(expect)
		failsWith(expect, function(definition)
			definition.Mover.SetSpeed = nil
		end, "Definition.Mover.SetSpeed must be a function, got a nil")
	end,

	["a Mover needs its signals"] = function(expect)
		failsWith(expect, function(definition)
			definition.Mover.Arrived = nil
		end, "Definition.Mover.Arrived must be a signal with Connect, got a nil")
	end,

	["a Sense needs Tick"] = function(expect)
		failsWith(expect, function(definition)
			definition.Senses = { {} }
		end, "Definition.Senses[1].Tick must be a function, got a nil")
	end,

	["the same sense twice is an error"] = function(expect)
		failsWith(expect, function(definition)
			local sense = Fakes.Sense("a", {})
			definition.Senses = { sense, Fakes.Sense("b", {}), sense }
		end, "Definition.Senses[3] is the same sense as Senses[1]; it would tick twice")
	end,

	["Senses must be a list"] = function(expect)
		failsWith(expect, function(definition)
			definition.Senses = { Sight = Fakes.Sense("a", {}) }
		end, 'Definition.Senses["Sight"] must be in a list, not keyed')
	end,

	["Tick must be above zero"] = function(expect)
		failsWith(expect, function(definition)
			definition.Tick = 0
		end, "Definition.Tick must be a number above 0, got 0")
	end,

	["Navigation fields are checked"] = function(expect)
		failsWith(expect, function(definition)
			definition.Navigation = { RepathInterval = 0 }
		end, "Definition.Navigation.RepathInterval must be a number above 0, got 0")

		failsWith(expect, function(definition)
			definition.Navigation = { ArriveDistance = -1 }
		end, "Definition.Navigation.ArriveDistance must be a number of 0 or more, got -1")

		failsWith(expect, function(definition)
			definition.Navigation = { MaxPathAge = 0 }
		end, "Definition.Navigation.MaxPathAge must be a number above 0, got 0")

		local Validate = load()
		local zeroes = goodDefinition()
		zeroes.Navigation = { RepathDistance = 0, ArriveDistance = 0, ArriveHeight = 0 }
		Validate.Definition(zeroes)

		failsWith(expect, function(definition)
			definition.Navigation = { Repath = 1 }
		end, "Definition.Navigation.Repath is not a field VluxyAI knows")
	end,

	["a pathfinder's Blocked, when present, must be a signal"] = function(expect)
		failsWith(expect, function(definition)
			definition.Pathfinder.Blocked = true
		end, "Definition.Pathfinder.Blocked must be a signal with Connect, got true")

		local Validate = load()
		local definition = goodDefinition()
		definition.Pathfinder.Blocked = Fakes.Signal().new()
		Validate.Definition(definition)
	end,

	["Validate.Brain uses the given path prefix"] = function(expect)
		local Validate = load()
		local brain = goodBrain()
		brain.Initial = "Gone"
		local message = expect.errors(function()
			Validate.Brain(brain, "Stalker.Brain")
		end)
		expect.includes(message, 'Stalker.Brain.Initial = "Gone" names no state')
	end,

	["Interrupts are checked like transitions, plus their Except list"] = function(expect)
		local Validate = load()
		local brain = goodBrain()
		brain.Interrupts = {
			{
				To = "Chase",
				When = function()
					return false
				end,
				Except = { "Chase" },
			},
		}
		Validate.Brain(brain)

		local function brainFails(mutate: (brain: any) -> (), wanted: string)
			local candidate = goodBrain()
			mutate(candidate)
			local message = expect.errors(function()
				Validate.Brain(candidate)
			end)
			expect.includes(message, wanted)
		end

		brainFails(function(b)
			b.Interrupts = { { To = "Nowhere", When = function() end } }
		end, 'Brain.Interrupts[1].To = "Nowhere" names no state')
		brainFails(function(b)
			b.Interrupts = { { To = "Chase" } }
		end, "Brain.Interrupts[1].When must be a function")
		brainFails(function(b)
			b.Interrupts = { { To = "Chase", When = function() end, Except = { "Gone" } } }
		end, 'Brain.Interrupts[1].Except[1] = "Gone" names no state')
		brainFails(function(b)
			b.Interrupts = { { To = "Chase", When = function() end, Unless = {} } }
		end, "Brain.Interrupts[1].Unless is not a field VluxyAI knows")
		brainFails(function(b)
			b.Interrupts = { first = { To = "Chase", When = function() end } }
		end, "Brain.Interrupts[first] must be in a list")
	end,

	["Steps must be functions keyed by label"] = function(expect)
		local Validate = load()
		local definition = goodDefinition()
		definition.Steps = { Door = function() end }
		Validate.Definition(definition)

		failsWith(expect, function(d)
			d.Steps = { Door = true }
		end, "Definition.Steps.Door must be a function, got true")
		failsWith(expect, function(d)
			d.Steps = { function() end }
		end, "Definition.Steps[1] must be keyed by the step's Label")
		failsWith(expect, function(d)
			d.Steps = "Door"
		end, "Definition.Steps must be a table")
	end,
}
