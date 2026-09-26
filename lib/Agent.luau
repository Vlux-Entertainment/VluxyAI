--!strict

--[[
	The running AI. Owns the tick, the blackboard, the senses, the brain runner and the navigator,
	and destroys all of them together. One Heartbeat connection per agent with an accumulator, so
	the tick rate is a number on the definition and not a hard-coded 0.1.

	Roblox is touched in exactly one place: Start reaches for RunService unless told the ticks are
	manual. Everything else is plain Luau, which is what lets a whole agent run under Lune with a
	fake mover and a fake pathfinder.
]]

local Cleaner = require(script.Parent.Utility.Cleaner)
local FormatMessage = require(script.Parent.Utility.FormatMessage)
local Navigator = require(script.Parent.Navigator)
local Runner = require(script.Parent.Brain.Runner)
local Signal = require(script.Parent.Utility.Signal)
local Tables = require(script.Parent.Utility.Tables)
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
	Destroyed: Types.Signal<()>,
	Events: Types.Signal<(string, any)>,

	_runner: Runner.Runner,
	_navigator: Navigator.Navigator?,
	_tick: number,
	_accumulator: number,
	_running: boolean,
	_destroyed: boolean,
	_eventsClosed: boolean,
	_timers: { [string]: number },
	_acknowledged: { [string]: any },
	_baseSpeed: number,
	_speedScale: number,
	_stateEnteredAt: number?,
	_paused: boolean,
	_pausedAt: number,
	_cleaner: Cleaner.Cleaner,
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
		Destroyed = Signal.new(),
		Events = Signal.new(),

		_runner = nil :: any,
		_navigator = nil,
		_tick = definition.Tick or DEFAULT_TICK,
		_accumulator = 0,
		_running = false,
		_destroyed = false,
		_eventsClosed = false,
		_timers = {},
		_acknowledged = {},
		_baseSpeed = if definition.Mover then definition.Mover:GetSpeed() else 0,
		_speedScale = 1,
		_stateEnteredAt = nil,
		_paused = false,
		_pausedAt = 0,
		_cleaner = Cleaner.new(),
	}

	local agent = setmetatable(self, Agent)
	local asContract = (agent :: any) :: Types.Agent

	self._runner = Runner.new(definition.Brain, asContract, function(new: string, old: string?)
		self._stateEnteredAt = os.clock()
		self.StateChanged:Fire(new, old)
	end)

	if definition.Pathfinder and definition.Mover then
		local navigator =
			Navigator.new(definition.Pathfinder, definition.Mover, asContract, definition.Navigation, definition.Steps)
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
		if self._destroyed then
			FormatMessage.Warn(`{self.Name}: SetState("{name}") on a destroyed agent does nothing`)
		else
			FormatMessage.Warn(`{self.Name}: SetState("{name}") before Start does nothing`)
		end
		return
	end

	self._runner:Transition(name)
end

--[[
	The agent's clock: the wall clock, frozen at the moment of Pause while paused, so timers and
	TimeInState hold still.
]]
function Agent._now(self: Agent): number
	return if self._paused then self._pausedAt else os.clock()
end

--[=[
	@within Agent
	@param name string -- Any name; `"Attack"`, `"Look"`.
	@param seconds number

	Starts (or restarts) a named timer that [Agent:TimerDone] reports on. Timers are the usual
	way a state waits: start one in `Enter`, transition when it is done.
]=]
function Agent.StartTimer(self: Agent, name: string, seconds: number)
	self._timers[name] = os.clock() + seconds
end

--[=[
	@within Agent
	@param name string
	@return boolean -- `true` when the timer has run out, or was never started.
]=]
function Agent.TimerDone(self: Agent, name: string): boolean
	local endsAt = self._timers[name]
	return endsAt == nil or self:_now() >= endsAt
end

--[=[
	@within Agent
	@param name string
	@return number -- Seconds left, `0` when done or never started.
]=]
function Agent.TimerLeft(self: Agent, name: string): number
	local endsAt = self._timers[name]
	if endsAt == nil then
		return 0
	end

	return math.max(0, endsAt - self:_now())
end

--[=[
	@within Agent
	@return number -- Seconds since the current state was entered, not counting time paused. `0` before `Start`.
]=]
function Agent.TimeInState(self: Agent): number
	local enteredAt = self._stateEnteredAt
	if enteredAt == nil then
		return 0
	end
	return self:_now() - enteredAt
end

--[=[
	@within Agent

	Freezes the agent: ticks stop, so senses, navigator and brain stand still; the mover halts;
	timers and `TimeInState` hold. For a cutscene, a jumpscare, or a director backing an enemy
	off. The navigator keeps its target and re-plans on the first tick after [Agent:Resume]. Does
	nothing when not running or already paused.
]=]
function Agent.Pause(self: Agent)
	if not self._running or self._paused then
		return
	end

	self._paused = true
	self._pausedAt = os.clock()

	-- Stopping the mover directly, not through the navigator, keeps the target: the navigator
	-- sees a mover that gave up and re-plans on its cadence once ticks resume.
	local mover = self.Mover
	if mover and mover:IsMoving() then
		mover:Stop()
	end
end

--[=[
	@within Agent

	Undoes [Agent:Pause]. Every running timer and `TimeInState` are pushed forward by the time
	spent paused, so a timer with two seconds left still has two seconds left.
]=]
function Agent.Resume(self: Agent)
	if not self._paused then
		return
	end

	local pausedFor = os.clock() - self._pausedAt
	self._paused = false

	for name, endsAt in self._timers do
		self._timers[name] = endsAt + pausedFor
	end
	if self._stateEnteredAt ~= nil then
		self._stateEnteredAt += pausedFor
	end
end

--[=[
	@within Agent
	@return boolean
]=]
function Agent.IsPaused(self: Agent): boolean
	return self._paused
end

--[=[
	@within Agent
	@param position Vector3? -- Where to face; `nil` to stop facing anything.

	Turns the body toward `position` while it stands still, so an enemy can stare at a player
	without walking. Calls the mover's optional `Face`; a mover without one ignores this.
]=]
function Agent.LookAt(self: Agent, position: Vector3?)
	local mover = self.Mover
	local face = if mover then (mover :: any).Face else nil
	if type(face) == "function" then
		face(mover, position)
	end
end

--[=[
	@within Agent
	@param position Vector3 -- Where the body goes: the root or pivot position, not a floor position.

	Puts the agent somewhere else at once and forgets the current target, so the next `MoveTo`
	plans from the new place. Uses the mover's optional `Teleport`, else pivots the entity. For a
	stalker that vanishes and reappears out of sight; pair it with [Perception.SeenByAnyone].
]=]
function Agent.Teleport(self: Agent, position: Vector3)
	if self._navigator then
		self._navigator:Stop()
	end

	local mover = self.Mover
	local teleport = if mover then (mover :: any).Teleport else nil
	if type(teleport) == "function" then
		teleport(mover, position)
		return
	end

	local entity = self.Entity :: any
	local pivot = entity:GetPivot()
	entity:PivotTo(pivot - pivot.Position + position)
end

--[=[
	@within Agent
	@param key string -- A blackboard key, usually a memory such as `HeardAt` or `HeardSoundAt`.
	@return boolean -- `true` while `Blackboard[key]` is non-nil and differs from the value last acknowledged.

	"Is there something here I have not dealt with yet?" A transition that investigates every
	new noise reads `agent:IsNew("HeardAt")` and calls [Agent:Acknowledge] when it acts, so the
	same noise is not investigated twice. [When.New] does both in one predicate.
]=]
function Agent.IsNew(self: Agent, key: string): boolean
	local value = self.Blackboard[key]
	return value ~= nil and value ~= self._acknowledged[key]
end

--[=[
	@within Agent
	@param key string

	Records the current `Blackboard[key]` as dealt with. [Agent:IsNew] is `false` for it until
	the value changes.
]=]
function Agent.Acknowledge(self: Agent, key: string)
	self._acknowledged[key] = self.Blackboard[key]
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
	if not self._running then
		local why = if self._destroyed then "on a destroyed agent" else "before Start"
		FormatMessage.Warn(`{self.Name}: MoveTo {why} does nothing`)
		return
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
	@param speed number -- Studs per second, before the speed scale.

	The agent's base speed: what a state asks for. The mover gets `speed` times the speed scale
	([Agent:SetSpeedScale]), so a crowd ease or a slow-motion effect layered on top survives a
	state changing its own speed. Does nothing without a mover.
]=]
function Agent.SetSpeed(self: Agent, speed: number)
	self._baseSpeed = speed
	if self.Mover then
		self.Mover:SetSpeed(speed * self._speedScale)
	end
end

--[=[
	@within Agent
	@param scale number -- A multiplier on the base speed; `1` is none, `0.5` half speed.

	Layered on top of whatever [Agent:SetSpeed] asked for, and kept across state changes. The
	[Neighbours] sense eases through this; a director or a stun can too.
]=]
function Agent.SetSpeedScale(self: Agent, scale: number)
	if scale == self._speedScale then
		return
	end
	self._speedScale = scale
	if self.Mover then
		self.Mover:SetSpeed(self._baseSpeed * scale)
	end
end

--[=[
	@within Agent
	@return number -- The current speed scale, `1` unless something set it.
]=]
function Agent.GetSpeedScale(self: Agent): number
	return self._speedScale
end

--[=[
	@within Agent
	@return number -- The base speed the last `SetSpeed` asked for, before the scale.
]=]
function Agent.GetSpeed(self: Agent): number
	return self._baseSpeed
end

--[=[
	@within Agent
	@param deltaTime number

	One tick: every sense, then the navigator, then the brain. Does nothing unless running. The
	Heartbeat loop calls this; a test or a custom scheduler calls it directly.
]=]
function Agent.Step(self: Agent, deltaTime: number)
	if not self._running or self._paused then
		return
	end

	local asContract = (self :: any) :: Types.Agent

	-- A sense or a state may Destroy the agent mid-tick; nothing after it may run.
	for _, sense in self.Senses do
		if not self._running then
			return
		end
		sense:Tick(asContract, deltaTime)
	end

	if not self._running then
		return
	end

	if self._navigator then
		self._navigator:Step(deltaTime)
	end

	if not self._running then
		return
	end

	self._runner:Step(deltaTime)
end

--[[
	Accumulates Heartbeat time and ticks when a tick's worth has passed. One Step per Heartbeat at
	most, so a long frame never runs the brain several times to catch up.
]]
function Agent._onHeartbeat(self: Agent, deltaTime: number)
	if self._paused then
		return
	end

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

	-- The initial Enter may have destroyed the agent; a heartbeat would then outlive it.
	if not manual and self._running then
		local RunService = game:GetService("RunService")
		self._cleaner:Connect(RunService.Heartbeat, function(deltaTime: number)
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
	@return boolean -- `true` once `Destroy` has run.

	For code that yields inside a state and needs to know whether the agent is still there when
	it wakes up.
]=]
function Agent.IsDestroyed(self: Agent): boolean
	return self._destroyed
end

--[=[
	@within Agent
	@param name string -- `"Scream"`, `"Kill"`, `"DoorOpened"`: whatever your client understands.
	@param payload any? -- Anything a remote can carry.

	Announces something for clients. Fires `Events`; a [Broadcaster] relays it, a [Replica]
	dispatches it to `On(name, ...)` handlers. Does nothing after `Destroy`.
]=]
function Agent.Emit(self: Agent, name: string, payload: any?)
	-- Events keep flowing through Destroy itself (a cancelled kill announces from an Exit that
	-- Destroy runs) and close only at the very end.
	if self._eventsClosed then
		return
	end
	self.Events:Fire(name, payload)
end

--[=[
	@within Agent

	Exits the current state, stops moving, and destroys the navigator, every sense, the mover and
	the pathfinder that have a `Destroy`, then fires `Destroyed`. Safe to call twice. The entity
	model is left alone; it is yours.
]=]
function Agent.Destroy(self: Agent)
	if self._destroyed then
		return
	end

	self._destroyed = true
	self._running = false
	self._cleaner:Destroy()

	-- Every step is protected: one part failing to tear down must not keep the others alive.
	local function guard(what: string, callback: () -> ())
		local ok, err = pcall(callback :: any)
		if not ok then
			FormatMessage.Warn(`{self.Name}: {what} errored during Destroy: {tostring(err)}`)
		end
	end

	guard("the current state's Exit", function()
		self._runner:Stop()
	end)

	if self._navigator then
		guard("the navigator", function()
			(self._navigator :: Navigator.Navigator):Destroy()
		end)
	end

	local asContract = (self :: any) :: Types.Agent
	for _, sense in self.Senses do
		local destroy = sense.Destroy
		if destroy then
			guard("a sense", function()
				destroy(sense, asContract)
			end)
		end
	end

	local mover = self.Mover
	if mover then
		local destroy = mover.Destroy
		if destroy then
			guard("the mover", function()
				destroy(mover)
			end)
		end
	end

	local pathfinder = self.Pathfinder
	if pathfinder then
		local destroy = pathfinder.Destroy
		if destroy then
			guard("the pathfinder", function()
				destroy(pathfinder)
			end)
		end
	end

	self.StateChanged:Destroy()
	-- Destroyed handlers may still Emit (a kill being cancelled); Events closes after them.
	self.Destroyed:Fire()
	self.Destroyed:Destroy()
	self._eventsClosed = true
	self.Events:Destroy()
end

return Agent
