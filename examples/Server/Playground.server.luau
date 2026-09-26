--!strict

--[[
	The playground. Builds the map, wires the noise signal to player jumps, sprinting, players opening doors and the noise pad,
	spawns one R15 rig per example enemy with animations, a debug label and a path visual, and
	starts them. Colour says which enemy it is; transparency says how it moves: solid rigs walk
	with the Humanoid mover, the see-through one is pivoted by the CFrame mover. The Guardian's
	alarm goes through the same noise signal as player jumps, so the Stalker answers it.

	Every agent gets a Broadcaster whose state changes and events go out over one RemoteEvent,
	VluxyAISync, in mirror mode: the rigs replicate on their own, the clients add visuals and
	present kills. A client that says it is ready gets a snapshot per agent.
	Serve `test-place.project.json` and press Play.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Context = require(script.Parent.Context)
local DoorScript = require(script.Parent.DoorScript)
local Map = require(script.Parent.Map)
local VluxyAI = require(ReplicatedStorage.Packages.VluxyAI)

local Enemies = script.Parent.Enemies

------------------------------------------------------------------------------------------------------------------------

type Entry = {
	Slot: string,
	Name: string,
	Module: ModuleScript,
	Color: Color3,
	Humanoid: boolean,
	Transparency: number?,
	Keys: { string },
}

local ROSTER: { Entry } = {
	-- Solid rigs walk with the Humanoid mover.
	{
		Slot = "1",
		Name = "Stalker",
		Module = Enemies.Stalker,
		Color = Color3.fromRGB(220, 70, 70), -- red: patrols, hears, hunts, searches
		Humanoid = true,
		Keys = { "SeenTarget", "SeenDistance", "HeardAt", "SafeDistance" },
	},
	{
		Slot = "2",
		Name = "Hunter",
		Module = Enemies.Hunter,
		Color = Color3.fromRGB(230, 130, 40), -- orange: scores its prey, sprints, tires
		Humanoid = true,
		Keys = { "SeenTargets", "NearestDistance", "Stamina", "SafeDistance" },
	},
	{
		Slot = "3",
		Name = "Guardian",
		Module = Enemies.Guardian,
		Color = Color3.fromRGB(60, 140, 230), -- blue: holds its ground, raises the alarm
		Humanoid = true,
		Keys = { "SeenTarget", "SeenDistance", "SafeDistance" },
	},
	-- A see-through rig is pivoted by the CFrame mover; its Humanoid does no work.
	{
		Slot = "4",
		Name = "WeepingAngel",
		Module = Enemies.WeepingAngel,
		Color = Color3.fromRGB(40, 40, 45), -- near black: only moves unseen
		Humanoid = false,
		Transparency = 0.35,
		Keys = { "IsWatched", "SeenTarget", "SeenDistance", "SafeDistance" },
	},
}

------------------------------------------------------------------------------------------------------------------------

local map = Map.Build(Workspace)
-- Enemy rigs get a collision group of their own: doors let it through, safe rooms stop it, and
-- every planner and sense keeps enemies out of a safe room while it is on.
VluxyAI.Collision.Setup()
VluxyAI.SafeAreas.Setup()

--[[
	The switch in each safe room: a prompt that turns the room off and on, and colours that say
	which it is. Off, the room is just a room, and enemies may come in.
]]
local SAFE_ON = Color3.fromRGB(70, 220, 120)
local SAFE_OFF = Color3.fromRGB(200, 70, 70)
for _, room in map.SafeRooms do
	local prompt = Instance.new("ProximityPrompt")
	prompt.MaxActivationDistance = 8
	prompt.RequiresLineOfSight = false
	prompt.Parent = room.Switch

	local function refresh()
		local on = VluxyAI.SafeAreas.IsEnabled(room.Zone)
		local color = if on then SAFE_ON else SAFE_OFF
		room.Zone.Color = color
		room.Floor.Color = color
		room.Switch.Color = color
		room.Sign.TextColor3 = color
		room.Sign.Text = if on then "SAFE ROOM" else "NOT SAFE"
		prompt.ObjectText = if on then "Safe room" else "Safe room (off)"
		prompt.ActionText = if on then "Turn off" else "Turn on"
	end
	prompt.Triggered:Connect(function()
		room.Zone:SetAttribute(VluxyAI.SafeAreas.ENABLED_ATTRIBUTE, not VluxyAI.SafeAreas.IsEnabled(room.Zone))
	end)
	room.Zone:GetAttributeChangedSignal(VluxyAI.SafeAreas.ENABLED_ATTRIBUTE):Connect(refresh)
	refresh()
end

local noises: VluxyAI.Signal<(Vector3, number?, string?)> = VluxyAI.Signal.new()

--[[
	Player jumps are ordinary noises; the noise pad is a loud one.
]]
local function watchCharacter(character: Model)
	local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
	local root = character:WaitForChild("HumanoidRootPart", 10) :: BasePart?
	if not humanoid or not root then
		return
	end

	humanoid.Jumping:Connect(function(active: boolean)
		if active then
			noises:Fire(root.Position, 1, "Jump")
		end
	end)
end

Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(watchCharacter)
	if player.Character then
		watchCharacter(player.Character)
	end
end)
for _, player in Players:GetPlayers() do
	player.CharacterAdded:Connect(watchCharacter)
	if player.Character then
		watchCharacter(player.Character)
	end
end

-- Players make noise by moving: a faint footstep while walking, a louder one while sprinting.
-- Heard by any enemy close enough, with the kind attached; only running is also a clue on the
-- shared map (Clues.luau). Read from the root's velocity on the server, so the client's sprint
-- script never reports anything.
VluxyAI.PlayerNoise.new(noises, {
	{ Speed = 4, Every = 0.7, Loudness = 0.25, Kind = "Footstep" }, -- about 10 studs
	{ Speed = 19, Every = 0.5, Loudness = 0.6, Kind = "Running" }, -- about 24 studs; walk is 16, sprint 24
})

-- A player opening a door is heard by whoever is near.
local DOOR_LOUDNESS = 0.8
for _, door in map.Doors do
	DoorScript.Watch(door, function(opened: BasePart)
		noises:Fire(opened.Position, DOOR_LOUDNESS, "Door")
	end)
end

for _, pad in map.NoisePads do
	local lastFired = 0
	pad.Touched:Connect(function(hit)
		if os.clock() - lastFired < 0.5 then
			return
		end
		local character = hit:FindFirstAncestorOfClass("Model")
		if not character or not Players:GetPlayerFromCharacter(character) then
			return
		end
		lastFired = os.clock()
		noises:Fire(pad.Position, 2.5, "Pad")
	end)
end

------------------------------------------------------------------------------------------------------------------------

--[[
	Whether a straight line between two points clears the maze walls, so the graph starts and ends
	a route at a node the agent can actually walk to. Only walls count: doors, rigs and players
	never stop an enemy.
]]
local wallParams = RaycastParams.new()
wallParams.FilterType = Enum.RaycastFilterType.Include
local walls = {}
for _, part in map.Folder:GetChildren() do
	if part.Name == "Wall" then
		table.insert(walls, part)
	end
end
wallParams.FilterDescendantsInstances = walls
local function clearOfWalls(from: Vector3, to: Vector3): boolean
	local a = Vector3.new(from.X, 3, from.Z)
	local b = Vector3.new(to.X, 3, to.Z)
	return Workspace:Raycast(a, b - a, wallParams) == nil
end

--[[
	What the enemies believe about where the players are. They know someone is in the maze but not
	where, so every cell outside the safe rooms is a point on one shared Interest map, and clues
	warm the cells near them: the kinds of noise below, and every sighting (each enemy's Clues
	sense). Interest calms over about a minute, and an enemy leaves a cell it just checked alone
	for 40 seconds, so together they search the maze instead of walking one loop.
]]
local clues = VluxyAI.Interest.new({
	Decay = 0.25,
	Visited = 40,
	Clues = {
		Running = { Radius = 24, Heat = 1.5 }, -- every half second while someone sprints
		Door = { Radius = 28, Heat = 5 }, -- a player opened a door
		Alarm = { Radius = 48, Heat = 12 }, -- the Guardian saw an intruder: everyone come
		Footstep = { Radius = 0, Heat = 0 }, -- not a clue
	},
})
clues:AddAll(map.CellCentres, { Skip = VluxyAI.SafeAreas.Contains })

local context: Context.Context = {
	Map = map,
	Noises = noises,
	-- One instance is one group: every enemy that adds it keeps out of the others' way.
	Crowd = VluxyAI.Senses.Neighbours.new({ Range = 10, Slow = { Distance = 5, Min = 0.5 }, Avoid = { Radius = 4 } }),
	-- Read back from the node parts the map placed, as it would be from a hand-authored level.
	Graph = VluxyAI.Pathfinders.Graph.FromInstances(map.NavGraph, {
		AutoLink = false,
		-- Never route through a safe room while it is on.
		Graph = { LineOfSight = clearOfWalls, Avoid = VluxyAI.SafeAreas.Contains },
	}),
	Interest = clues,
	Random = Random.new(7),
}

-- Every noise is a clue on the shared map, weighed by kind; a footstep is not one (only an enemy
-- close enough hears it, through its Hearing).
noises:Connect(function(position: Vector3, loudness: number?, kind: string?)
	clues:Heard(position, loudness, kind)
end)

-- The links of the A* node map; the node parts themselves are already purple and see-through.
VluxyAI.Debug.GraphVisual.new(context.Graph, { Nodes = false })

-- Give the navmesh a moment to bake around the freshly built walls before anyone plans.
task.wait(1)

local sync = Instance.new("RemoteEvent")
sync.Name = "VluxyAISync"
sync.Parent = ReplicatedStorage

local broadcasters: { [Model]: VluxyAI.Broadcaster } = {}

--[[
	Everything a client needs about every agent, for one that just joined.
]]
local function sendSnapshots(player: Player)
	for model, broadcaster in broadcasters do
		local snapshot = broadcaster:Snapshot()
		sync:FireClient(player, { Kind = "Snapshot", Id = model, Name = model.Name, Snapshot = snapshot })
	end
end

for _, entry in ROSTER do
	local spawn: Vector3? = map.Spawns[entry.Slot]
	if spawn == nil then
		warn(`Playground: no spawn "{entry.Slot}" on the map for {entry.Name}`)
		continue
	end

	local model = VluxyAI.Debug.Rig.Create(entry.Name, {
		Humanoid = entry.Humanoid,
		Color = entry.Color,
		Transparency = entry.Transparency,
	})
	local humanoid = model:FindFirstChildOfClass("Humanoid") :: Humanoid
	local root = model.PrimaryPart :: BasePart
	model:PivotTo(CFrame.new(spawn + Vector3.new(0, humanoid.HipHeight + root.Size.Y / 2, 0)))
	model.Parent = map.Folder
	-- Enemies walk through doors; the navmesh modifier decides where they may.
	VluxyAI.Collision.AddRig(model)

	local create = require(entry.Module) :: Context.Enemy
	local agent = create(model, context)

	VluxyAI.Locomotion.Attach(agent)
	VluxyAI.Debug.StateLabel.new(agent, { Keys = entry.Keys })
	VluxyAI.Debug.PathVisual.new(agent, { Color = entry.Color })

	-- Mirror mode: no position stream, the replicated rig is the truth. States and events only.
	-- The rig is the Id because streaming is off here and rigs exist before anyone joins; under
	-- StreamingEnabled send a string key and resolve the rig on the client.
	local broadcaster = VluxyAI.Sync.Broadcaster.new(agent, { PositionRate = 0 })
	broadcaster.StateChanged:Connect(function(state)
		sync:FireAllClients({ Kind = "State", Id = model, Name = model.Name, State = state })
	end)
	broadcaster.EventSent:Connect(function(name, payload)
		sync:FireAllClients({ Kind = "Event", Id = model, Name = model.Name, Event = name, Payload = payload })
	end)
	broadcasters[model] = broadcaster

	agent:Start()
end

-- A client asks once it is listening. Sending on PlayerAdded instead can land before its script
-- has connected, and an enemy that never changes state (the dormant Weeping Angel) would then
-- never appear on that client at all.
sync.OnServerEvent:Connect(function(player: Player, message: any)
	if message == "Ready" then
		sendSnapshots(player)
	end
end)
