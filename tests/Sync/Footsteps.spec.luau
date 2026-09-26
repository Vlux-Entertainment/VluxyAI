--!strict

--[[
	Footsteps: a step every Stride studs of horizontal travel while moving above MinSpeed, the
	sound made under the root, OnStep for a custom sound, and Destroy taking the sound with it.
]]

local Harness = require("../Support/Harness")

local roblox = require("@lune/roblox")
local CFrame = roblox.CFrame
local Vector3 = roblox.Vector3

local function setup()
	local heartbeat = Harness.ManualHeartbeat()
	local created = {}
	local Footsteps = Harness.Load("lib/Animator/Footsteps.luau", {
		services = { RunService = { Heartbeat = heartbeat } },
		globals = {
			Instance = {
				new = function(className: string)
					local instance = { ClassName = className, Plays = 0, Destroyed = false }
					function instance.Play(self)
						self.Plays += 1
					end
					function instance.Destroy(self)
						self.Destroyed = true
					end
					table.insert(created, instance)
					return instance
				end,
			},
		},
	})
	local root = { Name = "Root" }
	local rig = { PrimaryPart = root, Pivot = CFrame.new(0, 0, 0) }
	function rig.GetPivot(self)
		return self.Pivot
	end
	return { Footsteps = Footsteps, heartbeat = heartbeat, rig = rig, root = root, created = created }
end

return {
	["a step plays every Stride studs of travel, not while standing or crawling"] = function(expect)
		local s = setup()
		local steps = s.Footsteps.Attach(s.rig, { Sound = 12345, Stride = 2, Volume = 0.3, PitchVariation = 0 })
		local sound = s.created[1]
		expect.equal(sound.ClassName, "Sound")
		expect.equal(sound.SoundId, "rbxassetid://12345")
		expect.equal(sound.Volume, 0.3)
		expect.equal(sound.Parent, s.root, "under the root, so it is 3D")

		s.heartbeat:Fire(0.1)
		s.rig.Pivot = CFrame.new(1.5, 0, 0)
		s.heartbeat:Fire(0.1)
		expect.equal(sound.Plays, 0, "1.5 studs is under the stride")
		s.rig.Pivot = CFrame.new(2.5, 0, 0)
		s.heartbeat:Fire(0.1)
		expect.equal(sound.Plays, 1)
		expect.equal(sound.PlaybackSpeed, 1)

		s.rig.Pivot = CFrame.new(2.5, 5, 0)
		s.heartbeat:Fire(0.1)
		expect.equal(sound.Plays, 1, "height does not count")

		s.rig.Pivot = CFrame.new(2.52, 5, 0)
		s.heartbeat:Fire(0.1)
		expect.equal(sound.Plays, 1, "a crawl under MinSpeed resets the count")

		steps:Destroy()
		expect.truthy(sound.Destroyed)
		s.rig.Pivot = CFrame.new(50, 0, 0)
		s.heartbeat:Fire(0.1)
		expect.equal(sound.Plays, 1, "stopped")
	end,

	["OnStep runs per step with the position, with or without a Sound"] = function(expect)
		local s = setup()
		local steps = {}
		s.Footsteps.Attach(s.rig, {
			Stride = 1,
			OnStep = function(position, root)
				table.insert(steps, { position, root })
			end,
		})
		expect.equal(#s.created, 0, "no sound made")

		s.heartbeat:Fire(0.1)
		s.rig.Pivot = CFrame.new(0, 0, -3)
		s.heartbeat:Fire(0.1)
		expect.equal(#steps, 1, "one step per heartbeat at most")
		expect.equal(steps[1][1], Vector3.new(0, 0, -3))
		expect.equal(steps[1][2], s.root)

		expect.includes(
			expect.errors(function()
				s.Footsteps.Attach(s.rig, {})
			end),
			"give a Sound"
		)
	end,
}
