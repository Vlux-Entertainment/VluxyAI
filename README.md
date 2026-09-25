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

local agent = VluxyAI.Presets.Humanoid(rig)
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

## Install

```toml
[dependencies]
VluxyAI = "greenviper126/vluxyai@0.2.0"
```

Then `wally install`. The package is `shared` realm: requiring it on a client is harmless.

## Repository

- `lib/` is the package. `examples/` is a playground with six R15 example AIs that each show one
  feature; serve `test-place.project.json` and press Play.
- `lune run tests/runner` runs the headless suite; `.\Commands\Verify.ps1` runs everything.
- `PLAN.md` is the design record. `CLAUDE.md` is the map for contributors.

## License

MIT. See `LICENSE`.
