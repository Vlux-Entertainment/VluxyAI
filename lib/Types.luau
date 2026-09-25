--!strict

--[[
	Every contract the package exports, and nothing else. Content modules cast to these types and
	the runtime validator checks the same shapes, so a mistake is caught in the editor first and at
	`Build()` second, with the path of the offending field either way.

	Nothing in this file touches Roblox. The Roblox types it names (`Model`, `Vector3`) are only
	used as annotations.
]]

--[=[
	@class Types

	The contracts VluxyAI is built from. You extend the package by passing in your own module that
	satisfies one of these types; the package never learns your module exists.

	The important ones:

	- [Types.Brain]: a table of states. The part you write for every AI.
	- [Types.Pathfinder]: anything with `FindPath`. Plans, never moves.
	- [Types.Mover]: anything with `Follow` and `Stop`. Moves, never plans.
	- [Types.Sense]: anything with `Tick` that writes to the [Types.Blackboard].
	- [Types.AgentDefinition]: the composition of the above, which `Build()` validates and turns into
	  an [Agent].
]=]
local Types = {}

------------------------------------------------------------------------------------------------------------------------
--SIGNALS---------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------

--[=[
	@interface Connection
	@within Types

	.Connected boolean -- `false` once disconnected.
	.Disconnect (self: Connection) -> () -- Disconnects the handler.

	What [Types.Signal] `Connect` returns. Trove accepts it directly.
]=]
export type Connection = {
	Connected: boolean,
	Disconnect: (self: Connection) -> (),
}

--[=[
	@interface Signal<T...>
	@within Types

	.Connect (self: Signal<T...>, handler: (T...) -> ()) -> Connection -- Runs `handler` on every fire.
	.Once (self: Signal<T...>, handler: (T...) -> ()) -> Connection -- Runs `handler` on the next fire only.
	.Wait (self: Signal<T...>) -> T... -- Yields until the next fire.
	.Fire (self: Signal<T...>, T...) -> () -- Fires every connected handler.
	.DisconnectAll (self: Signal<T...>) -> () -- Drops every handler.
	.Destroy (self: Signal<T...>) -> () -- Drops every handler and refuses new ones.

	A small signal with the same surface as `RBXScriptSignal`, implemented in plain Luau so the
	core runs outside Roblox. Movers and agents expose these; Trove can clean them up.
]=]
export type Signal<T...> = {
	Connect: (self: Signal<T...>, handler: (T...) -> ()) -> Connection,
	Once: (self: Signal<T...>, handler: (T...) -> ()) -> Connection,
	Wait: (self: Signal<T...>) -> T...,
	Fire: (self: Signal<T...>, T...) -> (),
	DisconnectAll: (self: Signal<T...>) -> (),
	Destroy: (self: Signal<T...>) -> (),
}

------------------------------------------------------------------------------------------------------------------------
--PATHS-----------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------

--[=[
	@type StepAction "Walk" | "Jump" | "Custom"
	@within Types

	What a [Types.Mover] does at a step. Mirrors `Enum.PathWaypointAction`. `Custom` steps come
	from `PathfindingModifier` labels or your own pathfinder; the mover walks to them like any other
	step and the [Types.Navigator]'s `StepReached` tells you when it got there, so a door or a ladder
	is your code.
]=]
export type StepAction = "Walk" | "Jump" | "Custom"

--[=[
	@interface Step
	@within Types

	.Position Vector3 -- Where to go, as a floor position. Movers add their own height.
	.Action StepAction -- What to do on the way there.
	.Label string? -- The `PathfindingModifier` label, or whatever your pathfinder attaches.

	One point along a [Types.Path].
]=]
export type Step = {
	Position: Vector3,
	Action: StepAction,
	Label: string?,
}

--[=[
	@type Path { Step }
	@within Types

	An ordered list of steps from where the agent was to where it wants to be. The first step is the
	agent's own position when the pathfinder includes it; movers cope either way.
]=]
export type Path = { Step }

------------------------------------------------------------------------------------------------------------------------
--PATHFINDER------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------

--[=[
	@interface Pathfinder
	@within Types

	.FindPath (self: any, from: Vector3, to: Vector3, agent: Agent) -> (Path?, string?) -- Returns a path, or `nil` and a reason. May yield.
	.Destroy ((self: any) -> ())? -- Optional cleanup. Called when the agent is destroyed.
	.Name string? -- Used in messages, such as a [Ladder]'s joined reasons.

	Plans and nothing else. A pathfinder never moves the agent, never creates parts and never keeps
	a target. `from` and `to` may be at any height: `from` is the mover's root and `to` is often a
	player's root or a floor node; the path it returns holds floor positions. An empty path counts
	as a failure. `FindPath` runs in its own thread and may yield or error; an error is treated as a
	failed plan and warned about once. `VluxyAI.Pathfinders` ships `Navmesh`, `Straight` and
	`Ladder`; your own is any table with `FindPath`.
]=]
export type Pathfinder = {
	FindPath: (self: any, from: Vector3, to: Vector3, agent: Agent) -> (Path?, string?),
	Destroy: ((self: any) -> ())?,
	Name: string?,
}

------------------------------------------------------------------------------------------------------------------------
--MOVER-----------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------

--[=[
	@interface Mover
	@within Types

	.Follow (self: any, path: Path) -> () -- Starts moving along `path`, replacing any current path.
	.Stop (self: any) -> () -- Halts. Fires `Arrived(false)` if a path was in progress.
	.GetPosition (self: any) -> Vector3 -- Where the agent's root or pivot is right now: the body, not the floor.
	.GetSpeed (self: any) -> number -- Studs per second.
	.SetSpeed (self: any, speed: number) -> () -- Studs per second.
	.IsMoving (self: any) -> boolean -- `true` while a path is in progress.
	.StepReached Signal<(number, Step)> -- Fired with the index and step each time one is reached.
	.Arrived Signal<boolean> -- Fired once per `Follow`: `true` at the end of the path, `false` if stopped, replaced or stuck.
	.Destroy ((self: any) -> ())? -- Optional cleanup. Called when the agent is destroyed.

	Executes a [Types.Path] and nothing else. Rules that keep a mover and the [Navigator] honest:

	- `Follow` fires `Arrived(false)` for the path it replaces before starting the new one, and
	  the new path's outcome is reported on a later frame, never from inside `Follow`. An empty
	  path is `Arrived(false)` on the next frame.
	- `Follow` is called from the navigator's planning thread, so it must not yield.
	- `Arrived(true)` means the last step was reached. The navigator then checks the target for
	  itself: within `ArriveDistance` it reports arrival, otherwise it re-plans or reports failure.
	- `Arrived(false)` from a stuck detector makes the navigator re-plan on its cadence.

	`VluxyAI.Movers` ships `Humanoid` (uses `MoveTo`) and `CFrame` (steps a pivot, no rig needed);
	your own is any table with this shape. Make the signals with `VluxyAI.Signal.new()`.
]=]
export type Mover = {
	Follow: (self: any, path: Path) -> (),
	Stop: (self: any) -> (),
	GetPosition: (self: any) -> Vector3,
	GetSpeed: (self: any) -> number,
	SetSpeed: (self: any, speed: number) -> (),
	IsMoving: (self: any) -> boolean,
	StepReached: Signal<(number, Step)>,
	Arrived: Signal<boolean>,
	Destroy: ((self: any) -> ())?,
}

------------------------------------------------------------------------------------------------------------------------
--SENSES----------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------

--[=[
	@type Blackboard { [string]: any }
	@within Types

	The only thing states read about the world. Senses write to it every tick; states and utility
	considerations read it and never query the world themselves. Each sense documents the keys it
	writes. Declare your own blackboard type per AI and cast once at the boundary.
]=]
export type Blackboard = { [string]: any }

--[=[
	@interface Sense
	@within Types

	.Tick (self: any, agent: Agent, deltaTime: number) -> () -- Called once per agent tick. Writes to `agent.Blackboard`.
	.Destroy ((self: any, agent: Agent?) -> ())? -- Optional cleanup, called with each agent that is destroyed. A shared sense releases that agent's state and tears down only when none remain; called with no agent it tears down outright.

	Perceives and nothing else. Senses tick in the order they were added, before the navigator and
	the brain. A sense keeps no per-agent state of its own: memory (`SeenAt`, `HeardAt`) lives on
	the blackboard, so one instance may serve many agents and a state may clear a memory early by
	setting the key to `nil`. Distances are `math.huge` when there is nothing to measure.
	`VluxyAI.Senses` ships `Sight`, `Proximity`, `Hearing` and `Watched`; your own is any table
	with `Tick`.
]=]
export type Sense = {
	Tick: (self: any, agent: Agent, deltaTime: number) -> (),
	Destroy: ((self: any, agent: Agent?) -> ())?,
}

------------------------------------------------------------------------------------------------------------------------
--BRAIN-----------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------

--[=[
	@interface Transition
	@within Types

	.To string -- The state to enter. Must exist in the brain; `Build()` checks.
	.When (agent: Agent) -> boolean -- Checked every tick, in order, before `Update`.

	A declarative transition. The first one whose `When` returns `true` wins. `To` may name the
	current state, which re-enters it (`Exit` then `Enter`); an `Update` returning the current name
	does nothing. If `When` forces a change through [Agent:SetState], that change wins and its own
	result is ignored.
]=]
export type Transition = {
	To: string,
	When: (agent: Agent) -> boolean,
}

--[=[
	@interface State
	@within Types

	.Enter ((agent: Agent) -> ())? -- Runs once when the state becomes current.
	.Update ((agent: Agent, deltaTime: number) -> string?)? -- Runs every tick. Return a state name to change state, or nothing to stay.
	.Exit ((agent: Agent) -> ())? -- Runs once when the state stops being current.
	.Transitions { Transition }? -- Checked in order before `Update` each tick.

	One state of a [Types.Brain]. Every field is optional, so a state can be as small as a single
	`Update`. Returning the current state's name from `Update` does nothing; use [Agent:SetState] to
	re-enter a state on purpose. If `Update` itself forces a change through `SetState`, its return
	value is ignored so two transitions never stack.
]=]
export type State = {
	Enter: ((agent: Agent) -> ())?,
	Update: ((agent: Agent, deltaTime: number) -> string?)?,
	Exit: ((agent: Agent) -> ())?,
	Transitions: { Transition }?,
}

--[=[
	@interface Brain
	@within Types

	.Initial string -- The state entered on `Start()`.
	.States { [string]: State } -- Every state, keyed by name.

	A flat finite state machine as a table. The whole AI, readable top to bottom.
]=]
export type Brain = {
	Initial: string,
	States: { [string]: State },
}

------------------------------------------------------------------------------------------------------------------------
--UTILITY---------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------

--[=[
	@type Curve (x: number) -> number
	@within Types

	Maps a normalised input in `[0, 1]` to a score in `[0, 1]`. [Utility.Curves] ships the common
	shapes; any function works.
]=]
export type Curve = (x: number) -> number

--[=[
	@interface Consideration<T>
	@within Types

	.Input (agent: Agent, candidate: T) -> number -- Reads a raw value about the candidate, usually off the blackboard.
	.Min number? -- The raw value that maps to `0`. Default `0`.
	.Max number? -- The raw value that maps to `1`. Default `1`.
	.Curve Curve? -- The response curve. Default linear.
	.Invert boolean? -- Flip the normalised input before the curve, so a big distance scores low.

	One factor in scoring a candidate. A candidate's score is the product of its considerations, so
	any one of them can veto by returning `0`.
]=]
export type Consideration<T> = {
	Input: (agent: Agent, candidate: T) -> number,
	Min: number?,
	Max: number?,
	Curve: Curve?,
	Invert: boolean?,
}

--[=[
	@interface Scored<T>
	@within Types

	.Candidate T -- The thing that was scored.
	.Score number -- Its score in `[0, 1]`.

	One row of a [Utility.ScoreAll] result.
]=]
export type Scored<T> = {
	Candidate: T,
	Score: number,
}

------------------------------------------------------------------------------------------------------------------------
--NAVIGATOR-------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------

--[=[
	@type PathStatus "Idle" | "Planning" | "Moving" | "Arrived" | "Failed"
	@within Types

	Where a [Navigator] is with its current target. `Idle` means no target or stopped.
]=]
export type PathStatus = "Idle" | "Planning" | "Moving" | "Arrived" | "Failed"

--[=[
	@interface NavigationOptions
	@within Types

	.RepathInterval number? -- Seconds between re-plans while the target keeps moving. Default `0.5`.
	.RepathDistance number? -- Studs the target must move before a re-plan happens. Default `2`.
	.ArriveDistance number? -- Horizontal studs from the target that count as arrived. Must exceed the two bodies' radii for a chase to ever arrive. Default `2.5`.
	.ArriveHeight number? -- Height difference allowed for arrival, so a target on the floor above does not count. Default `8`.

	Tunes how [Navigator] turns repeated `MoveTo` calls into plans.
]=]
export type NavigationOptions = {
	RepathInterval: number?,
	RepathDistance: number?,
	ArriveDistance: number?,
	ArriveHeight: number?,
}

--[=[
	@interface Navigator
	@within Types

	.MoveTo (self: any, target: Vector3) -> () -- Head to `target`. Safe to call every tick; re-plans on a cadence.
	.Stop (self: any) -> () -- Forget the target and halt.
	.GetStatus (self: any) -> PathStatus -- Where the navigator is with its target.
	.GetTarget (self: any) -> Vector3? -- The current target.
	.GetPath (self: any) -> Path? -- The last path planned.
	.StepReached Signal<(number, Step)> -- Forwarded from the mover.
	.Arrived Signal<boolean> -- Fired when the target is reached (`true`) or given up on (`false`).
	.PathChanged Signal<Path?> -- Fired with each new path, and with `nil` when there is none.

	Owns the pair of a [Types.Pathfinder] and a [Types.Mover]: plans with one, follows with the
	other, and re-plans when the target moves. Every agent with both has one at `agent.Navigator`.
]=]
export type Navigator = {
	MoveTo: (self: any, target: Vector3) -> (),
	Stop: (self: any) -> (),
	GetStatus: (self: any) -> PathStatus,
	GetTarget: (self: any) -> Vector3?,
	GetPath: (self: any) -> Path?,
	StepReached: Signal<(number, Step)>,
	Arrived: Signal<boolean>,
	PathChanged: Signal<Path?>,
}

------------------------------------------------------------------------------------------------------------------------
--AGENT-----------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------

--[=[
	@interface AgentDefinition
	@within Types

	.Entity Model -- The model the AI drives. Needs a `PrimaryPart`.
	.Brain Brain -- The state table.
	.Pathfinder Pathfinder? -- Required if `Mover` is given.
	.Mover Mover? -- Required if `Pathfinder` is given.
	.Senses { Sense }? -- Ticked in order before the brain each tick.
	.Blackboard Blackboard? -- Initial blackboard values. Copied per agent.
	.Data { [string]: any }? -- Initial `agent.Data`. Copied per agent. Yours to use.
	.Tick number? -- Seconds between ticks. Default `0.1`.
	.Navigation NavigationOptions? -- Navigator tuning.
	.Name string? -- Used in messages. Default `Entity.Name`.

	Everything an [Agent] is built from. The [Builder] produces one of these; you can also write it
	as a table and hand it to `VluxyAI.NewAgent`. `Validate` checks it either way.
]=]
export type AgentDefinition = {
	Entity: Model,
	Brain: Brain,
	Pathfinder: Pathfinder?,
	Mover: Mover?,
	Senses: { Sense }?,
	Blackboard: Blackboard?,
	Data: { [string]: any }?,
	Tick: number?,
	Navigation: NavigationOptions?,
	Name: string?,
}

--[=[
	@interface Agent
	@within Types

	.Entity Model -- The model being driven.
	.Name string -- For messages.
	.Blackboard Blackboard -- Written by senses, read by states.
	.Data { [string]: any } -- Free scratch space for your states.
	.Brain Brain -- The state table.
	.Senses { Sense } -- Ticked before the brain.
	.Navigator Navigator? -- Present when the definition had a pathfinder and a mover.
	.Mover Mover? -- The mover, if any.
	.Pathfinder Pathfinder? -- The pathfinder, if any.
	.StateChanged Signal<(string, string?)> -- Fired with the new and previous state names.
	.Destroyed Signal<()> -- Fired once, at the end of `Destroy`, so anything built around the agent can go with it.
	.GetState (self: Agent) -> string? -- The current state name, `nil` before `Start`.
	.SetState (self: Agent, name: string) -> () -- Force a transition, re-entering if already there.
	.MoveTo (self: Agent, target: Vector3) -> () -- Shorthand for `Navigator:MoveTo`. Errors without a navigator.
	.Stop (self: Agent) -> () -- Shorthand for `Navigator:Stop`. No-op without a navigator.
	.GetPosition (self: Agent) -> Vector3 -- The mover's position, or the entity's pivot.
	.HasArrived (self: Agent) -> boolean -- `true` while the navigator status is `Arrived`.
	.GetPathStatus (self: Agent) -> PathStatus -- The navigator status, or `Idle` without a navigator.
	.SetSpeed (self: Agent, speed: number) -> () -- Shorthand for `Mover:SetSpeed`. No-op without a mover.
	.StartTimer (self: Agent, name: string, seconds: number) -> () -- Starts a named timer.
	.TimerDone (self: Agent, name: string) -> boolean -- `true` once the timer ran out, or if it was never started.
	.TimerLeft (self: Agent, name: string) -> number -- Seconds left on the timer, `0` when done.
	.Step (self: Agent, deltaTime: number) -> () -- One tick, driven by hand. Tests use this.
	.Start (self: Agent, manual: boolean?) -> Agent -- Enters the initial state and starts ticking on `Heartbeat`. With `manual`, you drive `Step` yourself.
	.IsRunning (self: Agent) -> boolean -- `true` between `Start` and `Destroy`.
	.Destroy (self: Agent) -> () -- Exits the current state, stops, destroys every part.

	The running AI. Handed to every `Enter`, `Update`, `Exit`, `When` and `Input` function.
]=]
export type Agent = {
	Entity: Model,
	Name: string,
	Blackboard: Blackboard,
	Data: { [string]: any },
	Brain: Brain,
	Senses: { Sense },
	Navigator: Navigator?,
	Mover: Mover?,
	Pathfinder: Pathfinder?,
	StateChanged: Signal<(string, string?)>,
	Destroyed: Signal<()>,

	GetState: (self: Agent) -> string?,
	SetState: (self: Agent, name: string) -> (),
	MoveTo: (self: Agent, target: Vector3) -> (),
	Stop: (self: Agent) -> (),
	GetPosition: (self: Agent) -> Vector3,
	HasArrived: (self: Agent) -> boolean,
	GetPathStatus: (self: Agent) -> PathStatus,
	SetSpeed: (self: Agent, speed: number) -> (),
	StartTimer: (self: Agent, name: string, seconds: number) -> (),
	TimerDone: (self: Agent, name: string) -> boolean,
	TimerLeft: (self: Agent, name: string) -> number,
	Step: (self: Agent, deltaTime: number) -> (),
	Start: (self: Agent, manual: boolean?) -> Agent,
	IsRunning: (self: Agent) -> boolean,
	Destroy: (self: Agent) -> (),
}

return Types
