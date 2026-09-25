--!strict

--[[
	The playground. Builds the map, wires the noise signal to player jumps and the noise pad,
	spawns one R15 rig per example enemy with animations, a debug label and a path visual, and
	starts them. Colour says which enemy it is; transparency says how it moves: solid rigs walk
	with the Humanoid mover, the see-through one is pivoted by the CFrame mover. The Guardian's
	alarm goes through the same noise signal as player jumps, so the Stalker answers it.

	Every agent gets a Broadcaster whose state changes and events go out over one RemoteEvent,
	VluxyAISync, in mirror mode: the rigs replicate on their own, the clients add visuals and
	present kills. Late joiners get a snapshot per agent.
	Serve `test-place.project.json` and press Play.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Context = require(script.Parent.Context)
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
		Keys = { "SeenTarget", "SeenDistance", "HeardAt" },
	},
	{
		Slot = "2",
		Name = "Hunter",
		Module = Enemies.Hunter,
		Color = Color3.fromRGB(230, 130, 40), -- orange: scores its prey, sprints, tires
		Humanoid = true,
		Keys = { "SeenTargets", "NearestDistance", "Stamina" },
	},
	{
		Slot = "3",
		Name = "Guardian",
		Module = Enemies.Guardian,
		Color = Color3.fromRGB(60, 140, 230), -- blue: holds its ground, raises the alarm
		Humanoid = true,
		Keys = { "SeenTarget", "SeenDistance" },
	},
	-- A see-through rig is pivoted by the CFrame mover; its Humanoid does no work.
	{
		Slot = "4",
		Name = "WeepingAngel",
		Module = Enemies.WeepingAngel,
		Color = Color3.fromRGB(40, 40, 45), -- near black: only moves unseen
		Humanoid = false,
		Transparency = 0.35,
		Keys = { "IsWatched", "SeenTarget", "SeenDistance" },
	},
}

------------------------------------------------------------------------------------------------------------------------

local map = Map.Build(Workspace)
print(`Playground: maze seed {map.Seed}`)

local noises: VluxyAI.Signal<(Vector3, number?)> = VluxyAI.Signal.new()

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
			noises:Fire(root.Position, 1)
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
		noises:Fire(pad.Position, 2.5)
	end)
end

------------------------------------------------------------------------------------------------------------------------

local context: Context.Context = {
	Map = map,
	Noises = noises,
	Random = Random.new(7),
}

-- Give the navmesh a moment to bake around the freshly built walls before anyone plans.
task.wait(1)

local sync = Instance.new("RemoteEvent")
sync.Name = "VluxyAISync"
sync.Parent = ReplicatedStorage

local agents: { VluxyAI.Agent } = {}
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
	model:PivotTo(CFrame.new(spawn + Vector3.new(0, 3, 0)))
	model.Parent = map.Folder

	local create = require(entry.Module) :: Context.Enemy
	local agent = create(model, context)

	VluxyAI.Locomotion.Attach(agent)
	VluxyAI.Debug.StateLabel.new(agent, { Keys = entry.Keys })
	VluxyAI.Debug.PathVisual.new(agent, { Color = entry.Color })

	agent.StateChanged:Connect(function(new, old)
		print(`[{agent.Name}] {old or "-"} -> {new}`)
	end)

	-- Mirror mode: no position stream, the replicated rig is the truth. States and events only.
	local broadcaster = VluxyAI.Sync.Broadcaster.new(agent, { PositionRate = 0 })
	broadcaster.StateChanged:Connect(function(state)
		sync:FireAllClients({ Kind = "State", Id = model, Name = model.Name, State = state })
	end)
	broadcaster.EventSent:Connect(function(name, payload)
		sync:FireAllClients({ Kind = "Event", Id = model, Name = model.Name, Event = name, Payload = payload })
	end)
	broadcasters[model] = broadcaster

	agent:Start()
	table.insert(agents, agent)
end

Players.PlayerAdded:Connect(sendSnapshots)
for _, player in Players:GetPlayers() do
	sendSnapshots(player)
end

print(`Playground: {#agents} agents running`)
