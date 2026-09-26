--!strict

--[[
	Points of interest: the places an enemy that has lost you would think to look. Each point
	has a position and a strength; the game raises a point when something happens near it (a
	noise, a door, a light switched on) and it drifts back toward its base. An agent asks for
	the best point by strength, distance and how recently it looked there itself, so two enemies
	sharing one map still spread out and one enemy does not check the same locker twice in a
	row. Pure Luau; the scoring is Utility.Best with three considerations and any the caller adds.

	The one decision worth knowing: visits are remembered per agent in agent.Data, not on the
	point, so a map of points is shared by a whole group and each member keeps its own notion of
	"already looked there".
]]

local FormatMessage = require(script.Parent.Utility.FormatMessage)
local Options = require(script.Parent.Utility.Options)
local Types = require(script.Parent.Types)
local Utility = require(script.Parent.Brain.Utility)

------------------------------------------------------------------------------------------------------------------------

local DEFAULT_OPTIONS = table.freeze({
	Decay = 0.1,
	Visited = 30,
	Key = "Interest",
})

--[=[
	@interface InterestOptions
	@within Interest

	.Decay number? -- Strength drifts back toward a point's base at this much per second. Default `0.1`.
	.Visited number? -- Seconds a point stays uninteresting to an agent that just looked there. Default `30`.
	.Key string? -- The `agent.Data` key visits are remembered under. Default `"Interest"`.
]=]
export type InterestOptions = {
	Decay: number?,
	Visited: number?,
	Key: string?,
}

type ResolvedOptions = {
	Decay: number,
	Visited: number,
	Key: string,
}

--[=[
	@interface InterestPoint
	@within Interest

	.Id any -- What it was added under.
	.Position Vector3
	.Strength number -- The current strength, after decay.
	.Base number -- What it drifts back to.
	.Tags { string }? -- For `Best` to filter on.
]=]
export type InterestPoint = {
	Id: any,
	Position: Vector3,
	Strength: number,
	Base: number,
	Tags: { string }?,
}

--[=[
	@interface InterestPointOptions
	@within Interest

	.Position Vector3
	.Strength number? -- The base strength. Default `1`.
	.Tags { string }? -- Labels such as `"Hiding"`, `"Door"`, `"Room"`.
]=]
export type InterestPointOptions = {
	Position: Vector3,
	Strength: number?,
	Tags: { string }?,
}

--[=[
	@interface BestOptions
	@within Interest

	.Range number? -- Studs at which distance alone scores a point to nothing. Default `120`.
	.Tags { string }? -- Only points carrying one of these tags.
	.Exclude { any }? -- Point ids to leave out (the one the agent is standing at, say).
	.Considerations { Consideration<InterestPoint> }? -- Extra scoring, multiplied in.
]=]
export type BestOptions = {
	Range: number?,
	Tags: { string }?,
	Exclude: { any }?,
	Considerations: { Types.Consideration<InterestPoint> }?,
}

type Entry = {
	Id: any,
	Position: Vector3,
	Strength: number,
	Base: number,
	Tags: { string }?,
	TouchedAt: number,
}

type self = {
	_options: ResolvedOptions,
	_points: { [any]: Entry },
}

local Interest = {}
Interest.__index = Interest

export type Interest = typeof(setmetatable({} :: self, Interest))

--[=[
	@class Interest

	A shared map of points of interest with a strength each, and `Best`, which picks where an
	agent should look next. Exposed as `VluxyAI.Interest`. Make one per map, fill it from your
	level (hiding spots, doors, rooms, the generator), raise points from events, and give
	enemies a [States.Roam] over it or ask `Best` from a state of your own.

	```lua
	local interest = VluxyAI.Interest.new({ Decay = 0.1, Visited = 30 })
	for _, locker in CollectionService:GetTagged("Locker") do
		interest:Add(locker, { Position = locker.Position, Strength = 1, Tags = { "Hiding" } })
	end
	noises:Connect(function(position, loudness)
		interest:BumpNear(position, 15, loudness or 1) -- a noise makes nearby spots worth a look
	end)

	Search = VluxyAI.States.Roam({ Interest = interest, Then = "Patrol", Duration = 40 }),
	```

	An enemy never learns where a player is from this; it learns where a player would plausibly
	be. Pair it with Sight's `PredictedPosition` for "they went that way" and the enemy hunts
	like something that has to look.
]=]

--[=[
	@within Interest
	@param options InterestOptions?
	@return Interest
]=]
function Interest.new(options: InterestOptions?): Interest
	local resolved = Options.Resolve("Interest.new", DEFAULT_OPTIONS, options :: any) :: ResolvedOptions

	local self: self = {
		_options = resolved,
		_points = {},
	}

	return setmetatable(self, Interest)
end

--[[
	The strength now: drifted toward the base since it was last touched.
]]
function Interest._settle(self: Interest, entry: Entry, now: number)
	local elapsed = now - entry.TouchedAt
	if elapsed <= 0 or entry.Strength == entry.Base then
		entry.TouchedAt = now
		return
	end

	local drift = self._options.Decay * elapsed
	if entry.Strength > entry.Base then
		entry.Strength = math.max(entry.Base, entry.Strength - drift)
	else
		entry.Strength = math.min(entry.Base, entry.Strength + drift)
	end
	entry.TouchedAt = now
end

local function snapshot(entry: Entry): InterestPoint
	return {
		Id = entry.Id,
		Position = entry.Position,
		Strength = entry.Strength,
		Base = entry.Base,
		Tags = entry.Tags,
	}
end

--[=[
	@within Interest
	@param id any -- A part, a name, anything usable as a key. Adding it again replaces it.
	@param options InterestPointOptions
	@error string -- No Vector3 `Position`.
]=]
function Interest.Add(self: Interest, id: any, options: InterestPointOptions)
	if typeof(options.Position) ~= "Vector3" then
		FormatMessage.Error(`Interest.Add: {tostring(id)} needs a Vector3 Position`, 2)
	end
	local strength = options.Strength or 1

	self._points[id] = {
		Id = id,
		Position = options.Position,
		Strength = strength,
		Base = strength,
		Tags = options.Tags,
		TouchedAt = os.clock(),
	}
end

--[=[
	@within Interest
	@param id any
]=]
function Interest.Remove(self: Interest, id: any)
	self._points[id] = nil
end

--[=[
	@within Interest
	@param id any
	@return InterestPoint? -- A copy with the strength as of now, or `nil`.
]=]
function Interest.Get(self: Interest, id: any): InterestPoint?
	local entry = self._points[id]
	if entry == nil then
		return nil
	end
	self:_settle(entry, os.clock())
	return snapshot(entry)
end

--[=[
	@within Interest
	@return { InterestPoint } -- Every point, strengths as of now, in no particular order.
]=]
function Interest.Points(self: Interest): { InterestPoint }
	local now = os.clock()
	local points = {}
	for _, entry in self._points do
		self:_settle(entry, now)
		table.insert(points, snapshot(entry))
	end
	return points
end

--[=[
	@within Interest
	@param id any
	@param amount number -- Added to the strength; it decays back toward the base. Negative lowers it.
]=]
function Interest.Bump(self: Interest, id: any, amount: number)
	local entry = self._points[id]
	if entry == nil then
		return
	end
	self:_settle(entry, os.clock())
	entry.Strength = math.max(0, entry.Strength + amount)
end

--[=[
	@within Interest
	@param position Vector3
	@param radius number
	@param amount number -- Added in full at the position, fading to nothing at `radius`.
	@return number -- How many points were raised.

	A noise, a slammed door, a light: everything near it becomes worth a look.
]=]
function Interest.BumpNear(self: Interest, position: Vector3, radius: number, amount: number): number
	if radius <= 0 then
		return 0
	end
	local now = os.clock()
	local raised = 0
	for _, entry in self._points do
		local distance = (entry.Position - position).Magnitude
		if distance > radius then
			continue
		end
		self:_settle(entry, now)
		entry.Strength = math.max(0, entry.Strength + amount * (1 - distance / radius))
		raised += 1
	end
	return raised
end

--[=[
	@within Interest
	@param id any
	@param strength number -- Sets both the current strength and the base.
]=]
function Interest.Set(self: Interest, id: any, strength: number)
	local entry = self._points[id]
	if entry == nil then
		return
	end
	entry.Strength = strength
	entry.Base = strength
	entry.TouchedAt = os.clock()
end

--[[
	This agent's visit times, kept in its Data.
]]
function Interest._visitsOf(self: Interest, agent: Types.Agent): { [any]: number }
	local visits = agent.Data[self._options.Key]
	if type(visits) ~= "table" then
		visits = {}
		agent.Data[self._options.Key] = visits
	end
	return visits
end

--[=[
	@within Interest
	@param agent Agent
	@param id any

	Marks the point as looked at by this agent, so `Best` passes over it for `Visited` seconds.
]=]
function Interest.Visit(self: Interest, agent: Types.Agent, id: any)
	self:_visitsOf(agent)[id] = os.clock()
end

--[=[
	@within Interest
	@param agent Agent
	@param id any
	@return number -- Seconds since this agent last visited the point, `math.huge` if never.
]=]
function Interest.SinceVisit(self: Interest, agent: Types.Agent, id: any): number
	local at = self:_visitsOf(agent)[id]
	return if at == nil then math.huge else os.clock() - at
end

--[=[
	@within Interest
	@param agent Agent
	@param options BestOptions?
	@return InterestPoint? -- The point to look at next, or `nil` when every candidate scores 0.
	@return number -- Its score in `[0, 1]`.

	Scores every point by strength (against the strongest) and nearness (linear to `Range`),
	multiplied, then any `Considerations` given, and returns the best. A point this agent
	visited within `Visited` seconds scores 0, so a roaming enemy spreads its search instead of
	circling one spot.
]=]
function Interest.Best(self: Interest, agent: Types.Agent, options: BestOptions?): (InterestPoint?, number)
	local resolved: BestOptions = options or {}
	local range = resolved.Range or 120
	local tags = resolved.Tags
	local exclude = resolved.Exclude

	local candidates: { InterestPoint } = {}
	local strongest = 0
	for _, point in self:Points() do
		if exclude ~= nil and table.find(exclude, point.Id) ~= nil then
			continue
		end
		if tags ~= nil then
			local tagged = false
			for _, tag in tags do
				if point.Tags ~= nil and table.find(point.Tags, tag) ~= nil then
					tagged = true
					break
				end
			end
			if not tagged then
				continue
			end
		end
		table.insert(candidates, point)
		strongest = math.max(strongest, point.Strength)
	end

	if #candidates == 0 or strongest <= 0 then
		return nil, 0
	end

	local origin = agent:GetPosition()
	local visited = math.max(self._options.Visited, 1e-3)
	range = math.max(range, 1e-3)
	local considerations: { Types.Consideration<InterestPoint> } = {
		{
			Input = function(_agent: Types.Agent, point: InterestPoint): number
				return point.Strength
			end,
			Max = strongest,
		},
		{
			Input = function(_agent: Types.Agent, point: InterestPoint): number
				return (point.Position - origin).Magnitude
			end,
			Max = range,
			Invert = true,
		},
		{
			-- Binary: a point this agent looked at within Visited seconds is not a candidate at
			-- all, so a roaming enemy spreads its search instead of drifting back.
			Input = function(candidate: Types.Agent, point: InterestPoint): number
				return if self:SinceVisit(candidate, point.Id) < visited then 0 else 1
			end,
		},
	}
	if resolved.Considerations ~= nil then
		for _, consideration in resolved.Considerations do
			table.insert(considerations, consideration)
		end
	end

	return Utility.Best(agent, candidates, considerations)
end

--[=[
	@within Interest

	Forgets every point. Agents keep their visit times in their own Data.
]=]
function Interest.Destroy(self: Interest)
	table.clear(self._points)
end

return Interest
