--!strict

--[[
	Noise from the players themselves: each player's root speed, measured every frame, turned into
	noises on the signal a Hearing sense listens to. The game says what speeds make what noise (a
	walk, a run, a crouch that makes none); the enemies hear it through Hearing like any other
	sound, with the kind attached.

	The one decision: speed is read from the root's velocity on the server, so a sprint script on
	the client never has to report anything and cannot lie about being quiet. Nothing touches
	Roblox at module scope; `Band` is pure and specced.
]]

local Cleaner = require(script.Parent.Parent.Utility.Cleaner)
local FormatMessage = require(script.Parent.Parent.Utility.FormatMessage)
local Types = require(script.Parent.Parent.Types)

------------------------------------------------------------------------------------------------------------------------

--[=[
	@interface NoiseBand
	@within PlayerNoise

	.Speed number -- Studs per second at or above which this band applies. The fastest band a player reaches wins.
	.Every number -- Seconds between noises while in this band.
	.Loudness number -- Passed to the signal; a [Hearing] with `Range` hears it from `Range * Loudness` studs.
	.Kind string? -- Passed as the third argument, written as `HeardKind` by [Hearing].
]=]
export type NoiseBand = {
	Speed: number,
	Every: number,
	Loudness: number,
	Kind: string?,
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
	their feet every `Every` seconds. Standing still, or moving below the slowest band, is silent.

	```lua
	VluxyAI.PlayerNoise.new(noises, {
		{ Speed = 4, Every = 0.7, Loudness = 0.25, Kind = "Footstep" }, -- walking
		{ Speed = 19, Every = 0.5, Loudness = 0.6, Kind = "Running" },  -- sprinting
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
	@param signal Signal<(Vector3, number?, string?)> -- The signal your Hearing senses listen to.
	@param bands { NoiseBand }
	@return PlayerNoise
	@error "bands need Speed, Every and Loudness"

	Starts listening on the server. Destroy it to stop.
]=]
function PlayerNoise.new(signal: Types.Signal<(Vector3, number?, string?)>, bands: { NoiseBand }): PlayerNoise
	for index, band in bands do
		if type(band.Speed) ~= "number" or type(band.Every) ~= "number" or type(band.Loudness) ~= "number" then
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
			local root = if character then character:FindFirstChild("HumanoidRootPart") :: BasePart? else nil
			if root == nil then
				continue
			end
			local velocity = root.AssemblyLinearVelocity
			local band = PlayerNoise.Band(bands, Vector3.new(velocity.X, 0, velocity.Z).Magnitude)
			if band ~= nil and now - (lastNoise[player] or -math.huge) >= band.Every then
				lastNoise[player] = now
				signal:Fire(root.Position, band.Loudness, band.Kind)
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
