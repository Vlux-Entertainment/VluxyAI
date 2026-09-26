--!strict

--[[
	Footstep sounds from movement, measured rather than scripted: every `Stride` studs the pivot
	travels along the floor, a sound plays at it. Meant for the client, attached to a Replica's
	rig, so the audio is local and never crosses the network; it works on the server for a rig
	there too. Nothing here talks to the AI: the mover's `Noise` option is what lets other agents
	hear the steps.

	The one decision worth knowing: the sound is a `Sound` instance parented to the rig's root
	(or the pivot part), so Roblox plays it in 3D and rolls it off for free; `OnStep` is there
	for a game that wants a material-dependent sound instead.
]]

local Cleaner = require(script.Parent.Parent.Utility.Cleaner)
local FormatMessage = require(script.Parent.Parent.Utility.FormatMessage)
local Options = require(script.Parent.Parent.Utility.Options)

------------------------------------------------------------------------------------------------------------------------

local DEFAULT_OPTIONS = table.freeze({
	Stride = 3,
	Volume = 0.5,
	MinSpeed = 0.5,
	PitchVariation = 0.1,
})

local ALLOWED_OPTIONS = { "Sound", "OnStep", "Random" }

--[=[
	@interface FootstepsOptions
	@within Footsteps

	.Sound Sound | number? -- A `Sound` to clone under the root, or an asset id to make one from. Leave it out with `OnStep`.
	.Stride number? -- Studs of floor travel between steps. Default `3`.
	.Volume number? -- Applied to a sound made from an id. Default `0.5`.
	.MinSpeed number? -- Studs per second below which no steps play, so a nudge or a settle is silent. Default `0.5`.
	.PitchVariation number? -- Random spread of `PlaybackSpeed` around `1`, so steps do not sound stamped. Default `0.1`.
	.OnStep ((position: Vector3, root: BasePart?) -> ())? -- Called on every step, with or without a `Sound`: pick a sound by material here.
	.Random Random? -- For the pitch. Default a new one.
]=]
export type FootstepsOptions = {
	Sound: (Sound | number)?,
	Stride: number?,
	Volume: number?,
	MinSpeed: number?,
	PitchVariation: number?,
	OnStep: ((position: Vector3, root: BasePart?) -> ())?,
	Random: Random?,
}

type ResolvedOptions = {
	Sound: (Sound | number)?,
	Stride: number,
	Volume: number,
	MinSpeed: number,
	PitchVariation: number,
	OnStep: ((position: Vector3, root: BasePart?) -> ())?,
	Random: Random?,
}

local Footsteps = {}

--[=[
	@class Footsteps

	Footstep audio from how far a rig actually walks. Exposed as `VluxyAI.Animator.Footsteps`
	(the client-side twin of [Locomotion]). Attach it to the rig a [Replica] moves and destroy
	it with the replica:

	```lua
	-- client, in the game's replica setup
	local steps = VluxyAI.Animator.Footsteps.Attach(replica.Entity, { Sound = 9114234567, Stride = 2.5 })
	replica.Destroyed:Connect(function() steps:Destroy() end)
	```

	For the enemies to hear each other's steps, give the mover a `Noise` option; that is the
	server's business and this is the player's ears.
]=]

--[[
	The part a Sound can live in: a Model's PrimaryPart, a BasePart itself, else nothing.
]]
local function rootOf(target: any): BasePart?
	if typeof(target) ~= "Instance" then
		local primary = target.PrimaryPart
		return if primary ~= nil then primary else nil
	end
	if target:IsA("BasePart") then
		return target
	end
	if target:IsA("Model") then
		return target.PrimaryPart
	end
	return nil
end

--[[
	The Sound instance to play, made or cloned under the root.
]]
local function makeSound(given: (Sound | number)?, root: BasePart?, volume: number): Sound?
	if given == nil or root == nil then
		return nil
	end

	local sound: Sound
	if type(given) == "number" then
		sound = Instance.new("Sound")
		sound.SoundId = `rbxassetid://{given}`
		sound.Volume = volume
	else
		sound = (given :: Sound):Clone()
	end
	sound.Name = "VluxyAI_Footstep"
	sound.Parent = root
	return sound
end

--[=[
	@within Footsteps
	@param target PVInstance -- The rig: a Model with a PrimaryPart, or a BasePart. Anything with `GetPivot` and a `PrimaryPart` works in a test.
	@param options FootstepsOptions?
	@return Cleaner -- Destroy it to stop; the sound instance goes with it.
	@error string -- Neither `Sound` nor `OnStep` given.

	Watches the pivot every Heartbeat and plays a step each `Stride` studs of horizontal travel
	while the rig is moving faster than `MinSpeed`.
]=]
function Footsteps.Attach(target: PVInstance, options: FootstepsOptions?): Cleaner.Cleaner
	local resolved =
		Options.Resolve("Footsteps.Attach", DEFAULT_OPTIONS, options :: any, ALLOWED_OPTIONS) :: ResolvedOptions
	if resolved.Sound == nil and resolved.OnStep == nil then
		FormatMessage.Error("Footsteps.Attach: give a Sound (instance or asset id) or an OnStep callback", 2)
	end
	if resolved.Stride <= 0 then
		FormatMessage.Error(`Footsteps.Attach: Stride must be above 0, got {resolved.Stride}`, 2)
	end

	local RunService = game:GetService("RunService")
	local cleaner = Cleaner.new()
	local root = rootOf(target)
	local sound = makeSound(resolved.Sound, root, resolved.Volume)
	if sound ~= nil then
		cleaner:Add(sound)
	end
	local random = resolved.Random or Random.new()

	local last: Vector3? = nil
	local travelled = 0

	cleaner:Connect(RunService.Heartbeat, function(deltaTime: number)
		local position = target:GetPivot().Position
		if last == nil then
			last = position
			return
		end

		local flat = Vector3.new(position.X - last.X, 0, position.Z - last.Z)
		last = position
		local distance = flat.Magnitude
		if deltaTime <= 0 or distance / deltaTime < resolved.MinSpeed then
			travelled = 0
			return
		end

		travelled += distance
		if travelled < resolved.Stride then
			return
		end
		travelled -= resolved.Stride

		if sound ~= nil then
			local spread = resolved.PitchVariation
			sound.PlaybackSpeed = if spread > 0 then 1 + random:NextNumber(-spread, spread) else 1
			sound:Play()
		end
		if resolved.OnStep ~= nil then
			resolved.OnStep(position, root)
		end
	end)

	return cleaner
end

return Footsteps
