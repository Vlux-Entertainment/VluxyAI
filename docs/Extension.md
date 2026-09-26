---
sidebar_position: 7
---

# Extension

Every part of an agent is a contract in [Types](/api/Types). The package never learns your
module exists: you pass it into the builder, `Build()` checks its shape, and the agent uses it.

## A sense

Anything with `Tick(self, agent, deltaTime)`, called with a colon once per tick before the brain.
The built-ins are [Sight](/api/Sight), [Proximity](/api/Proximity), [Hearing](/api/Hearing),
[Sounds](/api/Sounds) (the tagged `Sound` instances the world is playing, rolled off by distance),
[Awareness](/api/Awareness) (a detection meter fed by the others), [Watched](/api/Watched),
[Surroundings](/api/Surroundings) (a ring of rays for the nearest obstacle and the most open
direction) and [Neighbours](/api/Neighbours) (the other agents of a group, with an optional
speed ease and sideways nudge), plus [Throttle](/api/Throttle) to run any of them less often; the playground's
Hunter carries a stamina sense written in a dozen lines. Every built-in takes a `Prefix` so two
of a kind can coexist, and has `Configure` to change its options after construction.
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
	local humanoid = agent.Entity:FindFirstChildOfClass("Humanoid") -- the agent's own
	agent.Blackboard.Afraid = humanoid ~= nil and humanoid.Health < self._threshold
end

return Fear
```

`Destroy(self, agent)` is optional. It is called once per agent that is destroyed, with that
agent, so a sense that holds something outside itself (a signal connection, as
[Hearing](/api/Hearing) does) releases that agent's share and lets go entirely when none remain.

```lua
:AddSense(Fear.new(30))
```

## A pathfinder

Anything with `FindPath(self, from, to, agent) -> (Path?, reason?)`. It may yield. `from` is the
mover's root position and `to` is wherever the state asked to go; return a list of steps whose
`Position` is a **floor** position, or `nil` and a short reason.

A pathfinder that can tell when the world changes under its last path may also carry a `Blocked`
signal (`VluxyAI.Signal.new()`). Fire it with no arguments and the navigator re-plans on its next
cadence tick instead of waiting for the mover's stuck check. [Navmesh](/api/Navmesh) relays the
`Path.Blocked` event this way; a pathfinder that cannot know simply leaves the field out.

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

Compose it with the built-ins through a [Ladder](/api/Ladder), which tries each in order. Give
every rung the same `AgentRadius` and `AgentHeight`; each measures the body on its own.

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

A pathfinder may emit a step with a `Label` (and usually `Action = "Custom"`): a `PathfindingModifier`
label from the navmesh, or a [Graph](/api/Graph) link written as `{ To = 7, Label = "Door", Instance = door }`.
Register what to do there with [Builder:OnStep](/api/Builder#OnStep):

```lua
:OnStep("Door", function(agent, step)
	Doors.Open(step.Instance)
	task.wait(0.4)
end)
```

When the mover reaches the step the navigator stops it, reports `Interacting` through
`agent:GetPathStatus()`, runs the handler in its own thread, and walks the rest of the path when
it returns. A state that calls `MoveTo` every tick with the same target keeps waiting; a new
target or `Stop` abandons the path. Nothing in the package knows what a door is; it only knows
where to pause. `agent.Navigator.StepReached` still fires for every step, handled or not.

In a place, a `Link` ObjectValue under a graph node takes `Action` and `Label` attributes and an
`Instance` ObjectValue child pointing at the door, and `Graph.FromInstances` reads them.

## Content modules

A brain can be its own module. Cast it on the way out so a missing field fails in the editor:

```lua
return Stalker :: VluxyAI.Brain
```

`VluxyAI.ValidateBrain(Stalker, "Stalker")` runs the same checks at runtime, with `Stalker.` as
the prefix of any error, for a test that walks a folder of enemies.
