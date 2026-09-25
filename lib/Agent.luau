--!strict

--[[
	The running AI. Owns the tick, the blackboard, the senses, the brain runner and the navigator,
	and destroys all of them together. One Heartbeat connection per agent with an accumulator, so
	the tick rate is a number on the definition and not a hard-coded 0.1.

	Roblox is touched in exactly one place: Start reaches for RunService unless told the ticks are
	manual. Everything else is plain Luau, which is what lets a whole agent run under Lune with a
	fake mover and a fake pathfinder.
]]

local FormatMessage = require(script.Parent.Utility.FormatMessage)
local Navigator = require(script.Parent.Navigator)
local Runner = require(script.Parent.Brain.Runner)
local Signal = require(script.Parent.Utility.Signal)
local Tables = require(script.Parent.Utility.Tables)
local Trove = require(script.Parent.Utility.Trove)
local Types = require(script.Parent.Types)
local Validate = require(script.Parent.Brain.Validate)

------------------------------------------------------------------------------------------------------------------------

local DEFAULT_TICK = 0.1

type self = {
	Entity: Model,
	Name: string,
	Blackboard: Types.Blackboard,
	Data: { [string]: any },
	Brain: Types.Brain,
	Senses: { Types.Sense },
	Navigator: Types.Navigator?,
	Mover: Types.Mover?,
	Pathfinder: Types.Pathfinder?,
	StateChanged: Types.Signal<(string, string?)>,

	_runner: Runner.Runner,
	_navigator: Navigator.Navigator?,
	_tick: number,
	_accumulator: number,
	_running: boolean,
	_destroyed: boolean,
	_trove: Trove.Trove,
}

local Agent = {}
Agent.__index = Agent

export type Agent = typeof(setmetatable({} :: self, Agent))

--[=[
	@class Agent

	The running AI: what every `Enter`, `Update`, `Exit`, `When` and `Input` function receives.
	Made by [Builder:Build] or `VluxyAI.NewAgent`, started with [Agent:Start], and taken apart with
	[Agent:Destroy]. See [Types.Agent] for the fields.
]=]

--[=[
	@within Agent
	@param definition AgentDefinition
	@return Agent
	@error string -- The definition failed [Validate.Definition].

	Builds an agent from a definition. Blackboard and Data initial values are deep-copied, so one
	definition can make many agents. The agent is not running until [Agent:Start].
]=]
function Agent.new(definition: Types.AgentDefinition): Types.Agent
	Validate.Definition(definition)

	local entity = definition.Entity
	local name = definition.Name or (entity :: any).Name or "Agent"

	local self: self = {
		Entity = entity,
		Name = name,
		Blackboard = Tables.DeepCopy(definition.Blackboard or {}),
		Data = Tables.DeepCopy(definition.Data or {}),
		Brain = definition.Brain,
		Senses = table.clone(definition.Senses or {}),
		Navigator = nil,
		Mover = definition.Mover,
		Pathfinder = definition.Pathfinder,
		StateChanged = Signal.new(),

		_runner = nil :: any,
		_navigator = nil,
		_tick = definition.Tick or DEFAULT_TICK,
		_accumulator = 0,
		_running = false,
		_destroyed = false,
		_trove = Trove.new(),
	}

	local agent = setmetatable(self, Agent)
	local asContract = (agent :: any) :: Types.Agent

	self._runner = Runner.new(definition.Brain, asContract, function(new: string, old: string?)
		self.StateChanged:Fire(new, old)
	end)

	if definition.Pathfinder and definition.Mover then
		local navigator = Navigator.new(definition.Pathfinder, definition.Mover, asContract, definition.Navigation)
		self._navigator = navigator
		self.Navigator = navigator :: any
	end

	-- The contract type is what callers get: a metatable class is not structurally assignable to
	-- its interface under the current solver, so the cast happens once, here.
	return (agent :: any) :: Types.Agent
end

------------------------------------------------------------------------------------------------------------------------

--[=[
	@within Agent
	@return string? -- `nil` before `Start` and after `Destroy`.
]=]
function Agent.GetState(self: Agent): string?
	return self._runner:GetState()
end

--[=[
	@within Agent
	@param name string

	Forces a transition, running `Exit` and `Enter` even when `name` is already current. An unknown
	name warns and does nothing. Does nothing before `Start`.
]=]
function Agent.SetState(self: Agent, name: string)
	if not self._running then
		FormatMessage.Warn(`{self.Name}: SetState("{name}") before Start does nothing`)
		return
	end

	self._runner:Transition(name)
end

--[=[
	@within Agent
	@param target Vector3
	@error string -- The agent has no navigator.

	Shorthand for `agent.Navigator:MoveTo(target)`.
]=]
function Agent.MoveTo(self: Agent, target: Vector3)
	local navigator = self._navigator
	if navigator == nil then
		FormatMessage.Error(`{self.Name}: MoveTo needs a Pathfinder and a Mover on the definition`, 2)
	end

	(navigator :: Navigator.Navigator):MoveTo(target)
end

--[=[
	@within Agent

	Shorthand for `agent.Navigator:Stop()`. Does nothing without a navigator.
]=]
function Agent.Stop(self: Agent)
	if self._navigator then
		self._navigator:Stop()
	end
end

--[=[
	@within Agent
	@return Vector3 -- The mover's position, or the entity's pivot without one.
]=]
function Agent.GetPosition(self: Agent): Vector3
	if self.Mover then
		return self.Mover:GetPosition()
	end

	return self.Entity:GetPivot().Position
end

--[=[
	@within Agent
	@return boolean -- `true` while the navigator reports `Arrived`.
]=]
function Agent.HasArrived(self: Agent): boolean
	return self._navigator ~= nil and self._navigator:GetStatus() == "Arrived"
end

--[=[
	@within Agent
	@return PathStatus -- The navigator's status, or `Idle` without a navigator.
]=]
function Agent.GetPathStatus(self: Agent): Types.PathStatus
	if self._navigator then
		return self._navigator:GetStatus()
	end

	return "Idle"
end

--[=[
	@within Agent
	@param speed number -- Studs per second.

	Shorthand for `agent.Mover:SetSpeed(speed)`. Does nothing without a mover.
]=]
function Agent.SetSpeed(self: Agent, speed: number)
	if self.Mover then
		self.Mover:SetSpeed(speed)
	end
end

--[=[
	@within Agent
	@param deltaTime number

	One tick: every sense, then the navigator, then the brain. Does nothing unless running. The
	Heartbeat loop calls this; a test or a custom scheduler calls it directly.
]=]
function Agent.Step(self: Agent, deltaTime: number)
	if not self._running then
		return
	end

	local asContract = (self :: any) :: Types.Agent

	for _, sense in self.Senses do
		sense:Tick(asContract, deltaTime)
	end

	if self._navigator then
		self._navigator:Step(deltaTime)
	end

	self._runner:Step(deltaTime)
end

--[[
	Accumulates Heartbeat time and ticks when a tick's worth has passed. One Step per Heartbeat at
	most, so a long frame never runs the brain several times to catch up.
]]
function Agent._onHeartbeat(self: Agent, deltaTime: number)
	self._accumulator += deltaTime
	if self._accumulator < self._tick then
		return
	end

	local elapsed = self._accumulator
	self._accumulator = 0
	self:Step(elapsed)
end

--[=[
	@within Agent
	@param manual boolean? -- Skip the Heartbeat loop; you call [Agent:Step] yourself.
	@return Agent
	@error string -- The agent was destroyed.

	Enters the brain's initial state and starts ticking. Calling it again does nothing.
]=]
function Agent.Start(self: Agent, manual: boolean?): Agent
	if self._destroyed then
		FormatMessage.Error(`{self.Name}: cannot Start a destroyed agent`, 2)
	end
	if self._running then
		return self
	end

	self._running = true
	self._runner:Start()

	if not manual then
		local RunService = game:GetService("RunService")
		self._trove:Connect(RunService.Heartbeat, function(deltaTime: number)
			self:_onHeartbeat(deltaTime)
		end)
	end

	return self
end

--[=[
	@within Agent
	@return boolean
]=]
function Agent.IsRunning(self: Agent): boolean
	return self._running
end

--[=[
	@within Agent

	Exits the current state, stops moving, and destroys the navigator, every sense, the mover and
	the pathfinder that have a `Destroy`. Safe to call twice. The entity model is left alone; it is
	yours.
]=]
function Agent.Destroy(self: Agent)
	if self._destroyed then
		return
	end

	self._destroyed = true
	self._running = false
	self._trove:Destroy()

	self._runner:Stop()

	if self._navigator then
		self._navigator:Destroy()
	end

	for _, sense in self.Senses do
		local destroy = sense.Destroy
		if destroy then
			destroy(sense)
		end
	end

	local mover = self.Mover
	if mover then
		local destroy = mover.Destroy
		if destroy then
			destroy(mover)
		end
	end

	local pathfinder = self.Pathfinder
	if pathfinder then
		local destroy = pathfinder.Destroy
		if destroy then
			destroy(pathfinder)
		end
	end

	self.StateChanged:Destroy()
end

return Agent
