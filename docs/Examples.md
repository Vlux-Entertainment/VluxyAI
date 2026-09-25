---
sidebar_position: 4
---

# Examples

The repository ships a playground: a seeded maze (recursive backtracking, then a pass that
removes some walls so it has loops) and six example AIs on standard R15 rigs,
each showing one feature. Clone the repo, run `wally install`, serve `test-place.project.json`
with Rojo and press Play. Each rig is built at runtime, animated through the package's
[Animator](/api/NPCAnimator) by a small locomotion helper that blends idle and walk from the
rig's real speed, and carries a label with its state, its navigator status and a few blackboard
values, plus the path it is following.

Colour says which enemy it is. Transparency says how it moves: solid rigs walk with the Humanoid
mover; see-through rigs are pivoted by the CFrame mover and their Humanoid does no work.

| Enemy | Look | Shows | Stack |
|---|---|---|---|
| **Wanderer** | green, solid | The smallest useful AI: pick a point, walk, wait, repeat | Humanoid preset (its senses unused) |
| **Stalker** | red, solid | Sight writing the blackboard, transitions choosing the mode, a Ladder trying a straight line before the navmesh | Ladder(Straight, Navmesh) + Humanoid + Sight |
| **Patroller** | yellow, solid | Hearing with a noise signal the game owns, and a blackboard memory the states act on | Navmesh + Humanoid + Hearing |
| **Hunter** | orange, solid | Utility scoring choosing *which* player while transitions still choose the mode | Ladder + Humanoid + Sight + Proximity |
| **Ghost** | pale blue, 60% see-through | The CFrame mover on ordinary navmesh paths, floating | Navmesh + CFrame + Sight |
| **Watcher** | near black, 35% see-through | The Watched sense: only moves while nobody is looking, never patrols | Ladder + CFrame + Sight + Watched |

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
line of sight to the rig.
