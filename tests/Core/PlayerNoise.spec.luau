--!strict

--[[
	PlayerNoise: which band a speed falls in. The Heartbeat loop over players is play-tested.
]]

local Harness = require("../Support/Harness")

local function load()
	return Harness.Load("lib/World/PlayerNoise.luau")
end

local BANDS = {
	{ Speed = 4, Every = 0.7, Loudness = 0.25, Kind = "Footstep" },
	{ Speed = 19, Every = 0.5, Loudness = 0.6, Kind = "Running" },
}

return {
	["the fastest band reached wins, and below the slowest is silent"] = function(expect)
		local PlayerNoise = load()
		expect.equal(PlayerNoise.Band(BANDS, 0), nil, "standing still")
		expect.equal(PlayerNoise.Band(BANDS, 3.9), nil, "creeping")
		expect.equal(PlayerNoise.Band(BANDS, 16).Kind, "Footstep")
		expect.equal(PlayerNoise.Band(BANDS, 24).Kind, "Running")
		expect.equal(PlayerNoise.Band({ BANDS[2], BANDS[1] }, 24).Kind, "Running", "order does not matter")
	end,
	["a band's loudness is its number, or what its function says for the speed and character"] = function(expect)
		local PlayerNoise = load()
		local crouched = { Crouching = true }
		local standing = { Crouching = false }
		local band = {
			Speed = 4,
			Every = 0.7,
			Kind = "Footstep",
			Loudness = function(speed, character)
				return if character.Crouching then nil else speed / 16
			end,
		}

		expect.equal(PlayerNoise.LoudnessOf(BANDS[1], 10, standing), 0.25)
		expect.equal(PlayerNoise.LoudnessOf(band, 8, standing), 0.5, "the function sees the speed")
		expect.equal(PlayerNoise.LoudnessOf(band, 8, crouched), nil, "and the character")
		expect.equal(PlayerNoise.LoudnessOf({ Speed = 0, Every = 1, Loudness = 0 }, 8, standing), nil, "0 is silent")
	end,
}
