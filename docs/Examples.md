---
sidebar_position: 4
---

# Examples

The repository ships a playground: a seeded maze (recursive backtracking, then a pass that
removes some walls so it has loops) and four example AIs on standard R15 rigs. Clone the repo,
run `wally install`, serve `test-place.project.json` with Rojo and press Play. Each rig is built
at runtime by [Rig](/api/Rig), animated by [Locomotion](/api/Locomotion), and carries a label with its state,
its navigator status and a few blackboard values, plus the path it is following.

The maze has three green safe rooms (the spawn and two corners) that no enemy enters while their
wall switch is on, and doorways (one locked) that enemies force open on the way through and players
open or close with a prompt, and it is handed to the enemies as a [Graph](/api/Graph) of cell
centres, so the three walking enemies plan with a [Hybrid](/api/Hybrid): the graph for long routes,
the navmesh for the last stretch, and a straight walk whenever the way is clear.

The enemies know someone is in the maze but not where. Every cell is a point on one shared
[Interest](/api/Interest) map, built in the playground with `AddAll` and weighted noise kinds
(`Clues`), warmed by each enemy's [Clues](/api/Clues) sense; a noise, a sighting or the way a lost
player was heading warms the cells near it, and the Stalker and Hunter roam it
([States.Roam](/api/States#Roam)), so one enemy spotting you draws the others without any of them
being told where you are. Walking makes a faint footstep noise and sprinting a louder one, and all
three walkers notice you within 10 studs whichever way they face.

Colour says which enemy it is. Transparency says how it moves: solid rigs walk with the Humanoid
mover; the see-through one is pivoted by the CFrame mover and its Humanoid does no work.

| Enemy | Look | What it does | Shows |
|---|---|---|---|
| **Stalker** | red, solid | Searches the maze for you by the shared clue map, investigates every noise (footsteps included), hunts on sight toward where you were heading, searches around where it lost you, stares at a safe room and moves on | Sight and Hearing, blackboard memory, prioritised transitions, a state walking a list of points, Hybrid planning with a direct walk |
| **Hunter** | orange, solid | Searches the clue map, investigates noises, chases the player chosen by score, sprints until a stamina sense says it must rest | Utility for destinations and targets, a custom sense in a dozen lines, Proximity for reach |
| **Guardian** | blue, solid | Wanders its territory, checks noises on its ground, raises the alarm on an intruder, chases on a leash, returns home | Two agents cooperating through the game's noise signal, a brain built around a place, leash logic as transitions |
| **Weeping Angel** | near black, see-through | Dormant until it spots you; moves only while nobody looks; strikes when close and unwatched; burrows through the floor to rise near you when it has sat somewhere dead too long | The Watched sense from the players' side, the CFrame mover halting an anchored rig, a custom sense that picks an unseen spot with [Perception.SeenByAnyone](/api/Perception#SeenByAnyone) |

The client half lives in `examples/Client/`: one [Replica](/api/Replica) per rig in mirror mode,
per-enemy visuals (a glow while hunting, a shout while the Guardian raises the alarm, a creeping
vignette while the Weeping Angel advances unseen), sound (footsteps, a stinger per enemy, a
heartbeat while a hunting enemy is near), and the two kill presentations. The Stalker finishes
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

For sounds the world is already playing there is nothing to fire: tag the `Sound` with
`CollectionService` and give the agent a [Sounds](/api/Sounds) sense. It judges every tagged,
playing, 3D sound each tick by the volume it would have at the agent (the sound's own `Volume`
and roll-off), times an `VLUXYAI_SOUND/Multiplier` attribute on the sound when you want it to matter more or less,
and writes the loudest as `HeardSound` with its position and distance. A state investigates it
the same way the Stalker investigates a noise, reading `HeardSoundPosition` and `HeardSoundAt`.

```lua
CollectionService:AddTag(radio.Sound, "VLUXYAI_SOUND")
radio.Sound:SetAttribute("VLUXYAI_SOUND/Multiplier", 2)

:AddSense(VluxyAI.Senses.Sounds.new({ Threshold = 0.1 }))
```

## The Weeping Angel rule

Dormant until it sees someone. Then it advances only while `IsWatched` is false, freezes the tick
anyone looks, strikes when close, and goes dormant again once Sight's memory of the last position
expires. The "looking" check runs from the players' side: the observer's head facing, a cone, and a
line of sight to the rig.
