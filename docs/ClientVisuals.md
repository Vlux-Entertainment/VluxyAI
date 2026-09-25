---
sidebar_position: 7
---

# Client visuals and kills

The server owns the truth: where an enemy is, what state it is in, whether it killed you. The
client owns how that looks. The package gives each side one piece and leaves the remote between
them to you, because every game shapes its remotes differently.

## The two pieces

**[Broadcaster](/api/Broadcaster)** watches an agent on the server. It fires `StateChanged` on
every state change, `EventSent` for everything the agent [emits](/api/Agent#Emit), and, at a rate
you choose, `PositionChanged` with the rig's pivot position and a yaw. `Snapshot()` is for a
player who just joined. Make the broadcaster before `agent:Start()` so the first state is relayed.

**[Replica](/api/Replica)** lives on the client with a rig and a table of client states, the
**Visuals**. `SetState(name)` runs the old state's `Exit` and the new one's `Enter`;
`Receive(name, payload)` hands an event to your `On(name, ...)` handlers; `SetPosition` gives it
somewhere to smooth toward. Visuals have the same `Enter`, `Update`, `Exit` shape as a brain, with
the replica in place of the agent. That is your custom client logic: a highlight while it hunts,
a heartbeat sound while it advances, a camera shake on a scream.

```lua
-- server
local broadcaster = VluxyAI.Sync.Broadcaster.new(agent, { PositionRate = 0 })
broadcaster.StateChanged:Connect(function(state)
	syncRemote:FireAllClients({ Kind = "State", Id = model, State = state })
end)
broadcaster.EventSent:Connect(function(name, payload)
	syncRemote:FireAllClients({ Kind = "Event", Id = model, Event = name, Payload = payload })
end)

-- client
local replica = VluxyAI.Sync.Replica.new({
	Entity = model,
	Visuals = {
		Hunt = {
			Enter = function(replica) replica.Data.Glow.Enabled = true end,
			Exit = function(replica) replica.Data.Glow.Enabled = false end,
		},
	},
})
syncRemote.OnClientEvent:Connect(function(message)
	if message.Kind == "State" then
		replica:SetState(message.State)
	elseif message.Kind == "Event" then
		replica:Receive(message.Event, message.Payload)
	end
end)
```

## Mirror or puppet

**Mirror** is the simple mode and what the playground uses. The server rig is visible and
replicates through Roblox as any NPC does. The replica only runs visuals on it. Send states and
events; leave `PositionRate` at `0`.

**Puppet** is the mode from the design plan: the server keeps a logical position, usually with the
[CFrame mover](/api/CFrameMover) on an invisible collider, and each client draws its own rig.
Make the replica with `Puppet = true`, stream positions at ten or so a second over an unreliable
remote, and the replica smooths its rig toward each sample so the rate never shows. Kills are
still decided on the server from the server position; the client draws the enemy slightly behind,
and a hard cut hides the gap.

## Kills

[Kill](/api/Kill) gives an agent two ways to finish a character, both decided on the server and
both announced as a `"Kill"` event with `{ Kind, Victim, Duration }`:

- **Live**: `VluxyAI.Combat.Kill.Live(agent, character, { KillerAnimation, VictimAnimation })`
  takes the victim's root for the server, holds them in a pose next to the killer while both rigs
  play their animation, and kills them when it ends. Everyone sees it.
- **Black box**: `VluxyAI.Combat.Kill.BlackBox(agent, character)` announces at once and kills
  after a short delay. The client cuts to black on the event and the death happens behind it.

Both return a handle with `Finished` and `Cancel`. On the client:

```lua
replica:On("Kill", function(event)
	if event.Victim ~= Players.LocalPlayer.Character then
		return
	end
	if event.Kind == "BlackBox" then
		showBlackScreen(event.Duration + 1)
	else
		lockCameraOn(replica.Entity, event.Duration)
	end
end)
```

The playground's Stalker finishes you with a live kill and its Weeping Angel with a black-box one;
`examples/Client/Kills.luau` is the presentation.

## Ids over the wire

The playground sends the rig itself as the id, which is fine while the rig has replicated to
every client (the test place has streaming off and spawns before anyone joins). With
`StreamingEnabled`, an instance that has not streamed in arrives as `nil`; send a string key
instead (a `SyncId` attribute, a name) and resolve the rig lazily on the client.

## Anything else

`agent:Emit("Scream")` from a state, `replica:On("Scream", ...)` on the client. Emit is the
general channel; kills are just its first customer.
