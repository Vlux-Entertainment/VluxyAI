--!strict

--[[
	Runs a Brain table: enters the initial state, checks each state's ordered transitions before
	its Update every tick, and swaps states through Exit then Enter. Pure Luau with no notion of
	time or Roblox; the Agent drives Step from its tick and tests drive it by hand.

	The brain is assumed valid: Validate ran on it before a Runner is made. The one check that is
	only possible at runtime, an Update returning a state name that does not exist, warns and stays
	put rather than erroring, because a typo in a rarely hit branch should not kill the AI.
]]

local FormatMessage = require(script.Parent.Parent.Utility.FormatMessage)
local Types = require(script.Parent.Parent.Types)

------------------------------------------------------------------------------------------------------------------------

type self = {
	_brain: Types.Brain,
	_agent: Types.Agent,
	_current: string?,
	_onChanged: ((new: string, old: string?) -> ())?,
	_generation: number,
}

local Runner = {}
Runner.__index = Runner

export type Runner = typeof(setmetatable({} :: self, Runner))

--[[
	Creates a runner for a brain. `onChanged` is called after every state change with the new and
	previous names; the Agent forwards it to its StateChanged signal.
]]
function Runner.new(brain: Types.Brain, agent: Types.Agent, onChanged: ((new: string, old: string?) -> ())?): Runner
	local self: self = {
		_brain = brain,
		_agent = agent,
		_current = nil,
		_onChanged = onChanged,
		_generation = 0,
	}

	return setmetatable(self, Runner)
end

--[[
	Enters the initial state. Does nothing if already running.
]]
function Runner.Start(self: Runner)
	if self._current ~= nil then
		return
	end

	self:Transition(self._brain.Initial)
end

--[[
	The current state name, or nil when not running.
]]
function Runner.GetState(self: Runner): string?
	return self._current
end

--[[
	Exits the current state and enters `name`, even when `name` is the current state. An unknown
	name warns and changes nothing. A transition started from inside Enter wins over the one that
	called it: the outer call sees the generation move on and does not touch the state again.
]]
function Runner.Transition(self: Runner, name: string)
	local state = self._brain.States[name]
	if state == nil then
		FormatMessage.Warn(
			`{self._agent.Name}: state "{name}" does not exist, staying in "{self._current or "nothing"}"`
		)
		return
	end

	local previous = self._current
	local previousState = if previous then self._brain.States[previous] else nil

	self._generation += 1
	local generation = self._generation

	if previousState and previousState.Exit then
		previousState.Exit(self._agent)
	end

	-- Exit may have transitioned elsewhere already; that later transition owns the state now.
	if self._generation ~= generation then
		return
	end

	self._current = name

	if self._onChanged then
		self._onChanged(name, previous)
	end

	if state.Enter then
		state.Enter(self._agent)
	end
end

--[[
	One tick: the first true transition wins, otherwise Update runs and may name the next state.
	Nothing happens when not running.
]]
function Runner.Step(self: Runner, deltaTime: number)
	local current = self._current
	if current == nil then
		return
	end

	local state = self._brain.States[current]

	if state.Transitions then
		for _, transition in state.Transitions do
			if transition.When(self._agent) then
				self:Transition(transition.To)
				return
			end
		end
	end

	if state.Update then
		local next = state.Update(self._agent, deltaTime)

		-- Update may have forced a state change through SetState; do not stack another on it.
		if next ~= nil and next ~= current and self._current == current then
			self:Transition(next)
		end
	end
end

--[[
	Exits the current state and stops. Start can be called again afterwards.
]]
function Runner.Stop(self: Runner)
	local current = self._current
	if current == nil then
		return
	end

	local state = self._brain.States[current]
	self._generation += 1
	self._current = nil

	if state.Exit then
		state.Exit(self._agent)
	end
end

return Runner
