---
sidebar_position: 1
---

# Introduction

**VluxyAI** is a simple, composable AI library for Roblox.

An AI is four things stacked together:

| Part | What it does | You write it as |
|---|---|---|
| **Brain** | Decides what to do | A table of states with `Enter`, `Update`, `Exit` and transitions |
| **Pathfinder** | Plans a route | Anything with `FindPath` |
| **Mover** | Walks the route | Anything with `Follow`, `Stop`, a position, a speed, and `Arrived` and `StepReached` signals (see [Extension](Extension)) |
| **Senses** | Notice the world | Anything with `Tick` that writes to a blackboard |

The [Builder](/api/Builder) stacks them into an [Agent](/api/Agent), which ticks the senses, then the
navigator, then the brain, on a timer you choose.

```lua
local agent = VluxyAI.new(rig)
	:UseBrain(Stalker)
	:UsePathfinder(VluxyAI.Pathfinders.Navmesh.new())
	:UseMover(VluxyAI.Movers.Humanoid.new(rig))
	:AddSense(VluxyAI.Senses.Sight.new({ Range = 40 }))
	:Build()
	:Start()
```

## Why it is shaped like this

- **States never query the world.** Senses write what they notice to `agent.Blackboard`; states
  read it. That is what keeps a brain table readable, and what lets the whole thing run under Lune
  with fakes.
- **Modes are transitions, targets are scores.** A state's transitions are checked in order every
  tick and the first true one wins, so mode changes are deterministic. When a state has to choose
  *which* player or *which* room, [Utility](/api/Utility) scoring picks one; a bad score gives an
  odd choice, never an oscillating AI.
- **Contracts, not registries.** You never register a pathfinder kind or an enemy kind by name.
  You pass your own module in, and `Build()` checks its shape. A mistake reads as
  `Definition.Brain.States.Hunt.Transitions[2].To = "Chase" names no state`.

Read [Installation](Installation) to add the package, then [Your first AI](Setup) to build one.
