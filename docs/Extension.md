---
sidebar_position: 5
---

# Extension

Every part of an agent is a contract in [Types](/api/Types). The package never learns your
module exists: you pass it into the builder, `Build()` checks its shape, and the agent uses it.

## A sense

Anything with `Tick(self, agent, deltaTime)`, called with a colon once per tick before the brain.
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
local Graph = {}
Graph.__index = Graph

function Graph.new(nodes)
	return setmetatable({ Name = "Graph", _nodes = nodes }, Graph)
end

function Graph.FindPath(self, from, to, agent)
	local route = self:_astar(from, to)
	if route == nil then
		return nil, "no route through the graph"
	end

	local path = {}
	for _, node in route do
		table.insert(path, { Position = node.Position, Action = "Walk" })
	end
	return path
end

return Graph
```

Compose it with the built-ins through a [Ladder](/api/Ladder): try a straight line, then your
graph, then the navmesh.

```lua
:UsePathfinder(VluxyAI.Pathfinders.Ladder.new({
	VluxyAI.Pathfinders.Straight.new(),
	Graph.new(nodes),
	VluxyAI.Pathfinders.Navmesh.new(),
}))
```

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
