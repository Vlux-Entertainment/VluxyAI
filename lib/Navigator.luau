--!strict

--[[
	Owns the pair of a Pathfinder and a Mover: plans with one, follows with the other, re-plans
	when the target moves or the mover gives up. A state calls MoveTo every tick with wherever it
	wants to be and never thinks about paths.

	Pure Luau apart from Vector3 values and `task.spawn` for the plan, since FindPath may yield.
	Every plan carries a generation number; a plan that finishes after Stop, Destroy or a newer
	plan is thrown away, which is what makes yielding pathfinders safe.
]]

local FormatMessage = require(script.Parent.Utility.FormatMessage)
local Options = require(script.Parent.Utility.Options)
local Signal = require(script.Parent.Utility.Signal)
local Tables = require(script.Parent.Utility.Tables)
local Types = require(script.Parent.Types)

------------------------------------------------------------------------------------------------------------------------

local DEFAULT_OPTIONS = {
	RepathInterval = 0.5,
	RepathDistance = 2,
	ArriveDistance = 2.5,
	ArriveHeight = 8,
}

type Options = {
	RepathInterval: number,
	RepathDistance: number,
	ArriveDistance: number,
	ArriveHeight: number,
}

type self = {
	StepReached: Types.Signal<(number, Types.Step)>,
	Arrived: Types.Signal<boolean>,
	PathChanged: Types.Signal<Types.Path?>,

	_pathfinder: Types.Pathfinder,
	_mover: Types.Mover,
	_agent: Types.Agent,
	_options: Options,

	_status: Types.PathStatus,
	_target: Vector3?,
	_path: Types.Path?,
	_plannedTarget: Vector3?,
	_plannedAt: number,
	_needsPlan: boolean,
	_generation: number,
	_stopping: boolean,
	_following: boolean,
	_destroyed: boolean,
	_warnedTarget: Vector3?,

	_connections: { Types.Connection },
}

local Navigator = {}
Navigator.__index = Navigator

export type Navigator = typeof(setmetatable({} :: self, Navigator))

------------------------------------------------------------------------------------------------------------------------

--[=[
	@class Navigator

	Owns a [Types.Pathfinder] and a [Types.Mover]. `MoveTo` is safe to call every tick with a
	moving target: the navigator re-plans on a cadence, re-plans when the target moves, retries when
	the mover gets stuck, and reports through `GetStatus` and `Arrived`. Every [Agent] built with
	both a pathfinder and a mover has one at `agent.Navigator`.

	Arrival is judged by horizontal distance within `ArriveDistance`, with the height difference
	allowed up to `ArriveHeight`: a humanoid's root and a floor waypoint sit at different heights,
	but a target on the floor above is not reached.
]=]

--[=[
	@within Navigator
	@param pathfinder Pathfinder
	@param mover Mover
	@param agent Agent -- Handed to `FindPath` so a pathfinder can read the blackboard.
	@param options NavigationOptions?
	@return Navigator
]=]
function Navigator.new(
	pathfinder: Types.Pathfinder,
	mover: Types.Mover,
	agent: Types.Agent,
	options: Types.NavigationOptions?
): Navigator
	local resolved = Options.Resolve("Navigator.new", DEFAULT_OPTIONS, options :: any)

	local self: self = {
		StepReached = Signal.new(),
		Arrived = Signal.new(),
		PathChanged = Signal.new(),

		_pathfinder = pathfinder,
		_mover = mover,
		_agent = agent,
		_options = resolved,

		_status = "Idle",
		_target = nil,
		_path = nil,
		_plannedTarget = nil,
		_plannedAt = -math.huge,
		_needsPlan = false,
		_generation = 0,
		_stopping = false,
		_following = false,
		_destroyed = false,
		_warnedTarget = nil,

		_connections = {},
	}

	local navigator = setmetatable(self, Navigator)

	table.insert(
		self._connections,
		mover.StepReached:Connect(function(index: number, step: Types.Step)
			self.StepReached:Fire(index, step)
		end)
	)

	table.insert(
		self._connections,
		mover.Arrived:Connect(function(reached: boolean)
			navigator:_onMoverArrived(reached)
		end)
	)

	return navigator
end

------------------------------------------------------------------------------------------------------------------------

--[[
	Records the current path and tells listeners when it changed.
]]
function Navigator._setPath(self: Navigator, path: Types.Path?)
	if self._path == path then
		return
	end

	self._path = path
	self.PathChanged:Fire(path)
end

--[[
	Is the mover close enough to the target to count as there?
]]
function Navigator._isAtTarget(self: Navigator): boolean
	local target = self._target
	if target == nil then
		return false
	end

	local position = self._mover:GetPosition()
	return Tables.FlatDistance(position, target) <= self._options.ArriveDistance
		and math.abs(position.Y - target.Y) <= self._options.ArriveHeight
end

--[[
	Warns about an unreachable target once, since retries on the cadence would repeat it.
]]
function Navigator._warnOnce(self: Navigator, target: Vector3, message: string)
	if self._warnedTarget == target then
		return
	end

	self._warnedTarget = target
	FormatMessage.Warn(`{self._agent.Name}: {message}`)
end

--[[
	Marks the target as reached: stops the mover if it is still going and fires Arrived(true) once.
]]
function Navigator._arrive(self: Navigator)
	if self._status == "Arrived" then
		return
	end

	self._generation += 1
	self._status = "Arrived"
	self._needsPlan = false

	if self._mover:IsMoving() then
		self._stopping = true
		self._mover:Stop()
		self._stopping = false
	end

	self.Arrived:Fire(true)
end

--[[
	The mover finished a path or gave up on one.
]]
function Navigator._onMoverArrived(self: Navigator, reached: boolean)
	if self._destroyed or self._stopping or self._following or self._target == nil then
		return
	end

	if self._status ~= "Moving" then
		return
	end

	if reached and self:_isAtTarget() then
		self:_arrive()
		return
	end

	local target = self._target :: Vector3
	local plannedTarget = self._plannedTarget
	local targetMoved = plannedTarget == nil or (target - plannedTarget).Magnitude > self._options.RepathDistance

	if reached and not targetMoved then
		-- The whole path was walked and the target has not moved: the plan itself falls short, so
		-- planning again would only walk the same path. Report it instead of looping.
		self._status = "Failed"
		self:_warnOnce(
			target,
			`the path to {target} ends {math.round(Tables.FlatDistance(self._mover:GetPosition(), target))} studs short`
		)
		self.Arrived:Fire(false)
		return
	end

	-- The target moved since the plan, or the mover got stuck: plan again on the cadence.
	self._needsPlan = true
end

--[[
	Plans a path to the current target in its own thread and follows it when it arrives, unless
	something newer happened meanwhile.
]]
function Navigator._plan(self: Navigator)
	local target = self._target
	if target == nil then
		return
	end

	self._generation += 1
	local generation = self._generation

	self._status = "Planning"
	self._needsPlan = false
	self._plannedTarget = target
	self._plannedAt = os.clock()

	task.spawn(function()
		-- A pathfinder that errors must not leave the navigator planning forever.
		local ok, path, reason = pcall(function()
			return self._pathfinder:FindPath(self._mover:GetPosition(), target, self._agent)
		end)
		if not ok then
			reason = `FindPath errored: {tostring(path)}`
			path = nil
		end

		if self._destroyed or self._generation ~= generation then
			return
		end

		if path == nil or #path == 0 then
			self._status = "Failed"
			self:_setPath(nil)
			if reason then
				self:_warnOnce(target, `no path to {target} ({reason})`)
			end
			self.Arrived:Fire(false)
			return
		end

		self._status = "Moving"
		self:_setPath(path)

		-- A mover reports the path this one replaces from inside Follow; that is not news here.
		self._following = true
		self._mover:Follow(path)
		self._following = false
	end)
end

--[[
	Decides whether a plan is due, and starts it if so. `force` skips the cadence, for a brand new
	target.
]]
function Navigator._planIfDue(self: Navigator, force: boolean)
	local target = self._target
	if target == nil or self._status == "Planning" then
		return
	end

	if self:_isAtTarget() then
		self:_arrive()
		return
	end

	local now = os.clock()
	local sinceLast = now - self._plannedAt
	local plannedTarget = self._plannedTarget
	local targetMoved = plannedTarget == nil or (target - plannedTarget).Magnitude > self._options.RepathDistance
	local stale = self._status == "Arrived" or self._status == "Failed" or self._status == "Idle"

	local immediate = force or plannedTarget == nil
	local due = (self._needsPlan or targetMoved or stale) and sinceLast >= self._options.RepathInterval

	if immediate or due then
		self:_plan()
	end
end

------------------------------------------------------------------------------------------------------------------------

--[=[
	@within Navigator
	@param target Vector3

	Heads to `target`. Call it every tick with a moving target; a plan only happens when the
	target is new, has moved more than `RepathDistance` since the last plan, or the last plan
	failed or ran out, and never more often than `RepathInterval`. A new target after arriving is
	treated as new: the status leaves `Arrived` at once.
]=]
function Navigator.MoveTo(self: Navigator, target: Vector3)
	if self._destroyed then
		return
	end

	local previous = self._target
	self._target = target

	local force = previous == nil

	if not force and self._status == "Arrived" then
		local anchor = self._plannedTarget or previous
		if anchor and (target - anchor).Magnitude > self._options.RepathDistance then
			-- Arrived was about the old target. Leave it so the new one can arrive or plan at once.
			self._status = "Idle"
			self._plannedTarget = nil
			force = true
		end
	end

	self:_planIfDue(force)
end

--[=[
	@within Navigator

	Forgets the target and halts the mover. Fires `Arrived(false)` if a target was in progress.
]=]
function Navigator.Stop(self: Navigator)
	if self._target == nil then
		return
	end

	local wasUnderway = self._status == "Planning" or self._status == "Moving"

	self._generation += 1
	self._target = nil
	self._plannedTarget = nil
	self._needsPlan = false
	self._status = "Idle"
	self:_setPath(nil)

	if self._mover:IsMoving() then
		self._stopping = true
		self._mover:Stop()
		self._stopping = false
	end

	if wasUnderway then
		self.Arrived:Fire(false)
	end
end

--[=[
	@within Navigator
	@return PathStatus
]=]
function Navigator.GetStatus(self: Navigator): Types.PathStatus
	return self._status
end

--[=[
	@within Navigator
	@return Vector3?
]=]
function Navigator.GetTarget(self: Navigator): Vector3?
	return self._target
end

--[=[
	@within Navigator
	@return Path? -- The last path planned, kept until the next plan or `Stop`.
]=]
function Navigator.GetPath(self: Navigator): Types.Path?
	return self._path
end

--[=[
	@within Navigator
	@param deltaTime number

	One tick. Retries a plan that is due even when nobody called `MoveTo` this tick, so a state
	that called `MoveTo` once with a fixed position still gets there after a stuck mover.
]=]
function Navigator.Step(self: Navigator, deltaTime: number)
	local _ = deltaTime
	if self._destroyed or self._target == nil then
		return
	end

	self:_planIfDue(false)
end

--[=[
	@within Navigator

	Stops and disconnects from the mover. The mover and pathfinder are not destroyed; the agent
	owns those.
]=]
function Navigator.Destroy(self: Navigator)
	if self._destroyed then
		return
	end

	self:Stop()
	self._destroyed = true

	for _, connection in self._connections do
		connection:Disconnect()
	end
	table.clear(self._connections)

	self.StepReached:Destroy()
	self.Arrived:Destroy()
	self.PathChanged:Destroy()
end

return Navigator
