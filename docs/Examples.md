---
sidebar_position: 4
---

# Examples

The repository ships a playground: an ASCII-grid map and six cylinder AIs, each showing one
feature. Clone the repo, run `wally install`, serve `test-place.project.json` with Rojo and press
Play. Each cylinder carries a label with its state, its navigator status and a few blackboard
values, and draws the path it is following.

| Cylinder | Shows | Stack |
|---|---|---|
| **Wanderer** | The smallest useful AI: pick a point, walk, wait, repeat | Humanoid preset (its senses unused) |
| **Stalker** | Sight writing the blackboard, transitions choosing the mode, a Ladder trying a straight line before the navmesh | Ladder(Straight, Navmesh) + Humanoid + Sight |
| **Patroller** | Hearing with a noise signal the game owns, and a blackboard memory the states act on | Navmesh + Humanoid + Hearing |
| **Hunter** | Utility scoring choosing *which* player while transitions still choose the mode | Ladder + Humanoid + Sight + Proximity |
| **Ghost** | No Humanoid at all: the CFrame mover on ordinary navmesh paths | Navmesh + CFrame + Sight |
| **Watcher** | The Watched sense: only moves while nobody is looking, never patrols | Ladder + CFrame + Sight + Watched |

The enemy modules live in `examples/Enemies/`. Each is a function from a rig and a shared context
to a built agent, with the brain table at the top of the file. They are short on purpose: read them
as the reference for how the API is meant to look.

## Noise

Player jumps and the orange pad on the map fire a [Signal](/api/Signal) that the Patroller's
[Hearing](/api/Hearing) sense listens to. That is the whole integration: the game owns the signal,
the sense subscribes. Fire it from a door slam, a dropped object, a gunshot.

## The Watcher rule

Dormant until it sees someone. Then it advances only while `IsWatched` is false, freezes the tick
anyone looks, strikes when close, and goes dormant again once Sight's memory of the last position
expires. The "looking" check runs from the players' side: the observer's head facing, a cone, and a
line of sight to the cylinder.
