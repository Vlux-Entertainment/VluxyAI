--!strict

--[[
	The server half of client-side presentation. Watches one agent and turns what a client needs
	into a few signals: state changes, a position and facing sample at a fixed rate, and the
	events the agent emits. The game connects those to its own remotes; the package owns no
	remotes and never decides how they are shaped.

	The position sample is only worth sending in puppet mode, where the client owns the rig and the
	server holds a logical position. In mirror mode the rig replicates on its own and the game
	only forwards states and events.
]]

local FormatMessage = require(script.Parent.Parent.Utility.FormatMessage)
local Options = require(script.Parent.Parent.Utility.Options)
local Signal = require(script.Parent.Parent.Utility.Signal)
local Trove = require(script.Parent.Parent.Utility.Trove)
local Types = require(script.Parent.Parent.Types)

------------------------------------------------------------------------------------------------------------------------

local DEFAULT_OPTIONS = table.freeze({
	-- Position samples per second. 0 sends none (mirror mode).
	PositionRate = 10,
	-- A sample is skipped when the rig moved less than this and turned less than TurnEpsilon.
	MoveEpsilon = 0.05,
	TurnEpsilon = 0.01,
})

--[=[
	@interface BroadcasterOptions
	@within Broadcaster

	.PositionRate number? -- Position samples per second. `0` sends none. Default `10`.
	.MoveEpsilon number? -- Studs the rig must move to be worth a sample. Default `0.05`.
	.TurnEpsilon number? -- Radians the rig must turn to be worth a sample. Default `0.01`.
]=]
export type BroadcasterOptions = {
	PositionRate: number?,
	MoveEpsilon: number?,
	TurnEpsilon: number?,
}

type ResolvedOptions = {
	PositionRate: number,
	MoveEpsilon: number,
	TurnEpsilon: number,
}

type self = {
	StateChanged: Types.Signal<(string, string?)>,
	PositionChanged: Types.Signal<(Vector3, number)>,
	EventSent: Types.Signal<(string, any)>,

	_agent: Types.Agent,
	_options: ResolvedOptions,
	_elapsed: number,
	_lastPosition: Vector3?,
	_lastYaw: number?,
	_trove: Trove.Trove,
}

local Broadcaster = {}
Broadcaster.__index = Broadcaster

type BroadcasterClass = typeof(setmetatable({} :: self, Broadcaster))

--[=[
	@interface Broadcaster
	@within Broadcaster

	.StateChanged Signal<(string, string?)> -- Relayed from the agent.
	.PositionChanged Signal<(Vector3, number)> -- The rig's pivot position and yaw, at `PositionRate`.
	.EventSent Signal<(string, any)> -- Relayed from `agent.Events`.
	.Step (self: Broadcaster, deltaTime: number) -> ()
	.Snapshot (self: Broadcaster) -> Snapshot
	.Destroy (self: Broadcaster) -> ()

	What `new` returns.
]=]
export type Broadcaster = {
	StateChanged: Types.Signal<(string, string?)>,
	PositionChanged: Types.Signal<(Vector3, number)>,
	EventSent: Types.Signal<(string, any)>,
	Step: (self: Broadcaster, deltaTime: number) -> (),
	Snapshot: (self: Broadcaster) -> Types.Snapshot,
	Destroy: (self: Broadcaster) -> (),
}

--[[
	The yaw of a pivot, the only part of the facing a rig needs.
]]
local function yawOf(cframe: CFrame): number
	local look = cframe.LookVector
	return math.atan2(-look.X, -look.Z)
end

--[=[
	@class Broadcaster

	Watches an [Agent] on the server and produces what a client [Replica] consumes: state
	changes, pivot position samples at a rate, and emitted events. Make it before `agent:Start()`
	so the initial state is relayed; nothing emitted before it existed is replayed. Wire its
	signals to your remotes:

	```lua
	local broadcaster = VluxyAI.Sync.Broadcaster.new(agent)
	broadcaster.StateChanged:Connect(function(state)
		syncRemote:FireAllClients({ Kind = "State", Id = id, State = state })
	end)
	broadcaster.EventSent:Connect(function(name, payload)
		syncRemote:FireAllClients({ Kind = "Event", Id = id, Name = name, Payload = payload })
	end)
	```

	`Snapshot` gives a late joiner everything at once.
]=]

--[=[
	@within Broadcaster
	@param agent Agent
	@param options BroadcasterOptions?
	@return Broadcaster
]=]
function Broadcaster.new(agent: Types.Agent, options: BroadcasterOptions?): Broadcaster
	local resolved = Options.Resolve("Broadcaster.new", DEFAULT_OPTIONS, options :: any) :: ResolvedOptions
	if resolved.PositionRate < 0 then
		FormatMessage.Error(`Broadcaster.new: PositionRate must be 0 or more, got {resolved.PositionRate}`, 2)
	end

	local trove = Trove.new()
	local self: self = {
		StateChanged = Signal.new(),
		PositionChanged = Signal.new(),
		EventSent = Signal.new(),

		_agent = agent,
		_options = resolved,
		_elapsed = 0,
		_lastPosition = nil,
		_lastYaw = nil,
		_trove = trove,
	}

	local broadcaster = setmetatable(self, Broadcaster) :: BroadcasterClass

	trove:Connect(agent.StateChanged, function(new: string, old: string?)
		self.StateChanged:Fire(new, old)
	end)
	trove:Connect(agent.Events, function(name: string, payload: any)
		self.EventSent:Fire(name, payload)
	end)
	trove:Connect(agent.Destroyed, function()
		-- Other Destroyed handlers (a kill being cancelled) still emit in this same tick.
		task.defer(function()
			broadcaster:Destroy()
		end)
	end)

	if resolved.PositionRate > 0 then
		local RunService = game:GetService("RunService")
		trove:Connect(RunService.Heartbeat, function(deltaTime: number)
			broadcaster:Step(deltaTime)
		end)
	end

	return broadcaster :: any
end

--[=[
	@within Broadcaster
	@param deltaTime number

	One frame of the position sampler. Driven by Heartbeat; a test calls it directly.
]=]
function Broadcaster.Step(self: BroadcasterClass, deltaTime: number)
	local rate = self._options.PositionRate
	if rate <= 0 then
		return
	end

	local interval = 1 / rate
	self._elapsed += deltaTime
	if self._elapsed < interval then
		return
	end
	-- Carry the remainder so frames near the interval do not halve the rate; cap it so a long
	-- stall does not burst.
	self._elapsed = math.min(self._elapsed - interval, interval)

	local pivot = self._agent.Entity:GetPivot()
	local position = pivot.Position
	local yaw = yawOf(pivot)

	local lastPosition = self._lastPosition
	local lastYaw = self._lastYaw
	if
		lastPosition ~= nil
		and lastYaw ~= nil
		and (position - lastPosition).Magnitude < self._options.MoveEpsilon
		and math.abs(yaw - lastYaw) < self._options.TurnEpsilon
	then
		return
	end

	self._lastPosition = position
	self._lastYaw = yaw
	self.PositionChanged:Fire(position, yaw)
end

--[=[
	@within Broadcaster
	@return Snapshot -- The current state, position and yaw, for a client that just joined.
]=]
function Broadcaster.Snapshot(self: BroadcasterClass): Types.Snapshot
	local pivot = self._agent.Entity:GetPivot()
	return {
		State = self._agent:GetState(),
		Position = pivot.Position,
		Yaw = yawOf(pivot),
	}
end

--[=[
	@within Broadcaster

	Disconnects from the agent. Happens on its own when the agent is destroyed.
]=]
function Broadcaster.Destroy(self: BroadcasterClass)
	self._trove:Destroy()
	self.StateChanged:Destroy()
	self.PositionChanged:Destroy()
	self.EventSent:Destroy()
end

return Broadcaster
