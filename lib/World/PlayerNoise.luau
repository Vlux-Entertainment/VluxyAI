--!strict

--[[
	Noise from the players themselves: each player's root speed, measured every frame, turned into
	noises on the signal a Hearing sense listens to. The game says what speeds make what noise (a
	walk, a run, a crouch that makes none); the enemies hear it through Hearing like any other
	sound, with the kind attached and the player's character as the source.

	The one decision: speed is read from the root's velocity on the server, so a sprint script on
	the client never has to report anything and cannot lie about being quiet. A band's Loudness
	may be a function of the speed and the character, for what velocity cannot tell (a crouch off
	an attribute). Nothing touches Roblox at module scope; `Band` and `LoudnessOf` are pure and
	specced.
]]

local Cleaner = require(script.Parent.Parent.Utility.Cleaner)
local FormatMessage = require(script.Parent.Parent.Utility.FormatMessage)
local Options = require(script.Parent.Parent.Utility.Options)
local Types = require(script.Parent.Parent.Types)

local DEFAULT_OPTIONS = table.freeze({
	RootName = "HumanoidRootPart",
})

------------------------------------------------------------------------------------------------------------------------

--[=[
	@interface NoiseBand
	@within PlayerNoise

	.Speed number -- Studs per second at or above which this band applies. The fastest band a player reaches wins.
	.Every number -- Seconds between noises while in this band.
	.Loudness number | (speed: number, character: Model) -> number? -- Passed to the signal; a [Hearing] with `Range` hears it from `Range * Loudness` studs. A function is asked on every noise; `nil` or `0` makes none (a crouch off an attribute).
	.Kind string? -- Passed as the third argument, written as `HeardKind` by [Hearing].
]=]
export type NoiseBand = {
	Speed: number,
	Every: number,
	Loudness: number | (speed: number, character: Model) -> number?,
	Kind: string?,
}

--[=[
	@interface PlayerNoiseOptions
	@within PlayerNoise

	.RootName string? -- The part under each character whose velocity and position are read. Default `"HumanoidRootPart"`.
]=]
export type PlayerNoiseOptions = {
	RootName: string?,
}

type self = {
	_cleaner: Cleaner.Cleaner,
}

local PlayerNoise = {}
PlayerNoise.__index = PlayerNoise

export type PlayerNoise = typeof(setmetatable({} :: self, PlayerNoise))

--[=[
	@class PlayerNoise

	Players make noise by moving. Give it the noise signal your [Hearing] senses listen to and the
	speed bands; while a player moves at a band's speed or faster, a noise of that band is fired at
	their feet every `Every` seconds, with their character as the source. Standing still, or moving
	below the slowest band, is silent.

	```lua
	local function step(loudness)
		return function(_speed, character)
			return if character:GetAttribute("Crouching") then nil else loudness
		end
	end

	VluxyAI.PlayerNoise.new(noises, {
		{ Speed = 4, Every = 0.7, Loudness = step(0.25), Kind = "Footstep" }, -- walking, silent crouched
		{ Speed = 19, Every = 0.5, Loudness = 0.6, Kind = "Running" },        -- sprinting
	})
	```
]=]

--[=[
	@within PlayerNoise
	@param bands { NoiseBand }
	@param speed number
	@return NoiseBand? -- The fastest band whose `Speed` is at or below `speed`, or `nil`.

	Pure.
]=]
function PlayerNoise.Band(bands: { NoiseBand }, speed: number): NoiseBand?
	local chosen: NoiseBand? = nil
	for _, band in bands do
		if speed >= band.Speed and (chosen == nil or band.Speed > chosen.Speed) then
			chosen = band
		end
	end
	return chosen
end

--[=[
	@within PlayerNoise
	@param band NoiseBand
	@param speed number
	@param character Model
	@return number? -- The loudness to fire, or `nil` for no noise.

	A band's loudness for this speed and character: the number, or what the function returns.
	`0`, a negative or a non-number is `nil`, so the caller fires nothing. Pure.
]=]
function PlayerNoise.LoudnessOf(band: NoiseBand, speed: number, character: Model): number?
	local loudness = band.Loudness
	local amount: any = if type(loudness) == "function" then loudness(speed, character) else loudness
	if type(amount) ~= "number" or amount <= 0 then
		return nil
	end
	return amount
end

--[=[
	@within PlayerNoise
	@param signal Signal<(Vector3, number?, string?)> -- The signal your Hearing senses listen to.
	@param bands { NoiseBand }
	@param options PlayerNoiseOptions?
	@return PlayerNoise
	@error "bands need Speed, Every and Loudness"
	@error "unknown option"

	Starts listening on the server. Destroy it to stop.
]=]
function PlayerNoise.new(signal: Types.NoiseSignal, bands: { NoiseBand }, options: PlayerNoiseOptions?): PlayerNoise
	local resolved = Options.Resolve("PlayerNoise.new", DEFAULT_OPTIONS, options :: any) :: { RootName: string }
	for index, band in bands do
		local loudness = band.Loudness
		if
			type(band.Speed) ~= "number"
			or type(band.Every) ~= "number"
			or (type(loudness) ~= "number" and type(loudness) ~= "function")
		then
			FormatMessage.Error(`PlayerNoise.new: band {index} needs Speed, Every and Loudness`, 2)
		end
	end

	local Players = game:GetService("Players")
	local RunService = game:GetService("RunService")
	local cleaner = Cleaner.new()
	local lastNoise: { [Player]: number } = {}

	cleaner:Connect(RunService.Heartbeat, function()
		local now = os.clock()
		for _, player in Players:GetPlayers() do
			local character = player.Character
			local root = if character then character:FindFirstChild(resolved.RootName) :: BasePart? else nil
			if character == nil or root == nil then
				continue
			end
			local velocity = root.AssemblyLinearVelocity
			local speed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
			local band = PlayerNoise.Band(bands, speed)
			if band ~= nil and now - (lastNoise[player] or -math.huge) >= band.Every then
				-- The clock runs even when the band is silenced, so standing up mid-stride does not
				-- fire a burst of catch-up noise.
				lastNoise[player] = now
				local loudness = PlayerNoise.LoudnessOf(band, speed, character)
				if loudness ~= nil then
					signal:Fire(root.Position, loudness, band.Kind, character)
				end
			end
		end
	end)
	cleaner:Connect(Players.PlayerRemoving, function(player: Player)
		lastNoise[player] = nil
	end)

	local self: self = { _cleaner = cleaner }
	return setmetatable(self, PlayerNoise)
end

--[=[
	@within PlayerNoise

	Stops listening.
]=]
function PlayerNoise.Destroy(self: PlayerNoise)
	self._cleaner:Destroy()
end

return PlayerNoise
