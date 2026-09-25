--!strict

--[[
	The playground. Builds the map, wires the noise signal to player jumps and the noise pad,
	spawns one cylinder per example enemy with a debug label and a path visual, and starts them.
	Serve `test-place.project.json` and press Play.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Context = require(script.Parent.Context)
local Cylinder = require(script.Parent.Cylinder)
local Map = require(script.Parent.Map)
local VluxyAI = require(ReplicatedStorage.Packages.VluxyAI)

local Enemies = script.Parent.Enemies

------------------------------------------------------------------------------------------------------------------------

local ROSTER: {
	{
		Slot: string,
		Name: string,
		Module: ModuleScript,
		Color: Color3,
		Humanoid: boolean,
		Transparency: number?,
		Keys: { string },
	}
} =
	{
		{
			Slot = "1",
			Name = "Wanderer",
			Module = Enemies.Wanderer,
			Color = Color3.fromRGB(90, 200, 120),
			Humanoid = true,
			Keys = {},
		},
		{
			Slot = "2",
			Name = "Stalker",
			Module = Enemies.Stalker,
			Color = Color3.fromRGB(220, 70, 70),
			Humanoid = true,
			Keys = { "SeenTarget", "SeenDistance" },
		},
		{
			Slot = "3",
			Name = "Patroller",
			Module = Enemies.Patroller,
			Color = Color3.fromRGB(240, 200, 60),
			Humanoid = true,
			Keys = { "HeardPosition", "HeardLoudness" },
		},
		{
			Slot = "4",
			Name = "Hunter",
			Module = Enemies.Hunter,
			Color = Color3.fromRGB(230, 130, 40),
			Humanoid = true,
			Keys = { "SeenTargets", "NearestDistance" },
		},
		{
			Slot = "5",
			Name = "Ghost",
			Module = Enemies.Ghost,
			Color = Color3.fromRGB(170, 190, 255),
			Humanoid = false,
			Transparency = 0.5,
			Keys = { "SeenTarget" },
		},
		{
			Slot = "6",
			Name = "Watcher",
			Module = Enemies.Watcher,
			Color = Color3.fromRGB(40, 40, 45),
			Humanoid = false,
			Keys = { "IsWatched", "SeenTarget", "SeenDistance" },
		},
	}

------------------------------------------------------------------------------------------------------------------------

local map = Map.Build(Workspace)

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
		if
			not hit:FindFirstAncestorOfClass("Model")
			or not Players:GetPlayerFromCharacter(hit:FindFirstAncestorOfClass("Model") :: Model)
		then
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

local agents: { VluxyAI.Agent } = {}

for _, entry in ROSTER do
	local spawn: Vector3? = map.Spawns[entry.Slot]
	if spawn == nil then
		warn(`Playground: no spawn "{entry.Slot}" on the map for {entry.Name}`)
		continue
	end

	local model = Cylinder.Create(entry.Name, {
		Humanoid = entry.Humanoid,
		Color = entry.Color,
		Transparency = entry.Transparency,
	})
	model:PivotTo(CFrame.new(spawn + Vector3.new(0, 2.5, 0)))
	model.Parent = map.Folder

	local create = require(entry.Module) :: Context.Enemy
	local agent = create(model, context)

	VluxyAI.Debug.StateLabel.new(agent, { Keys = entry.Keys })
	VluxyAI.Debug.PathVisual.new(agent, { Color = entry.Color })

	agent.StateChanged:Connect(function(new, old)
		print(`[{agent.Name}] {old or "-"} -> {new}`)
	end)

	agent:Start()
	table.insert(agents, agent)
end

print(`Playground: {#agents} agents running`)
