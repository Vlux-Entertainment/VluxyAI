# VluxyAI plan

Status: agreed in conversation on 2026-09-25, nothing built yet. This file is the design record for the
next version of VluxyAI and for the monster system in TheLaundryShift that will be its first consumer.
The library decisions come first; the game-side decisions that shaped them are recorded after, so the
contracts make sense without the conversation.

## 1. Where the package is today

Facts about the tree as of commit `07be3ef`, so the plan can be checked against it later.

- Two lineages exist. This repo (mirrored 1:1 at `Vlux-Entertainment/VluxyAI` and
  `greenviper126/FSM-AI`) is a **place** layout: `src/ServerStorage/VluxyAI/` plus a `TestAI` server
  script, wally name `green/vluxyai@0.1.0`, realm `shared`. The **published** package
  `greenviper126/vluxyai@0.1.8` that TheLaundryShift installs is a **package** layout (`src/init.luau`,
  `model.project.json`, realm `server`) with an `init.luau` hierarchy table, an `AITypes` module and
  `Builders/SPSMBuilder`, but without `Animator/NPCAnimator` and the newer `BasicStates/Killer`. The
  published source is in no git history. Step one of the work is to bring the package layout into this
  repo and carry the animator over, so there is one lineage again.
- It is non-functional as shipped for a concrete reason: every module requires Trove as
  `ReplicatedStorage.Packages.trove` by absolute path, and `AIBuilder` requires `CombatAgent` through
  `ServerStorage.VluxyAI`. Inside a wally install the dependency is a sibling of the package folder
  and the game names it `Trove`, so the first require errors.
- The state shape is already close to what we want: a state is `Start` / `Update` / `End`, `Update`
  returns the next state's name, and the runner ticks at 0.1s. That part stays in spirit.
- The extension point is the problem the next version exists to fix. `SetStandardStateData` hard-codes
  the five agents and the Roblox pathfinder into every AI, `StandardStater` is a closed intersection
  type of exactly those, and the published `AITypes` closes `EnemyTypes` and `PathTypes` as string
  unions. A consumer cannot add an agent, an enemy kind or a pathfinder without editing the package.
- `RobloxPathfinding` couples four jobs in one class: computing a path, moving the humanoid along it,
  tracking a moving target, and visualising waypoints. It also creates a workspace folder at module
  scope and holds an invisible target part per agent. `Spatial.Roots` is a module-level global list.
- Smaller items to settle in the rewrite: `Killer` reads `perceptionAgent._target` directly; the
  cleanup method is `Cleanup`, which Trove does not auto-detect (TheLaundryShift's rule is `Destroy`);
  `MoveToYield` can yield forever after cleanup (its own comment says so); there are no tests and no
  headless runner; the README still says "not functional".

## 2. Decisions

### 2.1 Navigation: hybrid, split by region rather than distance

- A hand-placed **node graph** owns connectivity. Roblox's **navmesh** (PathfindingService) owns
  geometry inside one region. A region is an area with no door in it.
- If the agent and its target resolve to the same region, the local leg is a PathfindingService path.
  Otherwise A* over the graph gives the sequence of regions and doors, and each leg inside a region is
  again a local path. There is no "within N studs" switch anywhere.
- **Doors are graph edges** of kind `Door` that point at the door instance. Traversing one is a
  scripted step: walk to the node on this side, run the door interaction, walk to the node on the far
  side. The local layer therefore never crosses a door, so a closed door being solid geometry is
  correct. (Pure PathfindingService can also cross doors through a `PathfindingModifier` with
  `PassThrough` and a `Label`; doors alone did not force this decision, control did.)
- The local leg is a three-step ladder, deterministic at every step:
  1. A width-aware sweep (`Blockcast` / `Spherecast` at the agent's radius, root to root) is clear:
     move straight, no planning.
  2. Sweep blocked and same region: PathfindingService inside the region, recomputed on a short
     cadence because the player moves.
  3. PathfindingService fails or the mesh is not baked yet (maps are cloned at runtime, and the mesh
     rebuilds lazily): walk to the nearest graph node. The agent always has a plan.
- Raycasts are the "can I go straight" test and small steering nudges only. Whisker or bounce steering
  is never the planner: it has no memory and traps in concave furniture and alcoves. The macro graph is
  never the planner up close either: sparse nodes make the agent route away from a player one table
  away.
- "Distance to the player" for chase and tension logic is **graph path length** or region hops, never
  straight-line magnitude through a wall. Straight-line plus a clear sweep is only the attack trigger.

### 2.2 Authority and presentation: server owns the truth, client owns the rig

- The server holds the monster's logical position as a plain CFrame stepped along waypoints, with
  navmesh waypoints supplying floor height. No server rig is required; an invisible collider part
  driven from that CFrame is enough for raycasts and touch checks. (An invisible server humanoid is the
  easier first version but its parts replicate at physics rate, which is the jitter this model avoids.)
- Both sides run the same A* over the same authored graph, so on graph legs the server sends **intent**:
  "walking from node A to node B, left at server time T". Only the local chase leg, which depends on
  PathfindingService and a moving player, is a **position stream** on an unreliable event that the
  client interpolates behind. Reliable events carry state changes (patrol, hunt, chase, door, scream,
  kill); animations and sounds hang off those, never off the stream.
- Kills are decided on the server from the server position. The client draws the monster slightly
  behind, and the jumpscare's hard cut hides the gap. The client never claims contact.
- The monster opens doors by calling the server's ordinary door interaction, like any player would.
  Nothing in the door system knows about monsters, and clients see the door move through normal
  replication. The rig's reach animation is cued from the state stream, not from a door event.

### 2.3 Brain: a table FSM, utility inside a state

- A **brain** is a table of states. A state is a name, optional `Enter` / `Update` / `Exit`, and an
  ordered list of transitions, each a target state plus a predicate over the blackboard. First true
  transition wins, so mode changes are deterministic and readable.
- **Utility scoring chooses targets, never modes.** A utility state carries a list of options, each
  with considerations that map a blackboard value through a response curve and multiply into a score;
  the state picks the best (or weighted-random) option. Which room to search, which node to patrol to,
  which player to chase, which door to cut off through. A bad score gives an odd choice, never an
  oscillating monster, so there are no hysteresis knobs.
- A per-agent **blackboard** is the only thing states and scorers read. **Senses** write to it on a
  tick (last seen position, last heard noise, path status, door in the way). States never raycast or
  query the world themselves. That is what keeps the runner and the scoring pure Lua and testable
  headlessly, and it makes the brain table the shared contract: the client renderer receives a state
  name and looks up its animation and sound set in the same table.
- Flat machine only. A `Parent` field is a cheap addition later if a state genuinely needs substates; a
  hierarchical runner up front is not wanted.

### 2.4 Extension: injection against exported contracts

- The package exports **types and constructors**, never a catalogue a project merges into. The
  hierarchy table of what the package itself provides (`VluxyAI.Pathfinders.Navmesh`,
  `VluxyAI.Movers.Humanoid`, `VluxyAI.Brains.FSM`) is fine; nothing the project adds is ever written
  into it. No `Register("Pathfinder", "Graph", module)` API, no closed string unions naming enemy or
  pathfinder kinds: a string key is global mutable state that makes boot order matter and takes the
  type checker out of the loop.
- Extension is passing your own module in. A `Pathfinder` is anything with `FindPath`, a `Mover`
  anything with `Follow` / `Stop`, a `Sense` anything that writes to the blackboard, a `Brain` a state
  table. An enemy is an `AgentDefinition` composing those, built by `VluxyAI.NewAgent(definition)`.
  The package never learns the consumer's types exist, so a fourth pathfinder touches nothing in it.
  Composition covers the hybrid: it is itself a `Pathfinder` built from two others.
- Two checks, one per boundary. Analyze time: every content module ends
  `return Stalker :: VluxyAI.AgentDefinition`, so a missing field fails in the editor (types cross the
  wally boundary through wally-package-types, which TheLaundryShift's install script already runs).
  Runtime: `NewAgent` validates the definition and errors with the path of the field, because a folder
  walk that requires content dynamically loses the static types. The error names the field:
  `Stalker.Brain.States.Hunt.Transitions[2].To names no state`, not `attempt to index nil`.
- "Build an AI whenever you want" follows from this: no registration step and no module-scope side
  effects, so an agent can be constructed in a story, a Cmdr command or a Lune test with a fake mover
  and a fake blackboard.
- Package rules so it holds up: nothing in the package requires anything outside itself; the runner,
  the blackboard, the validator and the utility scoring never touch Roblox at module scope; only the
  navmesh pathfinder and the humanoid mover reach for services, inside their own functions.
- Blackboard typing: each enemy module declares its own blackboard type locally and casts once at the
  boundary. `Brain<Blackboard>` generics are possible in Luau and can come later if that proves too
  loose; generic errors through several layers are hard to read, so they are not the starting point.

## 3. Target shape of the package

```
src/
  init.luau            -- exports the types below, NewAgent, Validate, and the built-in tables
  Types.luau           -- every exported contract, nothing else; the only module content casts to
  Agent.luau           -- the agent object: owns the tick, the blackboard, the parts, Destroy
  Brain/
    Runner.luau        -- runs a Brain table: Enter/Update/Exit, ordered transitions
    Utility.luau       -- options, considerations, curves, Score(option, blackboard)
    Validate.luau      -- walks an AgentDefinition, errors with a field path
  Blackboard.luau      -- typed get/set with change signals, no Roblox
  Senses/
    Sight.luau         -- cone + width-aware sweep, writes LastSeen*
    Hearing.luau       -- subscribes to a noise signal the consumer injects
  Pathfinders/
    Navmesh.luau       -- PathfindingService; FindPath only, no movement, no parts
    Straight.luau      -- sweep-clear straight leg
    Hybrid.luau        -- ladder over an injected graph pathfinder + Straight + Navmesh
  Movers/
    Humanoid.luau      -- MoveTo along a path, MoveToFinished, Stop
    CFrame.luau        -- steps a CFrame along a path at a speed (no rig)
  Animator.luau        -- NPCAnimator carried over from this repo, cleanup renamed Destroy
  Debug/
    PathVisual.luau    -- the waypoint balls, opt-in, the only thing that creates parts
```

Contracts, in prose (the exact fields are settled when `Types.luau` is written):

- `Pathfinder`: `FindPath(from, to, agent) -> Path?` where `Path` is a list of `Step`s. A `Step` is
  `Walk { Position }` or `Door { Instance, Enter, Exit }` or `Link { ... }`. Pathfinders only plan.
- `Mover`: `Follow(path)`, `Stop()`, `Position()`, an `Arrived` signal. Movers only execute.
- `Sense`: `Tick(agent, delta)`; it writes to the blackboard and reads nothing back from states.
- `Brain`: `{ Initial: string, States: { [name]: State } }`; `State` is `{ Enter?, Update?, Exit?,
  Transitions: { { To: string, When: (Blackboard) -> boolean } }, Utility?: { Options, Pick } }`.
- `AgentDefinition`: `{ Brain, Pathfinder, Mover, Senses: { Sense }, Blackboard: initial values,
  Tick: seconds, Visuals?: { [stateName]: whatever the consumer's renderer wants } }`.

The realm should be `shared`, not `server`: the types, the runner, the blackboard and the utility
maths are what a client renderer and a story need, and they are pure. Server-only implementations
reach for their services lazily so requiring the package on a client is harmless. TheLaundryShift moves
it from `[server-dependencies]` to `[dependencies]` when it upgrades.

## 4. How TheLaundryShift consumes it

Placement against the framework's nine levels, so the level gate passes:

- The package is level 1.
- `VluxyShared/BaseClasses/` gets nothing new; the contracts come from the package.
- `NavGraph` is a level 8 EntityClass reading tagged node parts in the map (an `Attachment` or part per
  node under a `NavGraph` folder, edges auto-linked by raycast within a radius at bake, explicit
  `ObjectValue` links for doors and one-way edges). It is builder content, so it stays out of every
  generic system.
- `NavigationService` (level 7) implements the package's `Pathfinder` over the graph and composes the
  hybrid. `MonsterService` (level 7) owns the agents' server truth and the state stream.
- `MonsterGateway` (level 6) owns the two remotes: a reliable state event and an unreliable position
  stream, both in `net.zap`.
- `ReplicatedStorage/Enemies/` is a content layer like `ArcadeGames/`: one module per monster, ending
  `return Stalker :: VluxyAI.AgentDefinition`, an `init.luau` that walks its children, `--[[ ]]` blocks
  and no `@class`. A level 9 `Monsters` manager builds agents from it and stamps them onto tagged
  spawn points; a level 9 client `MonsterRenderer` controller is a pure consumer with the cosmetic rig,
  drivable from a story with no server.
- Tests: the runner, the validator, the utility maths and the graph A* run under Lune with a fake
  blackboard and a fake mover, through the existing `tests/` harness. Everything that needs a DataModel
  is a `/qa` item.

## 5. Order of work

Each step is one release of the package or one branch of the game, and leaves the previous step
working.

1. **Package hygiene (0.2.0).** Package layout in this repo (`src/init.luau`, `model.project.json`),
   relative requires for Trove, the animator carried over, `Cleanup` renamed `Destroy`, the
   module-scope workspace folder moved into `Debug/PathVisual`, a Lune test runner with one passing
   spec, README rewritten. Publishes as the same name TheLaundryShift already pins.
2. **Core (0.3.0).** `Types`, `Blackboard`, `Brain/Runner` with ordered transitions, `Validate` with
   field-path errors, `Agent` with `NewAgent` and `Destroy`. Fully headless, tests for every transition
   rule and every validator error.
3. **Planning and moving split (0.4.0).** `Pathfinders/Navmesh` as plan-only, `Pathfinders/Straight`
   with the width-aware sweep, `Movers/Humanoid` and `Movers/CFrame`, `Hybrid` taking an injected
   graph pathfinder. The old `RobloxPathfinding` is deleted, not kept beside them.
4. **Senses and utility (0.5.0).** `Senses/Sight`, `Senses/Hearing`, `Brain/Utility` with response
   curves and the tests that prove scoring picks what the curves say.
5. **Game: graph and navigation.** `NavGraph`, `NavigationService`, a bake command that flags islands
   and unreachable doors, a Studio visualiser. Verified in Studio on the laundromat.
6. **Game: the first monster.** `MonsterService`, `MonsterGateway`, the `Enemies/` folder with one
   monster, the client renderer, the `/qa` pass.

## 6. Open decisions

- **MoveTo or CFrame on the server.** `Movers/Humanoid` is the easy first version and gets MoveTo's
  steering for free; `Movers/CFrame` is the model section 2.2 describes and what the renderer wants.
  Both ship; the first monster decides which it uses after step 5 shows how the navmesh legs feel.
- **Node authoring.** Attachments under a folder plus auto-linking is the default. If placing nodes by
  hand in Studio is too slow on the laundromat, a plugin or a bake from a coarse grid in open areas is
  the fallback, with hand-placed nodes only at doors and chokepoints.
- **Where the client gets the brain table.** With realm `shared` the enemy module is required on both
  sides and the renderer reads `Visuals` off it, which keeps one file per monster. If a monster's
  server logic must stay hidden, `Visuals` splits into a sibling module; not needed yet.
- **Blackboard generics**, per section 2.4: revisit after two monsters exist.

## 7. Non-goals

- Hierarchical state machines, behaviour trees, GOAP. The flat FSM with utility target selection
  covers a horror monster; anything more waits for a case that needs it.
- Client-side authority over anything that affects a kill.
- Navmesh links, climbing or jumping agents. Doors are the only non-walk step until a map needs more.
- Keeping the current `Agents/` and `BaseAgents/` classes. Their useful bodies (player roots, alive
  checks, raycast params, the sight cone) move into `Senses/` and the `Agent`; the class split itself
  does not survive, because it is the closed intersection type that blocked extension.
