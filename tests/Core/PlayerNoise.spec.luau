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
}
