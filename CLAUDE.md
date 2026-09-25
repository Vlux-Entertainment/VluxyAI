# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this project is

**VluxyAI** is Vlux Entertainment's open-source **Roblox AI library**, published to Wally as
`greenviper126/vluxyai` (MIT). An AI is a **brain** (a table of states), a **pathfinder** (plans),
a **mover** (executes) and some **senses** (write to a blackboard), stacked with a **builder** into
an **agent**. The package exports contracts and constructors, never a catalogue a game registers
into: you extend it by passing your own module in. TheLaundryShift (sibling repo) is the first
consumer; `PLAN.md` is the design record and the reasoning behind every contract.

Language: **Luau**, `--!strict`. Managed with **Rojo**; toolchain pinned in `rokit.toml`.

Three deliverables live here:

1. **`lib/`** — the Wally package (what ships; see `include`/`exclude` in `wally.toml`).
2. **`examples/`** — the cylinder test AIs and the playground that builds a map and spawns them.
   Excluded from the package; mounted by `test-place.project.json`.
3. **Docs** — Moonwave site (`moonwave.toml`, `docs/*.md`), generated into `build/`.

## Commands

| Task | Command |
|---|---|
| Headless tests | `lune run tests/runner` (add a substring to filter, `--json` for machine output) |
| Test place sync | `rojo serve test-place.project.json` |
| Package-only build | `rojo build default.project.json -o VluxyAI.rbxm` |
| Lint / format | `selene lib examples tests` / `stylua lib examples tests` |
| Type check | `rojo sourcemap test-place.project.json -o sourcemap.json` then `luau-lsp analyze --sourcemap=sourcemap.json --defs=.luau-analyze/globalTypes.d.luau --platform=roblox lib examples` |
| Install deps | `wally install` |
| Docs preview | `moonwave dev` |

Run `lune run tests/runner` before every commit. A spec is a table of
`["name"] = function(expect)` cases under `tests/`, loaded through `tests/Support/Harness.luau`,
which fakes `script`, `require`, `game` and the Roblox datatypes so the real module runs.

## Architecture

```
lib/
  init.luau          public API: VluxyAI.new (builder), NewAgent, Validate, the module tables
  Types.luau         every exported contract, nothing else
  Builder.luau       fluent builder -> AgentDefinition -> Agent
  Agent.luau         the running AI: tick loop, blackboard, senses, brain runner, navigator
  Navigator.luau     owns pathfinder + mover; MoveTo every tick, re-plans on a cadence
  Brain/Runner       runs a Brain table: Enter/Update/Exit, ordered transitions
  Brain/Validate     walks a definition, errors with the field path
  Brain/Utility      considerations, curves, Score/Best/Weighted (targets, never modes)
  Senses/            Sight, Proximity, Hearing, Watched: Tick(agent, dt) writes the blackboard
  Pathfinders/       Navmesh (PathfindingService), Straight (sweep), Ladder (first that works)
  Movers/            Humanoid (MoveTo), CFrameMover (steps a pivot, no rig)
  Animator.luau      NPC animation helper carried over from 0.1
  Debug/             PathVisual (waypoint balls), StateLabel (billboard); opt-in, make parts
  Utility/           Signal (pure), FormatMessage, Tables, Trove (the one outside require)
```

Rules that keep it composable and testable:

- **Nothing in `lib/` touches Roblox at module scope.** Services are fetched inside `new` or the
  method that needs them. Requiring the package on a client must be harmless.
- **The core is pure Luau.** `Types`, `Runner`, `Validate`, `Utility`, `Navigator`, `Signal`,
  `Agent` and `Builder` run under Lune with fakes and are fully specced. A Roblox-facing module
  keeps its maths in exported pure helpers (`Navmesh.Simplify`, `CFrameMover.Advance`) so those
  are specced too; the rest is play-tested in the test place.
- **States never query the world.** Senses write the blackboard, states read it. States call
  `agent:MoveTo(position)` and never touch a pathfinder.
- **Pathfinders only plan, movers only move.** A pathfinder returns `(Path?, reason?)` and may
  yield; a mover fires `Arrived(false)` for a path it replaces inside `Follow` and reports the new
  path on a later frame, never inside `Follow`.
- **Contracts, not registries.** No string-union catalogue of kinds, no `Register` call. A game
  passes its own pathfinder in; the package never learns it exists.
- **The one outside require** is `lib/Utility/Trove.luau`, which walks three parents up to the
  Wally sibling. Every other require is relative through `script`.

## Conventions

- `--!strict` everywhere. A file starts with a `--[[ ]]` block saying what the module is for and
  the one non-obvious decision in it.
- Moonwave doc comments on all public API: `--[=[ @class X ]=]` once per module, then
  `@within X`, `@param`, `@return`, `@error`, `@yields` per function. Private helpers get a
  plain `--[[ ]]` comment. Types are documented in `Types.luau` with `@interface` / `@type`.
- Warnings and errors go through `Utility/FormatMessage` so they carry the `[VluxyAI]` prefix.
  Validation errors name the field path (`Definition.Brain.States.Hunt.Transitions[2].To`).
- Cleanup is `Destroy`, never `Cleanup`, so Trove picks it up.
- Classes: `local X = {}; X.__index = X`, a `type self = {}` for fields, `export type X = typeof(setmetatable({} :: self, X))`, private fields `_prefixed`.
- Options tables: a frozen `DEFAULT_OPTIONS` at the top, `new(options?)` clones and overlays.
- Tabs, 120 columns, double quotes, `stylua.toml` and `selene.toml` are the arbiters.
- Version bumps happen in `wally.toml` and are mentioned in the commit message.

## Gotchas

- Lune has no `Random`, and cannot derive a Part's `Position` from its `CFrame`. The harness
  injects a deterministic `Random`; movers drive anything with `GetPivot`/`PivotTo` so a spec can
  hand them a plain table.
- `Agent:Start(true)` skips the Heartbeat loop; specs and custom schedulers then call
  `agent:Step(dt)` themselves.
- Arrival is judged by horizontal distance: a humanoid root and a floor waypoint differ in height.
- `examples/` are not part of the package. They are the reference for how the API is meant to
  read; keep them short and boring.
