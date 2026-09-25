--!strict

--[[
	Who is looking at the agent: the Weeping Angel sense. Sight turned around. For each target
	root the observer's eye is its character's `Head` when it has one, else the root; the agent is
	watched when its pivot is inside the observer's view cone and, if required, a ray from that eye
	to the pivot hits nothing but the agent's own entity.

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
	.Targets ((agent: Agent) -> { BasePart })? -- Who might be looking. Default every alive player's root.
	.Ignore ((agent: Agent) -> { Instance })? -- Extra instances the observer's ray passes through, on top of the observer's own character. Default none.
]=]
export type WatchedOptions = {
	Range: number?,
	FieldOfView: number?,
	RequireLineOfSight: boolean?,
	Targets: ((agent: Types.Agent) -> { BasePart })?,
	Ignore: ((agent: Types.Agent) -> { Instance })?,
}

type Options = {
	Range: number,
	FieldOfView: number,
	RequireLineOfSight: boolean,
	Targets: (agent: Types.Agent) -> { BasePart },
	Ignore: (agent: Types.Agent) -> { Instance },
}

type self = {
	_options: Options,
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

--[=[
	@class Watched

	A [Types.Sense] that writes who is looking at the agent. An observer sees the agent when the
	agent's pivot is inside the observer's `FieldOfView` cone within `Range`, and (unless
	`RequireLineOfSight` is off) a ray from the observer's head to the pivot reaches the agent's
	entity. Writes `WatchedBy`, `IsWatched`, `WatchedAt` and `UnwatchedFor`, which is what a
	freeze-when-seen state reads.
]=]

--[=[
	@within Watched
	@param options WatchedOptions?
	@return Watched
]=]
function Watched.new(options: WatchedOptions?): Types.Sense
	local resolved = table.clone(DEFAULT_OPTIONS) :: any
	for key, value in (options or {}) :: any do
		resolved[key] = value
	end
	resolved.Targets = resolved.Targets or Perception.AliveRoots
	resolved.Ignore = resolved.Ignore or nothing

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
		local eye = Perception.EyeOf(root)
		local inCone = Perception.InCone(eye.CFrame, position, options.FieldOfView, options.Range)
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
