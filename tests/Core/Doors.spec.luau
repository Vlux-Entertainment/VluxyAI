--!strict

--[[
	Doors: the registration a door label gets. Doors are plain tables with attribute methods and
	the agent records what it emits, so every branch of the handler runs without a DataModel.
]]

local Harness = require("../Support/Harness")
local SenseFakes = require("../Senses/SenseFakes")

local roblox = require("@lune/roblox")
local Vector3 = roblox.Vector3

local function load(tagged: { any }?)
	return Harness.Load("lib/World/Doors.luau", {
		services = {
			CollectionService = {
				GetTagged = function(_self, tag)
					return if tag == "AI_DOOR" then tagged or {} else {}
				end,
			},
		},
	})
end

--[[
	A door with attributes, like an Instance's.
]]
local function fakeDoor(attributes: { [string]: any }?, position: any?)
	local door = { Name = "Door", Attributes = attributes or {}, Position = position or Vector3.new(0, 0, 0) }
	function door.IsA(_self, className)
		return className == "BasePart"
	end
	function door.GetAttribute(self, name)
		return self.Attributes[name]
	end
	function door.SetAttribute(self, name, value)
		self.Attributes[name] = value
	end
	return door
end

local function fakeAgent()
	local agent = { Name = "Fake", Blackboard = {}, Data = {}, Emitted = {} :: { { any } } }
	function agent.Emit(self, name, payload)
		table.insert(self.Emitted, { name, payload })
	end
	return agent
end

local function step(door: any?)
	return { Position = Vector3.new(0, 0, 0), Action = "Custom", Label = "Door", Instance = door }
end

return {
	["Step with no driver uses the attributes and the AI_DOOR tag"] = function(expect)
		local Doors = load()
		local registration = Doors.Step()
		expect.equal(registration.Tag, "AI_DOOR")
		expect.equal(registration.Radius, 8)
		expect.equal(type(registration.Handler), "function")
		expect.equal(type(registration.Ready), "function")
	end,

	["an open door is Ready, a closed or locked one is not, and no door at all is"] = function(expect)
		local Doors = load()
		local registration = Doors.Step()
		local agent = fakeAgent()

		expect.truthy(registration.Ready(agent, step(fakeDoor({ ["AI_DOOR/Open"] = true }))))
		expect.falsy(registration.Ready(agent, step(fakeDoor())))
		expect.falsy(registration.Ready(agent, step(fakeDoor({ ["AI_DOOR/Open"] = true, ["AI_DOOR/Locked"] = true }))))
		expect.truthy(registration.Ready(agent, step(nil)), "a step with no door found is walked through")
	end,

	["a closed door is announced, opened, waited for, and taken"] = function(expect)
		local Doors = load()
		local registration = Doors.Step(nil, { OpenTime = 0.01 })
		local agent = fakeAgent()
		local door = fakeDoor()

		local taken, seconds = registration.Handler(agent, step(door), 2)
		expect.equal(taken, true)
		expect.equal(seconds, nil)
		expect.equal(door:GetAttribute("AI_DOOR/Open"), true)
		expect.equal(#agent.Emitted, 1)
		expect.equal(agent.Emitted[1][1], "Door")
		expect.equal(agent.Emitted[1][2], door)
	end,

	["the door's own AI_DOOR/OpenTime wins over the option"] = function(expect)
		local Doors = load()
		expect.equal(Doors.Attributes:OpenTime(fakeDoor({ ["AI_DOOR/OpenTime"] = 1.5 })), 1.5)
		expect.equal(Doors.Attributes:OpenTime(fakeDoor()), 0.5)
		expect.equal(Doors.Attributes:OpenTime(fakeDoor({ ["AI_DOOR/OpenTime"] = "slow" })), 0.5)
	end,

	["a locked door is refused for CloseSeconds and never opened"] = function(expect)
		local Doors = load()
		local registration = Doors.Step(nil, { CloseSeconds = 15 })
		local agent = fakeAgent()
		local door = fakeDoor({ ["AI_DOOR/Locked"] = true })

		local taken, seconds = registration.Handler(agent, step(door), 2)
		expect.equal(taken, false)
		expect.equal(seconds, 15)
		expect.equal(door:GetAttribute("AI_DOOR/Open"), nil)
		expect.equal(#agent.Emitted, 0)
	end,

	['a custom driver is used as given, and Emit = "" sends nothing'] = function(expect)
		local Doors = load()
		local log = {}
		local driver = {
			IsOpen = function(_self, door)
				return door.Swung == true
			end,
			Open = function(_self, door, agent)
				table.insert(log, agent.Name)
				door.Swung = true
			end,
			OpenTime = function()
				return 0
			end,
		}
		local registration = Doors.Step(driver, { Emit = "" })
		local agent = fakeAgent()
		local door = { Name = "Hatch" }

		expect.falsy(registration.Ready(agent, step(door)))
		expect.equal(registration.Handler(agent, step(door), 1), true)
		expect.equal(door.Swung, true)
		expect.equal(log[1], "Fake")
		expect.equal(#agent.Emitted, 0)
		expect.truthy(registration.Ready(agent, step(door)), "a driver with no IsLocked has no locks")
	end,

	["a driver without IsOpen or Open, or an unknown option, is refused"] = function(expect)
		local Doors = load()
		local message = expect.errors(function()
			Doors.Step({ IsOpen = function() end } :: any)
		end)
		expect.includes(message, "driver needs IsOpen and Open")

		message = expect.errors(function()
			Doors.Step(nil, { Tags = "x" } :: any)
		end)
		expect.includes(message, "Doors.Step")
	end,

	["WalkThrough opens a closed door from Ready and never holds"] = function(expect)
		local Doors = load()
		local registration = Doors.Step(nil, { WalkThrough = true })
		local agent = fakeAgent()
		local door = fakeDoor()

		expect.truthy(registration.Ready(agent, step(door)), "the agent keeps walking")
		expect.equal(door:GetAttribute("AI_DOOR/Open"), true, "and the door was opened on the way")
		expect.equal(#agent.Emitted, 1)

		local locked = fakeDoor({ ["AI_DOOR/Locked"] = true })
		expect.falsy(registration.Ready(agent, step(locked)), "a locked door still goes to the handler")
		expect.equal(registration.Handler(agent, step(locked), 1), false)
		expect.equal(locked:GetAttribute("AI_DOOR/Open"), nil)
	end,

	["Opener opens the nearest closed door ahead within Radius, and writes NearDoor"] = function(expect)
		local ahead = fakeDoor(nil, Vector3.new(0, 0, -4))
		local behind = fakeDoor(nil, Vector3.new(0, 0, 3))
		local far = fakeDoor(nil, Vector3.new(0, 0, -9))
		local Doors = load({ behind, far, ahead })
		local opener = Doors.Opener()
		local agent = SenseFakes.Agent(Vector3.new(0, 0, 0), Vector3.new(0, 0, -1))
		local emitted = {}
		agent.Emit = function(_self, name, payload)
			table.insert(emitted, { name, payload })
		end

		opener:Tick(agent, 0.1)
		expect.equal(agent.Blackboard.NearDoor, ahead)
		expect.near(agent.Blackboard.NearDoorDistance, 4)
		expect.equal(ahead:GetAttribute("AI_DOOR/Open"), true)
		expect.equal(behind:GetAttribute("AI_DOOR/Open"), nil, "a door behind is left alone")
		expect.equal(far:GetAttribute("AI_DOOR/Open"), nil, "a door beyond Radius is left alone")
		expect.equal(#emitted, 1)

		opener:Tick(agent, 0.1)
		expect.equal(#emitted, 1, "an open door is not opened again")
	end,

	["Opener leaves a locked door shut and reports nothing when no door is near"] = function(expect)
		local locked = fakeDoor({ ["AI_DOOR/Locked"] = true }, Vector3.new(0, 0, -3))
		local Doors = load({ locked })
		local opener = Doors.Opener()
		local agent = SenseFakes.Agent(Vector3.new(0, 0, 0), Vector3.new(0, 0, -1))
		agent.Emit = function() end

		opener:Tick(agent, 0.1)
		expect.equal(agent.Blackboard.NearDoor, locked)
		expect.equal(locked:GetAttribute("AI_DOOR/Open"), nil)

		local empty = load({}).Opener()
		empty:Tick(agent, 0.1)
		expect.equal(agent.Blackboard.NearDoor, nil)
		expect.equal(agent.Blackboard.NearDoorDistance, math.huge)
	end,

	["IgnoreUnlocked adds every door that is not locked to the base list"] = function(expect)
		local open = fakeDoor()
		local locked = fakeDoor({ ["AI_DOOR/Locked"] = true })
		local Doors = load({ open, locked })
		local entity = { Name = "Rig" }
		local ignore = Doors.IgnoreUnlocked(function()
			return { entity }
		end)

		local list = ignore(fakeAgent())
		expect.equal(#list, 2)
		expect.equal(list[1], entity)
		expect.equal(list[2], open)
	end,
}
