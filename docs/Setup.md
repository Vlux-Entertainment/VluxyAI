---
sidebar_position: 3
---

# Your first AI

This builds a rig that stands still until it sees a player, chases them, and gives up when it
loses them. It uses a Humanoid rig with a `PrimaryPart`, the same as any NPC.

## 1. Write the brain

A brain is a table: an `Initial` state name and a `States` table. Each state can have `Enter`,
`Update`, `Exit` and `Transitions`, all optional.

```lua
local Stalker = {
	Initial = "Idle",
	States = {
		Idle = {
			Enter = function(agent)
				agent:Stop()
			end,
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
```

Every tick the runner checks the current state's transitions in order and takes the first whose
`When` is true. If none fires, `Update` runs; it may return the name of the next state, or nothing
to stay. `SeenTarget` and `SeenPosition` are written by the [Sight](/api/Sight) sense; the brain
never raycasts.

## 2. Stack the parts

```lua
local VluxyAI = require(ReplicatedStorage.Packages.VluxyAI)

local agent = VluxyAI.new(rig)
	:UseBrain(Stalker)
	:UsePathfinder(VluxyAI.Pathfinders.Navmesh.new({ AgentRadius = 2, AgentHeight = 5 }))
	:UseMover(VluxyAI.Movers.Humanoid.new(rig, { Speed = 14 }))
	:AddSense(VluxyAI.Senses.Sight.new({ Range = 40, FieldOfView = 120, Memory = 3 }))
	:Build()
	:Start()
```

`Build()` validates everything and errors with the path of the first bad field. `Start()` enters
the initial state and begins ticking on `Heartbeat`, every `0.1` seconds by default
([Builder:SetTick](/api/Builder#SetTick) changes it).

The same stack, with the pathfinder, the humanoid mover, Sight and Proximity already chosen:

```lua
local agent = VluxyAI.Presets.Humanoid(rig):UseBrain(Stalker):Build():Start()
```

## 3. Move

`agent:MoveTo(position)` is safe to call every tick with a moving target. The [Navigator](/api/Navigator)
behind it plans once, re-plans when the target moves more than a couple of studs, retries when the
mover gets stuck, and never plans more often than its `RepathInterval`. Ask it how things are going
with `agent:GetPathStatus()` (`Idle`, `Planning`, `Moving`, `Arrived`, `Failed`) or
`agent:HasArrived()`.

## 4. Take it apart

```lua
agent:Destroy()
```

Exits the current state, stops the mover, and destroys the navigator, every sense, the mover and
the pathfinder. The rig is yours; the agent never destroys it.

## Where to put things

- `agent.Blackboard` is what the AI knows. Senses write it; states read it.
- `agent.Data` is yours: timers, the current patrol index, the chosen target. Set initial values
  with [Builder:SetData](/api/Builder#SetData).
- Anything that needs the world (a raycast, a distance to a player) belongs in a sense, not a
  state. If none of the built-in senses fits, [write one](Extension).
