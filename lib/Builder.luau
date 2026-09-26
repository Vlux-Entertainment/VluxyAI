--!strict

--[[
	The fluent front door. Each method fills one field of an AgentDefinition and returns the
	builder, so an AI reads as a stack of choices; Build validates the lot and returns the Agent.
	Nothing here knows what a pathfinder or a sense does; it only carries them.
]]

local Agent = require(script.Parent.Agent)
local FormatMessage = require(script.Parent.Utility.FormatMessage)
local Types = require(script.Parent.Types)
local Validate = require(script.Parent.Brain.Validate)

------------------------------------------------------------------------------------------------------------------------

type self = {
	_definition: Types.AgentDefinition,
	_built: boolean,
}

local Builder = {}
Builder.__index = Builder

export type Builder = typeof(setmetatable({} :: self, Builder))

--[=[
	@class Builder

	Stacks the parts of an AI and builds an [Agent] from them.

	```lua
	local agent = VluxyAI.new(model)
		:UseBrain(Stalker)
		:UsePathfinder(VluxyAI.Pathfinders.Navmesh.new({ AgentRadius = 2 }))
		:UseMover(VluxyAI.Movers.Humanoid.new(model))
		:AddSense(VluxyAI.Senses.Sight.new({ Range = 40 }))
		:Build()
		:Start()
	```

	Every method returns the builder. [Builder:Build] validates the definition and errors with the
	path of the first bad field. A builder makes one agent; call `VluxyAI.new` again for the next.
]=]

--[=[
	@within Builder
	@param entity Model -- The model the AI drives. Needs a `PrimaryPart`.
	@return Builder
]=]
function Builder.new(entity: Model): Builder
	local self: self = {
		_definition = {
			Entity = entity,
			Brain = nil :: any,
		},
		_built = false,
	}

	return setmetatable(self, Builder)
end

--[=[
	@within Builder
	@param brain Brain
	@return Builder
]=]
function Builder.UseBrain(self: Builder, brain: Types.Brain): Builder
	self._definition.Brain = brain
	return self
end

--[=[
	@within Builder
	@param pathfinder Pathfinder
	@return Builder
]=]
function Builder.UsePathfinder(self: Builder, pathfinder: Types.Pathfinder): Builder
	self._definition.Pathfinder = pathfinder
	return self
end

--[=[
	@within Builder
	@param mover Mover
	@return Builder
]=]
function Builder.UseMover(self: Builder, mover: Types.Mover): Builder
	self._definition.Mover = mover
	return self
end

--[=[
	@within Builder
	@param sense Sense
	@return Builder

	Adds a sense. Senses tick in the order they were added.
]=]
function Builder.AddSense(self: Builder, sense: Types.Sense): Builder
	local senses = self._definition.Senses or {}
	table.insert(senses, sense)
	self._definition.Senses = senses
	return self
end

--[=[
	@within Builder
	@param values Blackboard -- Initial blackboard values, deep-copied per agent.
	@return Builder
]=]
function Builder.SetBlackboard(self: Builder, values: Types.Blackboard): Builder
	self._definition.Blackboard = values
	return self
end

--[=[
	@within Builder
	@param values { [string]: any } -- Initial `agent.Data`, deep-copied per agent.
	@return Builder
]=]
function Builder.SetData(self: Builder, values: { [string]: any }): Builder
	self._definition.Data = values
	return self
end

--[=[
	@within Builder
	@param seconds number -- Seconds between ticks. Default `0.1`.
	@return Builder
]=]
function Builder.SetTick(self: Builder, seconds: number): Builder
	self._definition.Tick = seconds
	return self
end

--[=[
	@within Builder
	@param options NavigationOptions
	@return Builder
]=]
function Builder.SetNavigation(self: Builder, options: Types.NavigationOptions): Builder
	self._definition.Navigation = options
	return self
end

--[=[
	@within Builder
	@param label string -- The step `Label` this handles: `"Door"`, `"Ladder"`, `"Vault"`.
	@param handler StepHandler -- Runs when a step with that label is reached; may yield.
	@return Builder

	What the agent does at a labelled step. The navigator holds the mover there, reports
	`Interacting`, runs the handler in its own thread, and walks on when it returns.

	```lua
	:OnStep("Door", function(agent, step)
		Doors.Open(step.Instance)
		task.wait(0.4)
	end)
	```
]=]
function Builder.OnStep(self: Builder, label: string, handler: Types.StepHandler): Builder
	local steps: { [string]: Types.StepHandler } = self._definition.Steps or {}
	self._definition.Steps = steps
	steps[label] = handler
	return self
end

--[=[
	@within Builder
	@param enabled boolean? -- Default `true`.
	@return Builder

	Development aid: the agent warns once for a blackboard read that looks like a typo of a key
	something has written (`SeenTaget` for `SeenTarget`). Nothing is typed; the check is by
	spelling, so a legitimate `nil` read of a real key stays quiet.
]=]
function Builder.SetStrictBlackboard(self: Builder, enabled: boolean?): Builder
	self._definition.StrictBlackboard = if enabled == nil then true else enabled
	return self
end

--[=[
	@within Builder
	@param name string -- Used in warnings and errors. Default the entity's name.
	@return Builder
]=]
function Builder.SetName(self: Builder, name: string): Builder
	self._definition.Name = name
	return self
end

--[=[
	@within Builder
	@return AgentDefinition -- A shallow copy of what has been stacked so far.

	For inspection, tests, or handing to `VluxyAI.NewAgent` later.
]=]
function Builder.GetDefinition(self: Builder): Types.AgentDefinition
	local copy = table.clone(self._definition)
	if copy.Senses then
		copy.Senses = table.clone(copy.Senses)
	end
	if copy.Steps then
		copy.Steps = table.clone(copy.Steps)
	end
	return copy
end

--[=[
	@within Builder
	@error string -- The path and problem of the first bad field.

	Validates without building. Useful to check a content module in a test.
]=]
function Builder.Validate(self: Builder)
	Validate.Definition(self._definition)
end

--[=[
	@within Builder
	@return Agent
	@error string -- The path and problem of the first bad field, or the builder was already used.

	Validates and builds the agent. The agent is not running; chain [Agent:Start].
]=]
function Builder.Build(self: Builder): Types.Agent
	if self._built then
		FormatMessage.Error("this Builder already built an agent; call VluxyAI.new again for another", 2)
	end

	local agent = Agent.new(self._definition)
	self._built = true

	return agent
end

return Builder
