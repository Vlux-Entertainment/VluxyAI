--!strict

--[[
	A mover for a rig: walks each step of a path with `Humanoid:MoveTo` and advances on
	`MoveToFinished`. A Heartbeat stuck check is the give-up that fires `Arrived(false)`; the
	Navigator re-plans from there. Roblox's own MoveTo timeout is not a give-up: it fires
	`MoveToFinished(false)` eight seconds after every `MoveTo` whether or not the rig is getting
	there, so a long straight step re-issues the `MoveTo` while the stuck check still sees progress.

	Two Roblox-specific decisions: the root's network owner is set to the server in `new`, because
	a client-owned NPC ignores server MoveTo calls and that is the first thing everyone hits; and a
	run of leading plain Walk steps within `SkipDistance` of the rig is skipped, because a navmesh
	path starts at the agent's own position and walking to where you already stand wastes a MoveTo
	round-trip. `HumanoidMover.ChooseStart` is that decision as a pure function, so it is specced.
]]

local FormatMessage = require(script.Parent.Parent.Utility.FormatMessage)
local Options = require(script.Parent.Parent.Utility.Options)
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

type ResolvedOptions = {
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
	_options: ResolvedOptions,
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
	@within HumanoidMover

	.Speed number? -- `WalkSpeed`, studs per second. Default `16`.
	.StuckTimeout number? -- Seconds without moving `StuckDistance` before giving up. Default `3`.
	.StuckDistance number? -- Studs the root must move within `StuckTimeout` to count as progress. Default `0.5`.
	.SkipDistance number? -- Leading plain Walk steps within this horizontal distance of the rig are skipped. Default `1`.
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
	@class HumanoidMover

	A [Types.Mover] for a model with a `Humanoid` and a `PrimaryPart`: walks each step with
	`MoveTo`, jumps at `Jump` steps, and gives up when the rig stops making progress for
	`StuckTimeout` seconds. Exposed as `VluxyAI.Movers.Humanoid`.

	Roblox fires `MoveToFinished(false)` eight seconds after any `MoveTo`, reached or not, so a step
	further than eight seconds of walking would otherwise end a healthy walk. The mover re-issues
	the `MoveTo` for the same step while the stuck check sees progress and only gives up when the
	stuck check agrees.

	Follows the two mover rules: `Follow` fires `Arrived(false)` for the path it replaces before
	starting the new one, and the new path is only ever reported from a later frame, because
	`MoveToFinished` never fires inside `MoveTo`.
]=]

------------------------------------------------------------------------------------------------------------------------

--[=[
	@within HumanoidMover
	@param path Path
	@param position Vector3 -- Where the rig is.
	@param skipDistance number -- Horizontal distance within which a leading step is already reached.
	@return number -- The index of the first step to walk toward; `#path + 1` only when the path is empty.

	Skips the run of leading plain `Walk` steps that sit within `skipDistance` of `position`,
	because a navmesh path starts where the agent already stands. A labelled, `Jump` or `Custom`
	step is never skipped, even one under the agent: it carries meaning (a door at the agent's
	feet) that `StepReached` must report. The last step is never skipped either, so there is
	always something to walk toward and arrival is always reported from `MoveToFinished`.
]=]
function HumanoidMover.ChooseStart(path: Types.Path, position: Vector3, skipDistance: number): number
	local index = 1
	while index < #path do
		local step = path[index]
		local plain = step.Action == "Walk" and step.Label == nil
		if not plain or Tables.FlatDistance(step.Position, position) > skipDistance then
			break
		end
		index += 1
	end

	return index
end

------------------------------------------------------------------------------------------------------------------------

--[=[
	@within HumanoidMover
	@param model Model -- Needs a `PrimaryPart` and a `Humanoid` child.
	@param options HumanoidOptions?
	@return HumanoidMover
	@error string -- The model has no `PrimaryPart` or no `Humanoid`.
	@error "unknown option" -- A key that is not in `HumanoidOptions`.

	Sets `WalkSpeed` to `Speed` and, with `ServerOwned`, hands the root to the server. That fails,
	with a warning, unless the model is a descendant of Workspace and unanchored before this call.
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

	local resolved = Options.Resolve("Humanoid.new", DEFAULT_OPTIONS, options :: any) :: ResolvedOptions

	humanoid.WalkSpeed = resolved.Speed

	if resolved.ServerOwned then
		local ok, err = pcall(function()
			root:SetNetworkOwner(nil)
		end)
		if not ok then
			FormatMessage.Warn(
				`Humanoid.new: could not hand {model:GetFullName()} to the server ({tostring(err)}); `
					.. "the model must be a descendant of Workspace and unanchored before Humanoid.new, "
					.. "or a client-owned rig will ignore MoveTo"
			)
		end
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
	The stuck check, shared by the Heartbeat and by MoveToFinished(false): notes progress when the
	root has moved `StuckDistance` since the last note, and answers `true` once `StuckTimeout`
	seconds have passed without one.
]]
function HumanoidMover._isStuck(self: HumanoidMover): boolean
	local position = self._root.Position
	if (position - self._stuckPosition).Magnitude >= self._options.StuckDistance then
		self._stuckPosition = position
		self._stuckTime = 0
		return false
	end

	return self._stuckTime >= self._options.StuckTimeout
end

--[[
	`MoveToFinished` for the current step: advance, or on `false` (Roblox's own timeout, which
	fires eight seconds after every MoveTo regardless of progress) ask the stuck check. While it
	sees progress the same step's MoveTo is re-issued and the stuck clock is left alone; only when
	it agrees the rig is stuck is the path given up.
]]
function HumanoidMover._onMoveToFinished(self: HumanoidMover, reached: boolean)
	local path = self._path
	if path == nil then
		return
	end

	if not reached then
		if self:_isStuck() then
			self:_finish(false)
		else
			self._humanoid:MoveTo(path[self._index].Position)
		end
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
	Advances the stuck clock; `StuckTimeout` seconds without the root moving `StuckDistance` is a
	give-up.
]]
function HumanoidMover._onHeartbeat(self: HumanoidMover, deltaTime: number)
	if self._path == nil then
		return
	end

	self._stuckTime += deltaTime
	if self:_isStuck() then
		self:_finish(false)
	end
end

------------------------------------------------------------------------------------------------------------------------

--[=[
	@within HumanoidMover
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
	@within HumanoidMover

	Cancels the walk. Fires `Arrived(false)` if a path was in progress.
]=]
function HumanoidMover.Stop(self: HumanoidMover)
	self:_finish(false)
end

--[=[
	@within HumanoidMover
	@return Vector3 -- The `PrimaryPart` position.
]=]
function HumanoidMover.GetPosition(self: HumanoidMover): Vector3
	return self._root.Position
end

--[=[
	@within HumanoidMover
	@return number -- Studs per second.
]=]
function HumanoidMover.GetSpeed(self: HumanoidMover): number
	return self._speed
end

--[=[
	@within HumanoidMover
	@param studsPerSecond number -- Becomes the humanoid's `WalkSpeed`.
]=]
function HumanoidMover.SetSpeed(self: HumanoidMover, studsPerSecond: number)
	self._speed = studsPerSecond
	self._humanoid.WalkSpeed = studsPerSecond
end

--[=[
	@within HumanoidMover
	@return boolean -- `true` while a path is in progress.
]=]
function HumanoidMover.IsMoving(self: HumanoidMover): boolean
	return self._path ~= nil
end

--[=[
	@within HumanoidMover

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
