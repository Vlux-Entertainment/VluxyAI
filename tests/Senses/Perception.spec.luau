--!strict

--[[
	The pure helpers every sense is built on: the view cone test, the distance sort, and the
	lookups from a part to its position, eye, character and humanoid.
]]

local Harness = require("../Support/Harness")
local SenseFakes = require("./SenseFakes")

local roblox = require("@lune/roblox")
local Vector3 = roblox.Vector3

local function load()
	return Harness.Load("lib/Senses/Perception.luau")
end

local ORIGIN = Vector3.new(0, 0, 0)
local AHEAD = Vector3.new(0, 0, -1)

return {
	["InCone: a position dead ahead within range is inside with dot 1"] = function(expect)
		local Perception = load()
		local eye = SenseFakes.Facing(ORIGIN, AHEAD)

		local inside, dot = Perception.InCone(eye, Vector3.new(0, 0, -10), 90, 40)
		expect.truthy(inside)
		expect.near(dot, 1)
	end,

	["InCone: a position outside the field of view is outside, with its dot"] = function(expect)
		local Perception = load()
		local eye = SenseFakes.Facing(ORIGIN, AHEAD)

		-- 60 degrees off the look direction, against a 90 degree cone (45 each side).
		local position = Vector3.new(math.sin(math.rad(60)), 0, -math.cos(math.rad(60))) * 10
		local inside, dot = Perception.InCone(eye, position, 90, 40)
		expect.falsy(inside)
		expect.near(dot, 0.5, 1e-6)
	end,

	["InCone: a position exactly on the edge of the cone is inside"] = function(expect)
		local Perception = load()
		local eye = SenseFakes.Facing(ORIGIN, AHEAD)

		local position = Vector3.new(math.sin(math.rad(45)), 0, -math.cos(math.rad(45))) * 10
		local inside = Perception.InCone(eye, position, 90, 40)
		expect.truthy(inside)
	end,

	["InCone: a position behind is outside with dot -1"] = function(expect)
		local Perception = load()
		local eye = SenseFakes.Facing(ORIGIN, AHEAD)

		local inside, dot = Perception.InCone(eye, Vector3.new(0, 0, 10), 120, 40)
		expect.falsy(inside)
		expect.near(dot, -1)
	end,

	["InCone: the angle counts vertically too"] = function(expect)
		local Perception = load()
		local eye = SenseFakes.Facing(ORIGIN, AHEAD)

		-- Straight ahead horizontally, but 60 degrees up: outside a 90 degree cone.
		local position = Vector3.new(0, math.sin(math.rad(60)), -math.cos(math.rad(60))) * 10
		local inside = Perception.InCone(eye, position, 90, 40)
		expect.falsy(inside)

		local lower = Vector3.new(0, math.sin(math.rad(30)), -math.cos(math.rad(30))) * 10
		expect.truthy(Perception.InCone(eye, lower, 90, 40))
	end,

	["InCone: out of range is outside even dead ahead, and still reports the dot"] = function(expect)
		local Perception = load()
		local eye = SenseFakes.Facing(ORIGIN, AHEAD)

		local inside, dot = Perception.InCone(eye, Vector3.new(0, 0, -41), 90, 40)
		expect.falsy(inside)
		expect.near(dot, 1)
		expect.truthy(Perception.InCone(eye, Vector3.new(0, 0, -40), 90, 40), "exactly at range is inside")
	end,

	["InCone: a position at the origin is inside"] = function(expect)
		local Perception = load()
		local eye = SenseFakes.Facing(Vector3.new(5, 5, 5), AHEAD)

		local inside, dot = Perception.InCone(eye, Vector3.new(5, 5, 5), 90, 40)
		expect.truthy(inside)
		expect.equal(dot, 1)
	end,

	["InCone: a 360 degree field of view sees all round"] = function(expect)
		local Perception = load()
		local eye = SenseFakes.Facing(ORIGIN, AHEAD)

		expect.truthy(Perception.InCone(eye, Vector3.new(0, 0, 10), 360, 40))
	end,

	["InCone: the look direction follows the origin CFrame"] = function(expect)
		local Perception = load()
		local eye = SenseFakes.Facing(Vector3.new(10, 0, 10), Vector3.new(1, 0, 0))

		expect.truthy(Perception.InCone(eye, Vector3.new(20, 0, 10), 90, 40), "ahead along +X")
		expect.falsy(Perception.InCone(eye, Vector3.new(10, 0, 0), 90, 40), "off to the side")
	end,

	["SortByDistance: nearest first, in a new list, without touching the input"] = function(expect)
		local Perception = load()
		local far = { Position = Vector3.new(30, 0, 0) }
		local near = { Position = Vector3.new(1, 0, 0) }
		local middle = { Position = Vector3.new(0, 10, 0) }
		local parts = { far, near, middle }

		local sorted = Perception.SortByDistance(ORIGIN, parts)
		expect.equal(sorted[1], near)
		expect.equal(sorted[2], middle)
		expect.equal(sorted[3], far)
		expect.equal(#sorted, 3)

		expect.falsy(sorted == parts, "a new list")
		expect.equal(parts[1], far, "input untouched")
		expect.equal(parts[2], near, "input untouched")
		expect.equal(parts[3], middle, "input untouched")
	end,

	["SortByDistance: parts at the same distance keep their order"] = function(expect)
		local Perception = load()
		local a = { Position = Vector3.new(5, 0, 0) }
		local b = { Position = Vector3.new(0, 5, 0) }
		local c = { Position = Vector3.new(0, 0, 5) }
		local d = { Position = Vector3.new(-5, 0, 0) }

		local sorted = Perception.SortByDistance(ORIGIN, { a, b, c, d })
		expect.equal(sorted[1], a)
		expect.equal(sorted[2], b)
		expect.equal(sorted[3], c)
		expect.equal(sorted[4], d)
	end,

	["SortByDistance: an empty list gives an empty list"] = function(expect)
		local Perception = load()
		expect.equal(#Perception.SortByDistance(ORIGIN, {}), 0)
	end,

	["PositionOf: uses GetPosition when the agent has it, else the pivot"] = function(expect)
		local Perception = load()

		local withMover = SenseFakes.Agent(Vector3.new(1, 2, 3))
		withMover.GetPosition = function()
			return Vector3.new(9, 9, 9)
		end
		expect.equal(Perception.PositionOf(withMover), Vector3.new(9, 9, 9))

		local pivotOnly = SenseFakes.Agent(Vector3.new(1, 2, 3)) :: any
		pivotOnly.GetPosition = nil
		expect.equal(Perception.PositionOf(pivotOnly), Vector3.new(1, 2, 3))
	end,

	["EyeOf: the head when the character has one, else the root"] = function(expect)
		local Perception = load()

		local withHead = SenseFakes.Character("A", ORIGIN, AHEAD, AHEAD)
		expect.equal(Perception.EyeOf(withHead.Root), withHead.Head)

		local headless = SenseFakes.Character("B", ORIGIN, AHEAD)
		expect.equal(Perception.EyeOf(headless.Root), headless.Root)

		local loose = SenseFakes.Part(ORIGIN)
		expect.equal(Perception.EyeOf(loose), loose, "a part with no model is its own eye")
	end,

	["CharacterOf: the nearest ancestor Model, or nil"] = function(expect)
		local Perception = load()

		local character = SenseFakes.Character("A", ORIGIN, AHEAD, AHEAD)
		expect.equal(Perception.CharacterOf(character.Root), character.Model)
		expect.equal(Perception.CharacterOf(character.Head), character.Model, "any part of the character")

		expect.equal(Perception.CharacterOf(SenseFakes.Part(ORIGIN)), nil, "a loose part has no character")
	end,

	["HumanoidOf: the Humanoid inside the part's character, or nil"] = function(expect)
		local Perception = load()

		local character = SenseFakes.Character("A", ORIGIN, AHEAD)
		expect.equal(Perception.HumanoidOf(character.Root), character.Humanoid)

		expect.equal(Perception.HumanoidOf(SenseFakes.Part(ORIGIN)), nil, "no character")

		local hollow = SenseFakes.Character("B", ORIGIN, AHEAD)
		hollow.Model.FindFirstChildOfClass = function()
			return nil
		end
		expect.equal(Perception.HumanoidOf(hollow.Root), nil, "a character without a Humanoid")
	end,

	["IgnoreList: the agent's entity alone"] = function(expect)
		local Perception = load()
		local agent = SenseFakes.Agent(ORIGIN)

		local list = Perception.IgnoreList(agent)
		expect.equal(#list, 1)
		expect.equal(list[1], agent.Entity)
	end,
}
