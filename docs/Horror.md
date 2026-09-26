---
sidebar_position: 5
---

# Building a horror enemy

VluxyAI is a general AI library, and everything on this page is general too. But horror is
where a monster's perception, patience and pacing carry the whole game, so the pieces built for
it are gathered here in the order a game tends to need them.

## The loop in twenty lines

Patrol, hear something, go and look, spot the player, hunt, lose them, search, give up. Written
with [When](/api/When), [States](/api/States) and interrupts, the brain is the list of those words:

```lua
local States, When = VluxyAI.States, VluxyAI.When

local Brain: VluxyAI.Brain = {
	Initial = "Patrol",
	Interrupts = {
		{ To = "Hunt", When = When.Has("SeenTarget"), Except = { "Hunt", "Attack" } },
		{ To = "Investigate", When = When.New("HeardAt"), Except = { "Hunt", "Attack" } },
	},
	States = {
		Patrol = States.Patrol({ Points = "Nodes", Speed = 10 }),
		Investigate = States.Investigate({ Target = "HeardPosition", Then = "Search" }),
		Hunt = {
			Enter = function(agent) agent:SetSpeed(15) end,
			Transitions = {
				{ To = "Attack", When = When.Below("SeenDistance", 4) },
				{ To = "Search", When = When.Missing("SeenPosition") },
			},
			Update = function(agent)
				agent.Data.LastSeen = agent.Blackboard.SeenPosition
				agent:MoveTo(agent.Blackboard.SeenPosition)
				return nil
			end,
		},
		Search = States.Search({ Around = "LastSeen", Radius = 12, Duration = 14, Then = "Patrol" }),
		Attack = VluxyAI.Combat.Attack.State({ Damage = 34, Cooldown = 1.8, TargetKey = "SeenTarget", Then = "Hunt", Kill = "Live" }),
	},
}
```

An interrupt is a transition that applies from every state, checked before the state's own.
`When.New("HeardAt")` is true once per noise: it acknowledges the value as it fires, so the same
noise is not investigated every tick. The ready-made states keep their scratch in `agent.Data`
and skip a point the navigator cannot reach.

## Seeing in the dark

[Sight](/api/Sight) is binary by default: in the cone with a clear ray is seen. Three options
turn it into a horror sense.

- **Darkness.** `Visibility` is a function of the agent and a target root that scales the sight
  range for that target. Tag the lights that matter with `AI_LIGHT` and pass
  [Perception.LightAt](/api/Perception#LightAt): a player in the dark is invisible until a light
  finds them, and a lit flashlight gives them away.
- **Glass.** `SeeThrough = VluxyAI.Perception.Transparent()` lets the ray look past transparent
  parts. Without it a window blocks sight like a wall.
- **Close range.** `NoticeRadius` is a distance within which a target is seen whichever way the
  enemy faces and however dark it is, as long as there is a clear line (`NoticeThroughWalls`
  drops that too). Five studs stops a player from simply walking up behind a monster.
- **Hiding spots.** Set the `AI_HIDDEN` attribute to `true` on a character while they are in a
  locker or under a bed, and [Perception.AliveRoots](/api/Perception#AliveRoots) leaves them
  out. That is the default target list of every sense, so one flag hides a player from Sight,
  Proximity and Watched together.

```lua
:AddSense(VluxyAI.Senses.Sight.new({
	Range = 40,
	Visibility = function(_, root) return VluxyAI.Perception.LightAt(root.Position, 0.1) end,
	SeeThrough = VluxyAI.Perception.Transparent(),
}))
```

## Searching like a creature

An enemy never reads a player's position. It knows what its senses wrote and nothing else, so
the question is what it does once it has lost you. Three pieces answer it.

- **Prediction.** Sight keeps `SeenVelocity` and carries `PredictedPosition` forward for up to
  `Predict` seconds after losing you: not where you were, where you were going. Search there
  first.
- **Points of interest.** An [Interest](/api/Interest) map holds the places a player would
  plausibly be, each with a strength: lockers, doorways, the generator. The game raises a point
  when something happens near it, and it drifts back. `Best` scores strength, distance and how
  long since this enemy looked there, so a group spreads out and nobody checks the same locker
  twice running.
- **Roaming.** [States.Roam](/api/States#Roam) walks the best point, lingers, marks it visited
  and asks again, until nothing is worth a look or its time is up.

```lua
local interest = VluxyAI.Interest.new()
for _, locker in CollectionService:GetTagged("Locker") do
	interest:Add(locker, { Position = locker.Position, Tags = { "Hiding" } })
end
noises:Connect(function(position, loudness)
	interest:BumpNear(position, 15, loudness or 1)
end)

Search = States.Search({ Around = "PredictedPosition", Duration = 8, Then = "Roam" }),
Roam = States.Roam({ Interest = interest, Duration = 40, Then = "Patrol" }),
```

That is the shape of a creature that has to look: a guess at where you went, then the likely
places in order of likelihood and nearness.

## A detection meter

A stealth enemy does not hunt the instant a player crosses its cone. [Awareness](/api/Awareness)
reads what Sight, Hearing and Sounds wrote and keeps one meter: it rises while a target is in
view, jumps on a noise, drains in silence, and passes through `Suspicious` on the way to
`Alerted`. It also keeps one `LastKnownPosition`, whichever sense supplied it last, so the brain
has a single place to go and look.

```lua
:AddSense(VluxyAI.Senses.Sight.new({ Range = 40 }))
:AddSense(VluxyAI.Senses.Hearing.new(noises))
:AddSense(VluxyAI.Senses.Awareness.new({ Rise = 0.8, Fall = 0.2 }))

Interrupts = {
	{ To = "Hunt", When = When.Equals("AwarenessLevel", "Alerted"), Except = { "Hunt", "Attack" } },
	{ To = "Investigate", When = When.Equals("AwarenessLevel", "Suspicious"), Except = { "Hunt", "Attack", "Investigate" } },
},
Investigate = States.Investigate({ Target = "LastKnownPosition", Then = "Patrol" }),
```

Add it after the senses it reads.

## Sound

Two senses hear. [Hearing](/api/Hearing) is for events your code fires on a signal: a jump, a
door slam, a gunshot. [Sounds](/api/Sounds) is for the `Sound` instances already playing in the
world: tag one with `AI_SOUND`, keep it on a part so it is 3D, and every agent judges it by the
volume it would have at their position, using the sound's own roll-off. An `AI_SOUND/Multiplier`
attribute makes a sound matter more or less to the AI without changing what players hear.

Both take `Occlusion`, a per-wall multiplier: with `Occlusion = 0.5` a noise is half as loud
through one wall and a quarter through two. Rays are only cast for noises that would have been
heard in the open.

## Doors

One line gives every enemy working doors:

```lua
:OnStep("Door", VluxyAI.Doors.Step())
```

[Doors.Step](/api/Doors#Step) talks to your door script through three attributes on the door:
it sets `AI_DOOR/Open` to `true` to open it, waits `AI_DOOR/OpenTime` seconds for the swing, and
refuses the door while `AI_DOOR/Locked` is `true`. Your door script listens to `AI_DOOR/Open`,
swings the door, and sets it back to `false` when it closes. Set it yourself when a player opens
the door, and an enemy that reaches an open door walks through without stopping. An open door
should turn off `CanQuery` as well as `CanCollide`, or rays still hit it: the enemy would not see
through the doorway, nor walk straight through it. A door system with its own API gets a
[DoorDriver](/api/Types#DoorDriver) instead: `IsOpen`, `Open`, and optionally `IsLocked` and
`OpenTime`, passed as `Doors.Step(driver)`.

### Doors enemies walk through

An enemy stuck on a half-open door is the classic failure, so the playground never lets a door
touch an enemy: rigs and doors sit in collision groups that pass through each other, and the
door's `PathfindingModifier` is the only thing that decides where an enemy may go, with
`PassThrough` on while the door is unlocked and off while it is locked. The enemy then forces a
door open on its way through rather than stopping at it:

```lua
:UseDirect(VluxyAI.Pathfinders.Straight.new({
	Ignore = VluxyAI.Doors.IgnoreUnlocked(VluxyAI.Pathfinders.Straight.DefaultIgnore),
}))
:OnStep("Door", VluxyAI.Doors.Step(nil, { WalkThrough = true }))
:AddSense(VluxyAI.Doors.Opener())
```

`WalkThrough` opens the door at the labelled step without stopping. [Doors.Opener](/api/Doors#Opener)
opens a door the enemy walks up to and faces, for a direct walk that has no labelled step, and
writes `NearDoor`. `IgnoreUnlocked` lets the straight-line check see through doors the enemy can
open, so a closed door does not force a plan. The door still swings for the players, who still
collide with it; `examples/Server/DoorScript.luau` is a complete door with a hinge swing and an
Open/Close prompt.

### Authoring

A door is a labelled step, and there are two ways to author one. Both reach the same handler.

- **Navmesh.** Put a `PathfindingLink` across the doorway (two attachments, one on each side)
  with `Label = "Door"`, or a `PathfindingModifier` with `PassThrough` and the label. Roblox
  plans through it and marks the crossing waypoint. A thin door can fall between two
  waypoints, so also put an invisible, non-colliding, non-queryable part a few studs deep across
  the doorway with a `PathfindingModifier` labelled `"Door"`: every path through it then has a
  labelled waypoint. [Navmesh](/api/Navmesh) collapses the run into one step and moves it to the
  waypoint just before the doorway (`StopBefore`), so the agent stops outside the closed door
  rather than walking into it. The step arrives without an `Instance`; tag the door `AI_DOOR`
  (the default `Tag` of `Doors.Step`) and the nearest tagged instance is looked up for it. A
  door locked for good is better as a modifier without `PassThrough`: the navmesh then plans
  around it and nobody has to be refused. No nodes to author.
- **Graph.** A link written as `{ To = 7, Label = "Door", Instance = door }`, or in a place a
  node part in the doorway with `Label = "Door"` and an Instance attribute `Instance` pointing
  at the door, linked to the nodes on either side by Instance attributes. The navmesh never crosses
  the door, so a closed door being solid is simply right, and links can be one-way or closed.

Writing the handler yourself looks like this:

```lua
:OnStep("Door", function(agent, step)
	local door = step.Instance
	if door:GetAttribute("Locked") then
		return false, 15 -- could not; plan around it for fifteen seconds
	end
	Doors.Open(door)
	task.wait(0.4)
	return true
end, { Tag = "AI_DOOR" })
```

The navigator stops the mover at the step, reports `Interacting`, runs the handler, and walks
the rest of the path when it returns. A handler that returns `false` gives the path up as
`Failed` and tells the pathfinder to `Close` the step: a [Graph](/api/Graph) closes the link,
a [Navmesh](/api/Navmesh) refuses paths through that crossing, and a [Ladder](/api/Ladder) or
[Hybrid](/api/Hybrid) passes it on. The next plan goes another way, or fails, and the brain
does what it does on a failed path. A monster that breaks doors is a handler that plays an
animation, unlocks the door and returns `true`.

## Safe rooms

A safe room is a part tagged `AI_SAFE`, the size of the room. While its `AI_SAFE/Enabled`
attribute is not `false`, no agent goes in, whatever its brain wants:

- [Navmesh](/api/Navmesh) prices the area at `math.huge`, so it is never planned through.
- [Straight](/api/Straight) refuses a line that crosses it, so a direct walk never cuts through.
- [Graph](/api/Graph) skips nodes in it when given `Avoid = VluxyAI.SafeAreas.Contains`.
- A player standing in it is left out of [Perception.AliveRoots](/api/Perception#AliveRoots), so
  no sense targets them. A chase stops at the door and the monster goes back to searching.
- After `VluxyAI.SafeAreas.Setup({ RigGroup = "Monsters" })` on the server, the part is solid to
  that collision group and to nothing else, so players walk through it and rigs cannot.

Set `AI_SAFE/Enabled` to `false` to switch a room off (a generator failing, a timer running out)
and back to `true` to make it safe again; every layer follows the attribute. The playground's
three green rooms have a switch on the wall.

[Sight](/api/Sight) forgets a position remembered inside a safe area and never predicts into one,
and [Hearing](/api/Hearing) ignores noises made inside one, so nothing follows a player in. For
the monster to react instead of simply losing interest, add [SafeWatch](/api/SafeWatch): it writes
`SafeTarget` and `SafePosition` for a player standing in a safe area that it can see, or that it
was chasing a moment ago (then from anywhere, with `SafeWasChased = true` for a couple of
seconds, and Sight's memory of them wiped so nothing is left to follow), and
[States.Stare](/api/States#Stare) is the state that stops and looks at them for a while before
moving on. SafeWatch also moves its agent out of a room switched on around it, to the nearest of
the `Spots` you give it (a [Graph](/api/Graph) works) that is outside every safe area.

```lua
:AddSense(VluxyAI.Senses.SafeWatch.new({ Spots = graph }))

-- in the brain
Stare = VluxyAI.States.Stare({ Target = "SafePosition", Duration = 4, Cooldown = 20, Then = "Patrol" }),
{
	To = "Stare",
	When = When.All(
		When.Has("SafeTarget"),
		When.Any(When.Equals("SafeWasChased", true), When.Timer("States.StareCooldown"))
	),
},
```

## Voice lines

[Voice](/api/Voice) gives a monster random lines by state: groans while it patrols, growls while
it hunts, a whisper while it creeps up. Add it as a sense; it speaks every `Interval` seconds in
a state with lines, sometimes as it enters one (`OnEnter`, a chance or a table of chances by
state), never the same line twice in a row and never over itself.

```lua
:AddSense(VluxyAI.Voice.new({
	Lines = {
		Patrol = { 9113636490, 9113636491 },
		Hunt = { 105926319962443 },
		Stare = { 8315677038 }, -- "I see you"
	},
	Interval = { 6, 14 },
	OnEnter = { Stare = 1, Hunt = 0.7, ["*"] = 0.2 },
}))
```

The line plays on the server from the rig, so every player hears the same line from the same
place, and it is announced as a `"Voice"` event for subtitles. Pass `Play` to play it your own
way instead.

## Hunting for someone they cannot see

An enemy that knows a player is somewhere, but not where, is a shared [Interest](/api/Interest)
map and three pieces:

```lua
local clues = VluxyAI.Interest.new({
	Decay = 0.25, -- clues cool over a minute or so
	Visited = 40, -- an enemy leaves a spot it just checked alone this long
	Clues = { -- what each kind of noise is worth; a footstep is not a clue
		Door = { Radius = 28, Heat = 5 },
		Running = { Radius = 24, Heat = 1.5 },
		Footstep = { Radius = 0, Heat = 0 },
	},
})
clues:AddAll(roomCentres, { Skip = VluxyAI.SafeAreas.Contains })
noises:Connect(function(position, loudness, kind)
	clues:Heard(position, loudness, kind)
end)

-- per enemy
:AddSense(VluxyAI.Senses.Clues.new(clues)) -- a sighting warms the map for everyone
:SetData({ Interest = clues })
Search = VluxyAI.States.Roam({ Interest = "Interest", Stray = 0.2 }), -- the warmest spot, now and then any
```

[PlayerNoise](/api/PlayerNoise) turns how fast players move into those noises, and
[Hideout](/api/Hideout) with [States.Burrow](/api/States#Burrow) gives an enemy that vanishes
somewhere to come back: the most suspicious spot nobody can see.

## Scares that do not kill

`Kill = "Scare"` on the attack state makes every blow a grab: the same hold and animations as a
live kill, `Damage` dealt as the victim is let go, no death, announced as `"Scare"` so the
client can do its jump scare. [Kill.Scare](/api/Kill#Scare) is the same thing for a state of
your own. A game that keeps health somewhere other than the Humanoid gives the attack state a
`Health` provider with `Get`, `Damage` and optionally `Kill`.

## Standing still, staring, vanishing

A statue should not breathe while it is watched: `VluxyAI.Locomotion.Freeze(agent, true)` holds
every animation in its pose and `false` lets them run again. The playground's Weeping Angel calls
it every tick from a two-line sense with `IsWatched` from [Watched](/api/Watched).


`agent:SetSpeed(speed, seconds)` ramps to a speed over time, so a lunge builds and a stop
settles instead of snapping.

- `agent:LookAt(position)` turns the body toward a point while it stands. `nil` stops.
- `agent:Pause()` freezes the agent for a cutscene or a jumpscare: no ticks, no movement,
  timers on hold. `Resume` picks up where it left off and re-plans to its target.
- `agent:Teleport(position)` puts it somewhere else at once. Ask
  [Perception.SeenByAnyone](/api/Perception#SeenByAnyone) first, so a stalker only ever
  vanishes and reappears off screen.

## Where the player is really looking

The [Watched](/api/Watched) sense judges "looking" by the head's facing, which on a default
rig is the walk direction. For a Weeping Angel or a "do not look at it" monster, replicate the
camera with [Look](/api/Look): one RemoteEvent, `Look.Report` on the client, `Look.Receive` on
the server, and its `Eye` handed to Watched. The server places the camera's rotation at the
player's head, so a camera peeking over a wall does not count.

## More than one monster

[Claims](/api/Claims) is a shared "who is on what" table: an enemy claims a player before
chasing, and the others score that player low. [Director](/api/Director) is the game's hand on
the group: a tension meter it raises on kills and near misses that drains by itself, a
difficulty number, and a blackboard every enemy in the group can read and write through
`director:Sense()`. A state scales itself with one line:

```lua
agent:SetSpeed(director:Scale(BASE_SPEED, 0.5)) -- up to half again at full tension
```

Every built-in sense has `Configure`, so the director can widen a cone or shorten a memory
mid-round without rebuilding the agent.

Bodies are the other half. [Neighbours](/api/Neighbours) is one instance shared by a group:
every enemy that adds it sees the others as `NearbyAgents`, `NearestAgentDistance`, `Crowding`
and `SeparationDirection`. Two options turn the knowledge into behaviour, and both are off
unless asked for, because a swarm should crowd:

```lua
local crowd = VluxyAI.Senses.Neighbours.new({
	Range = 10,
	Slow = { Distance = 5, Min = 0.5 },  -- ease to half speed as the nearest neighbour closes in
	Avoid = { Radius = 4 },              -- push the mover sideways within four studs
})
:AddSense(crowd) -- on each enemy in the group
```

`Slow` goes through `agent:SetSpeedScale`, a multiplier kept on top of whatever speed a state
asks for. `Avoid` goes through the mover's `SetNudge`, which aims at every step but the last
plus the offset. Two groups that should ignore each other use two instances; `Filter` excludes
one kind from another; one enemy opts out of a shared group for itself with
`agent.Data.Neighbours = { Avoid = false }`. A `Deadband` on `Avoid` stops the nudge
flickering when neighbours keep moving.

Enemies also hear each other. Give a mover `Noise = { Signal = noises, Interval = 0.5 }` and it
fires the same signal the [Hearing](/api/Hearing) sense listens to as it walks, so a pack
converges on a fight without any wiring in your states.

The player's ears are the client's business: [Footsteps](/api/Footsteps) on the replica's rig
plays a step every few studs of measured movement, locally, with no message from the server.

## Seeing what it senses

[SenseVisual](/api/SenseVisual) draws the sight cone (green while something is seen), the
hearing and proximity circles, and markers at the last seen, predicted and last known
positions, so ranges are tuned by eye. `Builder:SetStrictBlackboard()` makes the agent warn
when a state reads a key that looks like a typo of one a sense wrote, which is most of what a
typed blackboard would have caught, without the type plumbing.

## Keeping it cheap

Sight costs a ray per target per tick. Wrap it in [Throttle](/api/Throttle) to run it every
0.3 seconds while the brain keeps its 0.1 tick, and give each sense a `Prefix` when an enemy
needs two of the same kind (peripheral and focused vision, say).
