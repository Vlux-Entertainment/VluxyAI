--!strict

--[[
	Ready-made movement states, so the loop every enemy needs (walk the nodes, go and look, fan
	out around the last sighting, drift near home, stand still) is one line each instead of forty.
	Each factory returns a plain Types.State; a brain drops it in beside hand-written states and
	adds its own `Transitions` through the options.

	Scratch (the current index, the chosen points, the home) lives under one key in `agent.Data`
	per state, so one definition serves many agents. Random numbers come from `Random` on the
	options, then `agent.Data.Random`, then a fresh `Random.new()`, so a seeded playground stays
	reproducible. Pure Luau.
]]

local FormatMessage = require(script.Parent.Parent.Utility.FormatMessage)
local Options = require(script.Parent.Parent.Utility.Options)
local Types = require(script.Parent.Parent.Types)

------------------------------------------------------------------------------------------------------------------------

type Range = number | { number }
type PositionSource = string | Vector3 | ((agent: Types.Agent) -> Vector3?)
type PointsSource = string | { Vector3 } | ((agent: Types.Agent) -> { Vector3 })

local States = {}

--[=[
	@class States

	Factories for the states every enemy ends up writing: [States.Patrol], [States.Investigate],
	[States.Search], [States.Wander] and [States.Wait]. Exposed as `VluxyAI.States`.

	```lua
	local States = VluxyAI.States
	local When = VluxyAI.When

	local Brain: VluxyAI.Brain = {
		Initial = "Patrol",
		Interrupts = {
			{ To = "Hunt", When = When.Has("SeenTarget"), Except = { "Hunt", "Attack" } },
			{ To = "Investigate", When = When.New("HeardAt"), Except = { "Hunt", "Attack" } },
		},
		States = {
			Patrol = States.Patrol({ Points = "Nodes", Speed = 10 }),
			Investigate = States.Investigate({ Target = "HeardPosition", Speed = 14, Then = "Patrol" }),
			Hunt = { ... },
			Search = States.Search({ Around = "SeenPosition", Radius = 12, Points = 3, Duration = 14, Then = "Patrol" }),
			Attack = VluxyAI.Combat.Attack.State({ ... }),
		},
	}
	```

	[States.Roam] walks the best point of an [Interest] map, marking each visited, so an enemy
	that has lost you checks the places you would plausibly be.

	Every factory accepts `Transitions` (checked before the state's own logic, like any state),
	`Enter` and `Exit` hooks run after the built-in ones, `Speed` to set on entry, and `Key`, the
	`agent.Data` key its scratch lives under (default: the state's own name). Positions may be
	given as a blackboard or `Data` key, a `Vector3`, or a function of the agent. A point the
	navigator cannot reach is skipped on the next tick, so a search point inside a wall costs
	nothing but a failed plan.
]=]

------------------------------------------------------------------------------------------------------------------------

--[[
	The agent's random source: the options', then agent.Data.Random, then a fresh one.
]]
local function randomOf(agent: Types.Agent, given: Random?): Random
	if given ~= nil then
		return given
	end
	local fromData = agent.Data.Random
	if fromData ~= nil then
		return fromData
	end
	local fresh = Random.new()
	agent.Data.Random = fresh
	return fresh
end

--[[
	A number or a {min, max} pair, picked.
]]
local function pick(random: Random, value: Range): number
	if type(value) == "number" then
		return value
	end
	return random:NextNumber(value[1], value[2])
end

--[[
	A position from a key (blackboard first, then Data), a Vector3, or a function.
]]
local function positionOf(agent: Types.Agent, source: PositionSource?): Vector3?
	if source == nil then
		return nil
	end
	if typeof(source) == "Vector3" then
		return source
	end
	if type(source) == "function" then
		return source(agent)
	end
	local value = agent.Blackboard[source :: string]
	if value == nil then
		value = agent.Data[source :: string]
	end
	if value ~= nil and typeof(value) ~= "Vector3" then
		return nil
	end
	return value
end

--[[
	A list of points from a Data key, a list, or a function.
]]
local function pointsOf(agent: Types.Agent, source: PointsSource): { Vector3 }
	if type(source) == "function" then
		return source(agent) or {}
	end
	if type(source) == "table" then
		return source
	end
	local value = agent.Data[source]
	if type(value) ~= "table" then
		return {}
	end
	return value
end

--[[
	The state's scratch table under agent.Data[key], made on first use.
]]
local function scratchOf(agent: Types.Agent, key: string): { [string]: any }
	local scratch = agent.Data[key]
	if type(scratch) ~= "table" then
		scratch = {}
		agent.Data[key] = scratch
	end
	return scratch
end

local function pathDone(agent: Types.Agent): boolean
	local status = agent:GetPathStatus()
	return status == "Arrived" or status == "Failed"
end

--[[
	Assembles the State from the built-in behaviour and the caller's hooks and transitions.
]]
local function assemble(
	options: any,
	enter: (agent: Types.Agent) -> (),
	update: (agent: Types.Agent, deltaTime: number) -> string?,
	exit: ((agent: Types.Agent) -> ())?
): Types.State
	return {
		Enter = function(agent: Types.Agent)
			if options.Speed ~= nil then
				agent:SetSpeed(options.Speed)
			end
			enter(agent)
			if options.Enter then
				options.Enter(agent)
			end
		end,
		Update = update,
		Exit = if exit ~= nil or options.Exit ~= nil
			then function(agent: Types.Agent)
				if exit then
					exit(agent)
				end
				if options.Exit then
					options.Exit(agent)
				end
			end
			else nil,
		Transitions = options.Transitions,
	}
end

------------------------------------------------------------------------------------------------------------------------

--[=[
	@within States
	@param random Random
	@param centre Vector3
	@param radius number
	@return Vector3 -- A point on the horizontal disc of `radius` around `centre`, uniformly distributed, at the centre's height.
]=]
function States.RandomPoint(random: Random, centre: Vector3, radius: number): Vector3
	local angle = random:NextNumber(0, 2 * math.pi)
	local distance = math.sqrt(random:NextNumber(0, 1)) * radius
	return centre + Vector3.new(math.cos(angle) * distance, 0, math.sin(angle) * distance)
end

------------------------------------------------------------------------------------------------------------------------

local PATROL_DEFAULTS = table.freeze({
	Order = "Loop",
	Key = "Patrol",
})

local PATROL_ALLOWED = { "Points", "Speed", "Pause", "Random", "Transitions", "Enter", "Exit" }

--[=[
	@interface PatrolOptions
	@within States

	.Points string | { Vector3 } | (agent: Agent) -> { Vector3 } -- The route: a `Data` key holding a list, the list itself, or a function. Required.
	.Order "Loop" | "PingPong" | "Random"? -- Loop back to the first point, walk the list both ways, or pick any other point. Default `"Loop"`.
	.Pause number | { number }? -- Seconds to stand at each point, or a `{ min, max }` range. Default none.
	.Speed number? -- Set on entry.
	.Random Random? -- For `Random` order and a ranged `Pause`. Default `agent.Data.Random`, else a new one.
	.Key string? -- The `Data` key for the current index. Default `"Patrol"`.
	.Transitions { Transition }?
	.Enter ((agent: Agent) -> ())?
	.Exit ((agent: Agent) -> ())?
]=]
export type PatrolOptions = {
	Points: PointsSource,
	Order: ("Loop" | "PingPong" | "Random")?,
	Pause: Range?,
	Speed: number?,
	Random: Random?,
	Key: string?,
	Transitions: { Types.Transition }?,
	Enter: ((agent: Types.Agent) -> ())?,
	Exit: ((agent: Types.Agent) -> ())?,
}

--[=[
	@within States
	@param options PatrolOptions
	@return State

	Walks the points in order, forever. The index survives leaving and re-entering the state, so
	an enemy that broke off to investigate resumes where it was. A point that cannot be reached
	is skipped.
]=]
function States.Patrol(options: PatrolOptions): Types.State
	local resolved = Options.Resolve("States.Patrol", PATROL_DEFAULTS, options :: any, PATROL_ALLOWED) :: any
	if resolved.Points == nil then
		FormatMessage.Error("States.Patrol: Points is required", 2)
	end
	local key: string = resolved.Key
	local timer = `States.{key}`

	local function nextIndex(agent: Types.Agent, scratch: { [string]: any }, count: number): number
		local index: number = scratch.Index or 0
		if resolved.Order == "Random" then
			if count <= 1 then
				return 1
			end
			local choice = randomOf(agent, resolved.Random):NextInteger(1, count - 1)
			return if choice >= index then choice + 1 else choice
		end
		if resolved.Order == "PingPong" then
			local direction: number = scratch.Direction or 1
			local candidate = index + direction
			if candidate > count or candidate < 1 then
				direction = -direction
				scratch.Direction = direction
				candidate = math.clamp(index + direction, 1, count)
			end
			return candidate
		end
		return index % count + 1
	end

	local function go(agent: Types.Agent, scratch: { [string]: any })
		local points = pointsOf(agent, resolved.Points)
		if #points == 0 then
			return
		end
		local index = nextIndex(agent, scratch, #points)
		scratch.Index = index
		scratch.Pausing = false
		agent:MoveTo(points[index])
	end

	return assemble(resolved, function(agent: Types.Agent)
		local scratch = scratchOf(agent, key)
		local points = pointsOf(agent, resolved.Points)
		if #points == 0 then
			return
		end
		-- Resume the current leg after an interruption; start a fresh one the first time.
		local index = scratch.Index
		if index == nil or index > #points then
			go(agent, scratch)
		else
			scratch.Pausing = false
			agent:MoveTo(points[index])
		end
	end, function(agent: Types.Agent, _deltaTime: number): string?
		local scratch = scratchOf(agent, key)
		if not pathDone(agent) then
			return nil
		end

		if resolved.Pause ~= nil and agent:GetPathStatus() == "Arrived" then
			if not scratch.Pausing then
				scratch.Pausing = true
				agent:StartTimer(timer, pick(randomOf(agent, resolved.Random), resolved.Pause))
				return nil
			end
			if not agent:TimerDone(timer) then
				return nil
			end
		end

		go(agent, scratch)
		return nil
	end)
end

------------------------------------------------------------------------------------------------------------------------

local INVESTIGATE_DEFAULTS = table.freeze({
	Linger = 0,
	Key = "Investigate",
})

local INVESTIGATE_ALLOWED = { "Target", "Then", "Speed", "Acknowledge", "Random", "Transitions", "Enter", "Exit" }

--[=[
	@interface InvestigateOptions
	@within States

	.Target string | Vector3 | (agent: Agent) -> Vector3? -- Where to go: a blackboard or `Data` key such as `"HeardPosition"`, a position, or a function. Read once on entry. Required.
	.Then string? -- The state to enter when there, when the target is missing, or when the path fails. Without it the state waits for a transition.
	.Linger number | { number }? -- Seconds to stand at the spot before `Then`. Default `0`.
	.Acknowledge string? -- A blackboard key to [Agent:Acknowledge] on entry, such as `"HeardAt"`, so the noise that brought the agent here does not count as new again.
	.Speed number? -- Set on entry.
	.Random Random? -- For a ranged `Linger`.
	.Key string? -- Default `"Investigate"`.
	.Transitions { Transition }?
	.Enter ((agent: Agent) -> ())?
	.Exit ((agent: Agent) -> ())?
]=]
export type InvestigateOptions = {
	Target: PositionSource,
	Then: string?,
	Linger: Range?,
	Acknowledge: string?,
	Speed: number?,
	Random: Random?,
	Key: string?,
	Transitions: { Types.Transition }?,
	Enter: ((agent: Types.Agent) -> ())?,
	Exit: ((agent: Types.Agent) -> ())?,
}

--[=[
	@within States
	@param options InvestigateOptions
	@return State

	Goes to one place and, once there (or once the path fails), lingers and moves on to `Then`.
	The place is read on entry, so a newer noise re-enters the state through a transition rather
	than pulling the agent mid-walk.
]=]
function States.Investigate(options: InvestigateOptions): Types.State
	local resolved =
		Options.Resolve("States.Investigate", INVESTIGATE_DEFAULTS, options :: any, INVESTIGATE_ALLOWED) :: any
	if resolved.Target == nil then
		FormatMessage.Error("States.Investigate: Target is required", 2)
	end
	local key: string = resolved.Key
	local timer = `States.{key}`

	return assemble(resolved, function(agent: Types.Agent)
		local scratch = scratchOf(agent, key)
		if resolved.Acknowledge ~= nil then
			agent:Acknowledge(resolved.Acknowledge)
		end
		local target = positionOf(agent, resolved.Target)
		scratch.Target = target
		scratch.Lingering = false
		if target ~= nil then
			agent:MoveTo(target)
		end
	end, function(agent: Types.Agent, _deltaTime: number): string?
		local scratch = scratchOf(agent, key)
		if scratch.Target == nil then
			return resolved.Then
		end
		if not pathDone(agent) then
			return nil
		end

		if not scratch.Lingering then
			scratch.Lingering = true
			agent:StartTimer(timer, pick(randomOf(agent, resolved.Random), resolved.Linger))
		end
		if agent:TimerDone(timer) then
			return resolved.Then
		end
		return nil
	end)
end

------------------------------------------------------------------------------------------------------------------------

local SEARCH_DEFAULTS = table.freeze({
	Radius = 12,
	Points = 3,
	Duration = 15,
	Key = "Search",
})

local SEARCH_ALLOWED = { "Around", "Then", "Speed", "Random", "Transitions", "Enter", "Exit" }

--[=[
	@interface SearchOptions
	@within States

	.Around string | Vector3 | (agent: Agent) -> Vector3? -- The centre: usually `"SeenPosition"` or `"LastKnownPosition"`. Missing means the agent's own position. Read once on entry.
	.Radius number? -- Studs around the centre the points are picked in. Default `12`.
	.Points number? -- How many points to pick. They are walked in turn and cycled until `Duration` runs out. Default `3`.
	.Duration number | { number }? -- Seconds to search before `Then`. Default `15`.
	.Then string? -- The state to enter when time is up. Without it the state searches until a transition.
	.Speed number? -- Set on entry.
	.Random Random? -- Picks the points. Default `agent.Data.Random`, else a new one.
	.Key string? -- Default `"Search"`.
	.Transitions { Transition }?
	.Enter ((agent: Agent) -> ())?
	.Exit ((agent: Agent) -> ())?
]=]
export type SearchOptions = {
	Around: PositionSource?,
	Radius: number?,
	Points: number?,
	Duration: Range?,
	Then: string?,
	Speed: number?,
	Random: Random?,
	Key: string?,
	Transitions: { Types.Transition }?,
	Enter: ((agent: Types.Agent) -> ())?,
	Exit: ((agent: Types.Agent) -> ())?,
}

--[=[
	@within States
	@param options SearchOptions
	@return State

	Picks a few random points around a spot and walks them in turn until `Duration` runs out:
	the "where did they go" after losing sight. A point the navigator cannot reach is skipped.
]=]
function States.Search(options: SearchOptions?): Types.State
	local resolved = Options.Resolve("States.Search", SEARCH_DEFAULTS, options :: any, SEARCH_ALLOWED) :: any
	local key: string = resolved.Key
	local timer = `States.{key}`

	return assemble(resolved, function(agent: Types.Agent)
		local scratch = scratchOf(agent, key)
		local random = randomOf(agent, resolved.Random)
		local centre = positionOf(agent, resolved.Around) or agent:GetPosition()

		local points = table.create(resolved.Points)
		for _ = 1, resolved.Points do
			table.insert(points, States.RandomPoint(random, centre, resolved.Radius))
		end
		scratch.Centre = centre
		scratch.Points = points
		scratch.Index = 1
		agent:StartTimer(timer, pick(random, resolved.Duration))
		if #points > 0 then
			agent:MoveTo(points[1])
		end
	end, function(agent: Types.Agent, _deltaTime: number): string?
		if agent:TimerDone(timer) then
			return resolved.Then
		end

		local scratch = scratchOf(agent, key)
		local points: { Vector3 } = scratch.Points or {}
		if #points == 0 or not pathDone(agent) then
			return nil
		end

		local index = (scratch.Index or 0) % #points + 1
		scratch.Index = index
		agent:MoveTo(points[index])
		return nil
	end)
end

------------------------------------------------------------------------------------------------------------------------

local WANDER_DEFAULTS = table.freeze({
	Radius = 20,
	Pause = { 1, 3 } :: Range,
	Key = "Wander",
})

local WANDER_ALLOWED = { "Home", "Speed", "Random", "Transitions", "Enter", "Exit" }

--[=[
	@interface WanderOptions
	@within States

	.Home string | Vector3 | (agent: Agent) -> Vector3? -- The centre to stay around: a key, a position, or a function. Missing means where the agent stood when it first entered the state, kept from then on.
	.Radius number? -- Studs around home the points are picked in. Default `20`.
	.Pause number | { number }? -- Seconds to stand at each point. Default `{ 1, 3 }`.
	.Speed number? -- Set on entry.
	.Random Random? -- Picks the points and the pauses.
	.Key string? -- Default `"Wander"`.
	.Transitions { Transition }?
	.Enter ((agent: Agent) -> ())?
	.Exit ((agent: Agent) -> ())?
]=]
export type WanderOptions = {
	Home: PositionSource?,
	Radius: number?,
	Pause: Range?,
	Speed: number?,
	Random: Random?,
	Key: string?,
	Transitions: { Types.Transition }?,
	Enter: ((agent: Types.Agent) -> ())?,
	Exit: ((agent: Types.Agent) -> ())?,
}

--[=[
	@within States
	@param options WanderOptions?
	@return State

	Drifts between random points around home, pausing at each. The Guardian's idle, as a line.
]=]
function States.Wander(options: WanderOptions?): Types.State
	local resolved = Options.Resolve("States.Wander", WANDER_DEFAULTS, options :: any, WANDER_ALLOWED) :: any
	local key: string = resolved.Key
	local timer = `States.{key}`

	local function go(agent: Types.Agent, scratch: { [string]: any })
		local random = randomOf(agent, resolved.Random)
		scratch.Pausing = false
		agent:MoveTo(States.RandomPoint(random, scratch.Home, resolved.Radius))
	end

	return assemble(resolved, function(agent: Types.Agent)
		local scratch = scratchOf(agent, key)
		local home = positionOf(agent, resolved.Home)
		if home ~= nil then
			scratch.Home = home
		elseif scratch.Home == nil then
			scratch.Home = agent:GetPosition()
		end
		go(agent, scratch)
	end, function(agent: Types.Agent, _deltaTime: number): string?
		local scratch = scratchOf(agent, key)
		if not pathDone(agent) then
			return nil
		end

		if agent:GetPathStatus() == "Arrived" then
			if not scratch.Pausing then
				scratch.Pausing = true
				agent:StartTimer(timer, pick(randomOf(agent, resolved.Random), resolved.Pause))
				return nil
			end
			if not agent:TimerDone(timer) then
				return nil
			end
		end

		go(agent, scratch)
		return nil
	end)
end

------------------------------------------------------------------------------------------------------------------------

local ROAM_DEFAULTS = table.freeze({
	Range = 120,
	Linger = 1,
	Key = "Roam",
})

local ROAM_ALLOWED =
	{ "Interest", "Tags", "Duration", "Then", "Speed", "Random", "Considerations", "Transitions", "Enter", "Exit" }

--[=[
	@interface RoamOptions
	@within States

	.Interest Interest -- The map of points to roam. Required.
	.Range number? -- Studs beyond which a point scores nothing for distance. Default `120`.
	.Tags { string }? -- Only points with one of these tags.
	.Linger number | { number }? -- Seconds to stand at each point before moving on. Default `1`.
	.Duration number | { number }? -- Seconds to roam before `Then`. Without it, roams until a transition or until no point scores.
	.Then string? -- The state to enter when time is up or no point is worth a look.
	.Considerations { Consideration<InterestPoint> }? -- Extra scoring for [Interest.Best].
	.Speed number? -- Set on entry.
	.Random Random? -- For ranged `Linger` and `Duration`.
	.Key string? -- Default `"Roam"`.
	.Transitions { Transition }?
	.Enter ((agent: Agent) -> ())?
	.Exit ((agent: Agent) -> ())?
]=]
export type RoamOptions = {
	Interest: any,
	Range: number?,
	Tags: { string }?,
	Linger: Range?,
	Duration: Range?,
	Then: string?,
	Considerations: { any }?,
	Speed: number?,
	Random: Random?,
	Key: string?,
	Transitions: { Types.Transition }?,
	Enter: ((agent: Types.Agent) -> ())?,
	Exit: ((agent: Types.Agent) -> ())?,
}

--[=[
	@within States
	@param options RoamOptions
	@return State

	Asks the [Interest] map for the best point, walks there, lingers, marks it visited, and asks
	again. Points the agent just visited score nothing, so it spreads its search. When no point
	scores, or `Duration` runs out, it enters `Then`.
]=]
function States.Roam(options: RoamOptions): Types.State
	local resolved = Options.Resolve("States.Roam", ROAM_DEFAULTS, options :: any, ROAM_ALLOWED) :: any
	local interest = resolved.Interest
	if type(interest) ~= "table" or type(interest.Best) ~= "function" then
		FormatMessage.Error("States.Roam: Interest must be an Interest map", 2)
	end
	local key: string = resolved.Key
	local timer = `States.{key}`
	local lingerTimer = `States.{key}.Linger`

	local function next(agent: Types.Agent, scratch: { [string]: any }): boolean
		local point = interest:Best(agent, {
			Range = resolved.Range,
			Tags = resolved.Tags,
			Exclude = if scratch.Current ~= nil then { scratch.Current } else nil,
			Considerations = resolved.Considerations,
		})
		if point == nil then
			scratch.Current = nil
			return false
		end
		scratch.Current = point.Id
		scratch.Lingering = false
		agent:MoveTo(point.Position)
		return true
	end

	return assemble(resolved, function(agent: Types.Agent)
		local scratch = scratchOf(agent, key)
		scratch.Exhausted = false
		if resolved.Duration ~= nil then
			agent:StartTimer(timer, pick(randomOf(agent, resolved.Random), resolved.Duration))
		else
			agent:StartTimer(timer, math.huge)
		end
		scratch.Exhausted = not next(agent, scratch)
	end, function(agent: Types.Agent, _deltaTime: number): string?
		local scratch = scratchOf(agent, key)
		if scratch.Exhausted or agent:TimerDone(timer) then
			return resolved.Then
		end
		if not pathDone(agent) then
			return nil
		end

		if not scratch.Lingering then
			scratch.Lingering = true
			if scratch.Current ~= nil then
				interest:Visit(agent, scratch.Current)
			end
			agent:StartTimer(lingerTimer, pick(randomOf(agent, resolved.Random), resolved.Linger))
			return nil
		end
		if not agent:TimerDone(lingerTimer) then
			return nil
		end

		if not next(agent, scratch) then
			scratch.Exhausted = true
			return resolved.Then
		end
		return nil
	end)
end

------------------------------------------------------------------------------------------------------------------------

local WAIT_DEFAULTS = table.freeze({
	Key = "Wait",
})

local WAIT_ALLOWED = { "Duration", "Then", "Speed", "Random", "Transitions", "Enter", "Exit" }

--[=[
	@interface WaitOptions
	@within States

	.Duration number | { number }? -- Seconds to stand still before `Then`. Without it the state waits for a transition.
	.Then string? -- The state to enter when the time is up.
	.Speed number? -- Set on entry.
	.Random Random? -- For a ranged `Duration`.
	.Key string? -- Default `"Wait"`.
	.Transitions { Transition }?
	.Enter ((agent: Agent) -> ())?
	.Exit ((agent: Agent) -> ())?
]=]
export type WaitOptions = {
	Duration: Range?,
	Then: string?,
	Speed: number?,
	Random: Random?,
	Key: string?,
	Transitions: { Types.Transition }?,
	Enter: ((agent: Types.Agent) -> ())?,
	Exit: ((agent: Types.Agent) -> ())?,
}

--[=[
	@within States
	@param options WaitOptions?
	@return State

	Stops and stands still: dormant, stunned, listening. With `Duration` and `Then` it moves on by
	itself; otherwise its transitions decide.
]=]
function States.Wait(options: WaitOptions?): Types.State
	local resolved = Options.Resolve("States.Wait", WAIT_DEFAULTS, options :: any, WAIT_ALLOWED) :: any
	local key: string = resolved.Key
	local timer = `States.{key}`

	return assemble(resolved, function(agent: Types.Agent)
		agent:Stop()
		if resolved.Duration ~= nil then
			agent:StartTimer(timer, pick(randomOf(agent, resolved.Random), resolved.Duration))
		end
	end, function(agent: Types.Agent, _deltaTime: number): string?
		if resolved.Duration ~= nil and resolved.Then ~= nil and agent:TimerDone(timer) then
			return resolved.Then
		end
		return nil
	end)
end

return States
