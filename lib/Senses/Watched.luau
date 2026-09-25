--!strict

--[[
	Who is looking at the agent: the Weeping Angel sense. Sight turned around. For each target
	root the observer's eye is whatever `Eye` returns for it; by default its character's `Head`
	when it has one, else the root ([Perception.EyeOf]). The agent is watched when its pivot is
	inside the observer's view cone and, if required, a ray from that eye to the pivot hits nothing
	but the agent's own entity.

	The default eye judges "looking" by the head's facing. On a default rig the head turns with
	the body, so that is the walk direction, not where the player's camera points: a player
	walking towards the agent while looking over their shoulder counts as watching. A game that
	wants true camera direction replicates the camera's look to the server and passes `Eye`, which
	returns a CFrame for the root (the position is the eye, the LookVector the camera). Returning
	`nil` from `Eye` falls back to the default for that root.

	Writes to the blackboard:

	- `WatchedBy` { BasePart } -- The roots of every observer looking this tick, nearest first.
	- `IsWatched` boolean -- `#WatchedBy > 0`.
	- `WatchedAt` number? -- `os.clock()` of the last tick the agent was watched. `nil` if never.
	- `UnwatchedFor` number -- Seconds since `WatchedAt`: `0` while watched, `math.huge` if never.

	`WatchedAt` lives on the blackboard so one sense instance serves any number of agents.

	The ray is the observer's, so the observer's own character is always ignored and the agent's
	entity is what it is allowed to hit; `Ignore` adds to that and does not include the agent,
	unlike Sight, or the ray would pass through the agent and stop on whatever is behind it.

	Parts are read duck-typed: `.Position` on a root, `.CFrame` on the eye, and
	`:FindFirstAncestorOfClass("Model")` / `:FindFirstChild("Head")` only when present, so a spec
	can hand in tables.
]]

local FormatMessage = require(script.Parent.Parent.Utility.FormatMessage)
local Options = require(script.Parent.Parent.Utility.Options)
local Perception = require(script.Parent.Perception)
local Types = require(script.Parent.Parent.Types)

------------------------------------------------------------------------------------------------------------------------

local DEFAULT_OPTIONS = table.freeze({
	Range = 60,
	FieldOfView = 90,
	RequireLineOfSight = true,
})

--[=[
	@interface WatchedOptions
	@within Watched

	.Range number? -- Studs from which an observer can see the agent. Default `60`.
	.FieldOfView number? -- The full angle of the observer's view cone, in degrees. Default `90`.
	.RequireLineOfSight boolean? -- Cast a ray from the observer to the agent, or trust the cone alone. Default `true`.
	.Targets ((agent: Agent) -> { BasePart })? -- Who might be looking. Default [Perception.AliveRoots], every alive player's root.
	.Ignore ((agent: Agent) -> { Instance })? -- Extra instances the observer's ray passes through, on top of the observer's own character. Default none.
	.Eye ((root: BasePart) -> CFrame?)? -- Where an observer looks from and which way: a replicated camera, say. `nil` falls back to the default. Default the head's CFrame when the character has one, else the root's.
]=]
export type WatchedOptions = {
	Range: number?,
	FieldOfView: number?,
	RequireLineOfSight: boolean?,
	Targets: ((agent: Types.Agent) -> { BasePart })?,
	Ignore: ((agent: Types.Agent) -> { Instance })?,
	Eye: ((root: BasePart) -> CFrame?)?,
}

type ResolvedOptions = {
	Range: number,
	FieldOfView: number,
	RequireLineOfSight: boolean,
	Targets: (agent: Types.Agent) -> { BasePart },
	Ignore: (agent: Types.Agent) -> { Instance },
	Eye: (root: BasePart) -> CFrame?,
}

type self = {
	_options: ResolvedOptions,
}

local Watched = {}
Watched.__index = Watched

export type Watched = typeof(setmetatable({} :: self, Watched))

------------------------------------------------------------------------------------------------------------------------

--[[
	The default Ignore: nothing beyond the observer's own character.
]]
local function nothing(agent: Types.Agent): { Instance }
	local _ = agent
	return {}
end

--[[
	The default Eye: the head's CFrame when the character has one, else the root's.
]]
local function headOrRoot(root: BasePart): CFrame?
	return Perception.EyeOf(root).CFrame
end

--[=[
	@class Watched

	A [Types.Sense] that writes who is looking at the agent. An observer sees the agent when the
	agent's pivot is inside the observer's `FieldOfView` cone within `Range`, and (unless
	`RequireLineOfSight` is off) a ray from the observer's eye to the pivot reaches the agent's
	entity. Writes `WatchedBy`, `IsWatched`, `WatchedAt` and `UnwatchedFor`, which is what a
	freeze-when-seen state reads. `UnwatchedFor` is `math.huge` until the first time it is watched.

	By default an observer's eye is its character's head, so "looking" means the head's facing,
	which on a default rig is the walk direction rather than the camera. A game that wants the
	real camera direction replicates it to the server and passes `Eye`.
]=]

--[=[
	@within Watched
	@param options WatchedOptions?
	@return Watched
	@error "unknown option" -- A key not in `WatchedOptions`.
	@error "Range must be zero or more"
]=]
function Watched.new(options: WatchedOptions?): Types.Sense
	local resolved =
		Options.Resolve("Watched.new", DEFAULT_OPTIONS, options :: any, { "Targets", "Ignore", "Eye" }) :: ResolvedOptions
	resolved.Targets = resolved.Targets or Perception.AliveRoots
	resolved.Ignore = resolved.Ignore or nothing
	resolved.Eye = resolved.Eye or headOrRoot

	if resolved.Range < 0 then
		FormatMessage.Error("Watched: Range must be zero or more", 3)
	end

	local self: self = {
		_options = resolved,
	}

	return setmetatable(self, Watched) :: any
end

--[=[
	@within Watched
	@param agent Agent
	@param deltaTime number

	Checks every observer, and writes the keys listed above to `agent.Blackboard`.
]=]
function Watched.Tick(self: Watched, agent: Types.Agent, deltaTime: number)
	local _ = deltaTime
	local options = self._options
	local blackboard = agent.Blackboard

	local position = agent.Entity:GetPivot().Position
	local extraIgnore = options.Ignore(agent)

	local watchers: { BasePart } = {}
	for _, root in options.Targets(agent) do
		local eye = options.Eye(root) or headOrRoot(root) :: CFrame
		local inCone = Perception.InCone(eye, position, options.FieldOfView, options.Range)
		if not inCone then
			continue
		end

		if options.RequireLineOfSight then
			local ignore = table.clone(extraIgnore)
			local character = Perception.ModelOf(root)
			if character ~= nil then
				table.insert(ignore, character)
			else
				table.insert(ignore, root)
			end

			if not Perception.LineOfSight(eye.Position, position, ignore, agent.Entity) then
				continue
			end
		end

		table.insert(watchers, root)
	end

	watchers = Perception.SortByDistance(position, watchers)
	local now = os.clock()

	blackboard.WatchedBy = watchers
	blackboard.IsWatched = #watchers > 0

	if #watchers > 0 then
		blackboard.WatchedAt = now
		blackboard.UnwatchedFor = 0
		return
	end

	local watchedAt = blackboard.WatchedAt
	blackboard.UnwatchedFor = if type(watchedAt) == "number" then now - watchedAt else math.huge
end

--[=[
	@within Watched

	Nothing to release; present so the sense satisfies [Types.Sense] and Trove.
]=]
function Watched.Destroy(self: Watched)
	local _ = self
end

return Watched
