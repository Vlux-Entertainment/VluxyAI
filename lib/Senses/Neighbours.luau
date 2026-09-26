--!strict

--[[
	Other agents nearby, for the enemies that share a map. One Neighbours instance is a group:
	every agent that ticks it joins and sees the others, so two packs that should ignore each
	other simply use two instances, and an enemy with none is invisible to all. Writes who is
	near and which way is away from them; with `Slow` it also eases the agent's speed as it
	closes on its nearest neighbour, and with `Avoid` it nudges the mover sideways so two
	enemies do not fight for the same doorway. Both are off unless asked for, because some
	enemies should crowd.

	Writes to the blackboard:

	- `NearbyAgents` { Agent } -- Group members within `Range`, nearest first.
	- `NearestAgent` Agent? -- The nearest of those.
	- `NearestAgentDistance` number -- Studs to it, `math.huge` when there is none.
	- `Crowding` number -- `0` alone, rising toward `1` as neighbours get close and many.
	- `SeparationDirection` Vector3? -- A flat unit vector away from the neighbours, weighted by
	  closeness. `nil` when alone.

	The one decision worth knowing: the speed ease goes through the agent's speed scale, not the
	mover's speed, so a state that sets its own speed on entry is still obeyed; the scale sits on
	top of whatever the state asked for. Pure Luau.
]]

local FormatMessage = require(script.Parent.Parent.Utility.FormatMessage)
local Options = require(script.Parent.Parent.Utility.Options)
local Tables = require(script.Parent.Parent.Utility.Tables)
local Types = require(script.Parent.Parent.Types)

------------------------------------------------------------------------------------------------------------------------

local DEFAULT_OPTIONS = table.freeze({
	Prefix = "",
	Range = 10,
})

local ALLOWED_OPTIONS = { "Slow", "Avoid", "Others", "Filter" }

--[=[
	@interface NeighboursSlow
	@within Neighbours

	.Distance number -- Studs from the nearest neighbour at which the ease begins. Further away the speed is untouched. `0` turns the ease off.
	.Min number? -- The speed scale when the neighbour is on top of the agent. Default `0.5`.
	.Curve Curve? -- Shape of the ease over `[0, 1]` (distance over `Distance`). Default linear.
]=]
export type NeighboursSlow = {
	Distance: number,
	Min: number?,
	Curve: Types.Curve?,
}

--[=[
	@interface NeighboursAvoid
	@within Neighbours

	.Radius number -- Studs within which a neighbour pushes the agent sideways. `0` turns the nudge off.
	.Strength number? -- How hard: the nudge is up to `Strength * Radius` studs. Default `1`.
]=]
export type NeighboursAvoid = {
	Radius: number,
	Strength: number?,
}

--[=[
	@interface NeighboursOptions
	@within Neighbours

	.Range number? -- Studs within which another agent counts as nearby. Default `10`.
	.Slow NeighboursSlow? -- Ease the agent's speed as its nearest neighbour gets close. Off by default, and off with `Distance = 0`.
	.Avoid NeighboursAvoid? -- Nudge the mover away from neighbours while walking. Off by default, off with `Radius = 0`; needs a mover with `SetNudge` (both built-ins have it).
	.Others ((agent: Agent) -> { Agent })? -- Who counts, instead of the agents sharing this instance.
	.Filter ((agent: Agent, other: Agent) -> boolean)? -- Return `false` to ignore `other` for `agent`: same kind only, say.
	.Prefix string? -- Prepended to every key this sense writes. Default `""`.
]=]
export type NeighboursOptions = {
	Range: number?,
	Slow: NeighboursSlow?,
	Avoid: NeighboursAvoid?,
	Others: ((agent: Types.Agent) -> { Types.Agent })?,
	Filter: ((agent: Types.Agent, other: Types.Agent) -> boolean)?,
	Prefix: string?,
}

type ResolvedOptions = {
	Prefix: string,
	Range: number,
	Slow: NeighboursSlow?,
	Avoid: NeighboursAvoid?,
	Others: ((agent: Types.Agent) -> { Types.Agent })?,
	Filter: ((agent: Types.Agent, other: Types.Agent) -> boolean)?,
}

type self = {
	_options: ResolvedOptions,
	_members: { [Types.Agent]: Types.Connection | boolean },
}

local Neighbours = {}
Neighbours.__index = Neighbours

export type Neighbours = typeof(setmetatable({} :: self, Neighbours))

--[=[
	@class Neighbours

	A [Types.Sense] for enemies that share a map: who else from the group is near, which way is
	away from them, and, when asked, an eased speed and a sideways nudge so they do not pile up.
	One instance is one group; make it once and add it to every enemy that should know about
	the others. Exposed as `VluxyAI.Senses.Neighbours`.

	```lua
	local crowd = VluxyAI.Senses.Neighbours.new({
		Range = 10,
		Slow = { Distance = 5, Min = 0.5 },  -- half speed when shoulder to shoulder
		Avoid = { Radius = 4 },              -- step aside within four studs
	})
	-- every enemy in the group
	:AddSense(crowd)
	```

	Enemies that should crowd (a swarm) take the sense without `Slow` and `Avoid`, or with
	`Distance = 0` and `Radius = 0`, or leave it out. An enemy that must ignore one kind gives
	`Filter`; `Configure` turns either behaviour on or off later.
	`Configure({ Avoid = { Radius = 0 } })` is the opt-out at runtime.
]=]

--[=[
	@within Neighbours
	@param options NeighboursOptions?
	@return Neighbours
	@error "unknown option"
	@error string -- `Slow.Distance` or `Avoid.Radius` missing or below `0`.
]=]
function Neighbours.new(options: NeighboursOptions?): Types.Sense
	local resolved =
		Options.Resolve("Neighbours.new", DEFAULT_OPTIONS, options :: any, ALLOWED_OPTIONS) :: ResolvedOptions
	Neighbours._check(resolved)

	local self: self = {
		_options = resolved,
		_members = setmetatable({}, { __mode = "k" }) :: any,
	}

	return setmetatable(self, Neighbours) :: any
end

--[[
	The two behaviour tables need a distance each; zero is the same as leaving the table out.
]]
function Neighbours._check(resolved: ResolvedOptions)
	if resolved.Range < 0 then
		FormatMessage.Error("Neighbours: Range must be zero or more", 3)
	end
	local slow = resolved.Slow
	if slow ~= nil and (type(slow.Distance) ~= "number" or slow.Distance < 0) then
		FormatMessage.Error("Neighbours: Slow.Distance must be a number of 0 or more", 3)
	end
	local avoid = resolved.Avoid
	if avoid ~= nil and (type(avoid.Radius) ~= "number" or avoid.Radius < 0) then
		FormatMessage.Error("Neighbours: Avoid.Radius must be a number of 0 or more", 3)
	end
end

------------------------------------------------------------------------------------------------------------------------

--[[
	Joins an agent to the group, leaving again when it is destroyed.
]]
function Neighbours._join(self: Neighbours, agent: Types.Agent)
	if self._members[agent] ~= nil then
		return
	end

	local destroyed = (agent :: any).Destroyed
	if type(destroyed) == "table" and type(destroyed.Connect) == "function" then
		self._members[agent] = destroyed:Connect(function()
			self:Destroy(agent)
		end)
	else
		self._members[agent] = true
	end
end

--[[
	The agents this one measures against: the option's list, or the group minus itself.
]]
function Neighbours._othersOf(self: Neighbours, agent: Types.Agent): { Types.Agent }
	local others = self._options.Others
	if others ~= nil then
		return others(agent)
	end

	local list = {}
	for member in self._members do
		if member ~= agent then
			table.insert(list, member)
		end
	end
	return list
end

--[=[
	@within Neighbours
	@param agent Agent
	@param deltaTime number

	Joins the agent to the group on its first tick, measures the others, writes the keys listed
	above, and applies `Slow` and `Avoid` when they are set.
]=]
function Neighbours.Tick(self: Neighbours, agent: Types.Agent, deltaTime: number)
	local _ = deltaTime
	local options = self._options
	local blackboard = Tables.Prefixed(agent.Blackboard, options.Prefix)

	self:_join(agent)

	local origin = agent:GetPosition()
	local filter = options.Filter

	type Entry = { Agent: Types.Agent, Distance: number, Away: Vector3 }
	local entries: { Entry } = {}
	for _, other in self:_othersOf(agent) do
		if other == agent then
			continue
		end
		local isDestroyed = (other :: any).IsDestroyed
		if type(isDestroyed) == "function" and other:IsDestroyed() then
			continue
		end
		if filter ~= nil and filter(agent, other) == false then
			continue
		end

		local offset = origin - other:GetPosition()
		local flat = Vector3.new(offset.X, 0, offset.Z)
		local distance = flat.Magnitude
		if distance > options.Range then
			continue
		end

		table.insert(entries, {
			Agent = other,
			Distance = distance,
			Away = if distance > 1e-4 then flat / distance else Vector3.new(0, 0, 0),
		})
	end

	table.sort(entries, function(a: Entry, b: Entry)
		return a.Distance < b.Distance
	end)

	local nearby: { Types.Agent } = {}
	local crowding = 0
	local push = Vector3.new(0, 0, 0)
	for _, entry in entries do
		table.insert(nearby, entry.Agent)
		local closeness = if options.Range > 0 then 1 - entry.Distance / options.Range else 1
		crowding += closeness
		push += entry.Away * closeness
	end

	local nearest = entries[1]
	blackboard.NearbyAgents = nearby
	blackboard.NearestAgent = if nearest then nearest.Agent else nil
	blackboard.NearestAgentDistance = if nearest then nearest.Distance else math.huge
	blackboard.Crowding = math.clamp(crowding, 0, 1)
	blackboard.SeparationDirection = if push.Magnitude > 1e-4 then push.Unit else nil

	local slow = options.Slow
	if slow ~= nil and slow.Distance > 0 then
		local scale = 1
		if nearest ~= nil and nearest.Distance < slow.Distance then
			local t = nearest.Distance / slow.Distance
			local shaped = if slow.Curve then slow.Curve(t) else t
			local min = slow.Min or 0.5
			scale = math.clamp(min + (1 - min) * shaped, 0, 1)
		end
		agent:SetSpeedScale(scale)
	end

	local avoid = options.Avoid
	if avoid ~= nil and avoid.Radius > 0 then
		local mover = agent.Mover :: any
		local setNudge = if mover then mover.SetNudge else nil
		if type(setNudge) == "function" then
			local nudge: Vector3? = nil
			if nearest ~= nil and nearest.Distance < avoid.Radius and push.Magnitude > 1e-4 then
				local strength = avoid.Strength or 1
				local amount = math.min(avoid.Radius, strength * (avoid.Radius - nearest.Distance))
				nudge = push.Unit * amount
			end
			setNudge(mover, nudge)
		end
	end
end

--[=[
	@within Neighbours
	@param patch NeighboursOptions
	@error "unknown option"

	Changes options after construction. The same rules as `new` apply.
]=]
function Neighbours.Configure(self: Neighbours, patch: NeighboursOptions)
	self._options =
		Options.Resolve("Neighbours.Configure", self._options, patch :: any, ALLOWED_OPTIONS) :: ResolvedOptions
	Neighbours._check(self._options)
end

--[=[
	@within Neighbours
	@param agent Agent?

	Removes the agent from the group and undoes its ease and nudge; with no agent, empties the
	group.
]=]
function Neighbours.Destroy(self: Neighbours, agent: Types.Agent?)
	local function leave(member: Types.Agent)
		local connection = self._members[member]
		if type(connection) == "table" then
			connection:Disconnect()
		end
		self._members[member] = nil

		local isDestroyed = (member :: any).IsDestroyed
		if type(isDestroyed) == "function" and member:IsDestroyed() then
			return
		end
		if self._options.Slow ~= nil then
			member:SetSpeedScale(1)
		end
		local mover = member.Mover :: any
		if self._options.Avoid ~= nil and mover and type(mover.SetNudge) == "function" then
			mover:SetNudge(nil)
		end
	end

	if agent ~= nil then
		leave(agent)
		return
	end

	for member in self._members do
		leave(member)
	end
end

return Neighbours
