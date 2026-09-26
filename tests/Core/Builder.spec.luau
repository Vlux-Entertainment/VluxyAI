--!strict

--[[
	The builder: each method fills its field, the chain returns the builder, Build validates and
	makes an agent, and a builder is single use.
]]

local Fakes = require("../Support/Fakes")
local Harness = require("../Support/Harness")

local function load()
	return Harness.Load("lib/Builder.luau", {
		services = { RunService = { Heartbeat = Harness.ManualHeartbeat() } },
	})
end

return {
	["every method fills its field and returns the builder"] = function(expect)
		local Builder = load()
		local entity = Fakes.Entity()
		local brain = Fakes.Brain("Idle", { "Idle" }, {})
		local pathfinder = Fakes.Pathfinder()
		local mover = Fakes.Mover()
		local first = Fakes.Sense("a", {})
		local second = Fakes.Sense("b", {})

		local builder = Builder.new(entity)
		local returned = builder
			:UseBrain(brain)
			:UsePathfinder(pathfinder)
			:UseMover(mover)
			:AddSense(first)
			:AddSense(second)
			:SetBlackboard({ Seen = false })
			:SetData({ Hits = 0 })
			:SetTick(0.25)
			:SetNavigation({ RepathInterval = 1 })
			:SetName("Stalker")
		expect.equal(returned, builder)

		local definition = builder:GetDefinition()
		expect.equal(definition.Entity, entity)
		expect.equal(definition.Brain, brain)
		expect.equal(definition.Pathfinder, pathfinder)
		expect.equal(definition.Mover, mover)
		expect.equal(definition.Senses[1], first)
		expect.equal(definition.Senses[2], second)
		expect.equal(definition.Blackboard.Seen, false)
		expect.equal(definition.Data.Hits, 0)
		expect.equal(definition.Tick, 0.25)
		expect.equal(definition.Navigation.RepathInterval, 1)
		expect.equal(definition.Name, "Stalker")
	end,

	["GetDefinition returns a copy"] = function(expect)
		local Builder = load()
		local builder =
			Builder.new(Fakes.Entity()):UseBrain(Fakes.Brain("Idle", { "Idle" }, {})):AddSense(Fakes.Sense("a", {}))

		local copy = builder:GetDefinition()
		copy.Tick = 9
		table.insert(copy.Senses, Fakes.Sense("b", {}))

		local again = builder:GetDefinition()
		expect.equal(again.Tick, nil)
		expect.equal(#again.Senses, 1)
	end,

	["Build validates and returns a started-able agent"] = function(expect)
		local Builder = load()
		local log = {}
		local agent = Builder.new(Fakes.Entity("Cylinder")):UseBrain(Fakes.Brain("Idle", { "Idle" }, log)):Build()

		expect.equal(agent.Name, "Cylinder")
		expect.equal(agent:GetState(), nil)
		agent:Start(true)
		expect.equal(agent:GetState(), "Idle")
		agent:Destroy()
	end,

	["Build errors with the field path"] = function(expect)
		local Builder = load()
		local message = expect.errors(function()
			Builder.new(Fakes.Entity()):Build()
		end)
		expect.includes(message, "Definition.Brain must be a table, got a nil")

		message = expect.errors(function()
			Builder.new(Fakes.Entity()):UseBrain(Fakes.Brain("Idle", { "Idle" }, {})):UseMover(Fakes.Mover()):Build()
		end)
		expect.includes(message, "Definition.Pathfinder is missing")
	end,

	["Validate checks without building"] = function(expect)
		local Builder = load()
		local builder = Builder.new(Fakes.Entity()):UseBrain(Fakes.Brain("Idle", { "Idle" }, {}))
		builder:Validate()

		local message = expect.errors(function()
			Builder.new(Fakes.Entity()):Validate()
		end)
		expect.includes(message, "Definition.Brain")
	end,

	["a builder builds once"] = function(expect)
		local Builder = load()
		local builder = Builder.new(Fakes.Entity()):UseBrain(Fakes.Brain("Idle", { "Idle" }, {}))
		builder:Build():Destroy()

		local message = expect.errors(function()
			builder:Build()
		end)
		expect.includes(message, "already built an agent")
	end,

	["OnStep registers handlers by label and GetDefinition copies them"] = function(expect)
		local Builder = load()
		local function open() end
		local function climb() end
		local builder = Builder.new(Fakes.Entity()):UseBrain(Fakes.Brain("Idle", { "Idle" }, {}))
		expect.equal(builder:OnStep("Door", open), builder)
		builder:OnStep("Ladder", climb)

		local definition = builder:GetDefinition()
		expect.equal(definition.Steps.Door, open)
		expect.equal(definition.Steps.Ladder, climb)
		definition.Steps.Door = nil
		expect.equal(builder:GetDefinition().Steps.Door, open, "a copy")
	end,
}
