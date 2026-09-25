--!strict

--[[
	The public surface. Everything a game touches is reachable from here; nothing in this file
	does work at require time, so requiring the package on a client is harmless.
]]

local Agent = require(script.Agent)
local Animator = require(script.Animator)
local Builder = require(script.Builder)
local Navigator = require(script.Navigator)
local Types = require(script.Types)

local Runner = require(script.Brain.Runner)
local Utility = require(script.Brain.Utility)
local Validate = require(script.Brain.Validate)

local PathVisual = require(script.Debug.PathVisual)
local StateLabel = require(script.Debug.StateLabel)

local CFrameMover = require(script.Movers.CFrameMover)
local HumanoidMover = require(script.Movers.Humanoid)

local Ladder = require(script.Pathfinders.Ladder)
local Navmesh = require(script.Pathfinders.Navmesh)
local Straight = require(script.Pathfinders.Straight)

local Hearing = require(script.Senses.Hearing)
local Perception = require(script.Senses.Perception)
local Proximity = require(script.Senses.Proximity)
local Sight = require(script.Senses.Sight)
local Watched = require(script.Senses.Watched)

local Signal = require(script.Utility.Signal)

------------------------------------------------------------------------------------------------------------------------

export type Agent = Types.Agent
export type AgentDefinition = Types.AgentDefinition
export type Blackboard = Types.Blackboard
export type Brain = Types.Brain
export type State = Types.State
export type Transition = Types.Transition

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

export type Curve = Types.Curve
export type Consideration<T> = Types.Consideration<T>
export type Scored<T> = Types.Scored<T>

export type Builder = Builder.Builder
export type Animator = Animator.NPCAnimator
export type AnimationInfo = Animator.AnimationInfo

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
	@prop Signal Signal

	The package's [Signal]; make one for a [Hearing] noise source.
]=]
VluxyAI.Signal = Signal

--[=[
	@within VluxyAI
	@prop Pathfinders { Navmesh: Navmesh, Straight: Straight, Ladder: Ladder }

	The built-in [Types.Pathfinder]s.
]=]
VluxyAI.Pathfinders = {
	Navmesh = Navmesh,
	Straight = Straight,
	Ladder = Ladder,
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
	@prop Senses { Sight: Sight, Proximity: Proximity, Hearing: Hearing, Watched: Watched }

	The built-in [Types.Sense]s.
]=]
VluxyAI.Senses = {
	Sight = Sight,
	Proximity = Proximity,
	Hearing = Hearing,
	Watched = Watched,
}

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
	@prop Debug { PathVisual: PathVisual, StateLabel: StateLabel }

	Opt-in debug views.
]=]
VluxyAI.Debug = {
	PathVisual = PathVisual,
	StateLabel = StateLabel,
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

	.Navmesh table? -- Options for [Navmesh.new].
	.Mover table? -- Options for [Humanoid.new].
	.Sight table? -- Options for [Sight.new].
	.Proximity table? -- Options for [Proximity.new].
]=]
export type HumanoidPresetOptions = {
	Navmesh: any?,
	Mover: any?,
	Sight: any?,
	Proximity: any?,
}

--[=[
	@within VluxyAI
	@prop Presets { Humanoid: (model: Model, options: HumanoidPresetOptions?) -> Builder }

	Ready-made stacks. `Presets.Humanoid(model)` returns a [Builder] already carrying a
	[Navmesh] pathfinder, a [Humanoid] mover, and [Sight] and [Proximity] senses; add a brain
	and build. It is the 0.1 "standard" agent, but opt-in and overridable.
]=]
VluxyAI.Presets = {
	Humanoid = function(model: Model, options: HumanoidPresetOptions?): Builder.Builder
		local resolved: HumanoidPresetOptions = options or {}

		return Builder.new(model)
			:UsePathfinder(Navmesh.new(resolved.Navmesh))
			:UseMover(HumanoidMover.new(model, resolved.Mover))
			:AddSense(Sight.new(resolved.Sight))
			:AddSense(Proximity.new(resolved.Proximity))
	end,
}

return VluxyAI
