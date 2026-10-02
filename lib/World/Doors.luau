--!strict

--[[
	Doors that agents open. A door is a labelled step (a navmesh PathfindingLink or modifier, or a
	Graph link); this module is the ready-made registration for that label, so a game only says
	how its doors open and the navigator does the rest. Two ways to cross a door:

	- Hold (the default): stop at a closed door, open it, wait for it to swing, walk on. For doors
	  that are solid to the agent.
	- Walk through: open it and keep walking. For a game whose doors never collide with agents
	  (a collision group), where the navmesh modifier alone decides what is passable. `Opener`
	  then opens a door the agent comes up to without a labelled step, such as on a direct walk,
	  and `IgnoreUnlocked` lets the straight-line check look past doors it can open.

	Either way a locked door is refused, so the next plan goes around it.

	The one decision: the package never moves a door. A DoorDriver connects the agent to the
	game's own door script, and the default driver talks through attributes (`VLUXYAI_DOOR/Open`,
	`VLUXYAI_DOOR/Locked`, `VLUXYAI_DOOR/OpenTime`), so a door script that listens to one attribute works
	with no Luau glue. Nothing touches Roblox at module scope.
]]

local FormatMessage = require(script.Parent.Parent.Utility.FormatMessage)
local Options = require(script.Parent.Parent.Utility.Options)
local Perception = require(script.Parent.Parent.Senses.Perception)
local Tables = require(script.Parent.Parent.Utility.Tables)
local Types = require(script.Parent.Parent.Types)

------------------------------------------------------------------------------------------------------------------------

local OPEN_ATTRIBUTE = "VLUXYAI_DOOR/Open"
local LOCKED_ATTRIBUTE = "VLUXYAI_DOOR/Locked"
local OPEN_TIME_ATTRIBUTE = "VLUXYAI_DOOR/OpenTime"

local DEFAULT_OPTIONS = table.freeze({
	Tag = "VLUXYAI_DOOR",
	Radius = 8,
	OpenTime = 0.5,
	CloseSeconds = 10,
	Emit = "Door",
	WalkThrough = false,
})

local DEFAULT_OPENER_OPTIONS = table.freeze({
	Tag = "VLUXYAI_DOOR",
	Radius = 6,
	Facing = 0.3,
	Emit = "Door",
	Prefix = "",
})

--[=[
	@interface DoorStepOptions
	@within Doors

	.Tag string? -- `CollectionService` tag that finds the door for a navmesh step, which arrives without its `Instance`. Default `"VLUXYAI_DOOR"`.
	.Radius number? -- Studs from the step to look for the tagged door. Default `8`.
	.OpenTime number? -- Seconds to wait after opening, for a driver with no `OpenTime` of its own. Default `0.5`.
	.CloseSeconds number? -- Seconds a locked door is planned around before the agent tries it again. Default `10`.
	.Emit string? -- Sent with [Agent:Emit] as a door is opened, the door as the payload, so a client can play a reach. `""` sends nothing. Default `"Door"`.
	.WalkThrough boolean? -- Open a closed door and keep walking instead of stopping at it, for doors that never collide with agents. Default `false`.
]=]
export type DoorStepOptions = {
	Tag: string?,
	Radius: number?,
	OpenTime: number?,
	CloseSeconds: number?,
	Emit: string?,
	WalkThrough: boolean?,
}

type ResolvedOptions = {
	Tag: string,
	Radius: number,
	OpenTime: number,
	CloseSeconds: number,
	Emit: string,
	WalkThrough: boolean,
}

--[=[
	@interface DoorOpenerOptions
	@within Doors

	.Tag string? -- `CollectionService` tag of the doors. Default `"VLUXYAI_DOOR"`.
	.Radius number? -- Studs from the agent within which a door ahead is opened. Default `6`.
	.Facing number? -- How squarely the agent must face the door to open it: the dot product of its look direction and the direction to the door, from `-1` (any way) to `1` (dead ahead). Keeps an agent walking past a door in a side wall from opening it. Default `0.3`.
	.Emit string? -- Sent with [Agent:Emit] as a door is opened. `""` sends nothing. Default `"Door"`.
	.Driver DoorDriver? -- Default [Doors.Attributes].
	.Prefix string? -- Prepended to the keys this sense writes. Default `""`.
]=]
export type DoorOpenerOptions = {
	Tag: string?,
	Radius: number?,
	Facing: number?,
	Emit: string?,
	Driver: Types.DoorDriver?,
	Prefix: string?,
}

type ResolvedOpenerOptions = {
	Tag: string,
	Radius: number,
	Facing: number,
	Emit: string,
	Driver: Types.DoorDriver?,
	Prefix: string,
}

local Doors = {}

--[=[
	@class Doors

	Doors agents open, over a [Types.DoorDriver] your game supplies. [Doors.Step] is the
	registration for [Builder:OnStep]:

	```lua
	:OnStep("Door", VluxyAI.Doors.Step())
	```

	With no driver it uses [Doors.Attributes]: opening a door sets its `VLUXYAI_DOOR/Open` attribute to
	`true`, and your door script swings it and sets it back to `false` when it closes.
	`VLUXYAI_DOOR/Locked = true` makes an agent refuse it and plan around it; `VLUXYAI_DOOR/OpenTime` is
	how many seconds the agent waits for the swing.

	For doors that agents never collide with (put the doors and the rigs in collision groups that
	do not collide), let the agent walk through instead of stopping, open doors it walks up to on
	a direct line, and let the straight-line check look past them:

	```lua
	:UseDirect(VluxyAI.Pathfinders.Straight.new({
		Ignore = VluxyAI.Doors.IgnoreUnlocked(VluxyAI.Pathfinders.Straight.DefaultIgnore),
	}))
	:OnStep("Door", VluxyAI.Doors.Step(nil, { WalkThrough = true }))
	:AddSense(VluxyAI.Doors.Opener())
	```

	Then the navmesh modifier alone decides what is passable: `PassThrough` on while the door is
	unlocked, off while it is locked.

	Authoring a door for the navmesh: tag the door `VLUXYAI_DOOR`, give it a `PathfindingModifier` with
	`PassThrough` on and `Label = "Door"`, and put an invisible, non-colliding part a few studs deep
	across the doorway with a modifier labelled `"Door"`, so a waypoint always lands in the doorway.
	[Navmesh] moves the stop to the waypoint before the doorway.
]=]

--[=[
	@within Doors
	@prop OPEN_ATTRIBUTE "VLUXYAI_DOOR/Open"

	The attribute [Doors.Attributes] sets to open a door and reads to see that it is open.
]=]
Doors.OPEN_ATTRIBUTE = OPEN_ATTRIBUTE

--[=[
	@within Doors
	@prop LOCKED_ATTRIBUTE "VLUXYAI_DOOR/Locked"

	`true` on a door makes [Doors.Attributes] report it locked.
]=]
Doors.LOCKED_ATTRIBUTE = LOCKED_ATTRIBUTE

--[=[
	@within Doors
	@prop OPEN_TIME_ATTRIBUTE "VLUXYAI_DOOR/OpenTime"

	Seconds the door takes to open, read by [Doors.Attributes].
]=]
Doors.OPEN_TIME_ATTRIBUTE = OPEN_TIME_ATTRIBUTE

--[=[
	@within Doors
	@prop Attributes DoorDriver

	The default driver. `Open` sets `VLUXYAI_DOOR/Open` to `true`; `IsOpen` reads it; `IsLocked` reads
	`VLUXYAI_DOOR/Locked`; `OpenTime` reads `VLUXYAI_DOOR/OpenTime` when it is a number. Your door script
	listens to `VLUXYAI_DOOR/Open`, and sets it itself when a player opens or closes the door so agents
	know.
]=]
Doors.Attributes = table.freeze({
	IsOpen = function(_self: any, door: Instance): boolean
		return door:GetAttribute(OPEN_ATTRIBUTE) == true
	end,
	Open = function(_self: any, door: Instance, _agent: Types.Agent)
		door:SetAttribute(OPEN_ATTRIBUTE, true)
	end,
	IsLocked = function(_self: any, door: Instance, _agent: Types.Agent): boolean
		return door:GetAttribute(LOCKED_ATTRIBUTE) == true
	end,
	OpenTime = function(_self: any, door: Instance): number
		local seconds = door:GetAttribute(OPEN_TIME_ATTRIBUTE)
		return if type(seconds) == "number" and seconds >= 0 then seconds else DEFAULT_OPTIONS.OpenTime
	end,
}) :: Types.DoorDriver

--[[
	Whether the driver calls the door locked for this agent. A driver without `IsLocked` has no
	locks.
]]
local function isLocked(driver: Types.DoorDriver, door: Instance, agent: Types.Agent): boolean
	local check = driver.IsLocked
	return check ~= nil and check(driver, door, agent) == true
end

--[[
	Errors unless `driver` can at least tell open from closed and open a door.
]]
local function checkDriver(owner: string, driver: any)
	if type(driver) ~= "table" or type(driver.IsOpen) ~= "function" or type(driver.Open) ~= "function" then
		FormatMessage.Error(`{owner}: driver needs IsOpen and Open`, 3)
	end
end

--[[
	Announces and opens a closed door.
]]
local function open(driver: Types.DoorDriver, door: Instance, agent: Types.Agent, emit: string)
	if emit ~= "" then
		agent:Emit(emit, door)
	end
	driver:Open(door, agent)
end

--[[
	The world position of a door: a part, a model or an attachment.
]]
local function positionOf(instance: any): Vector3?
	if type(instance.IsA) ~= "function" then
		return nil
	end
	if instance:IsA("BasePart") then
		return instance.Position
	end
	if instance:IsA("Model") then
		return instance:GetPivot().Position
	end
	if instance:IsA("Attachment") then
		return instance.WorldPosition
	end
	return nil
end

--[=[
	@within Doors
	@param driver DoorDriver? -- How your doors open. Default [Doors.Attributes].
	@param options DoorStepOptions?
	@return StepRegistration -- For [Builder:OnStep].
	@error "unknown option" -- A key that is not in `DoorStepOptions`.
	@error "driver needs IsOpen and Open"

	The registration for a door label. When the agent reaches the step:

	- an open door (or a step with no door found) is walked through without stopping;
	- a locked door is refused: the path fails and the pathfinder plans around that doorway for
	  `CloseSeconds`;
	- a closed door is opened. By default the agent stops, [Agent:Emit]s `Emit`, calls the
	  driver's `Open`, waits `OpenTime`, and walks on. With `WalkThrough` it opens the door and
	  keeps walking.
]=]
function Doors.Step(driver: Types.DoorDriver?, options: DoorStepOptions?): Types.StepRegistration
	local resolved = Options.Resolve("Doors.Step", DEFAULT_OPTIONS, options :: any) :: ResolvedOptions
	local door: Types.DoorDriver = driver or Doors.Attributes
	checkDriver("Doors.Step", door)

	local function ready(agent: Types.Agent, step: Types.Step): boolean
		local instance = step.Instance
		if instance == nil then
			return true
		end
		if isLocked(door, instance, agent) then
			return false
		end
		if door:IsOpen(instance) then
			return true
		end
		if resolved.WalkThrough then
			-- Nothing to wait for: the door never stops the agent, so open it on the way past.
			open(door, instance, agent, resolved.Emit)
			return true
		end
		return false
	end

	local function handler(agent: Types.Agent, step: Types.Step, _index: number): (boolean?, number?)
		local instance = step.Instance
		if instance == nil then
			return true, nil
		end

		if isLocked(door, instance, agent) then
			return false, resolved.CloseSeconds
		end

		if door:IsOpen(instance) then
			return true, nil
		end

		open(door, instance, agent, resolved.Emit)

		local seconds = resolved.OpenTime
		local openTime = door.OpenTime
		if openTime ~= nil then
			local given = openTime(door, instance)
			if type(given) == "number" and given >= 0 then
				seconds = given
			end
		end
		if seconds > 0 then
			task.wait(seconds)
		end

		return true, nil
	end

	return {
		Handler = handler,
		Ready = ready,
		Tag = if resolved.Tag ~= "" then resolved.Tag else nil,
		Radius = resolved.Radius,
	}
end

------------------------------------------------------------------------------------------------------------------------

type Opener = {
	_options: ResolvedOpenerOptions,
	_driver: Types.DoorDriver,
}

local OpenerClass = {}
OpenerClass.__index = OpenerClass

--[=[
	@within Doors
	@param options DoorOpenerOptions?
	@return Sense
	@error "unknown option" -- A key that is not in `DoorOpenerOptions`.
	@error "driver needs IsOpen and Open"

	A sense for doors the agent walks up to without a labelled step, such as on a direct walk.
	Each tick it finds the nearest tagged door within `Radius` that the agent is facing, writes
	it as `NearDoor` (and `NearDoorDistance`, `math.huge` when there is none), and opens it if it
	is closed and not locked. Meant for doors agents never collide with; add it with
	[Builder:AddSense].
]=]
function Doors.Opener(options: DoorOpenerOptions?): Types.Sense
	local resolved =
		Options.Resolve("Doors.Opener", DEFAULT_OPENER_OPTIONS, options :: any, { "Driver" }) :: ResolvedOpenerOptions
	local driver: Types.DoorDriver = resolved.Driver or Doors.Attributes
	checkDriver("Doors.Opener", driver)

	local self: Opener = {
		_options = resolved,
		_driver = driver,
	}
	return setmetatable(self, OpenerClass) :: any
end

--[=[
	@within Doors
	@param agent Agent
	@param deltaTime number

	The [Doors.Opener] sense's tick: writes `NearDoor` and `NearDoorDistance`, and opens that door
	when it is closed and unlocked.
]=]
function OpenerClass.Tick(self: Opener, agent: Types.Agent, deltaTime: number)
	local _ = deltaTime
	local options = self._options
	local blackboard = Tables.Prefixed(agent.Blackboard, options.Prefix)

	local pivot = agent.Entity:GetPivot()
	local origin = Perception.PositionOf(agent)
	local look = Vector3.new(pivot.LookVector.X, 0, pivot.LookVector.Z)
	look = if look.Magnitude > 1e-4 then look.Unit else look

	local nearest: Instance? = nil
	local nearestDistance = math.huge
	for _, door in game:GetService("CollectionService"):GetTagged(options.Tag) do
		local at = positionOf(door)
		if at == nil then
			continue
		end
		local offset = Vector3.new(at.X - origin.X, 0, at.Z - origin.Z)
		local distance = offset.Magnitude
		if distance > options.Radius or distance >= nearestDistance then
			continue
		end
		local facing = if distance > 1e-4 then look:Dot(offset / distance) else 1
		if facing < options.Facing then
			continue
		end
		nearest = door
		nearestDistance = distance
	end

	blackboard.NearDoor = nearest
	blackboard.NearDoorDistance = nearestDistance

	if nearest ~= nil and not self._driver:IsOpen(nearest) and not isLocked(self._driver, nearest, agent) then
		open(self._driver, nearest, agent, options.Emit)
	end
end

--[=[
	@within Doors

	Nothing to release.
]=]
function OpenerClass.Destroy(self: Opener)
	local _ = self
end

------------------------------------------------------------------------------------------------------------------------

--[=[
	@within Doors
	@param base (agent: Agent) -> { Instance } -- The ignore list to extend, such as [Straight.DefaultIgnore].
	@param driver DoorDriver? -- Default [Doors.Attributes].
	@param tag string? -- Default `"VLUXYAI_DOOR"`.
	@return (agent: Agent) -> { Instance } -- An `Ignore` for [Straight] or [Sight].

	An ignore list that also passes through every tagged door the agent could open, so a direct
	walk treats an unlocked door as the open doorway it is to an agent that never collides with
	it. Locked doors still block.
]=]
function Doors.IgnoreUnlocked(
	base: (agent: Types.Agent) -> { Instance },
	driver: Types.DoorDriver?,
	tag: string?
): (agent: Types.Agent) -> { Instance }
	local door: Types.DoorDriver = driver or Doors.Attributes
	checkDriver("Doors.IgnoreUnlocked", door)
	local doorTag = tag or DEFAULT_OPTIONS.Tag

	return function(agent: Types.Agent): { Instance }
		local ignore = table.clone(base(agent))
		for _, instance in game:GetService("CollectionService"):GetTagged(doorTag) do
			if not isLocked(door, instance, agent) then
				table.insert(ignore, instance)
			end
		end
		return ignore
	end
end

return Doors
