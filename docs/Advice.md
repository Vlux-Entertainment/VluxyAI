---
sidebar_position: 5
---

# Advice

Things learned building the examples, in no particular order.

## Call MoveTo every tick

A chase state should call `agent:MoveTo(agent.Blackboard.SeenPosition)` in `Update`, every tick.
The [Navigator](/api/Navigator) decides when that turns into a plan; you do not. Calling it once
in `Enter` works for a fixed point, and the navigator still retries if the mover gets stuck, but a
moving target needs the fresh position.

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
