--!strict

--[[
	Sounds: the roll-off curves as pure numbers, which tagged sounds count as audible, how the
	attribute and the threshold weigh them, which one wins a tick, and how long the memory keys
	last. A fake CollectionService hands out plain tables shaped like Sounds.
]]

local Harness = require("../Support/Harness")
local SenseFakes = require("./SenseFakes")

local roblox = require("@lune/roblox")
local Vector3 = roblox.Vector3

--[[
	A stand-in Sound on a part at `position`. Every field a real one has that the sense reads,
	with the defaults a fresh Sound instance has.
]]
local function sound(position: any, fields: { [string]: any }?)
	local part = {
		Position = position,
		IsA = function(_self, className: string)
			return className == "BasePart"
		end,
	}
	local attributes: { [string]: any } = {}
	local instance = {
		Name = "Sound",
		IsPlaying = true,
		Volume = 0.5,
		RollOffMode = "Inverse",
		RollOffMinDistance = 10,
		RollOffMaxDistance = 10000,
		Parent = part,
		Attributes = attributes,
		Owner = nil :: any,
	}
	function instance.GetAttribute(_self, name: string)
		return attributes[name]
	end
	function instance.IsDescendantOf(self, ancestor)
		return self.Owner ~= nil and self.Owner == ancestor
	end
	for key, value in fields or {} do
		(instance :: any)[key] = value
	end
	return instance
end

local function setup(options: { sounds: any?, tagged: { [string]: { any } }? }?)
	local resolved = options or {}
	local clock = Harness.ManualClock(100)
	local tagged = resolved.tagged or {}
	local Sounds = Harness.Load("lib/Senses/Sounds.luau", {
		globals = SenseFakes.Globals({ clock = clock }),
		services = {
			CollectionService = {
				GetTagged = function(_self, tag: string)
					return tagged[tag] or {}
				end,
			},
		},
	})

	local sense = Sounds.new(resolved.sounds)
	local agent = SenseFakes.Agent(Vector3.new(0, 0, 0))

	return {
		Sounds = Sounds,
		sense = sense,
		agent = agent,
		blackboard = agent.Blackboard,
		clock = clock,
		tagged = tagged,
	}
end

local function near(expect, actual: number, wanted: number, message: string?)
	expect.truthy(math.abs(actual - wanted) < 1e-6, `{message or "value"}: expected {wanted}, got {actual}`)
end

return {
	["Attenuate: full volume within the min distance, in every mode"] = function(expect)
		local Sounds = Harness.Load("lib/Senses/Sounds.luau")
		for _, mode in { "Inverse", "InverseTapered", "Linear", "LinearSquare" } do
			near(expect, Sounds.Attenuate(0, 0.8, 10, 100, mode), 0.8, mode)
			near(expect, Sounds.Attenuate(10, 0.8, 10, 100, mode), 0.8, mode)
		end
	end,

	["Attenuate: Inverse falls as min / distance and stops at the max distance"] = function(expect)
		local Sounds = Harness.Load("lib/Senses/Sounds.luau")
		near(expect, Sounds.Attenuate(20, 1, 10, 100, "Inverse"), 0.5, "twice the min distance")
		near(expect, Sounds.Attenuate(40, 1, 10, 100, "Inverse"), 0.25)
		near(expect, Sounds.Attenuate(100, 1, 10, 100, "Inverse"), 0.1, "at the max distance")
		near(expect, Sounds.Attenuate(1000, 1, 10, 100, "Inverse"), 0.1, "no quieter past the max distance")
		near(expect, Sounds.Attenuate(20, 1, 10, 100, "NotAMode"), 0.5, "an unknown mode is Inverse")
	end,

	["Attenuate: Linear and LinearSquare reach silence at the max distance"] = function(expect)
		local Sounds = Harness.Load("lib/Senses/Sounds.luau")
		near(expect, Sounds.Attenuate(55, 1, 10, 100, "Linear"), 0.5, "halfway")
		near(expect, Sounds.Attenuate(100, 1, 10, 100, "Linear"), 0, "at max")
		near(expect, Sounds.Attenuate(500, 1, 10, 100, "Linear"), 0, "past max")
		near(expect, Sounds.Attenuate(55, 1, 10, 100, "LinearSquare"), 0.25, "halfway, squared")
		near(expect, Sounds.Attenuate(100, 1, 10, 100, "LinearSquare"), 0)
		near(expect, Sounds.Attenuate(11, 1, 10, 10, "Linear"), 0, "max at or below min is silence past min")
	end,

	["Attenuate: InverseTapered is the quieter of Inverse and LinearSquare"] = function(expect)
		local Sounds = Harness.Load("lib/Senses/Sounds.luau")
		near(expect, Sounds.Attenuate(20, 1, 10, 100, "InverseTapered"), 0.5, "up close the inverse curve is quieter")
		near(expect, Sounds.Attenuate(91, 1, 10, 100, "InverseTapered"), 0.01, "near max the square curve is")
		near(expect, Sounds.Attenuate(100, 1, 10, 100, "InverseTapered"), 0, "silence at max")
	end,

	["Attenuate: volume scales the result and zero volume is silence"] = function(expect)
		local Sounds = Harness.Load("lib/Senses/Sounds.luau")
		near(expect, Sounds.Attenuate(20, 2, 10, 100, "Inverse"), 1)
		near(expect, Sounds.Attenuate(0, 0, 10, 100, "Inverse"), 0)
	end,

	["a playing tagged 3D sound is heard, with its position, distance, loudness and time"] = function(expect)
		local radio = sound(Vector3.new(20, 0, 0), { Volume = 1 })
		local s = setup({ tagged = { AI_SOUND = { radio } } })

		s.sense:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.HeardSound, radio)
		expect.equal(s.blackboard.HeardSoundPosition, Vector3.new(20, 0, 0))
		expect.equal(s.blackboard.HeardSoundDistance, 20)
		near(expect, s.blackboard.HeardSoundLoudness, 0.5, "inverse roll-off at twice the min distance")
		expect.equal(s.blackboard.HeardSoundAt, 100)
	end,

	["the tag is an option"] = function(expect)
		local radio = sound(Vector3.new(5, 0, 0))
		local s = setup({ sounds = { Tag = "Noisy" }, tagged = { AI_SOUND = { radio }, Noisy = {} } })

		s.sense:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.HeardSound, nil, "the default tag is not asked for")

		table.insert(s.tagged.Noisy, radio)
		s.sense:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.HeardSound, radio)
	end,

	["a sound that is not playing, silent, 2D or unparented is not heard"] = function(expect)
		local folder = {
			IsA = function(_self, className: string)
				return className == "Folder"
			end,
		}
		local orphan = sound(Vector3.new(5, 0, 0))
		orphan.Parent = nil
		local s = setup({
			tagged = {
				AI_SOUND = {
					sound(Vector3.new(5, 0, 0), { IsPlaying = false }),
					sound(Vector3.new(5, 0, 0), { Volume = 0 }),
					sound(Vector3.new(5, 0, 0), { Parent = folder }),
					orphan,
				},
			},
		})

		s.sense:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.HeardSound, nil)
		expect.equal(s.blackboard.HeardSoundDistance, math.huge)
		expect.equal(s.blackboard.HeardSoundPosition, nil)
		expect.equal(s.blackboard.HeardSoundLoudness, nil)
		expect.equal(s.blackboard.HeardSoundAt, nil)
	end,

	["a sound on an attachment plays from its world position"] = function(expect)
		local attachment = {
			WorldPosition = Vector3.new(0, 0, 30),
			Position = Vector3.new(0, 0, 1),
			IsA = function(_self, className: string)
				return className == "Attachment"
			end,
		}
		local s = setup({ tagged = { AI_SOUND = { sound(nil, { Parent = attachment }) } } })

		s.sense:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.HeardSoundPosition, Vector3.new(0, 0, 30))
		expect.equal(s.blackboard.HeardSoundDistance, 30)
	end,

	["the roll-off mode may be an enum item and the sound's own distances are used"] = function(expect)
		local s = setup({
			tagged = {
				AI_SOUND = {
					sound(Vector3.new(55, 0, 0), {
						Volume = 1,
						RollOffMode = { Name = "Linear" },
						RollOffMinDistance = 10,
						RollOffMaxDistance = 100,
					}),
				},
			},
		})

		s.sense:Tick(s.agent, 0.1)
		near(expect, s.blackboard.HeardSoundLoudness, 0.5)
	end,

	["the multiplier attribute multiplies the volume at the agent, and zero silences"] = function(expect)
		local radio = sound(Vector3.new(20, 0, 0), { Volume = 1 })
		local s = setup({ tagged = { AI_SOUND = { radio } } })

		radio.Attributes["AI_SOUND/Multiplier"] = 3
		s.sense:Tick(s.agent, 0.1)
		near(expect, s.blackboard.HeardSoundLoudness, 1.5)

		radio.Attributes["AI_SOUND/Multiplier"] = 0
		s.sense:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.HeardSound, nil)

		radio.Attributes["AI_SOUND/Multiplier"] = "loud"
		s.sense:Tick(s.agent, 0.1)
		near(expect, s.blackboard.HeardSoundLoudness, 0.5, "a non-number attribute means 1")

		radio.Attributes["AI_SOUND/Multiplier"] = -2
		s.sense:Tick(s.agent, 0.1)
		near(expect, s.blackboard.HeardSoundLoudness, 0.5, "a negative attribute means 1")
	end,

	["the attribute name is an option"] = function(expect)
		local radio = sound(Vector3.new(20, 0, 0), { Volume = 1 })
		local s = setup({ sounds = { MultiplierAttribute = "AIWeight" }, tagged = { AI_SOUND = { radio } } })

		radio.Attributes["AI_SOUND/Multiplier"] = 4
		radio.Attributes.AIWeight = 2
		s.sense:Tick(s.agent, 0.1)
		near(expect, s.blackboard.HeardSoundLoudness, 1)
	end,

	["a sound below Threshold at the agent is not heard"] = function(expect)
		local far = sound(Vector3.new(100, 0, 0), { Volume = 1 })
		local s = setup({ sounds = { Threshold = 0.2 }, tagged = { AI_SOUND = { far } } })

		s.sense:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.HeardSound, nil, "0.1 at 100 studs is under the threshold")

		far.Attributes["AI_SOUND/Multiplier"] = 2
		s.sense:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.HeardSound, far, "exactly at the threshold is heard")
	end,

	["the loudest sound at the agent wins, and the nearest on a tie"] = function(expect)
		local quietNear = sound(Vector3.new(5, 0, 0), { Volume = 0.2 })
		local loudFar = sound(Vector3.new(40, 0, 0), { Volume = 2 })
		local s = setup({ tagged = { AI_SOUND = { quietNear, loudFar } } })

		s.sense:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.HeardSound, loudFar, "0.5 at the agent beats 0.2")

		local twin = sound(Vector3.new(0, 0, 20), { Volume = 1 })
		s.tagged.AI_SOUND = { loudFar, twin }
		s.sense:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.HeardSound, twin, "both 0.5 at the agent; the nearer wins")
	end,

	["the agent's own sounds and sounds the Filter rejects are ignored"] = function(expect)
		local footsteps = sound(Vector3.new(1, 0, 0), { Volume = 1 })
		local radio = sound(Vector3.new(20, 0, 0), { Volume = 1, Name = "Radio" })
		local tv = sound(Vector3.new(15, 0, 0), { Volume = 1, Name = "TV" })
		local filtered = {}
		local s = setup({
			sounds = {
				Filter = function(candidate, _agent)
					table.insert(filtered, candidate.Name)
					return candidate.Name ~= "TV"
				end,
			},
			tagged = { AI_SOUND = { footsteps, tv, radio } },
		})
		footsteps.Owner = s.agent.Entity

		s.sense:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.HeardSound, radio)
		expect.sequence(filtered, { "TV", "Radio" }, "the agent's own sound never reaches the Filter")
	end,

	["the sound is measured from the agent's GetPosition"] = function(expect)
		local radio = sound(Vector3.new(105, 0, 0), { Volume = 1 })
		local s = setup({ tagged = { AI_SOUND = { radio } } })
		s.agent.GetPosition = function()
			return Vector3.new(100, 0, 0)
		end

		s.sense:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.HeardSoundDistance, 5)
		near(expect, s.blackboard.HeardSoundLoudness, 1, "within the min distance")
	end,

	["the memory keys last Memory seconds after the sound stops, then clear together"] = function(expect)
		local radio = sound(Vector3.new(20, 0, 0), { Volume = 1 })
		local s = setup({ sounds = { Memory = 5 }, tagged = { AI_SOUND = { radio } } })

		s.sense:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.HeardSoundAt, 100)

		radio.IsPlaying = false
		s.clock:Advance(3)
		s.sense:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.HeardSound, nil, "not audible now")
		expect.equal(s.blackboard.HeardSoundDistance, math.huge)
		expect.equal(s.blackboard.HeardSoundPosition, Vector3.new(20, 0, 0), "remembered")
		near(expect, s.blackboard.HeardSoundLoudness, 0.5)
		expect.equal(s.blackboard.HeardSoundAt, 100)

		s.clock:Advance(2.5)
		s.sense:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.HeardSoundPosition, nil, "forgotten")
		expect.equal(s.blackboard.HeardSoundLoudness, nil)
		expect.equal(s.blackboard.HeardSoundAt, nil)
	end,

	["a sound that keeps playing keeps the time fresh"] = function(expect)
		local radio = sound(Vector3.new(20, 0, 0), { Volume = 1 })
		local s = setup({ sounds = { Memory = 1 }, tagged = { AI_SOUND = { radio } } })

		s.sense:Tick(s.agent, 0.1)
		s.clock:Advance(10)
		s.sense:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.HeardSoundAt, 110)
	end,

	["new rejects an unknown option, an empty tag and a negative threshold"] = function(expect)
		local s = setup()

		local message = expect.errors(function()
			s.Sounds.new({ Range = 30 })
		end)
		expect.includes(message, 'unknown option "Range"')

		message = expect.errors(function()
			s.Sounds.new({ Tag = "" })
		end)
		expect.includes(message, "Tag must be a non-empty string")

		message = expect.errors(function()
			s.Sounds.new({ Threshold = -1 })
		end)
		expect.includes(message, "Threshold must be zero or more")
	end,
}
