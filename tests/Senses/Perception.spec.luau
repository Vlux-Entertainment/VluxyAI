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

	["IsHidden reads the AI_HIDDEN attribute on the root or its character"] = function(expect)
		local Perception = load()
		local character = SenseFakes.Character("Hider", ORIGIN)
		local attributes = {}
		character.Model.GetAttribute = function(_self, name)
			return attributes[name]
		end

		expect.falsy(Perception.IsHidden(character.Root))
		attributes.AI_HIDDEN = true
		expect.truthy(Perception.IsHidden(character.Root))
		attributes.AI_HIDDEN = nil

		local part = {
			Position = ORIGIN,
			GetAttribute = function(_self, name)
				return if name == "AI_HIDDEN" then true else nil
			end,
		}
		expect.truthy(Perception.IsHidden(part))
		expect.equal(Perception.HIDDEN_ATTRIBUTE, "AI_HIDDEN")
	end,

	["AliveRoots skips dead, characterless and hidden players unless asked for the hidden"] = function(expect)
		local alive = SenseFakes.Character("Alive", ORIGIN)
		local hidden = SenseFakes.Character("Hidden", ORIGIN)
		hidden.Model.GetAttribute = function(_self, name)
			return if name == "AI_HIDDEN" then true else nil
		end
		local dead = SenseFakes.Character("Dead", ORIGIN)
		dead.Humanoid.Health = 0
		local Perception = Harness.Load("lib/Senses/Perception.luau", {
			services = {
				Players = {
					GetPlayers = function()
						return {
							{ Character = alive.Model },
							{ Character = hidden.Model },
							{ Character = dead.Model },
							{ Character = nil },
						}
					end,
				},
			},
		})

		local roots = Perception.AliveRoots()
		expect.equal(#roots, 1)
		expect.equal(roots[1], alive.Root)

		local all = Perception.AllAliveRoots()
		expect.equal(#all, 2)
		expect.equal(all[2], hidden.Root)
	end,

	["Transparent is a see-through rule on Transparency"] = function(expect)
		local Perception = load()
		local rule = Perception.Transparent()
		expect.truthy(rule({ Transparency = 0.5 }))
		expect.falsy(rule({ Transparency = 0.49 }))
		expect.truthy(Perception.Transparent(0.9)({ Transparency = 0.95 }))
		expect.falsy(Perception.Transparent(0.9)({ Transparency = 0.6 }))
		expect.falsy(rule({}))
	end,

	["LineOfSight looks past see-through parts by casting again without them, up to a limit"] = function(expect)
		local rays = {}
		local panes = {}
		for index = 1, 10 do
			panes[index] = {
				Name = `Pane{index}`,
				Transparency = 1,
				IsDescendantOf = function()
					return false
				end,
			}
		end
		local Perception = Harness.Load("lib/Senses/Perception.luau", {
			globals = SenseFakes.Globals({
				rays = rays,
				hit = function(ray)
					for _, pane in panes do
						if not table.find(ray.Params.FilterDescendantsInstances, pane) then
							return { Instance = pane }
						end
					end
					return nil
				end,
			}),
		})
		local rule = Perception.Transparent()

		expect.falsy(Perception.LineOfSight(ORIGIN, Vector3.new(0, 0, -10), {}), "blocked without a rule")
		expect.equal(#rays, 1)

		table.clear(rays)
		expect.falsy(
			Perception.LineOfSight(ORIGIN, Vector3.new(0, 0, -10), {}, nil, rule),
			"ten panes is past the limit"
		)
		expect.equal(#rays, 9, "eight see-through parts, then it gives up")

		panes = { panes[1], panes[2] }
		table.clear(rays)
		expect.truthy(Perception.LineOfSight(ORIGIN, Vector3.new(0, 0, -10), {}, nil, rule), "two panes are fine")
		expect.equal(#rays, 3)
		expect.equal(#rays[1].Params.FilterDescendantsInstances, 0, "the caller's ignore list is not modified")
	end,

	["LightFalloff is linear from Brightness at the light to 0 at Range"] = function(expect)
		local Perception = load()
		expect.near(Perception.LightFalloff(0, 10, 2), 2)
		expect.near(Perception.LightFalloff(5, 10, 2), 1)
		expect.near(Perception.LightFalloff(10, 10, 2), 0)
		expect.near(Perception.LightFalloff(50, 10, 2), 0)
		expect.near(Perception.LightFalloff(1, 0, 2), 0, 1e-6, "no range")
		expect.near(Perception.LightFalloff(1, 10, 0), 0, 1e-6, "no brightness")
	end,

	["LightContribution reads the light and its parent, and a spot light's cone"] = function(expect)
		local Perception = load()
		local part = SenseFakes.Part(ORIGIN, AHEAD)
		local point = {
			Enabled = true,
			Brightness = 1,
			Range = 20,
			Parent = part,
			IsA = function(_self, className)
				return className == "PointLight"
			end,
		}
		part.IsA = function(_self, className)
			return className == "BasePart"
		end

		expect.near(Perception.LightContribution(point, Vector3.new(0, 0, -10)), 0.5)
		point.Enabled = false
		expect.near(Perception.LightContribution(point, Vector3.new(0, 0, -10)), 0, 1e-6, "disabled")
		point.Enabled = true
		point.Parent = nil
		expect.near(Perception.LightContribution(point, Vector3.new(0, 0, -10)), 0, 1e-6, "not in the world")

		local spot = {
			Enabled = true,
			Brightness = 1,
			Range = 20,
			Angle = 90,
			Face = "Front",
			Parent = part,
			IsA = function(_self, className)
				return className == "SpotLight"
			end,
		}
		expect.near(Perception.LightContribution(spot, Vector3.new(0, 0, -10)), 0.5, 1e-6, "dead ahead of a Front face")
		expect.near(Perception.LightContribution(spot, Vector3.new(0, 0, 10)), 0, 1e-6, "behind the cone")
		spot.Face = "Back"
		expect.near(Perception.LightContribution(spot, Vector3.new(0, 0, 10)), 0.5, 1e-6, "a Back face points +Z")
	end,

	["LightAt sums the tagged lights over ambient and clamps to 1"] = function(expect)
		local part = SenseFakes.Part(ORIGIN, AHEAD)
		part.IsA = function(_self, className)
			return className == "BasePart"
		end
		local function lamp(brightness: number)
			return {
				Enabled = true,
				Brightness = brightness,
				Range = 20,
				Parent = part,
				IsA = function(_self, className)
					return className == "PointLight"
				end,
			}
		end
		local tagged = { AI_LIGHT = { lamp(1), lamp(0.6) } }
		local Perception = Harness.Load("lib/Senses/Perception.luau", {
			services = {
				CollectionService = {
					GetTagged = function(_self, tag)
						return tagged[tag] or {}
					end,
				},
			},
		})

		expect.near(Perception.LightAt(Vector3.new(0, 0, -10)), 0.8, 1e-6, "0.5 + 0.3")
		expect.near(Perception.LightAt(Vector3.new(0, 0, -10), 0.5), 1, 1e-6, "clamped")
		expect.near(Perception.LightAt(Vector3.new(0, 0, -100)), 0, 1e-6, "out of range")
		expect.near(Perception.LightAt(Vector3.new(0, 0, -100), 0.1), 0.1, 1e-6, "ambient alone")
		expect.equal(Perception.LIGHT_TAG, "AI_LIGHT")
	end,

	["SeenByAnyone: inside an observer's cone with a clear line, else not"] = function(expect)
		local watcher = SenseFakes.Character("Watcher", Vector3.new(0, 0, 10), AHEAD, AHEAD)
		local rays = {}
		local Perception = Harness.Load("lib/Senses/Perception.luau", { globals = SenseFakes.Globals({ rays = rays }) })
		local observers = { watcher.Root }

		expect.truthy(Perception.SeenByAnyone(Vector3.new(0, 0, -5), { Observers = observers }), "ahead of the watcher")
		expect.falsy(Perception.SeenByAnyone(Vector3.new(0, 0, 30), { Observers = observers }), "behind")
		expect.falsy(Perception.SeenByAnyone(Vector3.new(0, 0, -50), { Observers = observers, Range = 20 }), "too far")
		expect.equal(rays[1].From, watcher.Head.Position, "the ray starts at the head")

		local blocked = Harness.Load("lib/Senses/Perception.luau", {
			globals = SenseFakes.Globals({
				hit = function()
					return { Instance = {
						IsDescendantOf = function()
							return false
						end,
					} }
				end,
			}),
		})
		expect.falsy(blocked.SeenByAnyone(Vector3.new(0, 0, -5), { Observers = observers }), "a wall hides it")

		local eyes = {}
		expect.falsy(
			Perception.SeenByAnyone(Vector3.new(0, 0, -5), {
				Observers = observers,
				Eye = function(root)
					table.insert(eyes, root)
					return SenseFakes.Facing(Vector3.new(0, 0, 10), Vector3.new(1, 0, 0))
				end,
			}),
			"a custom eye looking the other way"
		)
		expect.equal(eyes[1], watcher.Root)
	end,

	["CountWalls counts distinct parts along the line, up to the limit, ignoring the margin at the end"] = function(
		expect
	)
		local hits = {}
		local walls = {
			{ Name = "Wall1", At = 3 },
			{ Name = "Wall2", At = 6 },
			{ Name = "Body", At = 19.5 },
		}
		local Perception = Harness.Load("lib/Senses/Perception.luau", {
			globals = SenseFakes.Globals({
				rays = hits,
				hit = function(ray)
					for _, wall in walls do
						if not table.find(ray.Params.FilterDescendantsInstances, wall) then
							return { Instance = wall, Position = ray.From + ray.Direction.Unit * wall.At }
						end
					end
					return nil
				end,
			}),
		})

		local from, to = Vector3.new(0, 0, 0), Vector3.new(0, 0, -20)
		expect.equal(Perception.CountWalls(from, to, {}), 2, "two walls; the body at the end is inside the margin")
		expect.equal(Perception.CountWalls(from, to, {}, 1), 1, "limited")
		expect.equal(Perception.CountWalls(from, to, { walls[1] }), 1, "an ignored part is not a wall")
		expect.equal(Perception.CountWalls(from, Vector3.new(0, 0, -1), {}), 0, "too short to have a wall")
		expect.equal(Perception.CountWalls(from, to, {}, 3, 0), 3, "with no margin the body counts")
	end,
}
