--!strict

--[[
	Locomotion: the idle, walk and run blend for a speed. Attaching to a rig drives real
	AnimationTracks and is play-tested.
]]

local Harness = require("../Support/Harness")

local function load()
	return Harness.Load("lib/Animator/Locomotion.luau")
end

local OPTIONS = { WalkSpeed = 10, RunSpeed = 20, MovingThreshold = 0.5 }

return {
	["below the threshold it idles"] = function(expect)
		local blend = load().Blend(0.4, OPTIONS, true)
		expect.equal(blend.Idle, 1)
		expect.equal(blend.Walk, 0)
		expect.equal(blend.Run, 0)
	end,

	["up to WalkSpeed it walks, at the speed over WalkSpeed"] = function(expect)
		local blend = load().Blend(5, OPTIONS, true)
		expect.equal(blend.Idle, 0)
		expect.equal(blend.Walk, 1)
		expect.equal(blend.Run, 0)
		expect.equal(blend.WalkPlayback, 0.5)
	end,

	["between WalkSpeed and RunSpeed the walk crossfades into the run"] = function(expect)
		local blend = load().Blend(15, OPTIONS, true)
		expect.equal(blend.Walk, 0.5)
		expect.equal(blend.Run, 0.5)
		expect.equal(blend.RunPlayback, 0.75)
	end,

	["above RunSpeed it runs, and without a run it keeps walking faster"] = function(expect)
		local Locomotion = load()
		local running = Locomotion.Blend(30, OPTIONS, true)
		expect.equal(running.Run, 1)
		expect.equal(running.Walk, 0)
		expect.equal(running.RunPlayback, 1.5)

		local walking = Locomotion.Blend(30, OPTIONS, false)
		expect.equal(walking.Walk, 1)
		expect.equal(walking.Run, 0)
		expect.equal(walking.WalkPlayback, 3)
	end,
}
