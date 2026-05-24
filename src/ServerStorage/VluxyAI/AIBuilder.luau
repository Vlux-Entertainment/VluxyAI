--!strict

--[[
	Note:
	
	May be a good idea to benchmark the npc system.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Trove = require(ReplicatedStorage.Packages.trove)

------------------------------------------------------------------------------------------------------------------------

local VluxyAI = script.Parent

local RobloxPathfinding = require(VluxyAI.Pathfinding.RobloxPathfinding)

local EnvironmentBaseAgent = require(VluxyAI.BaseAgents.EnvironmentBaseAgent)
local TargetingBaseAgent = require(VluxyAI.BaseAgents.TargetingBaseAgent)

local CombatAgent = require(ServerStorage.VluxyAI.Agents.CombatAgent)
local PerceptionAgent = require(VluxyAI.Agents.PerceptionAgent)
local SpatialAgent = require(VluxyAI.Agents.SpatialAgent)

------------------------------------------------------------------------------------------------------------------------

export type State<self> = {
	Start: (self: self) -> (),
	Update: (self: self) -> string?,
	End: (self: self) -> (),
}

export type StandardStater = {
	environmentBaseAgent: EnvironmentBaseAgent.Environment,
	targetingBaseAgent: TargetingBaseAgent.Targeting,

	perceptionAgent: PerceptionAgent.Perception,
	spatialAgent: SpatialAgent.Spatial,
	combatAgent: CombatAgent.Combat,

	pathfinder: RobloxPathfinding.Pathfinding,
} & StateData

type StateData = {
	entity: Model,

	states: { [string]: State<any> },
	data: { [string]: any },

	fallbackState: string,

	_cleaner: typeof(Trove.new()),
}

------------------------------------------------------------------------------------------------------------------------

type self = {
	entity: Model,

	_stateData: StateData,

	_validated: boolean,
	_started: boolean,

	_cleaner: typeof(Trove.new()),
}

------------------------------------------------------------------------------------------------------------------------

--[[
	Deep clones a table.
]]
local function deepClone<T>(t: T): T
	local clone = {}
	for k, v in t :: any do
		clone[k] = type(v) == "table" and deepClone(v) or v
	end
	return clone :: any
end

------------------------------------------------------------------------------------------------------------------------

--[[
    Builder Class for State Pattern State Machines (SPSM).
]]
local Builder = {}
Builder.__index = Builder

export type Builder = typeof(setmetatable({} :: self, Builder))

--[[
    Builds a New SPSM Entity.
]]
function Builder.new(entity: Model): Builder
	local self = setmetatable({} :: self, Builder)
	self._cleaner = Trove.new()

	self.entity = entity

	self._validated = false
	self._started = false

	return self
end

--[[
    Checks if the FSM-AI has already been started. If it has, it will warn the user and return true.

    @param self - the object

    @return boolean - whether the FSM-AI has already been started or not
]]
function Builder._startCheck(self: Builder)
	if self._started then
		warn("FSM-AI has already been started for this entity! : " .. self.entity:GetFullName())
	end

	return self._started
end

--[[
	Sets the standard agents and pathfinder for the FSM-AI. This is a helper function to quickly set up a standard FSM-AI with the provided states and fallback state.

	@param entity - the entity to set up the FSM-AI on
	@param States - the states for the FSM-AI
	@param fallbackState - the fallback state for the FSM-AI

	@return StateData - the state data object for the FSM-AI
]]
function Builder.SetStandardStateData(self: Builder, States: { [string]: State<any> }): Builder
	local stater = {}
	stater._cleaner = Trove.new()

	stater.entity = self.entity

	stater.states = deepClone(States)
	stater.fallbackState = "unknown"
	stater.data = {}

	--agents
	stater.environmentBaseAgent = EnvironmentBaseAgent.new(self.entity)
	stater.targetingBaseAgent = TargetingBaseAgent.new(self.entity)

	stater.spatialAgent = SpatialAgent.new(self.entity, stater.environmentBaseAgent)
	stater.perceptionAgent = PerceptionAgent.new(self.entity, stater.environmentBaseAgent)
	stater.combatAgent = CombatAgent.new(self.entity, stater.targetingBaseAgent)

	stater.environmentBaseAgent:SetAgentNetworkOwner(nil)
	stater.environmentBaseAgent:SetAgentCollisionGroup("Default")

	--pathfinding
	stater.pathfinder = RobloxPathfinding.new(self.entity)

	--cleanup
	stater._cleaner:Add(stater.environmentBaseAgent._cleaner)
	stater._cleaner:Add(stater.targetingBaseAgent._cleaner)
	stater._cleaner:Add(stater.combatAgent._cleaner)
	stater._cleaner:Add(stater.perceptionAgent._cleaner)
	stater._cleaner:Add(stater.spatialAgent._cleaner)

	stater._cleaner:Add(stater.pathfinder._cleaner)

	self:SetStateData(stater)

	return self
end

--[[
    Sets the state data for the FSM-AI.

    @param self - the object
    @param stateData - the state data object

    @return self - the object
]]
function Builder.SetStateData(self: Builder, stateData: StateData & { any }): Builder
	if self:_startCheck() then
		return self
	end

	self._stateData = stateData
	self._cleaner:Add(stateData._cleaner)

	return self
end

--[[
    Checks if the build is valid and Builds the states for the FSM-AI. Can be ran multiple times.

    @param self - the object

    @return self - the object
]]
function Builder.Build(self: Builder): Builder
	if self:_startCheck() then
		return self
	end

	if not self._stateData.fallbackState then
		error("No fallback state set for FSM-AI! " .. self.entity:GetFullName())
	end

	--validate state data
	for stateName, state in self._stateData.states do
		--check if types are correct
		if type(state.Start) ~= "function" then
			error("State " .. stateName .. " is missing a Start function!")
		end

		if type(state.Update) ~= "function" then
			error("State " .. stateName .. " is missing an Update function!")
		end

		if type(state.End) ~= "function" then
			error("State " .. stateName .. " is missing an End function!")
		end

		--check if functions are valid
		if not state.Update then
			error("Update function not provided for " .. stateName .. "!")
		end

		if not state.End then
			state.End = function() end
		end

		if not state.Start then
			state.Start = function() end
		end
	end

	self._validated = true

	return self
end

--[[
    Starts the FSM-AI. Can only be ran once.

    @param self - the object

    @return self - the object
]]
function Builder.Start(self: Builder): Builder
	if not self._stateData then
		warn("AI was not built! " .. self.entity:GetFullName())
		return self
	end
	if not self._validated then
		warn("FSM-AI has not been validated for this entity! : " .. self.entity:GetFullName())
		return self
	end
	if self:_startCheck() then
		return self
	end

	self._started = true

	self._cleaner:Add(task.spawn(function()
		local nextState = self:_getStateFromName(self._stateData.fallbackState)

		while true do
			nextState = self:_getStateFromName(self:_runState(nextState))
		end
	end))

	return self
end

--[[
	Runs the state and returns the next state name. If the next state name is nil, it will return the fallback state.

	@yields

	@param self - the object
	@param state - the state to run

	@return string - the name of the next state
]]
function Builder._runState(self: Builder, state: State<any>): string
	local nextStateName: string = nil
	local cleaner = self._cleaner:Extend()
	local stateChanged = cleaner:Add(Instance.new("BindableEvent"))

	state.Start(self._stateData)

	--setting to change the update speed should be added in soon
	local prevTime = os.clock()
	cleaner:Connect(RunService.Heartbeat, function()
		if os.clock() - prevTime < 0.1 then
			return
		end
		prevTime = os.clock()

		local newStateName = state.Update(self._stateData)

		if newStateName then
			nextStateName = newStateName
			stateChanged:Fire()
		end
	end)

	stateChanged.Event:Wait()
	cleaner:Destroy()

	state.End(self._stateData)

	return nextStateName
end

--[[
	Gets the state from the state name. If the state name is nil or invalid, it will return the fallback state.

	@param self - the object
	@param stateName - the name of the state

	@return State - the state object
]]
function Builder._getStateFromName(self: Builder, stateName: string?): State<any>
	if stateName == nil then
		warn("No state was provided, going to fallback state! " .. self.entity:GetFullName())

		return self._stateData.states[self._stateData.fallbackState]
	elseif not self._stateData.states[stateName] then
		warn("State name is not valid, going to fallback state! " .. self.entity:GetFullName())

		return self._stateData.states[self._stateData.fallbackState]
	else
		return self._stateData.states[stateName]
	end
end

--[[
    Destroys the FSM-AI and cleans up all connections. Can only be ran once.

    @param self - the object
]]
function Builder.Destroy(self: Builder)
	self._cleaner:Destroy()
end

return Builder
