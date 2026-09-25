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
local Types = require(script.Parent.Parent.Types)

------------------------------------------------------------------------------------------------------------------------

local DEFAULT_OPTIONS = table.freeze({
	Range = 40,
	FieldOfView = 120,
	EyeOffset = Vector3.new(0, 0, 0),
	Memory = 3,
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
]=]
export type SightOptions = {
	Range: number?,
	FieldOfView: number?,
	EyeOffset: Vector3?,
	Memory: number?,
	Targets: ((agent: Types.Agent) -> { BasePart })?,
	Ignore: ((agent: Types.Agent) -> { Instance })?,
	Visibility: ((agent: Types.Agent, target: BasePart) -> number)?,
	SeeThrough: ((part: BasePart) -> boolean)?,
}

type ResolvedOptions = {
	Range: number,
	FieldOfView: number,
	EyeOffset: Vector3,
	Memory: number,
	Targets: (agent: Types.Agent) -> { BasePart },
	Ignore: (agent: Types.Agent) -> { Instance },
	Visibility: ((agent: Types.Agent, target: BasePart) -> number)?,
	SeeThrough: ((part: BasePart) -> boolean)?,
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
	local blackboard = agent.Blackboard

	local eye = agent.Entity:GetPivot() + options.EyeOffset
	local ignore = options.Ignore(agent)

	local visible: { BasePart } = {}
	local visibilities: { [BasePart]: number } = {}
	for _, target in options.Targets(agent) do
		local visibility = 1
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

		local clear = Perception.LineOfSight(
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

	if nearest ~= nil then
		blackboard.SeenDistance = (nearest.Position - eye.Position).Magnitude
		blackboard.SeenVisibility = visibilities[nearest]
		blackboard.SeenPosition = nearest.Position
		blackboard.SeenAt = now
		return
	end

	blackboard.SeenDistance = math.huge
	blackboard.SeenVisibility = 0

	-- A state may forget early by clearing SeenAt; the position goes with it.
	if blackboard.SeenAt == nil then
		blackboard.SeenPosition = nil
	end

	local seenAt = blackboard.SeenAt
	if type(seenAt) == "number" and now - seenAt > options.Memory then
		blackboard.SeenPosition = nil
		blackboard.SeenAt = nil
	end
end

--[=[
	@within Sight

	Nothing to release; present so the sense satisfies [Types.Sense] and any cleanup helper.
]=]
function Sight.Destroy(self: Sight)
	local _ = self
end

return Sight
