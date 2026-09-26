--!strict

--[[
	Ready-made `When` predicates for transitions and interrupts, so a brain reads as a list of
	conditions instead of a list of small functions: has a key, a distance under a number, the
	path is done, a timer ran out, a memory is new. Each builder returns `(agent) -> boolean`.
	Pure Luau.

	The one decision worth knowing: `New` marks the value as acknowledged the moment it returns
	true. Transitions are checked in order and the first true one wins, so a `New` that returns
	true is the one that fires, and the noise it saw is dealt with. It is not a pure question.
]]

local Types = require(script.Parent.Parent.Types)

------------------------------------------------------------------------------------------------------------------------

type Predicate = (agent: Types.Agent) -> boolean

local When = {}

--[=[
	@class When

	Builders for the `When` of a [Types.Transition] or a [Types.Interrupt]. Exposed as
	`VluxyAI.When`.

	```lua
	local When = VluxyAI.When

	Interrupts = {
		{ To = "Hunt", When = When.Has("SeenTarget"), Except = { "Hunt", "Attack" } },
		{ To = "Investigate", When = When.New("HeardAt"), Except = { "Hunt", "Attack" } },
	},
	States = {
		Hunt = { Transitions = {
			{ To = "Attack", When = When.Below("SeenDistance", 4) },
			{ To = "Search", When = When.Missing("SeenPosition") },
		} },
		Search = { Transitions = { { To = "Patrol", When = When.Timer("Search") } } },
	}
	```
]=]

--[=[
	@within When
	@param key string
	@return (agent: Agent) -> boolean -- `true` while `Blackboard[key]` is not `nil`.
]=]
function When.Has(key: string): Predicate
	return function(agent: Types.Agent): boolean
		return agent.Blackboard[key] ~= nil
	end
end

--[=[
	@within When
	@param key string
	@return (agent: Agent) -> boolean -- `true` while `Blackboard[key]` is `nil`.
]=]
function When.Missing(key: string): Predicate
	return function(agent: Types.Agent): boolean
		return agent.Blackboard[key] == nil
	end
end

--[=[
	@within When
	@param key string
	@param value any
	@return (agent: Agent) -> boolean -- `true` while `Blackboard[key] == value`.
]=]
function When.Equals(key: string, value: any): Predicate
	return function(agent: Types.Agent): boolean
		return agent.Blackboard[key] == value
	end
end

--[=[
	@within When
	@param key string -- A number on the blackboard, such as `SeenDistance` or `Awareness`.
	@param limit number
	@return (agent: Agent) -> boolean -- `true` while the value is a number below `limit`. A missing key is not below anything.
]=]
function When.Below(key: string, limit: number): Predicate
	return function(agent: Types.Agent): boolean
		local value = agent.Blackboard[key]
		return type(value) == "number" and value < limit
	end
end

--[=[
	@within When
	@param key string
	@param limit number
	@return (agent: Agent) -> boolean -- `true` while the value is a number above `limit`.
]=]
function When.Above(key: string, limit: number): Predicate
	return function(agent: Types.Agent): boolean
		local value = agent.Blackboard[key]
		return type(value) == "number" and value > limit
	end
end

--[=[
	@within When
	@param key string -- A memory key that changes with each new event: `HeardAt`, `HeardSoundAt`, `LastKnownAt`.
	@return (agent: Agent) -> boolean -- `true` once per distinct value.

	"Something new is here." Reads [Agent:IsNew] and, when it is true, calls [Agent:Acknowledge]
	before returning, so the same noise fires one transition and not one per tick. A state may
	acknowledge earlier itself, and a state that wants to react again to the same value may clear
	the key.
]=]
function When.New(key: string): Predicate
	return function(agent: Types.Agent): boolean
		if agent:IsNew(key) then
			agent:Acknowledge(key)
			return true
		end
		return false
	end
end

--[=[
	@within When
	@param name string
	@return (agent: Agent) -> boolean -- [Agent:TimerDone] for `name`. A timer never started counts as done.
]=]
function When.Timer(name: string): Predicate
	return function(agent: Types.Agent): boolean
		return agent:TimerDone(name)
	end
end

--[=[
	@within When
	@param seconds number
	@return (agent: Agent) -> boolean -- `true` once the agent has been in its current state for `seconds`.
]=]
function When.InStateFor(seconds: number): Predicate
	return function(agent: Types.Agent): boolean
		return agent:TimeInState() >= seconds
	end
end

--[=[
	@within When
	@param agent Agent
	@return boolean -- The navigator reports `Arrived` or `Failed`: there is nothing more to walk.

	Not a builder: use it as a `When` directly. The usual end of a patrol leg or a search point.
]=]
function When.PathDone(agent: Types.Agent): boolean
	local status = agent:GetPathStatus()
	return status == "Arrived" or status == "Failed"
end

--[=[
	@within When
	@param agent Agent
	@return boolean -- The navigator reports `Arrived`.
]=]
function When.Arrived(agent: Types.Agent): boolean
	return agent:GetPathStatus() == "Arrived"
end

--[=[
	@within When
	@param agent Agent
	@return boolean -- The navigator reports `Failed`: no path, or one that ends short.
]=]
function When.PathFailed(agent: Types.Agent): boolean
	return agent:GetPathStatus() == "Failed"
end

--[=[
	@within When
	@param ... (agent: Agent) -> boolean
	@return (agent: Agent) -> boolean -- `true` when every predicate is. Stops at the first `false`.
]=]
function When.All(...: Predicate): Predicate
	local predicates = { ... }
	return function(agent: Types.Agent): boolean
		for _, predicate in predicates do
			if not predicate(agent) then
				return false
			end
		end
		return true
	end
end

--[=[
	@within When
	@param ... (agent: Agent) -> boolean
	@return (agent: Agent) -> boolean -- `true` when any predicate is. Stops at the first `true`.
]=]
function When.Any(...: Predicate): Predicate
	local predicates = { ... }
	return function(agent: Types.Agent): boolean
		for _, predicate in predicates do
			if predicate(agent) then
				return true
			end
		end
		return false
	end
end

--[=[
	@within When
	@param predicate (agent: Agent) -> boolean
	@return (agent: Agent) -> boolean -- The opposite.
]=]
function When.Not(predicate: Predicate): Predicate
	return function(agent: Types.Agent): boolean
		return not predicate(agent)
	end
end

return When
