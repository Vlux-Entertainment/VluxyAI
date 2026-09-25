--!strict

--[[
	A mover for anything with a pivot: an anchored part, a model without a rig, or a server-side
	"logical position" agent. Every Heartbeat it slides the pivot toward the current step by at most
	Speed * dt and turns its yaw toward the direction of travel by at most TurnSpeed * dt, through
	`PivotTo`. No Humanoid, no physics.

	The maths is `CFrameMover.Advance`, a pure function of (pivot, target, speed, turnSpeed, dt), so
	it is specced under Lune with real CFrames. The class around it only decides which step is
	current and when to fire. A step ends the frame's movement: the leftover fraction of a frame
	is dropped rather than carried into the next step, which keeps Advance simple and costs a
	fraction of a stud per step.

	Steps are floor positions and a pivot is a body centre, so without a `HeightOffset` the mover
	measures the gap on its first Follow (pivot height above the first step) and keeps it, rather
	than sinking the body to floor level.
]]

local FormatMessage = require(script.Parent.Parent.Utility.FormatMessage)
local Options = require(script.Parent.Parent.Utility.Options)
local Signal = require(script.Parent.Parent.Utility.Signal)
local Tables = require(script.Parent.Parent.Utility.Tables)
local Trove = require(script.Parent.Parent.Utility.Trove)
local Types = require(script.Parent.Parent.Types)

------------------------------------------------------------------------------------------------------------------------

local DEFAULT_OPTIONS = table.freeze({
	Speed = 8,
	TurnSpeed = 10,
	HeightOffset = nil :: number?,
	StepDistance = 0.25,
	StuckTimeout = 5,
})

-- Progress toward the current step smaller than this does not reset the stuck clock.
local PROGRESS_EPSILON = 0.05

-- Keys with no default value, so the resolver still accepts them.
local OPTIONAL_KEYS = { "HeightOffset" }

-- Below this distance a move is treated as zero-length: the pivot snaps to the target and keeps
-- its facing, because a direction cannot be read from a vector this short.
local EPSILON = 1e-5

type ResolvedOptions = {
	Speed: number,
	TurnSpeed: number,
	HeightOffset: number?,
	StepDistance: number,
	StuckTimeout: number,
}

type self = {
	StepReached: Types.Signal<(number, Types.Step)>,
	Arrived: Types.Signal<boolean>,

	_target: PVInstance,
	_options: ResolvedOptions,
	_speed: number,
	_heightOffset: number?,

	_path: Types.Path?,
	_index: number,
	_bestDistance: number,
	_stuckTime: number,
	_destroyed: boolean,

	_trove: Trove.Trove,
	_moveTrove: Trove.Trove,
}

local CFrameMover = {}
CFrameMover.__index = CFrameMover

export type CFrameMover = typeof(setmetatable({} :: self, CFrameMover))

--[=[
	@interface CFrameMoverOptions
	@within CFrameMover

	.Speed number? -- Studs per second. Default `8`.
	.TurnSpeed number? -- Radians per second of yaw. Default `10`.
	.HeightOffset number? -- Added to every step's Y, so a body rides above floor steps. A number is used as given; leave it out and the first `Follow` measures the pivot's height above the first step (never below `0`) and keeps that for the life of the mover. Default: measured.
	.StepDistance number? -- Horizontal distance to a step that counts as reached. Default `0.25`.
	.StuckTimeout number? -- Seconds without getting closer to the current step before giving up with `Arrived(false)`. Default `5`. Progress under 0.05 studs per check does not count, so speeds below about 0.01 studs per second read as stuck.
]=]
export type CFrameMoverOptions = {
	Speed: number?,
	TurnSpeed: number?,
	HeightOffset: number?,
	StepDistance: number?,
	StuckTimeout: number?,
}

--[=[
	@class CFrameMover

	A [Types.Mover] that steps a pivot with `PivotTo`, for anchored parts, rigless models and
	agents that only exist as a position on the server. Exposed as `VluxyAI.Movers.CFrame`.
	Each Heartbeat it moves toward the current step at `Speed` and turns its yaw toward the
	direction of travel at `TurnSpeed`; pitch and roll are dropped, so the pivot stays upright.

	Follows the two mover rules: `Follow` fires `Arrived(false)` for the path it replaces before
	starting the new one, and the new path is only ever reported from a later Heartbeat.
]=]

------------------------------------------------------------------------------------------------------------------------

--[[
	The yaw of a CFrame in radians, read from its look vector; from its right vector when the look
	vector is vertical. Yaw 0 faces -Z, the Roblox default.
]]
local function yawOf(pivot: CFrame): number
	local look = pivot.LookVector
	if look.X * look.X + look.Z * look.Z > EPSILON * EPSILON then
		return math.atan2(-look.X, -look.Z)
	end

	local right = pivot.RightVector
	return math.atan2(-right.Z, right.X)
end

--[[
	The signed shortest turn from one yaw to another, in [-pi, pi].
]]
local function shortestTurn(from: number, to: number): number
	local delta = (to - from) % (2 * math.pi)
	if delta > math.pi then
		delta -= 2 * math.pi
	end
	return delta
end

--[=[
	@within CFrameMover
	@param pivot CFrame -- Where the thing is now.
	@param target Vector3 -- Where it is going.
	@param speed number -- Studs per second.
	@param turnSpeed number -- Radians per second of yaw.
	@param deltaTime number -- Seconds since the last call.
	@return CFrame -- The new pivot: moved by at most `speed * deltaTime`, yaw turned by at most `turnSpeed * deltaTime`, upright.
	@return boolean -- `true` when the new pivot sits on `target`.

	One frame of movement, as a pure function. Moves straight toward `target` without overshooting
	and lands exactly on it when it is within reach. Turns the yaw toward the horizontal direction
	of travel by the shortest way; pitch and roll in `pivot` are discarded. A zero-length or purely
	vertical move keeps the current facing.
]=]
function CFrameMover.Advance(
	pivot: CFrame,
	target: Vector3,
	speed: number,
	turnSpeed: number,
	deltaTime: number
): (CFrame, boolean)
	local position = pivot.Position
	local offset = target - position
	local distance = offset.Magnitude
	local yaw = yawOf(pivot)

	local newPosition: Vector3
	local reached: boolean

	if distance <= EPSILON then
		newPosition = target
		reached = true
	else
		local direction = offset / distance
		local reach = speed * deltaTime
		if distance <= reach then
			newPosition = target
			reached = true
		else
			newPosition = position + direction * reach
			reached = false
		end
	end

	-- The offset is parallel to the direction of travel, and never optional.
	if distance > EPSILON and offset.X * offset.X + offset.Z * offset.Z > EPSILON * EPSILON then
		local wanted = math.atan2(-offset.X, -offset.Z)
		local turn = shortestTurn(yaw, wanted)
		local maxTurn = turnSpeed * deltaTime
		yaw += math.clamp(turn, -maxTurn, maxTurn)
	end

	return CFrame.new(newPosition) * CFrame.Angles(0, yaw, 0), reached
end

------------------------------------------------------------------------------------------------------------------------

--[=[
	@within CFrameMover
	@param target PVInstance -- Anything with `GetPivot` and `PivotTo`: a Model or a BasePart.
	@param options CFrameMoverOptions?
	@return CFrameMover
	@error string -- `target` has no `GetPivot`.
	@error "unknown option" -- A key that is not in `CFrameMoverOptions`.
]=]
function CFrameMover.new(target: PVInstance, options: CFrameMoverOptions?): Types.Mover
	if type((target :: any).GetPivot) ~= "function" or type((target :: any).PivotTo) ~= "function" then
		FormatMessage.Error(`CFrameMover needs something with GetPivot and PivotTo, got {tostring(target)}`, 2)
	end

	local resolved =
		Options.Resolve("CFrameMover.new", DEFAULT_OPTIONS, options :: any, OPTIONAL_KEYS) :: ResolvedOptions

	-- Pivoting a simulated part every frame fights physics; the rig must be anchored.
	if typeof(target) == "Instance" then
		local root: BasePart? = if target:IsA("BasePart")
			then target
			elseif target:IsA("Model") then target.PrimaryPart
			else nil
		if root ~= nil and not root.Anchored then
			FormatMessage.Warn(
				`CFrameMover.new: {target:GetFullName()} is not anchored; anchor its root or use the Humanoid mover`
			)
		end
	end

	if resolved.Speed < 0 then
		FormatMessage.Error(`CFrameMover.new: Speed must be 0 or more, got {resolved.Speed}`, 2)
	end
	if resolved.TurnSpeed < 0 then
		FormatMessage.Error(`CFrameMover.new: TurnSpeed must be 0 or more, got {resolved.TurnSpeed}`, 2)
	end
	if resolved.StuckTimeout <= 0 then
		FormatMessage.Error(`CFrameMover.new: StuckTimeout must be above 0, got {resolved.StuckTimeout}`, 2)
	end

	local trove = Trove.new()

	local self: self = {
		StepReached = Signal.new(),
		Arrived = Signal.new(),

		_target = target,
		_options = resolved,
		_speed = resolved.Speed,
		_heightOffset = resolved.HeightOffset,

		_path = nil,
		_index = 0,
		_bestDistance = math.huge,
		_stuckTime = 0,
		_destroyed = false,

		_trove = trove,
		_moveTrove = trove:Extend(),
	}

	return setmetatable(self, CFrameMover) :: any
end

------------------------------------------------------------------------------------------------------------------------

--[[
	Ends the current path, if any: forgets it, drops the Heartbeat connection and fires Arrived.
	Nothing may touch self after the fire, because a handler is free to call Follow again.
]]
function CFrameMover._finish(self: CFrameMover, reached: boolean)
	if self._path == nil then
		return
	end

	self._path = nil
	self._index = 0
	self._moveTrove:Clean()

	self.Arrived:Fire(reached)
end

--[[
	One Heartbeat while following: moves toward the current step and reports it when reached.
]]
function CFrameMover._onHeartbeat(self: CFrameMover, deltaTime: number)
	local path = self._path
	if path == nil then
		return
	end

	local index = self._index
	local step = path[index]
	if step == nil then
		-- An empty path, or one with nothing left: there is nowhere to go.
		self:_finish(false)
		return
	end

	local goal = step.Position + Vector3.new(0, self._heightOffset or 0, 0)
	local pivot, reached =
		CFrameMover.Advance(self._target:GetPivot(), goal, self._speed, self._options.TurnSpeed, deltaTime)
	self._target:PivotTo(pivot)

	local remaining = Tables.FlatDistance(pivot.Position, goal)
	if not reached and remaining > self._options.StepDistance then
		-- Not there yet: is it at least getting closer? Speed 0, or a step it cannot reach, is not.
		if remaining < self._bestDistance - PROGRESS_EPSILON then
			self._bestDistance = remaining
			self._stuckTime = 0
		else
			self._stuckTime += deltaTime
			if self._stuckTime >= self._options.StuckTimeout then
				self:_finish(false)
			end
		end
		return
	end

	self._index = index + 1
	self._bestDistance = math.huge
	self._stuckTime = 0
	self.StepReached:Fire(index, step)

	-- A StepReached handler may have stopped or replaced the path.
	if self._path ~= path then
		return
	end

	if index >= #path then
		self:_finish(true)
	end
end

------------------------------------------------------------------------------------------------------------------------

--[=[
	@within CFrameMover
	@param path Path

	Starts along `path`, replacing any current one. The replaced path gets `Arrived(false)` before
	the new one starts; the new one is only ever reported from a later Heartbeat. An empty path is
	reported as `Arrived(false)` on the next Heartbeat.

	Without a `HeightOffset` option, the first non-empty path measures it: the pivot's height above
	`path[1]`, never below `0`, kept from then on.
]=]
function CFrameMover.Follow(self: CFrameMover, path: Types.Path)
	self._bestDistance = math.huge
	self._stuckTime = 0
	if self._destroyed then
		return
	end

	self:_finish(false)

	if self._heightOffset == nil and #path > 0 then
		self._heightOffset = math.max(0, self._target:GetPivot().Position.Y - path[1].Position.Y)
	end

	self._path = path
	self._index = 1

	local RunService = game:GetService("RunService")
	self._moveTrove:Connect(RunService.Heartbeat, function(deltaTime: number)
		self:_onHeartbeat(deltaTime)
	end)
end

--[=[
	@within CFrameMover

	Halts where it is. Fires `Arrived(false)` if a path was in progress.
]=]
function CFrameMover.Stop(self: CFrameMover)
	self:_finish(false)
end

--[=[
	@within CFrameMover
	@return Vector3 -- The pivot's position.
]=]
function CFrameMover.GetPosition(self: CFrameMover): Vector3
	return self._target:GetPivot().Position
end

--[=[
	@within CFrameMover
	@return number -- Studs per second.
]=]
function CFrameMover.GetSpeed(self: CFrameMover): number
	return self._speed
end

--[=[
	@within CFrameMover
	@param studsPerSecond number
]=]
function CFrameMover.SetSpeed(self: CFrameMover, studsPerSecond: number)
	if studsPerSecond < 0 then
		FormatMessage.Error(`CFrameMover: Speed must be 0 or more, got {studsPerSecond}`, 2)
	end
	self._speed = studsPerSecond
end

--[=[
	@within CFrameMover
	@return boolean -- `true` while a path is in progress.
]=]
function CFrameMover.IsMoving(self: CFrameMover): boolean
	return self._path ~= nil
end

--[=[
	@within CFrameMover

	Stops, then drops the signals. The target instance is left alone; it is yours.
]=]
function CFrameMover.Destroy(self: CFrameMover)
	if self._destroyed then
		return
	end

	self:Stop()
	self._destroyed = true
	self._trove:Destroy()

	self.StepReached:Destroy()
	self.Arrived:Destroy()
end

return CFrameMover
