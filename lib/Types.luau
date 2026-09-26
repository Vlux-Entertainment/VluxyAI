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

	What [Types.Signal] `Connect` returns. Any cleanup helper that calls `Disconnect` accepts it.
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
	core runs outside Roblox. Movers and agents expose these; a [Cleaner] releases their connections.
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
	.Label string? -- The `PathfindingModifier` label, or whatever your pathfinder attaches. A [Types.StepHandler] registered for it runs when the step is reached.
	.Instance Instance? -- What the step is about, when the pathfinder knows: the door on a [Graph] link.

	One point along a [Types.Path].
]=]
export type Step = {
	Position: Vector3,
	Action: StepAction,
	Label: string?,
	Instance: Instance?,
}

--[=[
	@type StepHandler (agent: Agent, step: Step, index: number) -> (boolean?, number?)
	@within Types

	What happens at a labelled step: open the door, climb the ladder, play the vault. Registered
	with [Builder:OnStep] under the step's `Label`. Runs in its own thread and may yield; the
	navigator holds the mover at the step, reports `Interacting`, and walks the rest of the path
	when the handler returns. A new target or `Stop` while it runs abandons the path; the handler
	should check [Agent:IsDestroyed] after a long yield.

	Return `false` to say the step could not be taken (a locked door). The path is given up as
	`Failed`, and the pathfinder is told to `Close` that step for the seconds given as the second
	return (default `10`), so the next plan goes another way. Returning nothing or `true` means
	the step was taken.
]=]
export type StepHandler = (agent: Agent, step: Step, index: number) -> (boolean?, number?)

--[=[
	@interface StepRegistration
	@within Types

	.Handler StepHandler
	.Tag string? -- When the step arrives without an `Instance` (a navmesh link or modifier), the nearest instance carrying this `CollectionService` tag within `Radius` of the step is put in `step.Instance` before the handler runs.
	.Radius number? -- Studs. Default `8`.

	What [Builder:OnStep] stores for a label: the handler, and how to find the door for a step
	that does not already know it. A plain [Types.StepHandler] is accepted wherever this is.
]=]
export type StepRegistration = {
	Handler: StepHandler,
	Tag: string?,
	Radius: number?,
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
	.Blocked Signal<()>? -- Optional. Fired when the world changes under the last path returned; the [Navigator] re-plans on its cadence.
	.Close ((self: any, step: Step, seconds: number) -> ())? -- Optional. A labelled step could not be taken (a locked door): plan around it for `seconds`. [Graph] closes the link, [Navmesh] refuses paths through it; [Ladder] and [Hybrid] pass it on.

	Plans and nothing else. A pathfinder never moves the agent, never creates parts and never keeps
	a target. `from` and `to` may be at any height: `from` is the mover's root and `to` is often a
	player's root or a floor node; the path it returns holds floor positions. An empty path counts
	as a failure. `FindPath` runs in its own thread and may yield or error; an error is treated as a
	failed plan and warned about once. `VluxyAI.Pathfinders` ships `Navmesh`, `Straight` and
	`Ladder`; your own is any table with `FindPath`.

	`Blocked` is how a pathfinder that watches the world ([Navmesh] listens to its `Path.Blocked`)
	tells the navigator that the path being walked is no longer good, so the agent re-plans as soon
	as the cadence allows instead of walking into the obstacle and waiting for the mover's stuck
	check. A pathfinder that cannot know leaves it out; [Ladder] and [Hybrid] forward it from the
	rung that produced the current path.
]=]
export type Pathfinder = {
	FindPath: (self: any, from: Vector3, to: Vector3, agent: Agent) -> (Path?, string?),
	Destroy: ((self: any) -> ())?,
	Name: string?,
	Blocked: Signal<()>?,
	Close: ((self: any, step: Step, seconds: number) -> ())?,
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
	.Face ((self: any, position: Vector3?) -> ())? -- Optional. Turn toward `position` while standing still; `nil` stops. [Agent:LookAt] calls it.
	.Teleport ((self: any, position: Vector3) -> ())? -- Optional. Put the body at `position` at once, dropping any path. [Agent:Teleport] calls it.
	.SetNudge ((self: any, offset: Vector3?) -> ())? -- Optional. Aim at each step plus `offset` (never the last step), so a steering sense can push the body sideways; `nil` clears. [Neighbours] calls it.

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
	Face: ((self: any, position: Vector3?) -> ())?,
	Teleport: ((self: any, position: Vector3) -> ())?,
	SetNudge: ((self: any, offset: Vector3?) -> ())?,
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
	.Configure ((self: any, patch: { [string]: any }) -> ())? -- Optional. Changes options after construction; every built-in has it, so a director can widen a cone or shorten a memory mid-round.

	Perceives and nothing else. Senses tick in the order they were added, before the navigator and
	the brain. A sense keeps no per-agent state of its own: memory (`SeenAt`, `HeardAt`) lives on
	the blackboard, so one instance may serve many agents and a state may clear a memory early by
	setting the key to `nil`. Distances are `math.huge` when there is nothing to measure.
	`VluxyAI.Senses` ships `Sight`, `Proximity`, `Hearing`, `Sounds`, `Awareness`, `Watched`,
	`Surroundings` and `Neighbours`; your own is any table with `Tick`.
]=]
export type Sense = {
	Tick: (self: any, agent: Agent, deltaTime: number) -> (),
	Destroy: ((self: any, agent: Agent?) -> ())?,
	Configure: ((self: any, patch: { [string]: any }) -> ())?,
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
	@interface Interrupt
	@within Types

	.To string -- The state to enter. Must exist in the brain; `Build()` checks.
	.When (agent: Agent) -> boolean -- Checked every tick, in order, before the current state's own transitions.
	.Except { string }? -- States in which this interrupt is not checked, such as the one it leads to or an attack that must finish.

	A [Types.Transition] that applies from every state: "hunt whoever I see", "freeze when lit",
	"stop when the director says so". Written once on the brain instead of in every state.
	Interrupts are checked in order before the current state's transitions; the first true one
	wins the tick.
]=]
export type Interrupt = {
	To: string,
	When: (agent: Agent) -> boolean,
	Except: { string }?,
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
	.Interrupts { Interrupt }? -- Transitions that apply from every state, checked before the current state's own.

	A flat finite state machine as a table. The whole AI, readable top to bottom.
]=]
export type Brain = {
	Initial: string,
	States: { [string]: State },
	Interrupts: { Interrupt }?,
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
	@type PathStatus "Idle" | "Planning" | "Moving" | "Interacting" | "Arrived" | "Failed"
	@within Types

	Where a [Navigator] is with its current target. `Idle` means no target or stopped;
	`Interacting` means a [Types.StepHandler] is running at a step and the walk resumes after.
]=]
export type PathStatus = "Idle" | "Planning" | "Moving" | "Interacting" | "Arrived" | "Failed"

--[=[
	@interface NavigationOptions
	@within Types

	.RepathInterval number? -- Seconds between re-plans while the target keeps moving. Must be above 0; the three distances below may be 0. Default `0.5`.
	.RepathDistance number? -- Studs the target must move before a re-plan happens. Default `2`.
	.MaxPathAge number? -- Seconds a path is followed before it is planned again even though the target has not moved, so the agent keeps up with a changing level. Must be above 0. Default `math.huge` (never).
	.ArriveDistance number? -- Horizontal studs from the target that count as arrived. Must exceed the two bodies' radii for a chase to ever arrive. Default `2.5`.
	.ArriveHeight number? -- Height difference allowed for arrival, so a target on the floor above does not count. Default `8`.

	Tunes how [Navigator] turns repeated `MoveTo` calls into plans.
]=]
export type NavigationOptions = {
	RepathInterval: number?,
	RepathDistance: number?,
	MaxPathAge: number?,
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
	other, and re-plans when the target moves, the pathfinder reports the path blocked, or the path
	is older than `MaxPathAge`. Every agent with both has one at `agent.Navigator`.
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
	.Steps { [string]: StepHandler | StepRegistration }? -- What to do at labelled steps, by label. See [Builder:OnStep].
	.StrictBlackboard boolean? -- Warn once when a state reads a blackboard key that looks like a typo of one a sense wrote (`SeenTaget`). For development; costs a metatable on every read. Default `false`.
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
	Steps: { [string]: StepHandler | StepRegistration }?,
	StrictBlackboard: boolean?,
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
	.Events Signal<(string, any)> -- Everything the agent announces through [Agent:Emit]; a [Broadcaster] relays it to clients.
	.GetState (self: Agent) -> string? -- The current state name, `nil` before `Start`.
	.SetState (self: Agent, name: string) -> () -- Force a transition, re-entering if already there.
	.MoveTo (self: Agent, target: Vector3) -> () -- Shorthand for `Navigator:MoveTo`. Errors without a navigator; warns and does nothing before `Start`.
	.Stop (self: Agent) -> () -- Shorthand for `Navigator:Stop`. No-op without a navigator.
	.GetPosition (self: Agent) -> Vector3 -- The mover's position, or the entity's pivot.
	.HasArrived (self: Agent) -> boolean -- `true` while the navigator status is `Arrived`.
	.GetPathStatus (self: Agent) -> PathStatus -- The navigator status, or `Idle` without a navigator.
	.SetSpeed (self: Agent, speed: number, seconds: number?) -> () -- The base speed; the mover gets it times the speed scale. With `seconds`, ramps there over the ticks. No-op without a mover.
	.SetSpeedScale (self: Agent, scale: number) -> () -- A multiplier layered on the base speed, kept across states. `1` is none.
	.GetSpeedScale (self: Agent) -> number
	.GetSpeed (self: Agent) -> number -- The base speed, before the scale.
	.StartTimer (self: Agent, name: string, seconds: number) -> () -- Starts a named timer.
	.TimerDone (self: Agent, name: string) -> boolean -- `true` once the timer ran out, or if it was never started.
	.TimerLeft (self: Agent, name: string) -> number -- Seconds left on the timer, `0` when done.
	.TimeInState (self: Agent) -> number -- Seconds since the current state was entered, paused time excluded. `0` before `Start`.
	.Pause (self: Agent) -> () -- Freeze: no ticks, no movement, timers on hold. For cutscenes, jumpscares and a director backing an enemy off.
	.Resume (self: Agent) -> () -- Undo `Pause`. The navigator re-plans to its target on the next tick.
	.IsPaused (self: Agent) -> boolean
	.LookAt (self: Agent, position: Vector3?) -> () -- Turn toward `position` while standing still, `nil` to stop. Needs a mover with `Face`; otherwise does nothing.
	.Teleport (self: Agent, position: Vector3) -> () -- Put the body at `position` at once, dropping the current path. Uses the mover's `Teleport`, else the entity's `PivotTo`.
	.IsNew (self: Agent, key: string) -> boolean -- `true` while `Blackboard[key]` is non-nil and differs from the value last passed to `Acknowledge`.
	.Acknowledge (self: Agent, key: string) -> () -- Marks the current `Blackboard[key]` as dealt with, so `IsNew` is `false` until it changes.
	.Step (self: Agent, deltaTime: number) -> () -- One tick, driven by hand. Tests use this.
	.Start (self: Agent, manual: boolean?) -> Agent -- Enters the initial state and starts ticking on `Heartbeat`. With `manual`, you drive `Step` yourself.
	.IsRunning (self: Agent) -> boolean -- `true` between `Start` and `Destroy`.
	.IsDestroyed (self: Agent) -> boolean -- `true` once `Destroy` has run.
	.Emit (self: Agent, name: string, payload: any?) -> () -- Announces something for clients: a scream, a kill, a door. Fires `Events`.
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
	Events: Signal<(string, any)>,

	GetState: (self: Agent) -> string?,
	SetState: (self: Agent, name: string) -> (),
	MoveTo: (self: Agent, target: Vector3) -> (),
	Stop: (self: Agent) -> (),
	GetPosition: (self: Agent) -> Vector3,
	HasArrived: (self: Agent) -> boolean,
	GetPathStatus: (self: Agent) -> PathStatus,
	SetSpeed: (self: Agent, speed: number, seconds: number?) -> (),
	SetSpeedScale: (self: Agent, scale: number) -> (),
	GetSpeedScale: (self: Agent) -> number,
	GetSpeed: (self: Agent) -> number,
	StartTimer: (self: Agent, name: string, seconds: number) -> (),
	TimerDone: (self: Agent, name: string) -> boolean,
	TimerLeft: (self: Agent, name: string) -> number,
	TimeInState: (self: Agent) -> number,
	Pause: (self: Agent) -> (),
	Resume: (self: Agent) -> (),
	IsPaused: (self: Agent) -> boolean,
	LookAt: (self: Agent, position: Vector3?) -> (),
	Teleport: (self: Agent, position: Vector3) -> (),
	IsNew: (self: Agent, key: string) -> boolean,
	Acknowledge: (self: Agent, key: string) -> (),
	Step: (self: Agent, deltaTime: number) -> (),
	Start: (self: Agent, manual: boolean?) -> Agent,
	IsRunning: (self: Agent) -> boolean,
	IsDestroyed: (self: Agent) -> boolean,
	Emit: (self: Agent, name: string, payload: any?) -> (),
	Destroy: (self: Agent) -> (),
}

------------------------------------------------------------------------------------------------------------------------
--CLIENT----------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------

--[=[
	@interface ClientState
	@within Types

	.Enter ((replica: any) -> ())? -- Runs when the server enters the state of that name.
	.Update ((replica: any, deltaTime: number) -> ())? -- Runs every frame while it is current.
	.Exit ((replica: any) -> ())? -- Runs when the server leaves it.

	The client's side of one server state: what a [Replica] does while the enemy is in it. The
	same shape as a [Types.State] without transitions, since the server decides those.
]=]
export type ClientState = {
	Enter: ((replica: any) -> ())?,
	Update: ((replica: any, deltaTime: number) -> ())?,
	Exit: ((replica: any) -> ())?,
}

--[=[
	@type Visuals { [string]: ClientState }
	@within Types

	Client states keyed by server state name. Only the states a client needs to react to are
	listed; the rest are tracked without doing anything.
]=]
export type Visuals = { [string]: ClientState }

--[=[
	@interface Snapshot
	@within Types

	.State string? -- The current state name.
	.Position Vector3 -- The rig's pivot position.
	.Yaw number -- Facing in radians about Y.

	Everything a client that just joined needs, from [Broadcaster.Snapshot] to [Replica.ApplySnapshot].
]=]
export type Snapshot = {
	State: string?,
	Position: Vector3,
	Yaw: number,
}

--[=[
	@type KillKind "Live" | "BlackBox" | "Scare"
	@within Types

	How a [Kill] is presented: played out in the world, cut to black, or a scare, which is the
	live hold without the death.
]=]
export type KillKind = "Live" | "BlackBox" | "Scare"

--[=[
	@interface HealthProvider
	@within Types

	.Get (character: Model) -> number -- The character's current health.
	.Damage (character: Model, amount: number) -> () -- Hurt it.
	.Kill ((character: Model) -> ())? -- Finish it. Default: `Damage` with `math.huge`.

	How [Attack] and [Kill] read and change a victim's health when the game does not use the
	`Humanoid` for it. Without one, the Humanoid's `Health` and `TakeDamage` are used.
]=]
export type HealthProvider = {
	Get: (character: Model) -> number,
	Damage: (character: Model, amount: number) -> (),
	Kill: ((character: Model) -> ())?,
}

--[=[
	@interface KillEvent
	@within Types

	.Kind KillKind
	.Victim Model -- The character being killed.
	.Duration number -- Seconds until the victim dies (or, for a scare, is released), for the client to match.

	The payload of the `"Kill"` event an agent emits, and of the `"Scare"` event a scare emits.
	A `"KillCancelled"` (or `"ScareCancelled"`) event with `{ Kind, Victim }` follows if it ends
	early.
]=]
export type KillEvent = {
	Kind: KillKind,
	Victim: Model,
	Duration: number,
}

return Types
