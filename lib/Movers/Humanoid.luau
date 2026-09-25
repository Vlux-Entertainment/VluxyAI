--!strict

--[[
	A mover for a rig: walks each step of a path with `Humanoid:MoveTo` and advances on
	`MoveToFinished`. Roblox's own MoveTo timeout (8 seconds) and a Heartbeat stuck check are both
	give-ups that fire `Arrived(false)`; the Navigator re-plans from there.

	Two Roblox-specific decisions: the root's network owner is set to the server in `new`, because
	a client-owned NPC ignores server MoveTo calls and that is the first thing everyone hits; and a
	leading step within `SkipDistance` of the rig is skipped, because a navmesh path starts at the
	agent's own position and walking to where you already stand wastes a MoveTo round-trip.
	`Humanoid.ChooseStart` is that decision as a pure function, so it is specced.
]]

local FormatMessage = require(script.Parent.Parent.Utility.FormatMessage)
local Signal = require(script.Parent.Parent.Utility.Signal)
local Tables = require(script.Parent.Parent.Utility.Tables)
local Trove = require(script.Parent.Parent.Utility.Trove)
local Types = require(script.Parent.Parent.Types)

------------------------------------------------------------------------------------------------------------------------

local DEFAULT_OPTIONS = table.freeze({
	Speed = 16,
	StuckTimeout = 3,
	StuckDistance = 0.5,
	SkipDistance = 1,
	ServerOwned = true,
})

type Options = {
	Speed: number,
	StuckTimeout: number,
	StuckDistance: number,
	SkipDistance: number,
	ServerOwned: boolean,
}

type self = {
	StepReached: Types.Signal<(number, Types.Step)>,
	Arrived: Types.Signal<boolean>,

	_model: Model,
	_root: BasePart,
	_humanoid: Humanoid,
	_options: Options,
	_speed: number,

	_path: Types.Path?,
	_index: number,
	_stuckPosition: Vector3,
	_stuckTime: number,
	_destroyed: boolean,

	_trove: Trove.Trove,
	_moveTrove: Trove.Trove,
}

local HumanoidMover = {}
HumanoidMover.__index = HumanoidMover

export type HumanoidMover = typeof(setmetatable({} :: self, HumanoidMover))

--[=[
	@interface HumanoidOptions
	@within Humanoid

	.Speed number? -- `WalkSpeed`, studs per second. Default `16`.
	.StuckTimeout number? -- Seconds without moving `StuckDistance` before giving up. Default `3`.
	.StuckDistance number? -- Studs the root must move within `StuckTimeout` to count as progress. Default `0.5`.
	.SkipDistance number? -- Leading steps within this horizontal distance of the rig are skipped. Default `1`.
	.ServerOwned boolean? -- Set the root's network owner to the server in `new`. Default `true`.
]=]
export type HumanoidOptions = {
	Speed: number?,
	StuckTimeout: number?,
	StuckDistance: number?,
	SkipDistance: number?,
	ServerOwned: boolean?,
}

--[=[
	@class Humanoid

	A [Types.Mover] for a model with a `Humanoid` and a `PrimaryPart`: walks each step with
	`MoveTo`, jumps at `Jump` steps, and gives up when Roblox's MoveTo times out or the rig stops
	making progress. Exposed as `VluxyAI.Movers.Humanoid`.

	Follows the two mover rules: `Follow` fires `Arrived(false)` for the path it replaces before
	starting the new one, and the new path is only ever reported from a later frame, because
	`MoveToFinished` never fires inside `MoveTo`.
]=]

------------------------------------------------------------------------------------------------------------------------

--[=[
	@within Humanoid
	@param path Path
	@param position Vector3 -- Where the rig is.
	@param skipDistance number -- Horizontal distance within which a leading step is already reached.
	@return number -- The index of the first step to walk toward; `#path + 1` only when the path is empty.

	Skips the run of leading steps that sit within `skipDistance` of `position`, because a navmesh
	path starts where the agent already stands. The last step is never skipped, so there is always
	something to walk toward and arrival is always reported from `MoveToFinished`.
]=]
function HumanoidMover.ChooseStart(path: Types.Path, position: Vector3, skipDistance: number): number
	local index = 1
	while index < #path and Tables.FlatDistance(path[index].Position, position) <= skipDistance do
		index += 1
	end

	return index
end

------------------------------------------------------------------------------------------------------------------------

--[=[
	@within Humanoid
	@param model Model -- Needs a `PrimaryPart` and a `Humanoid` child.
	@param options HumanoidOptions?
	@return Humanoid
	@error string -- The model has no `PrimaryPart` or no `Humanoid`.

	Sets `WalkSpeed` to `Speed` and, with `ServerOwned`, hands the root to the server.
]=]
function HumanoidMover.new(model: Model, options: HumanoidOptions?): Types.Mover
	local root = model.PrimaryPart
	if root == nil then
		return FormatMessage.Error(`{model:GetFullName()} has no PrimaryPart; the Humanoid mover needs one`, 2)
	end

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		return FormatMessage.Error(`{model:GetFullName()} has no Humanoid; the Humanoid mover needs one`, 2)
	end

	local resolved = table.clone(DEFAULT_OPTIONS)
	for key, value in (options or {}) :: { [string]: any } do
		resolved[key] = value
	end

	humanoid.WalkSpeed = resolved.Speed

	if resolved.ServerOwned then
		-- Fails on the client and for a part that is anchored or welded to one; neither is fatal.
		pcall(function()
			root:SetNetworkOwner(nil)
		end)
	end

	local trove = Trove.new()

	local self: self = {
		StepReached = Signal.new(),
		Arrived = Signal.new(),

		_model = model,
		_root = root,
		_humanoid = humanoid,
		_options = resolved,
		_speed = resolved.Speed,

		_path = nil,
		_index = 0,
		_stuckPosition = root.Position,
		_stuckTime = 0,
		_destroyed = false,

		_trove = trove,
		_moveTrove = trove:Extend(),
	}

	return setmetatable(self, HumanoidMover) :: any
end

------------------------------------------------------------------------------------------------------------------------

--[[
	Ends the current path, if any: forgets it, drops the move connections, cancels the walk unless
	the rig got there on its own, and fires Arrived. Nothing may touch self after the fire, because
	a handler is free to call Follow again.
]]
function HumanoidMover._finish(self: HumanoidMover, reached: boolean)
	if self._path == nil then
		return
	end

	self._path = nil
	self._index = 0
	self._moveTrove:Clean()

	if not reached then
		self._humanoid:MoveTo(self._root.Position)
	end

	self.Arrived:Fire(reached)
end

--[[
	Starts walking toward step `index` of the current path, jumping if the step says so, and
	restarts the stuck clock.
]]
function HumanoidMover._walkTo(self: HumanoidMover, index: number)
	local path = self._path
	if path == nil then
		return
	end

	local step = path[index]
	self._index = index
	self._stuckPosition = self._root.Position
	self._stuckTime = 0

	if step.Action == "Jump" then
		self._humanoid.Jump = true
	end

	self._humanoid:MoveTo(step.Position)
end

--[[
	`MoveToFinished` for the current step: advance, or give up when Roblox timed out.
]]
function HumanoidMover._onMoveToFinished(self: HumanoidMover, reached: boolean)
	local path = self._path
	if path == nil then
		return
	end

	if not reached then
		self:_finish(false)
		return
	end

	local index = self._index
	local step = path[index]
	self.StepReached:Fire(index, step)

	-- A StepReached handler may have stopped or replaced the path.
	if self._path ~= path then
		return
	end

	if index >= #path then
		self:_finish(true)
	else
		self:_walkTo(index + 1)
	end
end

--[[
	The stuck check: `StuckTimeout` seconds without the root moving `StuckDistance` is a give-up.
]]
function HumanoidMover._onHeartbeat(self: HumanoidMover, deltaTime: number)
	if self._path == nil then
		return
	end

	local position = self._root.Position
	if (position - self._stuckPosition).Magnitude >= self._options.StuckDistance then
		self._stuckPosition = position
		self._stuckTime = 0
		return
	end

	self._stuckTime += deltaTime
	if self._stuckTime >= self._options.StuckTimeout then
		self:_finish(false)
	end
end

------------------------------------------------------------------------------------------------------------------------

--[=[
	@within Humanoid
	@param path Path

	Starts along `path`, replacing any current one. The replaced path gets `Arrived(false)` before
	the new one starts; the new one is only ever reported from a later frame. An empty path is
	reported as `Arrived(false)` on the next Heartbeat.
]=]
function HumanoidMover.Follow(self: HumanoidMover, path: Types.Path)
	if self._destroyed then
		return
	end

	self:_finish(false)

	self._path = path

	local RunService = game:GetService("RunService")

	if #path == 0 then
		-- Nowhere to walk. Report it on the next frame rather than from inside Follow.
		self._moveTrove:Connect(RunService.Heartbeat, function()
			self:_finish(false)
		end)
		return
	end

	self._moveTrove:Connect(RunService.Heartbeat, function(deltaTime: number)
		self:_onHeartbeat(deltaTime)
	end)

	self._moveTrove:Connect(self._humanoid.MoveToFinished, function(reached: boolean)
		self:_onMoveToFinished(reached)
	end)

	self:_walkTo(HumanoidMover.ChooseStart(path, self._root.Position, self._options.SkipDistance))
end

--[=[
	@within Humanoid

	Cancels the walk. Fires `Arrived(false)` if a path was in progress.
]=]
function HumanoidMover.Stop(self: HumanoidMover)
	self:_finish(false)
end

--[=[
	@within Humanoid
	@return Vector3 -- The `PrimaryPart` position.
]=]
function HumanoidMover.GetPosition(self: HumanoidMover): Vector3
	return self._root.Position
end

--[=[
	@within Humanoid
	@return number -- Studs per second.
]=]
function HumanoidMover.GetSpeed(self: HumanoidMover): number
	return self._speed
end

--[=[
	@within Humanoid
	@param studsPerSecond number -- Becomes the humanoid's `WalkSpeed`.
]=]
function HumanoidMover.SetSpeed(self: HumanoidMover, studsPerSecond: number)
	self._speed = studsPerSecond
	self._humanoid.WalkSpeed = studsPerSecond
end

--[=[
	@within Humanoid
	@return boolean -- `true` while a path is in progress.
]=]
function HumanoidMover.IsMoving(self: HumanoidMover): boolean
	return self._path ~= nil
end

--[=[
	@within Humanoid

	Stops, then drops the signals. The model is left alone; it is yours.
]=]
function HumanoidMover.Destroy(self: HumanoidMover)
	if self._destroyed then
		return
	end

	self:Stop()
	self._destroyed = true
	self._trove:Destroy()

	self.StepReached:Destroy()
	self.Arrived:Destroy()
end

return HumanoidMover
