--!strict

--[[
	SafeWatch: the sense for players an agent cannot reach. Every other sense leaves out a player
	standing in an enabled safe area, which is right for a chase but leaves a brain with nothing
	to react to; this one writes the nearest such player it can see, or was chasing a moment ago
	(they ran round a corner into the room), so a brain can stop at the door instead of walking
	into it. When it was chasing them it also wipes Sight's memory of them, so no state is left
	holding a last-seen position at the door to walk back to.

	It also keeps its own agent out: a room switched on around an agent would otherwise hold it
	inside, so an agent found in an enabled safe area is moved to the nearest spot that is not in
	one (a graph node, by default the ones given in `Spots`).

	The one decision: eviction lives in a sense because a sense is the one piece that runs every
	tick before the brain, whatever state the agent is in, so no brain has to remember to check.

	Writes to the blackboard:
	- `SafeTarget` BasePart? -- The nearest visible player root standing in an enabled safe area.
	- `SafePosition` Vector3? -- Its position.
	- `SafeDistance` number -- Studs to it, `math.huge` when there is none.
	- `SafeWasChased` boolean -- `true` for a couple of seconds after a player the agent was chasing
	  got into the safe area. A brain can react to that even when it would otherwise hold off.
]]

local FormatMessage = require(script.Parent.Parent.Utility.FormatMessage)
local Options = require(script.Parent.Parent.Utility.Options)
local Perception = require(script.Parent.Perception)
local SafeAreas = require(script.Parent.Parent.World.SafeAreas)
local Sight = require(script.Parent.Sight)
local Tables = require(script.Parent.Parent.Utility.Tables)
local Types = require(script.Parent.Parent.Types)

------------------------------------------------------------------------------------------------------------------------

local DEFAULT_OPTIONS = table.freeze({
	Prefix = "",
	Range = 60,
	EyeOffset = Vector3.new(0, 0, 0),
	Evict = true,
	Height = 3,
	Remember = 10,
	Forget = true,
	SightPrefix = "",
})

local ALLOWED = { "Spots" }

-- Seconds after a chased player gets into a safe area during which they still count as chased,
-- so a brain in the middle of something (an attack) sees it on its next check.
local ESCAPE_WINDOW = 2

--[=[
	@interface SafeWatchOptions
	@within SafeWatch

	.Range number? -- Studs within which a player in a safe area is noticed, with a clear line to them. Default `60`.
	.EyeOffset Vector3? -- Added to the entity's pivot to get the eye. Default `Vector3.zero`.
	.Evict boolean? -- Move the agent out when it finds itself in an enabled safe area. Default `true`.
	.Spots ({ Vector3 } | { GetNodes: (self: any) -> { { Position: Vector3 } } })? -- Where an evicted agent may go: floor positions, or a [Graph] whose nodes are used. The nearest one outside every safe area is chosen. Without it the agent is pushed out through the nearest face of the area's box.
	.Height number? -- Studs above a spot's floor to put the body. Default `3`, a humanoid's root.
	.Remember number? -- Seconds a player stays "the one being chased" after [Sight] last wrote them as `SeenTarget`. Such a player in a safe area counts even with no line to them. Default `10`.
	.Forget boolean? -- When the player in the safe area is one being chased, [Sight.Forget] the sighting, so the chase has nothing left to follow. Default `true`.
	.SightPrefix string? -- The `Prefix` of the [Sight] whose keys are read and forgotten. Default `""`.
	.Prefix string? -- Prepended to every key this sense writes. Default `""`.
]=]
export type SafeWatchOptions = {
	Prefix: string?,
	Range: number?,
	EyeOffset: Vector3?,
	Evict: boolean?,
	Spots: any?,
	Height: number?,
	Remember: number?,
	Forget: boolean?,
	SightPrefix: string?,
}

type ResolvedOptions = {
	Prefix: string,
	Range: number,
	EyeOffset: Vector3,
	Evict: boolean,
	Spots: any?,
	Height: number,
	Remember: number,
	Forget: boolean,
	SightPrefix: string,
}

type self = {
	_options: ResolvedOptions,
	_chased: { [any]: number },
	_escaped: { [any]: number },
}

local SafeWatch = {}
SafeWatch.__index = SafeWatch

export type SafeWatch = typeof(setmetatable({} :: self, SafeWatch))

--[=[
	@class SafeWatch

	A [Types.Sense] for players in [SafeAreas]. Writes `SafeTarget`, `SafePosition` and
	`SafeDistance` for the nearest player it can see standing in an enabled safe area, so a brain
	can stop and stare ([States.Stare]) rather than try the door. With `Evict` (the default) it
	also moves its own agent out of a safe area that was switched on around it.

	```lua
	:AddSense(VluxyAI.Senses.SafeWatch.new({ Spots = graph }))
	```
]=]

--[=[
	@within SafeWatch
	@param options SafeWatchOptions?
	@return SafeWatch
	@error "unknown option"
	@error "Range must be zero or more"
]=]
function SafeWatch.new(options: SafeWatchOptions?): Types.Sense
	local resolved = Options.Resolve("SafeWatch.new", DEFAULT_OPTIONS, options :: any, ALLOWED) :: ResolvedOptions
	if resolved.Range < 0 then
		FormatMessage.Error("SafeWatch: Range must be zero or more", 3)
	end
	local self: self = {
		_options = resolved,
		_chased = setmetatable({}, { __mode = "k" }) :: any,
		_escaped = setmetatable({}, { __mode = "k" }) :: any,
	}
	return setmetatable(self, SafeWatch) :: any
end

--[[
	The candidate floor positions for an evicted agent.
]]
local function spotsOf(spots: any): { Vector3 }
	if spots == nil then
		return {}
	end
	if type(spots) == "table" and type(spots.GetNodes) == "function" then
		local positions = {}
		for _, node in spots:GetNodes() do
			table.insert(positions, node.Position)
		end
		return positions
	end
	return spots :: { Vector3 }
end

--[=[
	@within SafeWatch
	@param cframe CFrame -- The safe area's box.
	@param size Vector3
	@param point Vector3 -- A point inside it.
	@param margin number -- Studs past the face to land.
	@return Vector3 -- `point` moved out through the nearest side face (never the top or bottom).

	The fallback when no spots were given. Pure.
]=]
function SafeWatch.PushOut(cframe: CFrame, size: Vector3, point: Vector3, margin: number): Vector3
	local localPoint = cframe:PointToObjectSpace(point)
	local toX = size.X / 2 - math.abs(localPoint.X)
	local toZ = size.Z / 2 - math.abs(localPoint.Z)
	local moved
	if toX <= toZ then
		local side = if localPoint.X >= 0 then 1 else -1
		moved = Vector3.new(side * (size.X / 2 + margin), localPoint.Y, localPoint.Z)
	else
		local side = if localPoint.Z >= 0 then 1 else -1
		moved = Vector3.new(localPoint.X, localPoint.Y, side * (size.Z / 2 + margin))
	end
	return cframe:PointToWorldSpace(moved)
end

--[[
	Moves the agent out of the safe area it stands in, if it does.
]]
function SafeWatch._evict(self: SafeWatch, agent: Types.Agent, position: Vector3)
	local inside, area = SafeAreas.Contains(position)
	if not inside or area == nil then
		return
	end

	local best: Vector3? = nil
	local bestDistance = math.huge
	local lift = Vector3.new(0, 1, 0)
	for _, spot in spotsOf(self._options.Spots) do
		local distance = (spot - position).Magnitude
		if distance < bestDistance and not SafeAreas.Contains(spot + lift) then
			best = spot
			bestDistance = distance
		end
	end

	if best ~= nil then
		agent:Teleport(best + Vector3.new(0, self._options.Height, 0))
	else
		agent:Teleport(SafeWatch.PushOut(area.CFrame, area.Size, position, 3))
	end
end

--[=[
	@within SafeWatch
	@param agent Agent
	@param deltaTime number

	Evicts the agent when it is in a safe area, then writes the keys listed above.
]=]
function SafeWatch.Tick(self: SafeWatch, agent: Types.Agent, deltaTime: number)
	local _ = deltaTime
	local options = self._options
	local blackboard = Tables.Prefixed(agent.Blackboard, options.Prefix)

	if options.Evict then
		self:_evict(agent, Perception.PositionOf(agent))
	end

	-- Whoever Sight is on now is the one being chased, for Remember seconds after; seeing them
	-- again outside a safe area means any earlier escape is over.
	local now = os.clock()
	local sight = Tables.Prefixed(agent.Blackboard, options.SightPrefix)
	local seen = sight.SeenTarget
	if seen ~= nil then
		self._chased[seen] = now
		self._escaped[seen] = nil
	end
	for root, at in self._chased do
		if now - at > options.Remember then
			self._chased[root] = nil
			self._escaped[root] = nil
		end
	end

	local eye = (agent.Entity:GetPivot() + options.EyeOffset).Position
	local ignore = Perception.IgnoreList(agent)
	local nearest: BasePart? = nil
	local nearestDistance = math.huge
	local nearestChased = false
	for _, root in Perception.AllAliveRoots() do
		if Perception.IsHidden(root) then
			continue
		end
		if not SafeAreas.Contains(root.Position) then
			-- Out again: a later run back in is a fresh escape.
			self._escaped[root] = nil
			continue
		end

		-- One it was chasing counts from anywhere for ESCAPE_WINDOW after they got in, so a brain
		-- busy with an attack still sees it; anyone else only in view and in range.
		local escapedAt = self._escaped[root]
		local chased = self._chased[root] ~= nil and (escapedAt == nil or now - escapedAt <= ESCAPE_WINDOW)
		local distance = (root.Position - eye).Magnitude
		if distance >= nearestDistance or (not chased and distance > options.Range) then
			continue
		end
		if chased or Perception.LineOfSight(eye, root.Position, ignore, Perception.ModelOf(root)) then
			nearest = root
			nearestDistance = distance
			nearestChased = chased
		end
	end

	if nearest ~= nil and nearestChased then
		if self._escaped[nearest] == nil then
			self._escaped[nearest] = now
		end
		if options.Forget then
			-- They made it in: nothing left to follow.
			Sight.Forget(agent.Blackboard, options.SightPrefix)
		end
	end

	blackboard.SafeTarget = nearest
	blackboard.SafePosition = if nearest then nearest.Position else nil
	blackboard.SafeDistance = nearestDistance
	blackboard.SafeWasChased = nearestChased
end

--[=[
	@within SafeWatch

	Nothing to release.
]=]
function SafeWatch.Destroy(self: SafeWatch)
	local _ = self
end

--[=[
	@within SafeWatch
	@param patch SafeWatchOptions
	@error "unknown option"

	Changes options after construction.
]=]
function SafeWatch.Configure(self: SafeWatch, patch: SafeWatchOptions)
	self._options = Options.Resolve("SafeWatch.Configure", self._options, patch :: any, ALLOWED) :: ResolvedOptions
end

return SafeWatch
