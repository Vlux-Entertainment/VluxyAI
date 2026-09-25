---
sidebar_position: 5
---

# Extension

Every part of an agent is a contract in [Types](/api/Types). The package never learns your
module exists: you pass it into the builder, `Build()` checks its shape, and the agent uses it.

## A sense

Anything with `Tick(self, agent, deltaTime)`, called with a colon once per tick before the brain.
The built-ins are [Sight](/api/Sight), [Proximity](/api/Proximity), [Hearing](/api/Hearing),
[Watched](/api/Watched) and [Surroundings](/api/Surroundings) (a ring of rays for the nearest
obstacle and the most open direction); the playground's Hunter carries a stamina sense written
in a dozen lines.
It writes to `agent.Blackboard` and reads nothing from states. Document the keys you write, use
`math.huge` for a distance with nothing to measure, and keep memory (a `SeenAt`-style timestamp)
on the blackboard rather than in the sense, so one instance can serve many agents. The agent's
position is `agent:GetPosition()`; [Perception](/api/Perception) has the alive player roots, cone
and line-of-sight helpers the built-in senses use.

```lua
local Fear = {}
Fear.__index = Fear

function Fear.new(threshold: number)
	return setmetatable({ _threshold = threshold }, Fear)
end

-- Writes: Afraid (boolean)
function Fear.Tick(self, agent, deltaTime)
	local humanoid = agent.Entity:FindFirstChildOfClass("Humanoid")
	agent.Blackboard.Afraid = humanoid ~= nil and humanoid.Health < self._threshold
end

return Fear
```

```lua
:AddSense(Fear.new(30))
```

## A pathfinder

Anything with `FindPath(self, from, to, agent) -> (Path?, reason?)`. It may yield. `from` is the
mover's root position and `to` is wherever the state asked to go; return a list of steps whose
`Position` is a **floor** position, or `nil` and a short reason.

```lua
local Teleporters = {}
Teleporters.__index = Teleporters

function Teleporters.new(pads)
	return setmetatable({ Name = "Teleporters", _pads = pads }, Teleporters)
end

function Teleporters.FindPath(self, from, to, agent)
	local pad = self:_nearestPad(from)
	if pad == nil then
		return nil, "no pad near"
	end

	return {
		{ Position = pad.Entrance, Action = "Custom", Label = "Teleport" },
		{ Position = to, Action = "Walk" },
	}
end

return Teleporters
```

Compose it with the built-ins through a [Ladder](/api/Ladder), which tries each in order:

```lua
:UsePathfinder(VluxyAI.Pathfinders.Ladder.new({
	VluxyAI.Pathfinders.Straight.new(),
	Teleporters.new(pads),
	VluxyAI.Pathfinders.Navmesh.new(),
}))
```

For a level with doors, one-way drops or rooms the navmesh cannot connect, the package already
has the two pieces the design plan calls for: a [Graph](/api/Graph) of hand-placed nodes with
A\*, read out of a folder of parts with `Graph.FromInstances`, and a [Hybrid](/api/Hybrid) that
uses your local pathfinder up close and the graph for long legs, refining both ends locally.

```lua
-- once, for the level: reading the folder casts a ray per pair of nodes
local graph = VluxyAI.Pathfinders.Graph.FromInstances(workspace.NavGraph)

-- per agent: the local pathfinder holds a navmesh Path of its own
:UsePathfinder(VluxyAI.Pathfinders.Hybrid.new({
	Graph = graph,
	Local = VluxyAI.Pathfinders.Ladder.new({
		VluxyAI.Pathfinders.Straight.new(),
		VluxyAI.Pathfinders.Navmesh.new(),
	}),
	LocalRadius = 40,
}))
```

A door is a `Custom` step on a graph link: the game listens to `agent.Navigator.StepReached`,
stops the agent, opens the door, and calls `MoveTo` again.

## A mover

Anything with `Follow(path)`, `Stop()`, `GetPosition()`, `GetSpeed()`, `SetSpeed(speed)`,
`IsMoving()`, and two signals: `StepReached` and `Arrived`. The rules that keep it honest with
the [Navigator](/api/Navigator), all listed on [Types.Mover](/api/Types#Mover):

1. `Follow` fires `Arrived(false)` for the path it replaces, before starting the new one, and
   must not yield: the navigator calls it from its planning thread.
2. The new path's outcome is reported on a later frame, never from inside `Follow`:
   `Arrived(true)` once the last step is reached (fire `StepReached` for it first), `Arrived(false)`
   when stuck. An empty path is `Arrived(false)` on the next frame.
3. `Stop` fires `Arrived(false)` if a path was in progress, and nothing otherwise.
4. Steps are floor positions; add your own height. `GetPosition` returns the body, not the floor.

What the navigator does with the outcome: on `true` it checks the target against `ArriveDistance`
and either reports arrival or re-plans; on `false` it re-plans on its cadence.

Make the signals with `VluxyAI.Signal.new()`. Read [CFrameMover](/api/CFrameMover) for a small
complete one; it is what a server-side "logical position" agent with no rig uses.

## Doors and other scripted steps

A pathfinder may emit a step with `Action = "Custom"` and a `Label`. Movers walk to it like any
other step, and `agent.Navigator.StepReached` fires with the index and the step when they get
there. Stop the agent, run your door interaction, and call `MoveTo` again; nothing in the package
knows what a door is.

## Content modules

A brain can be its own module. Cast it on the way out so a missing field fails in the editor:

```lua
return Stalker :: VluxyAI.Brain
```

`VluxyAI.ValidateBrain(Stalker, "Stalker")` runs the same checks at runtime, with `Stalker.` as
the prefix of any error, for a test that walks a folder of enemies.
