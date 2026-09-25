--!strict

--[[
	The client half of client-side presentation. Holds a rig and a table of client states, the
	visuals, and is fed by the game's remote handlers: SetState runs the matching visual state's
	Exit and Enter, SetPosition gives it somewhere to smooth toward, Receive hands an emitted event
	to whoever asked for it. Every state a client needs to react to is content you write, in the
	same Enter, Update, Exit shape as a brain, with the replica in place of the agent.

	Two modes. Mirror: the rig is the server's own, replicated by Roblox, and the replica only runs
	visuals on it. Puppet: the server rig is invisible or absent, the replica owns this rig and
	moves it toward the streamed position, smoothed so the sample rate never shows.
]]

local FormatMessage = require(script.Parent.Parent.Utility.FormatMessage)
local Options = require(script.Parent.Parent.Utility.Options)
local Signal = require(script.Parent.Parent.Utility.Signal)
local Trove = require(script.Parent.Parent.Utility.Trove)
local Types = require(script.Parent.Parent.Types)

------------------------------------------------------------------------------------------------------------------------

local DEFAULT_OPTIONS = table.freeze({
	-- Puppet mode moves the rig; mirror mode leaves it to replication.
	Puppet = false,
	-- Studs per second the rig may catch up toward the latest sample; 0 snaps.
	Smoothing = 24,
	-- Radians per second the rig may turn; 0 snaps.
	TurnSmoothing = 12,
	-- Added to streamed positions, for a rig whose pivot sits above its floor point.
	HeightOffset = 0,
})

--[=[
	@interface ReplicaOptions
	@within Replica

	.Entity PVInstance -- The rig, or anything with `GetPivot` and `PivotTo`.
	.Visuals Visuals? -- Client states keyed by server state name. Missing states are fine.
	.Puppet boolean? -- `true` to move the rig toward streamed positions. Default `false`.
	.Smoothing number? -- Studs per second of catch-up in puppet mode; `0` snaps. Default `24`.
	.TurnSmoothing number? -- Radians per second of turning in puppet mode; `0` snaps. Default `12`.
	.HeightOffset number? -- Added to streamed positions, for a client rig whose pivot sits higher than the server's. Default `0`.
]=]
export type ReplicaOptions = {
	Entity: PVInstance,
	Visuals: Types.Visuals?,
	Puppet: boolean?,
	Smoothing: number?,
	TurnSmoothing: number?,
	HeightOffset: number?,
}

type ResolvedOptions = {
	Puppet: boolean,
	Smoothing: number,
	TurnSmoothing: number,
	HeightOffset: number,
}

type Handler = {
	Callback: (payload: any) -> (),
	Connection: Types.Connection,
}

type self = {
	Entity: PVInstance,
	Data: { [string]: any },
	StateChanged: Types.Signal<(string, string?)>,
	Events: Types.Signal<(string, any)>,

	_visuals: Types.Visuals,
	_options: ResolvedOptions,
	_state: string?,
	_targetPosition: Vector3?,
	_targetYaw: number?,
	_handlers: { [string]: { Handler } },
	_exiting: string?,
	_destroyed: boolean,
	_trove: Trove.Trove,
}

local Replica = {}
Replica.__index = Replica

type ReplicaClass = typeof(setmetatable({} :: self, Replica))

--[=[
	@interface Replica
	@within Replica

	.Entity PVInstance -- The rig.
	.Data { [string]: any } -- Yours: highlights, sounds, whatever a visual state makes.
	.StateChanged Signal<(string, string?)> -- Fired by `SetState`.
	.Events Signal<(string, any)> -- Fired by `Receive`, for every event.
	.GetState (self: Replica) -> string?
	.SetState (self: Replica, name: string) -> ()
	.SetPosition (self: Replica, position: Vector3, yaw: number?) -> ()
	.ApplySnapshot (self: Replica, snapshot: Snapshot) -> ()
	.On (self: Replica, name: string, handler: (payload: any) -> ()) -> Connection
	.Receive (self: Replica, name: string, payload: any) -> ()
	.Step (self: Replica, deltaTime: number) -> ()
	.Destroy (self: Replica) -> ()

	What `new` returns, and what every visual state receives.
]=]
export type Replica = {
	Entity: PVInstance,
	Data: { [string]: any },
	StateChanged: Types.Signal<(string, string?)>,
	Events: Types.Signal<(string, any)>,
	GetState: (self: Replica) -> string?,
	SetState: (self: Replica, name: string) -> (),
	SetPosition: (self: Replica, position: Vector3, yaw: number?) -> (),
	ApplySnapshot: (self: Replica, snapshot: Types.Snapshot) -> (),
	On: (self: Replica, name: string, handler: (payload: any) -> ()) -> Types.Connection,
	Receive: (self: Replica, name: string, payload: any) -> (),
	Step: (self: Replica, deltaTime: number) -> (),
	Destroy: (self: Replica) -> (),
}

local function yawOf(cframe: CFrame): number
	local look = cframe.LookVector
	return math.atan2(-look.X, -look.Z)
end

local function shortestTurn(from: number, to: number): number
	local turn = (to - from + math.pi) % (2 * math.pi) - math.pi
	return turn
end

--[=[
	@class Replica

	The client side of an enemy: a rig, a table of client states, and three inputs the game's
	remote handlers call. Runs on the client; the package is `shared` realm so it is there.

	```lua
	local replica = VluxyAI.Sync.Replica.new({
		Entity = model,
		Visuals = {
			Hunt = {
				Enter = function(replica) replica.Data.Highlight.Enabled = true end,
				Exit = function(replica) replica.Data.Highlight.Enabled = false end,
			},
		},
	})
	replica:On("Kill", function(payload) ... end)

	syncRemote.OnClientEvent:Connect(function(message)
		if message.Kind == "State" then replica:SetState(message.State)
		elseif message.Kind == "Position" then replica:SetPosition(message.Position, message.Yaw)
		elseif message.Kind == "Event" then replica:Receive(message.Name, message.Payload) end
	end)
	```
]=]

--[=[
	@within Replica
	@param options ReplicaOptions
	@return Replica
]=]
function Replica.new(options: ReplicaOptions): Replica
	if type(options) ~= "table" or (options :: any).Entity == nil then
		FormatMessage.Error("Replica.new: options.Entity is required", 2)
	end
	local entity = options.Entity
	if type((entity :: any).GetPivot) ~= "function" or type((entity :: any).PivotTo) ~= "function" then
		FormatMessage.Error(`Replica.new: Entity needs GetPivot and PivotTo, got {tostring(entity)}`, 2)
	end

	local given = table.clone(options :: any) :: { [string]: any }
	given.Entity = nil
	local visuals = given.Visuals or {}
	given.Visuals = nil
	local resolved = Options.Resolve("Replica.new", DEFAULT_OPTIONS, given) :: ResolvedOptions

	local trove = Trove.new()
	local self: self = {
		Entity = entity,
		Data = {},
		StateChanged = Signal.new(),
		Events = Signal.new(),

		_visuals = visuals,
		_options = resolved,
		_state = nil,
		_targetPosition = nil,
		_targetYaw = nil,
		_handlers = {},
		_exiting = nil,
		_destroyed = false,
		_trove = trove,
	}

	local replica = setmetatable(self, Replica) :: ReplicaClass

	local RunService = game:GetService("RunService")
	trove:Connect(RunService.Heartbeat, function(deltaTime: number)
		replica:Step(deltaTime)
	end)

	return replica :: any
end

--[=[
	@within Replica
	@return string? -- The last state set, `nil` before the first.
]=]
function Replica.GetState(self: ReplicaClass): string?
	return self._state
end

--[=[
	@within Replica
	@param name string -- The server state's name.

	Runs the current visual state's `Exit`, then the new one's `Enter`, and fires `StateChanged`.
	A state with no visuals is tracked all the same. Setting the current state again re-enters it.
	A `SetState` made from inside `Exit` does not run that Exit again; an Exit or Enter that errors
	is warned about and the state still moves on.
]=]
function Replica.SetState(self: ReplicaClass, name: string)
	if self._destroyed then
		return
	end

	local previous = self._state
	local previousVisual = if previous then self._visuals[previous] else nil
	if previousVisual and previousVisual.Exit and self._exiting ~= previous then
		self._exiting = previous
		local ok, err = pcall(previousVisual.Exit :: any, self)
		self._exiting = nil
		if not ok then
			FormatMessage.Warn(`Replica: Exit of "{previous :: string}" errored: {tostring(err)}`)
		end
	end

	self._state = name
	self.StateChanged:Fire(name, previous)

	local visual = self._visuals[name]
	if visual and visual.Enter then
		local ok, err = pcall(visual.Enter :: any, self)
		if not ok then
			FormatMessage.Warn(`Replica: Enter of "{name}" errored: {tostring(err)}`)
		end
	end
end

--[=[
	@within Replica
	@param position Vector3 -- The server rig's pivot position from the stream.
	@param yaw number? -- Facing in radians about Y, as the [Broadcaster] samples it.

	Where the rig should be. In puppet mode the rig smooths toward it every frame; in mirror
	mode it is recorded and nothing moves.
]=]
function Replica.SetPosition(self: ReplicaClass, position: Vector3, yaw: number?)
	self._targetPosition = position + Vector3.new(0, self._options.HeightOffset, 0)
	self._targetYaw = yaw
end

--[=[
	@within Replica
	@param snapshot Snapshot

	Applies a [Broadcaster] snapshot: the position, then the state.
]=]
function Replica.ApplySnapshot(self: ReplicaClass, snapshot: Types.Snapshot)
	self:SetPosition(snapshot.Position, snapshot.Yaw)
	if self._options.Puppet and self._targetPosition then
		self.Entity:PivotTo(CFrame.new(self._targetPosition) * CFrame.Angles(0, snapshot.Yaw, 0))
	end
	if snapshot.State then
		self:SetState(snapshot.State)
	end
end

--[=[
	@within Replica
	@param name string
	@param handler (payload: any) -> ()
	@return Connection

	Runs `handler` for every received event of that name. `Events` fires for all of them too.
]=]
function Replica.On(self: ReplicaClass, name: string, handler: (payload: any) -> ()): Types.Connection
	local handlers = self._handlers[name]
	if handlers == nil then
		handlers = {}
		self._handlers[name] = handlers
	end

	local entry: Handler
	local connection: Types.Connection = {
		Connected = true,
		Disconnect = function(this)
			local index = table.find(handlers, entry)
			if index then
				table.remove(handlers, index)
			end
			this.Connected = false
		end,
	}
	entry = { Callback = handler, Connection = connection }
	table.insert(handlers, entry)

	return connection
end

--[=[
	@within Replica
	@param name string
	@param payload any

	Hands an event the server emitted to its handlers and to `Events`.
]=]
function Replica.Receive(self: ReplicaClass, name: string, payload: any)
	if self._destroyed then
		return
	end

	self.Events:Fire(name, payload)
	local handlers = self._handlers[name]
	if handlers then
		for _, entry in table.clone(handlers) do
			if entry.Connection.Connected then
				task.spawn(entry.Callback, payload)
			end
		end
	end
end

--[=[
	@within Replica
	@param deltaTime number

	One frame: puppet smoothing toward the latest sample, then the current visual state's
	`Update`. Driven by Heartbeat; a test calls it directly.
]=]
function Replica.Step(self: ReplicaClass, deltaTime: number)
	if self._destroyed then
		return
	end

	local target = self._targetPosition
	if self._options.Puppet and target ~= nil then
		local pivot = self.Entity:GetPivot()
		local position = pivot.Position
		local offset = target - position
		local distance = offset.Magnitude

		local newPosition = target
		if self._options.Smoothing > 0 and distance > 1e-4 then
			local reach = self._options.Smoothing * deltaTime
			if reach < distance then
				newPosition = position + offset / distance * reach
			end
		end

		local yaw = yawOf(pivot)
		local wantedYaw = self._targetYaw or yaw
		local turn = shortestTurn(yaw, wantedYaw)
		if self._options.TurnSmoothing > 0 then
			local maxTurn = self._options.TurnSmoothing * deltaTime
			turn = math.clamp(turn, -maxTurn, maxTurn)
		end

		self.Entity:PivotTo(CFrame.new(newPosition) * CFrame.Angles(0, yaw + turn, 0))
	end

	local state = self._state
	local visual = if state then self._visuals[state] else nil
	if visual and visual.Update then
		visual.Update(self :: any, deltaTime)
	end
end

--[=[
	@within Replica

	Runs the current visual state's `Exit` and stops. The rig is yours; it is not destroyed.
]=]
function Replica.Destroy(self: ReplicaClass)
	if self._destroyed then
		return
	end
	self._destroyed = true

	local state = self._state
	local visual = if state then self._visuals[state] else nil
	if visual and visual.Exit then
		visual.Exit(self :: any)
	end
	self._state = nil

	self._trove:Destroy()
	self.StateChanged:Destroy()
	self.Events:Destroy()
end

return Replica
