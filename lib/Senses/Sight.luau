--!strict

--[[
	What the agent can see: every target inside its view cone with a clear line of sight from its
	eye. The eye is the entity's pivot plus `EyeOffset`, so a tall rig looks out of its head.

	Writes to the blackboard:

	- `SeenTargets` { BasePart } -- Visible this tick, nearest first. Empty when none.
	- `SeenTarget` BasePart? -- The nearest visible target.
	- `SeenDistance` number -- Studs from the eye to `SeenTarget`, `math.huge` when there is none,
	  so a consideration can read it without a nil check.
	- `SeenPosition` Vector3? -- Where `SeenTarget` is, kept for `Memory` seconds after losing
	  sight so a state can go and look, then `nil`.
	- `SeenAt` number? -- `os.clock()` of the last sighting. `nil` once forgotten.
	- `SeenVisibility` number -- The `Visibility` factor of `SeenTarget` (`1` without the
	  option), `0` when nothing is seen.
	- `SeenMemory` { [BasePart]: { Position: Vector3, At: number } } -- With `PerTarget`: where
	  each target was last seen, kept `Memory` seconds. One table, updated in place.
	- `SeenVelocity` Vector3? -- The flat velocity of `SeenTarget` at the last sighting, read
	  off its root, kept with `SeenPosition`. `nil` when the root has no velocity to read.
	- `PredictedPosition` Vector3? -- Where the target would be now if it kept going: the last
	  position plus up to `Predict` seconds of `SeenVelocity`. Equal to `SeenPosition` while in
	  sight. The place to search first; a creature does not know, it guesses.

	Two hooks make it a horror sense: `Visibility` scales the range per target (darkness, a
	flashlight, crouching), and `SeeThrough` lets the ray pass glass. Players hidden with
	`AI_HIDDEN` are already gone from the default `Targets`.

	`SeenPosition` and `SeenAt` are the sense's memory and live on the blackboard, not in the
	sense, so one sense instance serves any number of agents and a state may clear them early.

	Parts are read duck-typed (`.Position`, and `:FindFirstAncestorOfClass` only when present), so
	a spec can pass plain tables through `Targets`.
]]

local FormatMessage = require(script.Parent.Parent.Utility.FormatMessage)
local Options = require(script.Parent.Parent.Utility.Options)
local Perception = require(script.Parent.Perception)
local SafeAreas = require(script.Parent.Parent.World.SafeAreas)
local Tables = require(script.Parent.Parent.Utility.Tables)
local Types = require(script.Parent.Parent.Types)

------------------------------------------------------------------------------------------------------------------------

local DEFAULT_OPTIONS = table.freeze({
	Prefix = "",
	Range = 40,
	FieldOfView = 120,
	EyeOffset = Vector3.new(0, 0, 0),
	Memory = 3,
	PerTarget = false,
	Predict = 2,
	PredictMax = 16,
	NoticeRadius = 0,
	NoticeThroughWalls = false,
})

--[=[
	@interface SightOptions
	@within Sight

	.Range number? -- Studs the agent can see. Default `40`.
	.FieldOfView number? -- The full angle of the view cone, in degrees. Default `120`.
	.EyeOffset Vector3? -- Added to the entity's pivot to get the eye. Default `Vector3.zero`.
	.Memory number? -- Seconds `SeenPosition` and `SeenAt` outlive the last sighting. Default `3`.
	.Targets ((agent: Agent) -> { BasePart })? -- What to look for. Default [Perception.AliveRoots], every alive player's root.
	.Ignore ((agent: Agent) -> { Instance })? -- What the sight ray passes through. Default [Perception.IgnoreList], the agent's entity.
	.Visibility ((agent: Agent, target: BasePart) -> number)? -- How visible a target is, `0` to `1` (or more): the range is multiplied by it, so `0` is invisible and `0.5` is seen at half the distance. Pass `function(_, root) return VluxyAI.Perception.LightAt(root.Position) end` for darkness. Default: everything `1`.
	.SeeThrough ((part: BasePart) -> boolean)? -- Parts the sight ray looks past, such as [Perception.Transparent]. Default: everything blocks.
	.PerTarget boolean? -- Also write `SeenMemory`, the last position and time of every target seen within `Memory` seconds, so an enemy remembers where each of several players went. Default `false`.
	.Predict number? -- Seconds of the target's last velocity to carry `PredictedPosition` forward after losing sight, capped. `0` turns prediction off. Default `2`.
	.PredictMax number? -- Studs the prediction may run past the last sighting at most. It also stops short of the first wall. Default `16`.
	.NoticeRadius number? -- Studs within which a target is noticed even outside the cone or in the dark, like someone brushing past. It still needs a clear line unless `NoticeThroughWalls`; a player hidden with `AI_HIDDEN` stays hidden. `0` turns it off. Default `0`.
	.NoticeThroughWalls boolean? -- Let `NoticeRadius` work through walls too, for a creature that senses rather than sees. Default `false`.
	.Prefix string? -- Prepended to every key this sense writes, so two instances can coexist. Default `""`.
]=]
export type SightOptions = {
	Prefix: string?,
	Range: number?,
	FieldOfView: number?,
	EyeOffset: Vector3?,
	Memory: number?,
	Targets: ((agent: Types.Agent) -> { BasePart })?,
	Ignore: ((agent: Types.Agent) -> { Instance })?,
	Visibility: ((agent: Types.Agent, target: BasePart) -> number)?,
	SeeThrough: ((part: BasePart) -> boolean)?,
	PerTarget: boolean?,
	Predict: number?,
	PredictMax: number?,
	NoticeRadius: number?,
	NoticeThroughWalls: boolean?,
}

type ResolvedOptions = {
	Prefix: string,
	Range: number,
	FieldOfView: number,
	EyeOffset: Vector3,
	Memory: number,
	Targets: (agent: Types.Agent) -> { BasePart },
	Ignore: (agent: Types.Agent) -> { Instance },
	Visibility: ((agent: Types.Agent, target: BasePart) -> number)?,
	SeeThrough: ((part: BasePart) -> boolean)?,
	PerTarget: boolean,
	Predict: number,
	PredictMax: number,
	NoticeRadius: number,
	NoticeThroughWalls: boolean,
}

type self = {
	_options: ResolvedOptions,
}

local Sight = {}
Sight.__index = Sight

export type Sight = typeof(setmetatable({} :: self, Sight))

------------------------------------------------------------------------------------------------------------------------

--[=[
	@class Sight

	A [Types.Sense] that writes what the agent can see. A target is seen when it is within `Range`,
	inside the `FieldOfView` cone around the entity's look direction, and a ray from the eye to it
	hits nothing but the target's own model.

	Writes `SeenTargets`, `SeenTarget`, `SeenDistance`, `SeenVisibility`, `SeenPosition` and
	`SeenAt`. The last two are memory: they outlive the sighting by `Memory` seconds so a state
	can head to where the target was. Distances are `math.huge` when there is nothing to measure.

	For a horror game: `Visibility` scales the range per target, so darkness and a lit flashlight
	are one function ([Perception.LightAt] is the ready-made one); `SeeThrough` lets the ray pass
	glass ([Perception.Transparent]); and a player hidden with `AI_HIDDEN` is not a target at all.

	A position remembered inside an enabled [SafeAreas] area is forgotten at once, and a
	prediction never carries into one, so no chase follows a player into a safe room.

	`NoticeRadius` is the close-range sense every enemy wants: a player that close is seen
	whichever way the agent faces and however dark it is, so sneaking right behind an enemy
	does not work.
]=]

--[=[
	@within Sight
	@param options SightOptions?
	@return Sight
	@error "unknown option" -- A key not in `SightOptions`.
	@error "Range must be zero or more"
]=]
function Sight.new(options: SightOptions?): Types.Sense
	local resolved = Options.Resolve(
		"Sight.new",
		DEFAULT_OPTIONS,
		options :: any,
		{ "Targets", "Ignore", "Visibility", "SeeThrough" }
	) :: ResolvedOptions
	resolved.Targets = resolved.Targets or Perception.AliveRoots
	resolved.Ignore = resolved.Ignore or Perception.IgnoreList

	if resolved.Range < 0 then
		FormatMessage.Error("Sight: Range must be zero or more", 3)
	end
	if resolved.NoticeRadius < 0 then
		FormatMessage.Error("Sight: NoticeRadius must be zero or more", 3)
	end

	local self: self = {
		_options = resolved,
	}

	return setmetatable(self, Sight) :: any
end

--[=[
	@within Sight
	@param agent Agent
	@param deltaTime number

	Looks, and writes the keys listed above to `agent.Blackboard`.
]=]
function Sight.Tick(self: Sight, agent: Types.Agent, deltaTime: number)
	local _ = deltaTime
	local options = self._options
	local blackboard = Tables.Prefixed(agent.Blackboard, options.Prefix)

	local eye = agent.Entity:GetPivot() + options.EyeOffset
	local ignore = options.Ignore(agent)

	local visible: { BasePart } = {}
	local visibilities: { [BasePart]: number } = {}
	for _, target in options.Targets(agent) do
		-- Close enough to notice: no cone, no darkness, and walls only when they count.
		local noticed = options.NoticeRadius > 0 and (target.Position - eye.Position).Magnitude <= options.NoticeRadius

		local visibility = 1
		if not noticed then
			if options.Visibility ~= nil then
				visibility = options.Visibility(agent, target)
				if type(visibility) ~= "number" or visibility <= 0 then
					continue
				end
			end

			local inCone = Perception.InCone(eye, target.Position, options.FieldOfView, options.Range * visibility)
			if not inCone then
				continue
			end
		end

		local clear = (noticed and options.NoticeThroughWalls)
			or Perception.LineOfSight(
				eye.Position,
				target.Position,
				ignore,
				Perception.ModelOf(target),
				options.SeeThrough
			)
		if clear then
			table.insert(visible, target)
			visibilities[target] = visibility
		end
	end

	visible = Perception.SortByDistance(eye.Position, visible)
	local nearest: BasePart? = visible[1]
	local now = os.clock()

	blackboard.SeenTargets = visible
	blackboard.SeenTarget = nearest

	if options.PerTarget then
		local memory = blackboard.SeenMemory
		if type(memory) ~= "table" then
			memory = {}
			blackboard.SeenMemory = memory
		end
		for _, target in visible do
			memory[target] = { Position = target.Position, At = now }
		end
		for target, entry in memory do
			if now - entry.At > options.Memory or SafeAreas.Contains(entry.Position) then
				memory[target] = nil
			end
		end
	end

	if nearest ~= nil then
		blackboard.SeenDistance = (nearest.Position - eye.Position).Magnitude
		blackboard.SeenVisibility = visibilities[nearest]
		blackboard.SeenPosition = nearest.Position
		blackboard.SeenAt = now
		local velocity = (nearest :: any).AssemblyLinearVelocity
		blackboard.SeenVelocity = if typeof(velocity) == "Vector3" then Vector3.new(velocity.X, 0, velocity.Z) else nil
		blackboard.PredictedPosition = nearest.Position
		return
	end

	blackboard.SeenDistance = math.huge
	blackboard.SeenVisibility = 0

	-- A state may forget early by clearing SeenAt; the position goes with it.
	if blackboard.SeenAt == nil then
		blackboard.SeenPosition = nil
	end

	-- Someone last seen inside a safe area is gone as far as the chase is concerned: nothing may
	-- follow them in, so the memory would only walk the agent into the door.
	local remembered = blackboard.SeenPosition
	if typeof(remembered) == "Vector3" and SafeAreas.Contains(remembered) then
		blackboard.SeenPosition = nil
		blackboard.SeenAt = nil
	end

	local seenAt = blackboard.SeenAt
	if type(seenAt) == "number" and now - seenAt > options.Memory then
		blackboard.SeenPosition = nil
		blackboard.SeenAt = nil
	end

	local position = blackboard.SeenPosition
	local velocity = blackboard.SeenVelocity
	if typeof(position) ~= "Vector3" or type(seenAt) ~= "number" or blackboard.SeenAt == nil then
		blackboard.SeenVelocity = nil
		blackboard.PredictedPosition = nil
	elseif typeof(velocity) == "Vector3" and options.Predict > 0 then
		blackboard.PredictedPosition = Sight.Predict(position, velocity, now - seenAt, options, agent)
	else
		blackboard.PredictedPosition = position
	end
end

--[=[
	@within Sight
	@param blackboard Blackboard -- The agent's blackboard.
	@param prefix string? -- The sense's `Prefix`. Default `""`.

	Forgets the last sighting at once: `SeenPosition`, `SeenAt`, `PredictedPosition`,
	`SeenVelocity` and `SeenMemory`. For a state or another sense that knows the chase is over (the
	target reached a safe room, got away through a door that locked) and wants nothing left to
	follow. The next sighting writes them again.
]=]
function Sight.Forget(blackboard: Types.Blackboard, prefix: string?)
	local keys = Tables.Prefixed(blackboard, prefix or "")
	keys.SeenPosition = nil
	keys.SeenAt = nil
	keys.PredictedPosition = nil
	keys.SeenVelocity = nil
	keys.SeenMemory = nil
end

-- Studs a prediction stops short of the wall it would run into, about a body's radius.
local WALL_MARGIN = 2

--[=[
	@within Sight
	@param position Vector3 -- Where the target was last seen.
	@param velocity Vector3 -- How it was moving, flat.
	@param elapsed number -- Seconds since then.
	@param options SightOptions -- `Predict` and `PredictMax` are read.
	@param agent Agent? -- For the wall ray's ignore list; without it no ray is cast.
	@return Vector3 -- Where the target probably is: carried along `velocity` for up to `Predict` seconds and `PredictMax` studs, stopped `2` studs short of the first wall in the way, and never inside a safe area.

	A prediction that ran through walls would send a chase to a point the target never went
	near, and often one no path reaches, so the agent would walk at it again and again.
]=]
function Sight.Predict(
	position: Vector3,
	velocity: Vector3,
	elapsed: number,
	options: any,
	agent: Types.Agent?
): Vector3
	local offset = velocity * math.min(elapsed, options.Predict)
	local limit = options.PredictMax or math.huge
	if offset.Magnitude > limit then
		offset = offset.Unit * limit
	end
	if offset.Magnitude < 1e-3 then
		return position
	end

	if agent ~= nil then
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		-- The ray passes the agent and the targets themselves: only the level stops a prediction.
		local ignore = Perception.IgnoreList(agent)
		local targets = if options.Targets then options.Targets(agent) else {}
		for _, root in targets do
			table.insert(ignore, Perception.ModelOf(root) or root)
		end
		params.FilterDescendantsInstances = ignore
		local hit = workspace:Raycast(position, offset, params)
		if hit then
			local travel = math.max((hit.Position - position).Magnitude - WALL_MARGIN, 0)
			offset = offset.Unit * travel
		end
	end

	local predicted = position + offset
	-- Prediction stops at a safe area's edge rather than carrying the chase inside.
	return if SafeAreas.Contains(predicted) then position else predicted
end

--[=[
	@within Sight

	Nothing to release; present so the sense satisfies [Types.Sense] and any cleanup helper.
]=]
function Sight.Destroy(self: Sight)
	local _ = self
end

--[=[
	@within Sight
	@param patch SightOptions -- The options to change; the rest keep their values.
	@error "unknown option"

	Changes options after construction, for difficulty and pacing: a director widening the cone
	or shortening the memory mid-round. The same rules as `new` apply.
]=]
function Sight.Configure(self: Sight, patch: SightOptions)
	self._options = Options.Resolve(
		"Sight.Configure",
		self._options,
		patch :: any,
		{ "Targets", "Ignore", "Visibility", "SeeThrough" }
	) :: ResolvedOptions
	if self._options.Range < 0 then
		FormatMessage.Error("Sight: Range must be zero or more", 3)
	end
	if self._options.NoticeRadius < 0 then
		FormatMessage.Error("Sight: NoticeRadius must be zero or more", 3)
	end
end

return Sight
