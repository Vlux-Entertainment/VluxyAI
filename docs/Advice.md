---
sidebar_position: 6
---

# Advice

Things learned building the examples, in no particular order.

## Call MoveTo every tick

A chase state should call `agent:MoveTo(agent.Blackboard.SeenPosition)` in `Update`, every tick.
The [Navigator](/api/Navigator) decides when that turns into a plan; you do not. Calling it once
in `Enter` works for a fixed point, and the navigator still retries if the mover gets stuck, but a
moving target needs the fresh position.

## Plan only when it is not obvious

A chase that plans every step is always a little behind: each plan is a query, and the navigator
only re-plans on its cadence. [Builder:UseDirect](/api/Builder#UseDirect) with a
[Straight](/api/Straight) walks straight at a target in a clear line and refreshes that line as
the target moves; the navmesh is asked only when the line is blocked, and again whenever walking
straight stops making progress for `DirectStuckTime`. `agent.Navigator:IsDirect()` says which
it is doing. The check runs a sweep and a floor ray every couple of studs each `DirectInterval`,
so a long clear corridor costs more than a short one; raise the interval for a crowd.

## Let the graph do the routing

Roblox's navmesh re-plans to slightly different waypoints every time, which is fine for one
walk and jittery for a chase that re-plans four times a second. With authored nodes, route with
the graph and keep the navmesh as the fallback:

```lua
:UsePathfinder(VluxyAI.Pathfinders.Hybrid.new({
	Graph = graph,
	Local = VluxyAI.Pathfinders.Navmesh.new(),
	Prefer = "Graph",   -- the graph for every route; the navmesh only when the graph has none
	RefineEnds = false, -- end legs walked straight: the graph picks its end nodes on a clear line
}))
:UseDirect(VluxyAI.Pathfinders.Straight.new()) -- and a target in plain view is walked at straight
```

## Lead a moving target

A chase that plans to where the player is arrives where the player was. The
[Navigator](/api/Navigator) measures how fast the `MoveTo` target moves and plans `Lead` seconds
ahead of it (half a second by default, capped at `LeadMax` studs, and not within
`LeadMinDistance` so an agent at arms' length does not overshoot); a point ahead that cannot be
reached falls back to the target itself. [Navmesh](/api/Navmesh) shaves off waypoints that turn
less than `SimplifyAngle` degrees (8 by default), so a curve becomes a few long legs instead of a
stop at every 2-stud waypoint. Both come from the original VluxyAI pathfinding, where they were
tuned by play-testing. `agent.Navigator:GetRemainingDistance()` is the walk left along the path.

## Transitions before Update

Transitions are checked first, in order, and the first true one wins. `Update` only runs when none
fired. Put the important interrupts (attack range, lost the target) at the top of the list.

## Memory lives in the blackboard

[Sight](/api/Sight) keeps `SeenPosition` for `Memory` seconds after losing the target, then clears
it. A chase state that transitions out on `SeenPosition == nil` gets "run to where I last saw
them, then give up" for free. Tune `Memory` per enemy; it is the difference between a stalker and a
bloodhound.

## Distance is not sight

`Proximity` writes `NearestDistance` through walls; `Sight` writes `SeenDistance` only with a clear
line. Use the first to decide an attack that does not care about walls (a scream, a shockwave) and
the second for one that does.

## Utility for targets, transitions for modes

When a state must choose one of several things, score them with [Utility.Best](/api/Utility#Best)
and give the current choice a bonus consideration so the choice is sticky. Do not score the
decision to attack or flee; write it as a transition, where you can read it.

## Watch the tick

The default tick is `0.1` seconds. A fast enemy that must freeze the instant it is seen (the
Weeping Angel) runs at `0.05`. A slow patroller is fine at `0.25`. Senses cost raycasts per tick, so
the tick is your budget knob.

## Give the navmesh a second

`PathfindingService` rebuilds its mesh lazily after parts are added. An agent spawned in the same
frame as its map will fail its first plan; the navigator retries on its cadence, so this is harmless,
but the playground waits a second before spawning so the first path is clean.

## Straight legs walk off ledges only if you let them

[Straight](/api/Straight) checks for floor every few studs and projects its endpoints onto it.
With `FloorCheck` off it is just a sweep, which is fine on a flat arena and wrong on a rooftop.

## A kill is the finishing blow

`Attack.State` with `Kill = "Live"` still does plain damage on every hit that does not finish
the victim; the live kill only plays for the blow that would bring their health to zero. If you
want every hit to be a kill, make `Damage` at least the victim's health.

## `return nil` under strict

Under `--!strict` with the brain annotated as `VluxyAI.Brain`, an `Update` must end with
`return nil` when it stays put: the checker wants every path to return a `string?`. A state
with only transitions needs no `Update` at all, which is the shorter way to say "stay".

## Debug views are cheap

[StateLabel](/api/StateLabel) and [PathVisual](/api/PathVisual) exist so you never have to print.
Make them right after `Build()` and destroy them with the agent.
