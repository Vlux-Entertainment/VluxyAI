--!strict

--[[
	The Humanoid mover against a fake rig: a root with a Position the spec moves by hand, and a
	humanoid whose MoveToFinished is the package's own Signal, so the spec plays Roblox and fires
	it. Stuck detection is driven by a manual Heartbeat. `ChooseStart` is specced as pure maths.
]]

local Fakes = require("../Support/Fakes")
local Harness = require("../Support/Harness")

local roblox = require("@lune/roblox")
local Vector3 = roblox.Vector3

local function load(heartbeat: any?)
	return Harness.Load("lib/Movers/Humanoid.luau", {
		services = { RunService = { Heartbeat = heartbeat or Harness.ManualHeartbeat() } },
	})
end

--[[
	A stand-in Model with a PrimaryPart and a Humanoid child. Records every MoveTo.
]]
local function fakeRig(position: any?, withHumanoid: boolean?, withRoot: boolean?)
	local Signal = Fakes.Signal()

	local root = {
		Name = "HumanoidRootPart",
		Position = position or Vector3.new(0, 0, 0),
		NetworkOwners = {} :: { any },
	}
	function root.SetNetworkOwner(self, owner)
		table.insert(self.NetworkOwners, if owner == nil then "server" else owner)
	end

	local humanoid = {
		WalkSpeed = 0,
		Jump = false,
		MoveTos = {} :: { any },
		MoveToFinished = Signal.new(),
	}
	function humanoid.MoveTo(self, target)
		table.insert(self.MoveTos, target)
	end

	local model = {
		Name = "Rig",
		PrimaryPart = if withRoot == false then nil else root,
	}
	function model.FindFirstChildOfClass(_self, className: string)
		if className == "Humanoid" and withHumanoid ~= false then
			return humanoid
		end
		return nil
	end
	function model.GetFullName()
		return "Workspace.Rig"
	end

	return model, root, humanoid
end

local function step(x: number, y: number, z: number, action: string?, label: string?)
	return { Position = Vector3.new(x, y, z), Action = action or "Walk", Label = label }
end

local function setup(options: any?, position: any?)
	local heartbeat = Harness.ManualHeartbeat()
	local HumanoidMover = load(heartbeat)
	local model, root, humanoid = fakeRig(position)
	local mover = HumanoidMover.new(model, options)

	local events = {}
	mover.Arrived:Connect(function(reached)
		table.insert(events, `arrived {tostring(reached)}`)
	end)
	mover.StepReached:Connect(function(index, reachedStep)
		table.insert(events, `step {index}{if reachedStep.Label then " " .. reachedStep.Label else ""}`)
	end)

	return {
		HumanoidMover = HumanoidMover,
		heartbeat = heartbeat,
		model = model,
		root = root,
		humanoid = humanoid,
		mover = mover,
		events = events,
	}
end

return {
	------------------------------------------------------------------------------------------------------------------
	-- ChooseStart
	------------------------------------------------------------------------------------------------------------------

	["ChooseStart skips a leading step at the rig's position"] = function(expect)
		local HumanoidMover = load()
		local path = { step(0, 0, 0), step(4, 0, 0), step(8, 0, 0) }
		expect.equal(HumanoidMover.ChooseStart(path, Vector3.new(0, 0, 0), 1), 2)
	end,

	["ChooseStart keeps a leading step that is further than SkipDistance"] = function(expect)
		local HumanoidMover = load()
		local path = { step(2, 0, 0), step(4, 0, 0) }
		expect.equal(HumanoidMover.ChooseStart(path, Vector3.new(0, 0, 0), 1), 1)
	end,

	["ChooseStart ignores height"] = function(expect)
		local HumanoidMover = load()
		local path = { step(0.5, -3, 0), step(4, 0, 0) }
		expect.equal(HumanoidMover.ChooseStart(path, Vector3.new(0, 0, 0), 1), 2)
	end,

	["ChooseStart skips a run of leading steps but never the last"] = function(expect)
		local HumanoidMover = load()
		local path = { step(0, 0, 0), step(0.5, 0, 0), step(0.9, 0, 0) }
		expect.equal(HumanoidMover.ChooseStart(path, Vector3.new(0, 0, 0), 1), 3)
		expect.equal(HumanoidMover.ChooseStart({ step(0, 0, 0) }, Vector3.new(0, 0, 0), 1), 1)
	end,

	["ChooseStart returns 1 for an empty path"] = function(expect)
		local HumanoidMover = load()
		expect.equal(HumanoidMover.ChooseStart({}, Vector3.new(0, 0, 0), 1), 1)
	end,

	------------------------------------------------------------------------------------------------------------------
	-- new and the options
	------------------------------------------------------------------------------------------------------------------

	["the default options set WalkSpeed to 16 and hand the root to the server"] = function(expect)
		local s = setup()
		expect.equal(s.humanoid.WalkSpeed, 16)
		expect.equal(s.mover:GetSpeed(), 16)
		expect.sequence(s.root.NetworkOwners, { "server" })
	end,

	["options overlay the defaults"] = function(expect)
		local s = setup({ Speed = 20, ServerOwned = false })
		expect.equal(s.humanoid.WalkSpeed, 20)
		expect.equal(s.mover:GetSpeed(), 20)
		expect.sequence(s.root.NetworkOwners, {})
	end,

	["SetSpeed changes WalkSpeed"] = function(expect)
		local s = setup()
		s.mover:SetSpeed(9)
		expect.equal(s.humanoid.WalkSpeed, 9)
		expect.equal(s.mover:GetSpeed(), 9)
	end,

	["new needs a PrimaryPart and a Humanoid and names the model"] = function(expect)
		local HumanoidMover = load()

		local noRoot = fakeRig(nil, true, false)
		local message = expect.errors(function()
			HumanoidMover.new(noRoot :: any)
		end)
		expect.includes(message, "[VluxyAI]")
		expect.includes(message, "Workspace.Rig")
		expect.includes(message, "PrimaryPart")

		local noHumanoid = fakeRig(nil, false, true)
		message = expect.errors(function()
			HumanoidMover.new(noHumanoid :: any)
		end)
		expect.includes(message, "Workspace.Rig")
		expect.includes(message, "Humanoid")
	end,

	["GetPosition is the PrimaryPart position"] = function(expect)
		local s = setup(nil, Vector3.new(1, 2, 3))
		expect.equal(s.mover:GetPosition(), Vector3.new(1, 2, 3))
		s.root.Position = Vector3.new(4, 5, 6)
		expect.equal(s.mover:GetPosition(), Vector3.new(4, 5, 6))
	end,

	------------------------------------------------------------------------------------------------------------------
	-- Follow, Stop and the signals
	------------------------------------------------------------------------------------------------------------------

	["Follow walks each step on MoveToFinished and fires Arrived(true) after the last"] = function(expect)
		local s = setup()
		local path = { step(0, 0, 0, "Walk", "here"), step(4, 0, 0, "Walk", "a"), step(8, 0, 0, "Walk", "b") }

		s.mover:Follow(path)
		expect.truthy(s.mover:IsMoving())
		expect.sequence(s.events, {}, "nothing is reported from inside Follow")
		expect.equal(#s.humanoid.MoveTos, 1)
		expect.equal(s.humanoid.MoveTos[1], Vector3.new(4, 0, 0), "the step at the rig's position is skipped")

		s.root.Position = Vector3.new(4, 0, 0)
		s.humanoid.MoveToFinished:Fire(true)
		expect.sequence(s.events, { "step 2 a" })
		expect.equal(s.humanoid.MoveTos[2], Vector3.new(8, 0, 0))

		s.root.Position = Vector3.new(8, 0, 0)
		s.humanoid.MoveToFinished:Fire(true)
		expect.sequence(s.events, { "step 2 a", "step 3 b", "arrived true" })
		expect.falsy(s.mover:IsMoving())
		expect.equal(#s.humanoid.MoveTos, 2, "no cancel MoveTo after a clean arrival")
		expect.equal(s.heartbeat:Count(), 0, "the stuck check is disconnected")

		s.humanoid.MoveToFinished:Fire(true)
		expect.sequence(s.events, { "step 2 a", "step 3 b", "arrived true" }, "a late MoveToFinished is ignored")
	end,

	["a Jump step sets Jump when starting toward it; Custom walks like Walk"] = function(expect)
		local s = setup()
		s.mover:Follow({ step(4, 0, 0, "Custom", "door"), step(8, 0, 0, "Jump", "gap") })
		expect.falsy(s.humanoid.Jump)
		expect.equal(s.humanoid.MoveTos[1], Vector3.new(4, 0, 0))

		s.humanoid.MoveToFinished:Fire(true)
		expect.sequence(s.events, { "step 1 door" })
		expect.truthy(s.humanoid.Jump)
		expect.equal(s.humanoid.MoveTos[2], Vector3.new(8, 0, 0))
	end,

	["MoveToFinished(false) gives up with Arrived(false)"] = function(expect)
		local s = setup()
		s.mover:Follow({ step(4, 0, 0), step(8, 0, 0) })
		s.humanoid.MoveToFinished:Fire(false)
		expect.sequence(s.events, { "arrived false" })
		expect.falsy(s.mover:IsMoving())
		expect.equal(#s.humanoid.MoveTos, 2, "the walk is cancelled with a MoveTo to the root")
		expect.equal(s.humanoid.MoveTos[2], s.root.Position)
	end,

	["Follow fires Arrived(false) for the path it replaces before the new one starts"] = function(expect)
		local s = setup()
		s.mover:Follow({ step(4, 0, 0, "Walk", "old") })
		s.mover:Follow({ step(0, 0, 8, "Walk", "new") })
		expect.sequence(s.events, { "arrived false" })
		expect.truthy(s.mover:IsMoving())
		expect.equal(s.humanoid.MoveTos[#s.humanoid.MoveTos], Vector3.new(0, 0, 8))
		expect.equal(s.heartbeat:Count(), 1, "one stuck check, not two")

		s.humanoid.MoveToFinished:Fire(true)
		expect.sequence(s.events, { "arrived false", "step 1 new", "arrived true" })
	end,

	["Stop cancels the walk and fires Arrived(false) once"] = function(expect)
		local s = setup(nil, Vector3.new(1, 0, 1))
		s.mover:Follow({ step(4, 0, 0) })
		s.mover:Stop()
		expect.sequence(s.events, { "arrived false" })
		expect.falsy(s.mover:IsMoving())
		expect.equal(s.humanoid.MoveTos[2], Vector3.new(1, 0, 1), "MoveTo to the root cancels the walk")
		expect.equal(s.heartbeat:Count(), 0)

		s.mover:Stop()
		s.humanoid.MoveToFinished:Fire(true)
		expect.sequence(s.events, { "arrived false" })
	end,

	["a zero-step path fires Arrived(false) on the next heartbeat, never inside Follow"] = function(expect)
		local s = setup()
		s.mover:Follow({})
		expect.sequence(s.events, {})
		expect.truthy(s.mover:IsMoving())
		expect.equal(#s.humanoid.MoveTos, 0)

		s.heartbeat:Fire(0.1)
		expect.sequence(s.events, { "arrived false" })
		expect.falsy(s.mover:IsMoving())
	end,

	["a rig that stops making progress gives up after StuckTimeout"] = function(expect)
		local s = setup({ StuckTimeout = 1, StuckDistance = 0.5 })
		s.mover:Follow({ step(10, 0, 0) })

		s.root.Position = Vector3.new(1, 0, 0)
		s.heartbeat:Fire(0.9)
		expect.sequence(s.events, {}, "it moved")
		s.heartbeat:Fire(0.9)
		expect.sequence(s.events, {}, "0.9 seconds since the last move")
		s.root.Position = Vector3.new(1.2, 0, 0)
		s.heartbeat:Fire(0.2)
		expect.sequence(s.events, { "arrived false" }, "0.2 studs is not progress; 1.1 seconds is the timeout")
		expect.falsy(s.mover:IsMoving())
		expect.equal(s.humanoid.MoveTos[2], Vector3.new(1.2, 0, 0), "cancelled")
	end,

	["the stuck clock restarts at each step"] = function(expect)
		local s = setup({ StuckTimeout = 1 })
		s.mover:Follow({ step(4, 0, 0), step(8, 0, 0) })

		s.heartbeat:Fire(0.8)
		s.humanoid.MoveToFinished:Fire(true)
		s.heartbeat:Fire(0.8)
		expect.sequence(s.events, { "step 1" }, "still going")
		s.heartbeat:Fire(0.3)
		expect.sequence(s.events, { "step 1", "arrived false" })
	end,

	["a StepReached handler may call Follow again without a double report"] = function(expect)
		local s = setup()
		local replaced = false
		s.mover.StepReached:Connect(function(index)
			if index == 1 and not replaced then
				replaced = true
				s.mover:Follow({ step(50, 0, 0, "Walk", "detour") })
			end
		end)

		s.mover:Follow({ step(10, 0, 0, "Walk", "a"), step(20, 0, 0, "Walk", "b") })
		s.humanoid.MoveToFinished:Fire(true)
		expect.sequence(s.events, { "step 1 a", "arrived false" })
		expect.equal(s.humanoid.MoveTos[#s.humanoid.MoveTos], Vector3.new(50, 0, 0), "walking the detour, not step b")

		s.humanoid.MoveToFinished:Fire(true)
		expect.sequence(s.events, { "step 1 a", "arrived false", "step 1 detour", "arrived true" })
	end,

	["Destroy stops, reports the path and ignores later calls"] = function(expect)
		local s = setup()
		s.mover:Follow({ step(10, 0, 0) })
		s.mover:Destroy()
		expect.sequence(s.events, { "arrived false" })
		expect.equal(s.heartbeat:Count(), 0)

		s.mover:Follow({ step(10, 0, 0) })
		expect.falsy(s.mover:IsMoving())
		expect.equal(#s.humanoid.MoveTos, 2, "no new MoveTo after Destroy")
		s.mover:Destroy()
	end,
}
