--!strict

--[[
	Owns the pair of a Pathfinder and a Mover: plans with one, follows with the other, re-plans
	when the target moves, the mover gives up, the pathfinder says the path is blocked, or the path
	is older than MaxPathAge. A state calls MoveTo every tick with wherever it wants to be and never
	thinks about paths.

	A labelled step with a handler (a door) pauses the walk: the mover is stopped at the step,
	the handler runs in its own thread, and the rest of the same path is followed when it returns.
	The path's remaining steps are handed to the mover as a new path, so StepReached indices are
	offset back to the original path's numbering on the way out.

	With a direct pathfinder, the navigator first asks whether it can walk straight at the target,
	and while it can nothing is planned: the mover is handed a two-step path, refreshed as the
	target moves. The check runs synchronously, so it must not yield. Getting stuck is judged here
	rather than by the mover, because refreshing the path restarts a mover's own stuck clock; a
	direct walk that makes no progress for DirectStuckTime is dropped for DirectCooldown and the
	target is planned for as usual.

	A target that moves between MoveTo calls is led, as the original VluxyAI pathfinding did: the
	plan aims `Lead` seconds of its velocity ahead of it (capped at LeadMax studs, and not within
	LeadMinDistance), so a chase heads for where the player is going. A led point the pathfinder
	cannot reach is dropped for the target itself in the same plan.

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
	MaxPathAge = math.huge,
	ArriveDistance = 2.5,
	ArriveHeight = 8,
	DirectInterval = 0.15,
	DirectStuckTime = 1,
	DirectCooldown = 3,
	Lead = 0.5,
	LeadMax = 8,
	LeadMinDistance = 10,
	FailedRetry = 1,
}

type Options = {
	RepathInterval: number,
	RepathDistance: number,
	MaxPathAge: number,
	ArriveDistance: number,
	ArriveHeight: number,
	DirectInterval: number,
	DirectStuckTime: number,
	DirectCooldown: number,
	Lead: number,
	LeadMax: number,
	LeadMinDistance: number,
	FailedRetry: number,
}

-- The longest wait between retries of a target that keeps failing: FailedRetry doubles up to this.
local MAX_FAILED_RETRY = 4

-- A target sampled closer together than this in time is not a velocity measurement.
local MIN_SAMPLE_SECONDS = 0.05
-- A gap longer than this between samples means the target was not being followed; start over.
local MAX_SAMPLE_SECONDS = 1

-- A direct walk only hands the mover a fresh path once the target has moved this far.
local DIRECT_REFRESH_DISTANCE = 0.5
-- Studs the mover must cover while walking direct to count as progress.
local DIRECT_PROGRESS_DISTANCE = 1
-- How near the end of its path the mover must be for "the path ends short" to be the path's fault.
local WALKED_SLACK = 4

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
	_planning: boolean,
	_generation: number,
	_stopping: boolean,
	_following: boolean,
	_destroyed: boolean,
	_warnedTarget: Vector3?,
	_lastFailed: Vector3?,
	_failStreak: number,
	_leftArrivedAt: number,
	_anchor: Vector3?,
	_anchorKind: "Arrived" | "Failed" | nil,
	_steps: { [string]: Types.StepHandler | Types.StepRegistration },
	_stepOffset: number,

	_direct: Types.Pathfinder?,
	_isDirect: boolean,
	_directCheckedAt: number,
	_directCooldownUntil: number,
	_directFollowed: Vector3?,
	_directProgress: Vector3?,
	_directStill: number,
	_warnedYield: boolean,

	_targetVelocity: Vector3,
	_sampledTarget: Vector3?,
	_sampledAt: number,

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

	A path to a target that stays put is followed to its end by default. Two options change that
	for a level that moves under the agent (doors, moving platforms, other NPCs): a pathfinder
	with a `Blocked` signal ([Navmesh] has one) makes the navigator re-plan on the next cadence
	tick, and `MaxPathAge` plans again once the current path is that many seconds old, whether or
	not anything is known to have changed. Both cost one plan each time; neither plans more often
	than `RepathInterval`.

	Arrival is judged by horizontal distance within `ArriveDistance`, with the height difference
	allowed up to `ArriveHeight`: a humanoid's root and a floor waypoint sit at different heights,
	but a target on the floor above is not reached.

	A step whose `Label` has a handler (see [Builder:OnStep]) is where the navigator does the one
	thing a mover cannot: it stops at the step, reports `Interacting`, runs the handler, and then
	walks the rest of the path. `MoveTo` with the same target keeps waiting; a new target or `Stop`
	abandons the path and the handler's return is ignored.

	With a direct pathfinder ([Builder:UseDirect]) the navigator walks straight at a target it can
	reach in a line and only plans when it cannot, or when walking straight stopped making
	progress. `IsDirect` says which it is doing.
]=]

--[=[
	@within Navigator
	@param pathfinder Pathfinder
	@param mover Mover
	@param agent Agent -- Handed to `FindPath` so a pathfinder can read the blackboard.
	@param options NavigationOptions?
	@param steps { [string]: StepHandler | StepRegistration }? -- Handlers by step label.
	@param direct Pathfinder? -- Asked first whether the agent can walk straight at the target; must not yield. See [Builder:UseDirect].
	@return Navigator
]=]
function Navigator.new(
	pathfinder: Types.Pathfinder,
	mover: Types.Mover,
	agent: Types.Agent,
	options: Types.NavigationOptions?,
	steps: { [string]: Types.StepHandler | Types.StepRegistration }?,
	direct: Types.Pathfinder?
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
		_planning = false,
		_generation = 0,
		_stopping = false,
		_following = false,
		_destroyed = false,
		_warnedTarget = nil,
		_lastFailed = nil,
		_failStreak = 0,
		_leftArrivedAt = -math.huge,
		_anchor = nil,
		_anchorKind = nil,
		_steps = steps or {},
		_stepOffset = 0,

		_direct = direct,
		_isDirect = false,
		_directCheckedAt = -math.huge,
		_directCooldownUntil = -math.huge,
		_directFollowed = nil,
		_directProgress = nil,
		_directStill = 0,
		_warnedYield = false,

		_targetVelocity = Vector3.new(0, 0, 0),
		_sampledTarget = nil,
		_sampledAt = -math.huge,

		_connections = {},
	}

	local navigator = setmetatable(self, Navigator)

	table.insert(
		self._connections,
		mover.StepReached:Connect(function(index: number, step: Types.Step)
			navigator:_onStepReached(index, step)
		end)
	)

	table.insert(
		self._connections,
		mover.Arrived:Connect(function(reached: boolean)
			navigator:_onMoverArrived(reached)
		end)
	)

	local blocked = (pathfinder :: any).Blocked
	if type(blocked) == "table" and type(blocked.Connect) == "function" then
		table.insert(
			self._connections,
			blocked:Connect(function()
				navigator:_onBlocked()
			end)
		)
	end

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
	-- A player's root jitters, so "the same target" is anything within RepathDistance of the last.
	local warned = self._warnedTarget
	if warned ~= nil and (target - warned).Magnitude <= self._options.RepathDistance then
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

	local silent = os.clock() - self._leftArrivedAt < self._options.RepathInterval

	self._generation += 1
	self._status = "Arrived"
	self._needsPlan = false
	self._anchor = self._target
	self._anchorKind = "Arrived"

	if self._mover:IsMoving() then
		self._stopping = true
		self._mover:Stop()
		self._stopping = false
	end

	-- A target that slipped out and straight back in is one arrival, not two.
	if not silent then
		self.Arrived:Fire(true)
	end
end

-- How long a step a handler refused stays closed when the handler gives no time.
local DEFAULT_CLOSE_SECONDS = 10

--[[
	The world position of an instance a step may be about: a part, a model or an attachment.
]]
local function positionOfInstance(instance: any): Vector3?
	if type(instance.IsA) ~= "function" then
		return nil
	end
	if instance:IsA("BasePart") then
		return instance.Position
	end
	if instance:IsA("Attachment") then
		return instance.WorldPosition
	end
	if instance:IsA("Model") then
		return instance:GetPivot().Position
	end
	return nil
end

--[[
	The nearest instance carrying `tag` within `radius` of `position`, for a step that arrived
	without its door.
]]
local function nearestTagged(tag: string, position: Vector3, radius: number): Instance?
	local CollectionService = game:GetService("CollectionService")

	local best: Instance? = nil
	local bestDistance = radius
	for _, instance in CollectionService:GetTagged(tag) do
		local at = positionOfInstance(instance)
		if at == nil then
			continue
		end
		local distance = (at - position).Magnitude
		if distance <= bestDistance then
			best = instance
			bestDistance = distance
		end
	end

	return best
end

--[[
	A handler said the step could not be taken: give the path up as Failed and tell the
	pathfinder to plan around the step for a while.
]]
function Navigator._refuseStep(self: Navigator, step: Types.Step, seconds: number?)
	local close = (self._pathfinder :: any).Close
	if type(close) == "function" then
		close(self._pathfinder, step, seconds or DEFAULT_CLOSE_SECONDS)
	end

	self._status = "Failed"
	self._anchor = self._target
	self._anchorKind = "Failed"
	self.Arrived:Fire(false)
end

--[[
	The mover reached a step. Forwards it in the original path's numbering, then, when the step's
	label has a handler, holds the walk there and runs it.
]]
function Navigator._onStepReached(self: Navigator, index: number, step: Types.Step)
	local original = index + self._stepOffset
	self.StepReached:Fire(original, step)

	if self._destroyed or self._status ~= "Moving" or self._following then
		return
	end

	local registration = if step.Label ~= nil then self._steps[step.Label] else nil
	if registration == nil then
		return
	end

	local handler: Types.StepHandler
	if type(registration) == "table" then
		handler = registration.Handler
		if step.Instance == nil and registration.Tag ~= nil then
			step.Instance = nearestTagged(registration.Tag, step.Position, registration.Radius or 8)
		end
		local ready = registration.Ready
		if ready ~= nil then
			local ok, isReady = pcall(ready, self._agent, step)
			if not ok then
				FormatMessage.Warn(`{self._agent.Name}: the "{step.Label}" step's Ready errored: {tostring(isReady)}`)
			elseif isReady == true then
				-- Nothing to do here (the door is already open): keep walking.
				return
			end
		end
	else
		handler = registration
	end

	local path = self._path
	if path == nil then
		return
	end

	-- Hold here. The mover's Arrived(false) for the stop is ours, not a give-up.
	self._stopping = true
	self._mover:Stop()
	self._stopping = false

	self._status = "Interacting"
	local generation = self._generation

	task.spawn(function()
		local taken: boolean? = nil
		local closeFor: number? = nil
		local ok, err = pcall(function()
			taken, closeFor = handler(self._agent, step, original)
		end)
		if not ok then
			FormatMessage.Warn(`{self._agent.Name}: the "{step.Label}" step handler errored: {tostring(err)}`)
		end

		local status: Types.PathStatus = self._status
		if self._destroyed or self._generation ~= generation or status ~= "Interacting" then
			return
		end

		if taken == false then
			self:_refuseStep(step, closeFor)
			return
		end

		self._status = "Moving"

		local remaining = table.move(path, original + 1, #path, 1, {})
		if #remaining == 0 then
			-- The handled step was the last one: the path is walked.
			self:_onMoverArrived(true)
			return
		end

		self._stepOffset = original
		self._following = true
		self._mover:Follow(remaining)
		self._following = false
	end)
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
	local position = self._mover:GetPosition()
	local targetMoved = plannedTarget == nil or (target - plannedTarget).Magnitude > self._options.RepathDistance
	local reachedPlan = plannedTarget ~= nil
		and Tables.FlatDistance(position, plannedTarget) <= self._options.ArriveDistance
		and math.abs(position.Y - plannedTarget.Y) <= self._options.ArriveHeight

	-- Only a path that was really walked can be said to fall short: a mover that reports the end
	-- while far from the path's last step was wrong about it, and a fresh plan is the answer.
	local path = self._path
	local last = if path then path[#path] else nil
	local walkedIt = last ~= nil
		and Tables.FlatDistance(position, last.Position) <= math.max(self._options.ArriveDistance, WALKED_SLACK)

	if reached and not targetMoved and not reachedPlan and walkedIt then
		-- The whole path was walked, the target has not moved, and we are still not where the plan
		-- was going: the plan itself falls short, so planning again would only walk the same path.
		self._status = "Failed"
		self._anchor = target
		self._anchorKind = "Failed"
		local previous = self._lastFailed
		local repeated = previous ~= nil and (target - previous).Magnitude <= self._options.RepathDistance
		self._lastFailed = target
		self._failStreak = if repeated then self._failStreak + 1 else 1
		self:_warnOnce(
			target,
			`the path to {target} ends {math.round(Tables.FlatDistance(position, target))} studs short`
		)
		self.Arrived:Fire(false)
		return
	end

	-- The target moved since the plan, or the mover got stuck: plan again on the cadence.
	self._needsPlan = true
end

--[[
	The pathfinder says the path being walked is no longer good. Only a path in progress can be
	blocked: while Planning the report is about the path that plan is already replacing, and after
	Arrived or Failed there is nothing to re-plan. The plan itself waits for the cadence, so a
	level that flickers does not cost a plan per flicker.
]]
function Navigator._onBlocked(self: Navigator)
	if self._destroyed or self._status ~= "Moving" then
		return
	end

	self._needsPlan = true
	self:_planIfDue(false)
end

--[[
	Asks the direct pathfinder for a straight path without letting it yield: a check that yields
	is treated as a failure, warned about once, and left to finish on its own.
]]
function Navigator._checkDirect(self: Navigator, target: Vector3): Types.Path?
	local direct = self._direct :: Types.Pathfinder
	local thread = coroutine.create(function()
		return direct:FindPath(self._mover:GetPosition(), target, self._agent)
	end)
	local ok, path = coroutine.resume(thread)
	if coroutine.status(thread) ~= "dead" then
		if not self._warnedYield then
			self._warnedYield = true
			FormatMessage.Warn(`{self._agent.Name}: the direct pathfinder yielded; it must answer at once`)
		end
		return nil
	end
	if not ok then
		self:_warnOnce(target, `the direct pathfinder errored: {tostring(path)}`)
		return nil
	end
	if type(path) ~= "table" or #path == 0 then
		return nil
	end
	return path
end

--[[
	Stops walking direct. The target is planned for at once, or, when a plan from before is still
	in flight, as soon as it lands.
]]
function Navigator._leaveDirect(self: Navigator)
	self._isDirect = false
	self._directFollowed = nil
	self._directProgress = nil
	self._directStill = 0
	self._needsPlan = true
	if not self._planning then
		self:_plan()
	end
end

--[[
	The direct half of `_planIfDue`. Returns `true` when walking direct handled this call (or
	leaving it already started a plan), `false` when the ordinary plan logic should run.
]]
function Navigator._steerDirect(self: Navigator, target: Vector3, now: number, force: boolean): boolean
	if self._direct == nil then
		return false
	end

	if self._status == "Interacting" or now < self._directCooldownUntil then
		if self._isDirect then
			self:_leaveDirect()
			return true
		end
		return false
	end

	if not force and now - self._directCheckedAt < self._options.DirectInterval then
		-- Between checks a direct walk carries on; a planned one waits for the next check.
		return self._isDirect
	end
	self._directCheckedAt = now

	local path = self:_checkDirect(target)
	if path == nil then
		if self._isDirect then
			self:_leaveDirect()
			return true
		end
		return false
	end

	if not self._isDirect then
		-- Anything planned or still planning is about the old way there; drop it.
		self._isDirect = true
		self._generation += 1
		self._directFollowed = nil
		self._directProgress = self._mover:GetPosition()
		self._directStill = 0
	end

	local followed = self._directFollowed
	local refresh = followed == nil
		or (target - followed).Magnitude > DIRECT_REFRESH_DISTANCE
		or self._status ~= "Moving"
		or not self._mover:IsMoving()
	if refresh then
		self._directFollowed = target
		self._status = "Moving"
		self._needsPlan = false
		self._plannedTarget = target
		self._stepOffset = 0
		self:_setPath(path)

		self._following = true
		self._mover:Follow(path)
		self._following = false
	end

	return true
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
	self._planning = true
	self._plannedTarget = target
	self._plannedAt = os.clock()

	task.spawn(function()
		-- A pathfinder that errors must not leave the navigator planning forever.
		-- Aim where a moving target is going; if that point cannot be planned to, the target itself.
		local aim = self:_aim(target)
		local ok, path, reason = pcall(function()
			local from = self._mover:GetPosition()
			local led, why = self._pathfinder:FindPath(from, aim, self._agent)
			if (led == nil or #led == 0) and aim ~= target then
				return self._pathfinder:FindPath(from, target, self._agent)
			end
			return led, why
		end)
		if not ok then
			reason = `FindPath errored: {tostring(path)}`
			path = nil
		end

		self._planning = false

		if self._destroyed then
			return
		end
		if self._generation ~= generation then
			-- Superseded while in flight (a Stop, a new target). Only one FindPath may run at a
			-- time on a pathfinder that keeps state, so the newer wish waited for this one.
			if self._target ~= nil then
				self:_planIfDue(true)
			end
			return
		end

		if path == nil or #path == 0 then
			self._status = "Failed"
			self._anchor = target
			self._anchorKind = "Failed"
			self:_setPath(nil)
			-- One failure is often expected (a search point that fell inside a wall, and the state
			-- moves on); the same target failing twice in a row is worth a warning, and a pathfinder
			-- that errors is a bug worth one at once.
			local previous = self._lastFailed
			local repeated = previous ~= nil and (target - previous).Magnitude <= self._options.RepathDistance
			self._lastFailed = target
			self._failStreak = if repeated then self._failStreak + 1 else 1
			if reason and (repeated or not ok) then
				self:_warnOnce(target, `no path to {target} ({reason})`)
			end
			self.Arrived:Fire(false)
			return
		end

		self._lastFailed = nil
		self._failStreak = 0
		self._status = "Moving"
		self._stepOffset = 0
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
	if target == nil then
		return
	end

	if self:_isAtTarget() then
		self:_arrive()
		return
	end

	local now = os.clock()

	-- Arrived is only true while the mover is at the target. The moment it is not, say so; the plan
	-- follows on the cadence, so a target jittering across the line does not cost a plan per tick.
	if self._status == "Arrived" then
		self._status = "Idle"
		self._needsPlan = true
		self._leftArrivedAt = now
	end

	if self:_steerDirect(target, now, force) then
		return
	end

	if self._planning then
		return
	end

	local sinceLast = now - self._plannedAt
	local plannedTarget = self._plannedTarget
	local targetMoved = plannedTarget == nil or (target - plannedTarget).Magnitude > self._options.RepathDistance
	local stale = self._status == "Failed" or self._status == "Idle"
	local aged = self._status == "Moving" and sinceLast >= self._options.MaxPathAge

	-- A target that keeps failing (the path ends short, there is no path) is retried after
	-- FailedRetry seconds from its second failure in a row, doubling, not on every RepathInterval:
	-- re-planning the same unreachable point four times a second only restarts the walk, which
	-- reads as a jerk.
	local interval = self._options.RepathInterval
	if self._status == "Failed" and not targetMoved and self._failStreak >= 2 then
		interval =
			math.max(interval, math.min(self._options.FailedRetry * 2 ^ (self._failStreak - 2), MAX_FAILED_RETRY))
	end

	local immediate = force or self._plannedAt == -math.huge
	local due = (self._needsPlan or targetMoved or stale or aged) and sinceLast >= interval

	if immediate or due then
		self:_plan()
	end
end

------------------------------------------------------------------------------------------------------------------------

--[=[
	@within Navigator
	@param target Vector3

	Heads to `target`. Call it every tick with a moving target; a plan only happens when the
	target is new, has moved more than `RepathDistance` since the last plan, the last plan failed
	or ran out, the pathfinder reported the path blocked, or the path is older than `MaxPathAge`,
	and never more often than `RepathInterval`. A new target after arriving is treated as new: the
	status leaves `Arrived` at once.
]=]
function Navigator.MoveTo(self: Navigator, target: Vector3)
	if self._destroyed then
		return
	end

	self:_sampleTarget(target)

	local previous = self._target
	self._target = target

	local force = previous == nil
	local settled = self._status == "Arrived" or self._status == "Failed" or self._status == "Idle"
	local anchor = self._anchor

	if not force and settled and anchor ~= nil then
		-- After arriving, a small drift is chased on the cadence; only a target that has clearly
		-- moved on is new. After a failure any move past RepathDistance is worth a fresh plan.
		local threshold = self._options.RepathDistance
		if self._anchorKind == "Arrived" then
			threshold += self._options.ArriveDistance
		end
		if (target - anchor).Magnitude > threshold then
			-- The old outcome was about the old target. Drop it so the new one plans at once.
			self._status = "Idle"
			self._anchor = nil
			self._anchorKind = nil
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

	local wasUnderway = self._status == "Planning" or self._status == "Moving" or self._status == "Interacting"

	self._generation += 1
	self._target = nil
	self._plannedTarget = nil
	self._needsPlan = false
	self._status = "Idle"
	self._anchor = nil
	self._anchorKind = nil
	self._stepOffset = 0
	self._isDirect = false
	self._targetVelocity = Vector3.new(0, 0, 0)
	self._sampledTarget = nil
	self._sampledAt = -math.huge
	self._directCheckedAt = -math.huge
	self._directFollowed = nil
	self._directProgress = nil
	self._directStill = 0
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
	@return number -- Studs left along the current path from where the agent is, `math.huge` when there is no path.

	The distance still to walk, around corners rather than through walls: from the agent to the
	next step of the path, then along the rest of it. What the original VluxyAI pathfinding called
	`GoalDistance`; a brain can use it to give up on a target that is too far to walk to.
]=]
function Navigator.GetRemainingDistance(self: Navigator): number
	local path = self._path
	if path == nil or #path == 0 or self._target == nil then
		return math.huge
	end

	local position = self._mover:GetPosition()
	local nearest = 1
	local nearestDistance = math.huge
	for index, step in path do
		local distance = Tables.FlatDistance(position, step.Position)
		if distance < nearestDistance then
			nearest = index
			nearestDistance = distance
		end
	end

	local next = math.min(nearest + 1, #path)
	local total = Tables.FlatDistance(position, path[next].Position)
	for index = next, #path - 1 do
		total += Tables.FlatDistance(path[index].Position, path[index + 1].Position)
	end
	return total
end

--[[
	Measures how fast the target is moving from successive MoveTo calls, flat and smoothed. Calls
	closer together than MIN_SAMPLE_SECONDS are not a measurement; a gap over MAX_SAMPLE_SECONDS
	starts over.
]]
function Navigator._sampleTarget(self: Navigator, target: Vector3)
	local now = os.clock()
	local previous = self._sampledTarget
	local elapsed = now - self._sampledAt

	if previous == nil or elapsed > MAX_SAMPLE_SECONDS then
		self._targetVelocity = Vector3.new(0, 0, 0)
		self._sampledTarget = target
		self._sampledAt = now
		return
	end
	if elapsed < MIN_SAMPLE_SECONDS then
		return
	end

	local moved = target - previous
	local velocity = Vector3.new(moved.X, 0, moved.Z) / elapsed
	self._targetVelocity = self._targetVelocity:Lerp(velocity, 0.5)
	self._sampledTarget = target
	self._sampledAt = now
end

--[[
	Where to plan to: `Lead` seconds ahead of a moving target, capped at LeadMax studs; the target
	itself when it is not moving, when leading is off, or when the agent is within LeadMinDistance.
]]
function Navigator._aim(self: Navigator, target: Vector3): Vector3
	local options = self._options
	local velocity = self._targetVelocity
	if options.Lead <= 0 or velocity.Magnitude < 1 then
		return target
	end
	if Tables.FlatDistance(self._mover:GetPosition(), target) < options.LeadMinDistance then
		return target
	end

	local lead = velocity * options.Lead
	if lead.Magnitude > options.LeadMax then
		lead = lead.Unit * options.LeadMax
	end
	return target + lead
end

--[=[
	@within Navigator
	@param deltaTime number

	One tick. Retries a plan that is due even when nobody called `MoveTo` this tick, so a state
	that called `MoveTo` once with a fixed position still gets there after a stuck mover, a blocked
	path or a path past `MaxPathAge`.
]=]
function Navigator.Step(self: Navigator, deltaTime: number)
	if self._destroyed or self._target == nil then
		return
	end

	if self._isDirect and self._status == "Moving" then
		-- Counted in ticks, not by the clock, so a paused agent is not stuck when it resumes.
		local position = self._mover:GetPosition()
		local progress = self._directProgress
		if progress == nil or (position - progress).Magnitude >= DIRECT_PROGRESS_DISTANCE then
			self._directProgress = position
			self._directStill = 0
		else
			self._directStill += deltaTime
			if self._directStill >= self._options.DirectStuckTime then
				self._directCooldownUntil = os.clock() + self._options.DirectCooldown
				self:_leaveDirect()
				return
			end
		end
	end

	self:_planIfDue(false)
end

--[=[
	@within Navigator
	@return boolean

	Whether the agent is walking straight at its target (see [Builder:UseDirect]) rather than
	following a planned path.
]=]
function Navigator.IsDirect(self: Navigator): boolean
	return self._isDirect
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
