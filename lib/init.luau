--!strict

--[[
	The public surface. Everything a game touches is reachable from here; nothing in this file
	does work at require time, so requiring the package on a client is harmless.
]]

local Agent = require(script.Agent)
local Animator = require(script.Animator)
local Builder = require(script.Builder)
local Collision = require(script.World.Collision)
local Director = require(script.Group.Director)
local Doors = require(script.World.Doors)
local Footsteps = require(script.Animator.Footsteps)
local Interest = require(script.Group.Interest)
local Locomotion = require(script.Animator.Locomotion)
local Navigator = require(script.Navigator)
local PlayerNoise = require(script.World.PlayerNoise)
local SafeAreas = require(script.World.SafeAreas)
local Types = require(script.Types)
local Voice = require(script.Animator.Voice)

local Runner = require(script.Brain.Runner)
local States = require(script.Brain.States)
local Utility = require(script.Brain.Utility)
local Validate = require(script.Brain.Validate)
local When = require(script.Brain.When)

local Attack = require(script.Combat.Attack)
local Kill = require(script.Combat.Kill)

local GraphVisual = require(script.Debug.GraphVisual)
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
local Clues = require(script.Senses.Clues)
local Hearing = require(script.Senses.Hearing)
local Hideout = require(script.Senses.Hideout)
local Neighbours = require(script.Senses.Neighbours)
local Perception = require(script.Senses.Perception)
local Proximity = require(script.Senses.Proximity)
local SafeWatch = require(script.Senses.SafeWatch)
local Sight = require(script.Senses.Sight)
local Sounds = require(script.Senses.Sounds)
local Stamina = require(script.Senses.Stamina)
local Surroundings = require(script.Senses.Surroundings)
local Throttle = require(script.Senses.Throttle)
local Watched = require(script.Senses.Watched)

local Broadcaster = require(script.Sync.Broadcaster)
local Look = require(script.Sync.Look)
local Replica = require(script.Sync.Replica)

local Claims = require(script.Group.Claims)
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
export type NoiseSignal = Types.NoiseSignal
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
export type StepRegistration = Types.StepRegistration
export type DoorDriver = Types.DoorDriver
export type DoorStepOptions = Doors.DoorStepOptions
export type DoorOpenerOptions = Doors.DoorOpenerOptions
export type SafeAreaSetupOptions = SafeAreas.SafeAreaSetupOptions
export type NoiseBand = PlayerNoise.NoiseBand
export type VoiceOptions = Voice.VoiceOptions
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
	@prop Senses { Sight: Sight, Proximity: Proximity, Hearing: Hearing, Sounds: Sounds, Awareness: Awareness, Watched: Watched, Surroundings: Surroundings, Neighbours: Neighbours, Throttle: Throttle, SafeWatch: SafeWatch, Clues: Clues, Hideout: Hideout, Stamina: Stamina }

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
	SafeWatch = SafeWatch,
	Clues = Clues,
	Hideout = Hideout,
	Stamina = Stamina,
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
	@prop Doors Doors

	Doors agents open: `:OnStep("Door", VluxyAI.Doors.Step())` over your door script, through
	attributes or a driver of your own.
]=]
VluxyAI.Doors = Doors

--[=[
	@within VluxyAI
	@prop SafeAreas SafeAreas

	Parts tagged `VLUXYAI_SAFE` that agents never enter while `VLUXYAI_SAFE/Enabled` is not `false`. Call
	`VluxyAI.SafeAreas.Setup()` once on the server.
]=]
VluxyAI.SafeAreas = SafeAreas

--[=[
	@within VluxyAI
	@prop Collision Collision

	The rig collision group, and parts agents walk through while players still collide with them.
]=]
VluxyAI.Collision = Collision

--[=[
	@within VluxyAI
	@prop PlayerNoise PlayerNoise

	Players make noise by moving: speed bands turned into noises on your Hearing signal.
]=]
VluxyAI.PlayerNoise = PlayerNoise

--[=[
	@within VluxyAI
	@prop Voice Voice

	Random voice lines by state, added as a sense: `:AddSense(VluxyAI.Voice.new({ Lines = ... }))`.
]=]
VluxyAI.Voice = Voice

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
	@prop Debug { PathVisual: PathVisual, GraphVisual: GraphVisual, StateLabel: StateLabel, SenseVisual: SenseVisual, Rig: Rig }

	Opt-in debug views, and a runtime R15 rig for tests and playgrounds.
]=]
VluxyAI.Debug = {
	PathVisual = PathVisual,
	GraphVisual = GraphVisual,
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
	.Straight StraightOptions? -- Options for [Straight.new], the direct walker.
	.Mover HumanoidOptions? -- Options for [HumanoidMover.new].
	.Sight SightOptions? -- Options for [Sight.new].
	.Proximity ProximityOptions? -- Options for [Proximity.new].
	.Navigation NavigationOptions? -- Navigator tuning. Default `{ RepathInterval = 0.25, MaxPathAge = 2 }`.
	.Graph Pathfinder? -- Authored nodes ([Graph]): routes go over the graph first ([Hybrid] with `Prefer = "Graph"`, `RefineEnds = false`) and the navmesh answers only where the graph has no way. Without it, the navmesh plans everything.
	.Doors boolean? -- Walk through doors: [Doors.Step] with `WalkThrough` for `"Door"` steps, a [Doors.Opener] sense, and a direct walker that sees past unlocked doors. For doors rigs do not collide with ([Collision.LetRigsThrough]). Default `false`.
	.SafeWatch boolean? -- Add [SafeWatch], so the agent notices players in safe areas and is moved out of one that switches on around it (to a `Graph` node when given). Default `true`.
]=]
export type HumanoidPresetOptions = {
	Navmesh: Navmesh.Options?,
	Straight: Straight.Options?,
	Mover: HumanoidMover.HumanoidOptions?,
	Sight: Sight.SightOptions?,
	Proximity: Proximity.ProximityOptions?,
	Navigation: Types.NavigationOptions?,
	Graph: Types.Pathfinder?,
	Doors: boolean?,
	SafeWatch: boolean?,
}

local PRESET_KEYS =
	{ "Navmesh", "Straight", "Mover", "Sight", "Proximity", "Navigation", "Graph", "Doors", "SafeWatch" }

--[=[
	@interface PuppetPresetOptions
	@within VluxyAI

	.Navmesh NavmeshOptions? -- Options for [Navmesh.new]: `AgentRadius`, `AgentHeight` and the rest.
	.Mover CFrameMoverOptions? -- Options for [CFrameMover.new]: `Speed`, `TurnSpeed`, `HeightOffset`. `HeightOffset` defaults to `0` here, so the anchor's pivot is the floor point.
	.Navigation NavigationOptions? -- Navigator tuning. Default `{ RepathInterval = 0.25, MaxPathAge = 2 }`.
]=]
export type PuppetPresetOptions = {
	Navmesh: Navmesh.Options?,
	Mover: CFrameMover.CFrameMoverOptions?,
	Navigation: Types.NavigationOptions?,
}

local PUPPET_PRESET_KEYS = { "Navmesh", "Mover", "Navigation" }

--[[
	Errors on a key a preset does not take, naming the ones it does.
]]
local function checkPresetKeys(preset: string, given: { [any]: any }, keys: { string })
	for key in given do
		if table.find(keys, key) == nil then
			FormatMessage.Error(
				`Presets.{preset}: unknown option "{tostring(key)}"; expected one of {table.concat(keys, ", ")}`,
				3
			)
		end
	end
end

--[[
	The Model a puppet's anchor needs to be an agent: a Model as it is, or a Part wrapped in a new
	Model in its place, as its PrimaryPart, made invisible and inert.
]]
local function puppetModel(anchor: Model | BasePart): Model
	if anchor:IsA("Model") then
		return anchor
	end
	if not anchor:IsA("BasePart") then
		FormatMessage.Error(`Presets.Puppet: the anchor must be a Model or a BasePart, got {anchor.ClassName}`, 3)
	end
	local part = anchor :: BasePart
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1

	local model = Instance.new("Model")
	model.Name = part.Name
	local parent = part.Parent
	part.Parent = model
	model.PrimaryPart = part
	model.Parent = parent
	return model
end

--[=[
	@within VluxyAI
	@prop Presets { Humanoid: (model: Model, options: HumanoidPresetOptions?) -> Builder, Puppet: (anchor: Model | BasePart, options: PuppetPresetOptions?) -> Builder }

	Ready-made stacks. `Presets.Humanoid(model)` returns a [Builder] already carrying a
	[Navmesh] pathfinder (graph-first [Hybrid] when `Graph` is given) with [Straight] as its
	direct walker, a [HumanoidMover] mover, [Sight], [Proximity] and [SafeWatch] senses, and a
	quarter-second repath; `Doors = true` adds walking through doors. Add a brain, any senses of
	your own, and build. It is the stack the examples build by hand, opt-in and overridable.

	```lua
	local agent = VluxyAI.Presets.Humanoid(rig, { Graph = graph, Doors = true })
		:UseBrain(Brain)
		:AddSense(VluxyAI.Senses.Clues.new(interest))
		:Build()
	```

	`Presets.Puppet(anchor)` is the server half of puppet mode, for an enemy with no visible body
	on the server: a [Navmesh] pathfinder and a [CFrameMover] on the anchor (`HeightOffset` `0`, so
	its pivot is the floor point) with the same repath. A Part anchor is wrapped in a Model of its
	own and made invisible, anchored and inert. It adds no senses; stream it with a [Broadcaster]
	once built, and draw it on the client with a puppet [Replica].

	```lua
	local agent = VluxyAI.Presets.Puppet(anchorPart, {
		Navmesh = { AgentRadius = 4, AgentHeight = 12 },
		Mover = { Speed = 10, TurnSpeed = 6 },
	})
		:UseBrain(Brain)
		:AddSense(VluxyAI.Senses.Hearing.new(noises))
		:Build()
	local broadcaster = VluxyAI.Sync.Broadcaster.new(agent, { PositionRate = 10 })
	```
]=]
VluxyAI.Presets = {
	Humanoid = function(model: Model, options: HumanoidPresetOptions?): Builder.Builder
		local resolved: HumanoidPresetOptions = options or {}
		checkPresetKeys("Humanoid", resolved :: any, PRESET_KEYS)

		local graph = resolved.Graph
		local navmesh = Navmesh.new(resolved.Navmesh)
		local pathfinder = if graph
			then Hybrid.new({ Graph = graph, Local = navmesh, Prefer = "Graph", RefineEnds = false })
			else navmesh

		local straightOptions: any = table.clone(resolved.Straight or {})
		if resolved.Doors and straightOptions.Ignore == nil then
			straightOptions.Ignore = Doors.IgnoreUnlocked(Straight.DefaultIgnore)
		end

		local builder = Builder.new(model)
			:UsePathfinder(pathfinder)
			:UseDirect(Straight.new(straightOptions))
			:UseMover(HumanoidMover.new(model, resolved.Mover))
			:AddSense(Sight.new(resolved.Sight))
			:AddSense(Proximity.new(resolved.Proximity))
			:SetNavigation(resolved.Navigation or { RepathInterval = 0.25, MaxPathAge = 2 })

		if resolved.SafeWatch ~= false then
			builder:AddSense(SafeWatch.new({ Spots = graph }))
		end
		if resolved.Doors then
			builder:OnStep("Door", Doors.Step(nil, { WalkThrough = true })):AddSense(Doors.Opener())
		end
		return builder
	end,

	Puppet = function(anchor: Model | BasePart, options: PuppetPresetOptions?): Builder.Builder
		local resolved: PuppetPresetOptions = options or {}
		checkPresetKeys("Puppet", resolved :: any, PUPPET_PRESET_KEYS)

		local model = puppetModel(anchor)
		local moverOptions: any = table.clone(resolved.Mover or {})
		if moverOptions.HeightOffset == nil then
			moverOptions.HeightOffset = 0
		end

		return Builder.new(model)
			:UsePathfinder(Navmesh.new(resolved.Navmesh))
			:UseMover(CFrameMover.new(model, moverOptions))
			:SetNavigation(resolved.Navigation or { RepathInterval = 0.25, MaxPathAge = 2 })
	end,
}

return VluxyAI
