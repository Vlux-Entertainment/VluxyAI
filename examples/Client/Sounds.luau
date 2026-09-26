--!strict

--[[
	The playground's sound on the client: enemy footsteps, a stinger when an enemy changes state,
	a heartbeat while a hunting enemy is close, a hit when you take damage and a scream when you
	are killed. Doors make their own sound on the server (DoorScript), so everyone hears them.

	The one decision: every enemy sound is a 3D Sound in the rig's root with a short roll-off, so
	where a sound comes from and how loud it is tell you where the enemy is. That is the point of
	sound in a horror game; a flat 2D stinger would only say that something happened.

	All ids are free Creator Store audio, checked to load in Studio.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")

local VluxyAI = require(ReplicatedStorage.Packages.VluxyAI)

local IDS = {
	HeavyStep = 85383897332935,
	HeavyStepAlt = 91926553559466,
	ConcreteStep = 135085025171496,
	StoneScrape = 7785668624,
	Growl = 129162115855106,
	Roar = 133651202885353,
	Alarm = 130617192462910,
	Heartbeat = 139481207162657,
	Hit = 109316755832781,
	Scream = 138587239935890,
	Grind = 103179450736739,
}

-- Per enemy: footstep sound and stride, and a stinger for entering a state.
local ENEMIES: { [string]: { Step: number, Stride: number, StepVolume: number, Enter: { [string]: number } } } = {
	Stalker = { Step = IDS.HeavyStep, Stride = 3, StepVolume = 0.7, Enter = { Hunt = IDS.Growl } },
	Hunter = { Step = IDS.HeavyStepAlt, Stride = 3.5, StepVolume = 0.8, Enter = { Hunt = IDS.Roar } },
	Guardian = { Step = IDS.ConcreteStep, Stride = 2.5, StepVolume = 0.6, Enter = { Alert = IDS.Alarm } },
	-- A statue has no feet: you hear it scrape each time it moves, and only when you are not looking.
	WeepingAngel = {
		Step = IDS.StoneScrape,
		Stride = 4,
		StepVolume = 0.9,
		-- A long stone grind as it sinks into the floor and rises somewhere else.
		Enter = { Burrow = IDS.Grind },
	},
}

-- States in which an enemy is after someone, for the heartbeat.
local HUNTING = { Hunt = true, Chase = true, Attack = true }
-- Enemies that never raise the heartbeat: the Weeping Angel is felt through the vignette and its
-- scraping, and a heartbeat would give away that it is closing in.
local NO_HEARTBEAT = { WeepingAngel = true }

-- Every volume below is multiplied by this: one knob for the whole mix.
local MASTER_VOLUME = 0.7

local ROLL_OFF_MIN = 8 -- studs at full volume
local ROLL_OFF_MAX = 90 -- studs until silent
local STINGER_COOLDOWN = 8 -- seconds before the same enemy's same stinger plays again
local HEARTBEAT_RANGE = 45 -- studs within which a hunting enemy makes your heart race

local Sounds = {}

--[[
	A 3D sound under `parent` with the playground's roll-off.
]]
local function make(id: number, parent: Instance, volume: number): Sound
	local sound = Instance.new("Sound")
	sound.SoundId = `rbxassetid://{id}`
	sound.Volume = volume * MASTER_VOLUME
	sound.RollOffMode = Enum.RollOffMode.InverseTapered
	sound.RollOffMinDistance = ROLL_OFF_MIN
	sound.RollOffMaxDistance = ROLL_OFF_MAX
	sound.Parent = parent
	return sound
end

--[[
	Plays a sound once under `parent` and cleans it up when it ends.
]]
function Sounds.PlayOnce(id: number, parent: Instance, volume: number?)
	local sound = make(id, parent, volume or 0.8)
	sound.Ended:Once(function()
		sound:Destroy()
	end)
	sound:Play()
	task.delay(20, function()
		if sound.Parent then
			sound:Destroy()
		end
	end)
end

--[[
	Footsteps and stingers for one enemy's replica.
]]
function Sounds.Attach(replica: VluxyAI.Replica, name: string)
	local config = ENEMIES[name]
	local root = (replica.Entity :: Model).PrimaryPart
	if config == nil or root == nil then
		return
	end

	local template = make(config.Step, root, config.StepVolume)
	template.Name = "StepTemplate"
	local steps = VluxyAI.Footsteps.Attach(replica.Entity, { Sound = template, Stride = config.Stride })
	template:Destroy()

	local lastPlayed: { [string]: number } = {}
	local connection = replica.StateChanged:Connect(function(state: string)
		local id = config.Enter[state]
		if id == nil then
			return
		end
		local now = os.clock()
		if now - (lastPlayed[state] or -math.huge) < STINGER_COOLDOWN then
			return
		end
		lastPlayed[state] = now
		Sounds.PlayOnce(id, root, 1)
	end)

	replica.Entity.Destroying:Once(function()
		connection:Disconnect()
		steps:Destroy()
	end)
end

--[[
	The local player's own sounds: a hit on every loss of health, and a heartbeat that rises
	while any hunting enemy in `replicas` is within HEARTBEAT_RANGE.
]]
function Sounds.Player(replicas: { [Model]: VluxyAI.Replica })
	local player = Players.LocalPlayer

	local heartbeat = Instance.new("Sound")
	heartbeat.SoundId = `rbxassetid://{IDS.Heartbeat}`
	heartbeat.Looped = true
	heartbeat.Volume = 0
	heartbeat.Parent = SoundService
	heartbeat:Play()

	RunService.RenderStepped:Connect(function()
		local character = player.Character
		local root = if character then character:FindFirstChild("HumanoidRootPart") :: BasePart? else nil
		local nearest = math.huge
		if root then
			for model, replica in replicas do
				if HUNTING[replica:GetState() or ""] and not NO_HEARTBEAT[model.Name] then
					nearest = math.min(nearest, (model:GetPivot().Position - root.Position).Magnitude)
				end
			end
		end
		local closeness = math.clamp(1 - nearest / HEARTBEAT_RANGE, 0, 1)
		heartbeat.Volume = closeness * 1.2 * MASTER_VOLUME
		heartbeat.PlaybackSpeed = 1 + closeness * 0.5
	end)

	local function watch(character: Model)
		local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
		if humanoid == nil then
			return
		end
		local health = humanoid.Health
		humanoid.HealthChanged:Connect(function(now: number)
			if now < health and now > 0 then
				Sounds.PlayOnce(IDS.Hit, SoundService, 0.9)
			end
			health = now
		end)
	end
	player.CharacterAdded:Connect(watch)
	if player.Character then
		task.spawn(watch, player.Character)
	end
end

--[[
	A scream for the local player's own death or scare.
]]
function Sounds.Killed()
	Sounds.PlayOnce(IDS.Scream, SoundService, 1)
end

return Sounds
