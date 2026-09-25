---
sidebar_position: 4
---

# Examples

The repository ships a playground: a seeded maze (recursive backtracking, then a pass that
removes some walls so it has loops) and four example AIs on standard R15 rigs. Clone the repo,
run `wally install`, serve `test-place.project.json` with Rojo and press Play. Each rig is built
at runtime, animated through the package's [Animator](/api/NPCAnimator) by a small locomotion
helper that blends idle and walk from the rig's real speed, and carries a label with its state,
its navigator status and a few blackboard values, plus the path it is following.

Colour says which enemy it is. Transparency says how it moves: solid rigs walk with the Humanoid
mover; the see-through one is pivoted by the CFrame mover and its Humanoid does no work.

| Enemy | Look | What it does | Shows |
|---|---|---|---|
| **Stalker** | red, solid | Patrols, investigates noises, hunts on sight with memory, searches around the last sighting, attacks with a clear line | Sight and Hearing, blackboard memory, prioritised transitions, a state walking a list of points, Ladder(Straight, Navmesh) |
| **Hunter** | orange, solid | Roams between nodes chosen by score, chases the player chosen by score, sprints until a stamina sense says it must rest | Utility for destinations and targets, a custom sense in a dozen lines, Proximity for reach |
| **Guardian** | blue, solid | Wanders its territory, raises the alarm on an intruder, chases on a leash, returns home | Two agents cooperating through the game's noise signal, a brain built around a place, leash logic as transitions |
| **Weeping Angel** | near black, see-through | Dormant until it spots you; moves only while nobody looks; strikes when close and unwatched | The Watched sense from the players' side, the CFrame mover halting an anchored rig |

The client half lives in `examples/Client/`: one [Replica](/api/Replica) per rig in mirror mode,
per-enemy visuals (a glow while hunting, a shout while the Guardian raises the alarm, a creeping
vignette while the Weeping Angel advances unseen), and the two kill presentations. The Stalker finishes
you with a live kill you watch; the Weeping Angel with a black-box kill that cuts to black. See
[Client visuals and kills](ClientVisuals).

The enemy modules live in `examples/Server/Enemies/`. Each is a function from a rig and a shared context
to a built agent, with the brain table at the top of the file. They are short on purpose: read them
as the reference for how the API is meant to look.

## Noise

Player jumps, the orange pad on the map and the Guardian's alarm all fire one [Signal](/api/Signal)
that the Stalker's [Hearing](/api/Hearing) sense listens to. That is the whole integration: the
game owns the signal, the sense subscribes, and an agent may fire it too. Fire it from a door
slam, a dropped object, a gunshot.

## The Weeping Angel rule

Dormant until it sees someone. Then it advances only while `IsWatched` is false, freezes the tick
anyone looks, strikes when close, and goes dormant again once Sight's memory of the last position
expires. The "looking" check runs from the players' side: the observer's head facing, a cone, and a
line of sight to the rig.
