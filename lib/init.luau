--!strict

--[[
	The public surface. Everything a game touches is reachable from here; nothing in this file
	does work at require time, so requiring the package on a client is harmless.
]]

local Agent = require(script.Agent)
local Animator = require(script.Animator)
local Builder = require(script.Builder)
local Director = require(script.Director)
local Footsteps = require(script.Animator.Footsteps)
local Interest = require(script.Interest)
local Locomotion = require(script.Animator.Locomotion)
local Navigator = require(script.Navigator)
local Types = require(script.Types)

local Runner = require(script.Brain.Runner)
local States = require(script.Brain.States)
local Utility = require(script.Brain.Utility)
local Validate = require(script.Brain.Validate)
local When = require(script.Brain.When)

local Attack = require(script.Combat.Attack)
local Kill = require(script.Combat.Kill)

local PathVisual = require(script.Debug.PathVisual)
local Rig = require(script.Debug.Rig)
local SenseVisual = require(script.Debug.SenseVisual)
local StateLabel = require(script.Debug.StateLabel)

local CFrameMover = require(script.Movers.CFrameMover)
local HumanoidMover = require(script.Movers.Humanoid)

local Graph = require(script.Pathfinders.Graph)
local Hybrid = require(script.Pathfinders.Hybrid)
local Ladder = require(script.Pathfinders.Ladder)
local Navmesh = require(script.Pathfinders.Navmesh)
local Straight = require(script.Pathfinders.Straight)

local Awareness = require(script.Senses.Awareness)
local Hearing = require(script.Senses.Hearing)
local Neighbours = require(script.Senses.Neighbours)
local Perception = require(script.Senses.Perception)
local Proximity = require(script.Senses.Proximity)
local Sight = require(script.Senses.Sight)
local Sounds = require(script.Senses.Sounds)
local Surroundings = require(script.Senses.Surroundings)
local Throttle = require(script.Senses.Throttle)
local Watched = require(script.Senses.Watched)

local Broadcaster = require(script.Sync.Broadcaster)
local Look = require(script.Sync.Look)
local Replica = require(script.Sync.Replica)

local Claims = require(script.Utility.Claims)
local Cleaner = require(script.Utility.Cleaner)
local FormatMessage = require(script.Utility.FormatMessage)
local Signal = require(script.Utility.Signal)
local Tables = require(script.Utility.Tables)

------------------------------------------------------------------------------------------------------------------------

export type Agent = Types.Agent
export type AgentDefinition = Types.AgentDefinition
export type Blackboard = Types.Blackboard
export type Brain = Types.Brain
export type State = Types.State
export type Transition = Types.Transition
export type Interrupt = Types.Interrupt

export type Pathfinder = Types.Pathfinder
export type Mover = Types.Mover
export type Sense = Types.Sense
export type Navigator = Types.Navigator
export type NavigationOptions = Types.NavigationOptions
export type PathStatus = Types.PathStatus

export type Path = Types.Path
export type Step = Types.Step
export type StepAction = Types.StepAction

export type Signal<T...> = Types.Signal<T...>
export type Connection = Types.Connection
export type Cleaner = Cleaner.Cleaner

export type Curve = Types.Curve
export type Consideration<T> = Types.Consideration<T>
export type Scored<T> = Types.Scored<T>

export type ClientState = Types.ClientState
export type Visuals = Types.Visuals
export type Snapshot = Types.Snapshot
export type KillKind = Types.KillKind
export type KillEvent = Types.KillEvent

export type Builder = Builder.Builder
export type Animator = Animator.NPCAnimator
export type AnimationInfo = Animator.AnimationInfo
export type Broadcaster = Broadcaster.Broadcaster
export type Replica = Replica.Replica
export type KillHandle = Kill.KillHandle
export type GraphNode = Graph.GraphNode
export type GraphLink = Graph.GraphLink
export type StepHandler = Types.StepHandler
export type Director = Director.Director
export type Interest = Interest.Interest
export type InterestPoint = Interest.InterestPoint
export type HealthProvider = Types.HealthProvider
export type Claims = Claims.Claims
export type LookReceiver = Look.LookReceiver

------------------------------------------------------------------------------------------------------------------------

--[=[
	@class VluxyAI

	Simple, composable AI for Roblox. An AI is a **brain** (a table of states), a **pathfinder**
	(plans), a **mover** (executes) and some **senses** (write a blackboard), stacked with the
	builder into an **agent**.

	```lua
	local VluxyAI = require(ReplicatedStorage.Packages.VluxyAI)

	local agent = VluxyAI.new(model)
		:UseBrain(Stalker)
		:UsePathfinder(VluxyAI.Pathfinders.Navmesh.new({ AgentRadius = 2 }))
		:UseMover(VluxyAI.Movers.Humanoid.new(model))
		:AddSense(VluxyAI.Senses.Sight.new({ Range = 40 }))
		:Build()
		:Start()
	```

	Every part is a contract in [Types]; pass your own module in to extend the package.
]=]
local VluxyAI = {}

--[=[
	@within VluxyAI
	@function new
	@param entity Model
	@return Builder

	Starts a [Builder] for `entity`.
]=]
VluxyAI.new = Builder.new

--[=[
	@within VluxyAI
	@function NewAgent
	@param definition AgentDefinition
	@return Agent
	@error string -- The definition failed validation; the message names the field.

	Builds an [Agent] straight from a definition table, for code that assembles definitions
	itself rather than through the [Builder].
]=]
VluxyAI.NewAgent = Agent.new

--[=[
	@within VluxyAI
	@function Validate
	@param definition AgentDefinition
	@error string -- The path and problem of the first bad field.

	Checks a definition without building it. See [Validate].
]=]
VluxyAI.Validate = Validate.Definition

--[=[
	@within VluxyAI
	@function ValidateBrain
	@param brain Brain
	@param path string? -- Prefix for messages.
	@error string

	Checks a brain table on its own. See [Validate.Brain].
]=]
VluxyAI.ValidateBrain = Validate.Brain

--[=[
	@within VluxyAI
	@prop Utility Utility

	Utility scoring: [Utility.Best], [Utility.Weighted], [Utility.Curves].
]=]
VluxyAI.Utility = Utility

--[=[
	@within VluxyAI
	@prop When When

	Ready-made `When` predicates for transitions and interrupts: [When.Has], [When.New],
	[When.Below], [When.PathDone], [When.Timer] and the rest.
]=]
VluxyAI.When = When

--[=[
	@within VluxyAI
	@prop States States

	Ready-made states: [States.Patrol], [States.Investigate], [States.Search], [States.Wander]
	and [States.Wait].
]=]
VluxyAI.States = States

--[=[
	@within VluxyAI
	@prop Cleaner Cleaner

	The package's cleanup bag, for anything you build around an agent.
]=]
VluxyAI.Cleaner = Cleaner

--[=[
	@within VluxyAI
	@prop Signal Signal

	The package's [Signal]; make one for a [Hearing] noise source.
]=]
VluxyAI.Signal = Signal

--[=[
	@within VluxyAI
	@prop Pathfinders { Navmesh: Navmesh, Straight: Straight, Ladder: Ladder, Graph: Graph, Hybrid: Hybrid }

	The built-in [Types.Pathfinder]s: [Navmesh] for geometry, [Straight] for a clear line,
	[Ladder] to try several in order, [Graph] for A* over authored nodes, and [Hybrid] to
	compose a graph with a local pathfinder.
]=]
VluxyAI.Pathfinders = {
	Navmesh = Navmesh,
	Straight = Straight,
	Ladder = Ladder,
	Graph = Graph,
	Hybrid = Hybrid,
}

--[=[
	@within VluxyAI
	@prop Movers { Humanoid: HumanoidMover, CFrame: CFrameMover }

	The built-in [Types.Mover]s.
]=]
VluxyAI.Movers = {
	Humanoid = HumanoidMover,
	CFrame = CFrameMover,
}

--[=[
	@within VluxyAI
	@prop Senses { Sight: Sight, Proximity: Proximity, Hearing: Hearing, Sounds: Sounds, Awareness: Awareness, Watched: Watched, Surroundings: Surroundings, Neighbours: Neighbours, Throttle: Throttle }

	The built-in [Types.Sense]s. [Hearing] is for noises your code fires; [Sounds] is for the
	tagged `Sound` instances the world is already playing; [Awareness] turns what the others
	wrote into a detection meter; [Neighbours] is the group sense, so enemies sharing a map
	know about each other and, when asked, keep out of each other's way.
]=]
VluxyAI.Senses = {
	Sight = Sight,
	Proximity = Proximity,
	Hearing = Hearing,
	Sounds = Sounds,
	Awareness = Awareness,
	Watched = Watched,
	Surroundings = Surroundings,
	Neighbours = Neighbours,
	Throttle = Throttle,
}

--[=[
	@within VluxyAI
	@prop Director Director

	Pacing and shared knowledge for a group of enemies: a tension meter, a difficulty knob and a
	shared blackboard, read through `director:Sense()`.
]=]
VluxyAI.Director = Director

--[=[
	@within VluxyAI
	@prop Interest Interest

	Points of interest with a strength each, and `Best` to pick where an enemy looks next.
	[States.Roam] walks one.
]=]
VluxyAI.Interest = Interest

--[=[
	@within VluxyAI
	@prop Claims Claims

	A shared "who is on what" table, so two enemies never chase the same player unless you say so.
]=]
VluxyAI.Claims = Claims

--[=[
	@within VluxyAI
	@prop Tables Tables

	The package's small table helpers, including [Tables.Prefixed].
]=]
VluxyAI.Tables = Tables

--[=[
	@within VluxyAI
	@prop Perception Perception

	The helpers the built-in senses are made of: alive player roots, cones, line of sight, and
	`HumanoidOf` for a state that acts on a target. The place to start for a custom sense.
]=]
VluxyAI.Perception = Perception

--[=[
	@within VluxyAI
	@prop Animator NPCAnimator

	The NPC animation helper.
]=]
VluxyAI.Animator = Animator

--[=[
	@within VluxyAI
	@prop Locomotion Locomotion

	Idle and walk for a rig from its real speed, plus one-shots by name, through the animator.
]=]
VluxyAI.Locomotion = Locomotion

--[=[
	@within VluxyAI
	@prop Footsteps Footsteps

	Footstep audio from measured movement, for the client's replica rigs (or a server rig).
]=]
VluxyAI.Footsteps = Footsteps

--[=[
	@within VluxyAI
	@prop Sync { Broadcaster: Broadcaster, Replica: Replica, Look: Look }

	Client-side presentation: a [Broadcaster] watches an agent on the server, a [Replica] drives
	a rig and your client states on the client. The game owns the remotes between them.
]=]
VluxyAI.Sync = {
	Broadcaster = Broadcaster,
	Replica = Replica,
	Look = Look,
}

--[=[
	@within VluxyAI
	@prop Combat { Kill: Kill }

	[Attack.State], the one generic state, and [Kill.Live] and [Kill.BlackBox], the two ways an
	agent kills a character.
]=]
VluxyAI.Combat = {
	Attack = Attack,
	Kill = Kill,
}

--[=[
	@within VluxyAI
	@prop Debug { PathVisual: PathVisual, StateLabel: StateLabel, SenseVisual: SenseVisual, Rig: Rig }

	Opt-in debug views, and a runtime R15 rig for tests and playgrounds.
]=]
VluxyAI.Debug = {
	PathVisual = PathVisual,
	StateLabel = StateLabel,
	SenseVisual = SenseVisual,
	Rig = Rig,
}

--[=[
	@within VluxyAI
	@prop Internals { Runner: Runner, Navigator: Navigator }

	The pieces the [Agent] is made of, for a custom scheduler or a client renderer that wants to
	run a brain table itself.
]=]
VluxyAI.Internals = {
	Runner = Runner,
	Navigator = Navigator,
}

--[=[
	@interface HumanoidPresetOptions
	@within VluxyAI

	.Navmesh NavmeshOptions? -- Options for [Navmesh.new].
	.Straight StraightOptions? -- Options for [Straight.new], the first rung of the ladder.
	.Mover HumanoidOptions? -- Options for [HumanoidMover.new].
	.Sight SightOptions? -- Options for [Sight.new].
	.Proximity ProximityOptions? -- Options for [Proximity.new].
	.Navigation NavigationOptions? -- Navigator tuning. Default `{ RepathInterval = 0.25 }`.
]=]
export type HumanoidPresetOptions = {
	Navmesh: Navmesh.Options?,
	Straight: Straight.Options?,
	Mover: HumanoidMover.HumanoidOptions?,
	Sight: Sight.SightOptions?,
	Proximity: Proximity.ProximityOptions?,
	Navigation: Types.NavigationOptions?,
}

local PRESET_KEYS = { "Navmesh", "Straight", "Mover", "Sight", "Proximity", "Navigation" }

--[=[
	@within VluxyAI
	@prop Presets { Humanoid: (model: Model, options: HumanoidPresetOptions?) -> Builder }

	Ready-made stacks. `Presets.Humanoid(model)` returns a [Builder] already carrying a
	[Ladder] of [Straight] then [Navmesh] (a target in plain sight costs no navmesh query), a
	[HumanoidMover] mover, [Sight] and [Proximity] senses, and a quarter-second repath; add a
	brain and build. It is what the examples build by hand, opt-in and overridable.
]=]
VluxyAI.Presets = {
	Humanoid = function(model: Model, options: HumanoidPresetOptions?): Builder.Builder
		local resolved: HumanoidPresetOptions = options or {}
		for key in resolved :: any do
			if table.find(PRESET_KEYS, key) == nil then
				FormatMessage.Error(
					`Presets.Humanoid: unknown option "{tostring(key)}"; expected one of {table.concat(
						PRESET_KEYS,
						", "
					)}`,
					2
				)
			end
		end

		return Builder.new(model)
			:UsePathfinder(Ladder.new({
				Straight.new(resolved.Straight),
				Navmesh.new(resolved.Navmesh),
			}))
			:UseMover(HumanoidMover.new(model, resolved.Mover))
			:AddSense(Sight.new(resolved.Sight))
			:AddSense(Proximity.new(resolved.Proximity))
			:SetNavigation(resolved.Navigation or { RepathInterval = 0.25 })
	end,
}

return VluxyAI
