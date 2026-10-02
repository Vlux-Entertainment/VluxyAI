<div align="center">
	<img src=".moonwave/static/VluxIcon.png" alt="Vlux" height="150" />
	<br/>
	<a href="https://discord.gg/Ebbp9UgBUD"><img src="https://img.shields.io/discord/757104089984270346.svg?label=discord" /></a>
	<p><a href="https://Vlux-Entertainment.github.io/VluxyAI/">View Docs</a></p>
</div>

<!--moonwave-hide-before-this-line-->

# VluxyAI

**VluxyAI** is a simple, composable AI library for Roblox. An AI is a **brain** (a table of states), a
**pathfinder** (plans), a **mover** (executes) and some **senses** (write a blackboard), stacked with
a builder into an **agent**.

```lua
local VluxyAI = require(ReplicatedStorage.Packages.VluxyAI)

local Stalker = {
	Initial = "Idle",
	States = {
		Idle = {
			Transitions = {
				{ To = "Chase", When = function(agent) return agent.Blackboard.SeenTarget ~= nil end },
			},
		},
		Chase = {
			Transitions = {
				{ To = "Idle", When = function(agent) return agent.Blackboard.SeenPosition == nil end },
			},
			Update = function(agent)
				agent:MoveTo(agent.Blackboard.SeenPosition)
			end,
		},
	},
}

local agent = VluxyAI.Presets.Humanoid(rig) -- any Model with a PrimaryPart and a Humanoid
	:UseBrain(Stalker)
	:Build()
	:Start()
```

- **A brain is a table.** States have `Enter`, `Update`, `Exit` and an ordered list of transitions.
  The whole AI reads top to bottom.
- **Senses write, states read.** States never raycast; a blackboard holds what the AI knows.
- **Everything is a contract.** Pass in your own pathfinder, mover or sense; the package never
  learns your module exists. Mistakes fail at `Build()` with the path of the bad field.
- **Headless core.** The runner, validator, scoring and navigator are plain Luau, tested under Lune.

## What's in it

- **Brains:** a state runner with interrupts, ready-made `When` predicates, utility scoring, and
  states for patrolling, investigating, searching, wandering, roaming points of interest or an
  authored graph (`States.GraphRoam`), staring and burrowing.
- **Pathfinding:** `Navmesh` (PathfindingService), `Straight`, `Ladder`, `Graph` (A\* over authored
  nodes, read from a folder of parts) and `Hybrid`; doors and other scripted steps through `OnStep`.
- **Movers:** `Humanoid` (`MoveTo`) and `CFrame` (pivots anything, no rig needed).
- **Senses:** sight, hearing (with noise kinds, sources and strength), proximity, tagged sounds,
  awareness, being watched, neighbours, safe areas, clues, hideouts and stamina.
- **Groups and world:** a director (tension and difficulty), shared points of interest, claims,
  doors, safe areas, rig collision and player noise.
- **Combat:** attacks, and kills that are live, behind a black screen, or a non-lethal scare.
- **Client presentation:** a server `Broadcaster` and client `Replica`, either mirroring the
  server's rig or drawing a client-side puppet (`Presets.Puppet` on the server,
  `Locomotion.AttachReplica` on the client), plus animation, footsteps and voice lines.
- **Debug:** path, graph, sense and state visuals, and a runtime R15 rig.

Tags and attributes a game sets for the package are prefixed `VLUXYAI_` (`VLUXYAI_SAFE`,
`VLUXYAI_SOUND`, `VLUXYAI_LIGHT`, `VLUXYAI_DOOR`, `VLUXYAI_HIDDEN`) so they do not collide with your
own. Before 0.11.0 they were `AI_*`.

## Install

```toml
[dependencies]
VluxyAI = "greenviper126/vluxyai@0.11.0"
```

Then `wally install`. The package has no dependencies and is `shared` realm: requiring it on a
client is harmless.

## Repository

- `lib/` is the package. `examples/` is a playground: a seeded maze and four R15 example AIs that
  show the package off; serve `test-place.project.json` and press Play.
- `lune run tests/runner` runs the headless suite; `.\Commands\Verify.ps1` runs everything.
- `PLAN.md` is the design record. `CLAUDE.md` is the map for contributors.

## License

MIT. See `LICENSE`.
