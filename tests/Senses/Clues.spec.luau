--!strict

--[[
	The clue pieces: Interest:Heard weighing noises by kind, Interest:AddAll, the Clues sense
	warming the map from sightings, and the Hideout sense picking an unseen point.
]]

local Harness = require("../Support/Harness")

local roblox = require("@lune/roblox")
local Vector3 = roblox.Vector3

local function loadInterest()
	return Harness.Load("lib/Group/Interest.luau")
end

return {
	["Heard weighs a noise by its kind, falls back to loudness, and a zero clue counts for nothing"] = function(expect)
		local Interest = loadInterest()
		local interest = Interest.new({
			Decay = 0,
			NoiseRadius = 20,
			NoiseHeat = 2,
			Clues = {
				Door = { Radius = 20, Heat = 5 },
				Footstep = { Radius = 0, Heat = 0 },
			},
		})
		interest:Add("here", { Position = Vector3.new(0, 0, 0) })

		expect.equal(interest:Heard(Vector3.new(0, 0, 0), 0.25, "Footstep"), 0, "a footstep is no clue")
		expect.equal(interest:Get("here").Strength, 1)
		interest:Heard(Vector3.new(0, 0, 0), 0.1, "Door")
		expect.near(interest:Get("here").Strength, 6, 1e-6, "a door counts 5 whatever its loudness")
		interest:Heard(Vector3.new(0, 0, 0), 1.5, "Jump")
		expect.near(interest:Get("here").Strength, 9, 1e-6, "an unlisted kind counts NoiseHeat per loudness")
	end,

	["AddAll adds a point per position, skipping what Skip refuses"] = function(expect)
		local Interest = loadInterest()
		local interest = Interest.new()
		local added = interest:AddAll({ Vector3.new(0, 0, 0), Vector3.new(16, 0, 0), Vector3.new(32, 0, 0) }, {
			Strength = 2,
			Skip = function(position)
				return position.X == 16
			end,
		})
		expect.equal(added, 2)
		expect.equal(interest:Get(1).Strength, 2)
		expect.equal(interest:Get(2), nil, "skipped")
		expect.equal(interest:Get(3).Position, Vector3.new(32, 0, 0))
	end,

	["the Clues sense warms the map around a sighting, and where a lost target was heading"] = function(expect)
		local Interest = loadInterest()
		local Clues = Harness.Load("lib/Senses/Clues.luau")
		local interest = Interest.new({ Decay = 0 })
		interest:Add("seen", { Position = Vector3.new(0, 0, 0) })
		interest:Add("heading", { Position = Vector3.new(100, 0, 0) })
		local sense = Clues.new(interest, { Radius = 10, SeenHeat = 4, HeadingHeat = 2 })
		local agent = { Name = "Fake", Blackboard = {} :: { [string]: any }, Data = {} }

		agent.Blackboard.SeenTarget = "someone"
		agent.Blackboard.SeenPosition = Vector3.new(0, 0, 0)
		sense:Tick(agent, 0.5)
		expect.near(interest:Get("seen").Strength, 3, 1e-6, "4 a second for half a second")

		agent.Blackboard.SeenTarget = nil
		agent.Blackboard.PredictedPosition = Vector3.new(100, 0, 0)
		sense:Tick(agent, 1)
		expect.near(interest:Get("heading").Strength, 3, 1e-6, "2 a second where they were heading")
		expect.near(interest:Get("seen").Strength, 3, 1e-6)
	end,

	["Hideout picks the hottest point it may use, or any with Stray, and writes it under Key"] = function(expect)
		local Interest = loadInterest()
		local Hideout = Harness.Load("lib/Senses/Hideout.luau", {
			services = {
				Players = {
					GetPlayers = function()
						return {}
					end,
				},
				CollectionService = {
					GetTagged = function()
						return {}
					end,
				},
			},
		})
		local interest = Interest.new({ Decay = 0 })
		interest:Add("calm", { Position = Vector3.new(0, 0, 0), Strength = 1 })
		interest:Add("hot", { Position = Vector3.new(50, 0, 0), Strength = 8 })
		interest:Add("near", { Position = Vector3.new(3, 0, 0), Strength = 20 })
		local agent =
			{ Name = "Fake", Blackboard = {} :: { [string]: any }, Data = { Random = Harness.FakeRandom.new(4) } }

		local sense = Hideout.new(interest, {
			Key = "LurkSpot",
			Accept = function(position)
				return position.X > 5 or position.X == 0
			end,
		})
		sense:Tick(agent, 0.1)
		expect.equal(agent.Blackboard.LurkSpot, Vector3.new(50, 0, 0), "the hottest point Accept allows")

		local strays = 0
		for seed = 1, 10 do
			local strayAgent = { Name = "Fake", Blackboard = {}, Data = { Random = Harness.FakeRandom.new(seed) } }
			local straying = Hideout.new(interest, { Stray = 1 })
			straying:Tick(strayAgent, 0.1)
			if strayAgent.Blackboard.Hideout ~= Vector3.new(3, 0, 0) then
				strays += 1
			end
		end
		expect.truthy(strays >= 3, `Stray 1 does not always take the hottest ({strays} of 10 elsewhere)`)
	end,
}
