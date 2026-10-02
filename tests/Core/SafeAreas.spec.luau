--!strict

--[[
	SafeAreas: the box test is pure, and Contains runs against a fake CollectionService so the
	tag, the Enabled attribute and the box are all checked without a DataModel. Setup (collision
	groups and modifiers) is play-tested.
]]

local Harness = require("../Support/Harness")

local roblox = require("@lune/roblox")
local CFrame = roblox.CFrame
local Vector3 = roblox.Vector3

--[[
	A tagged part as SafeAreas sees one: a box with attributes.
]]
local function safePart(position: any, size: any, enabled: boolean?)
	local part = {
		Name = "SafeRoom",
		CFrame = CFrame.new(position),
		Size = size,
		Attributes = { ["VLUXYAI_SAFE/Enabled"] = enabled },
	}
	function part.IsA(_self, className: string)
		return className == "BasePart"
	end
	function part.GetAttribute(self, name: string)
		return self.Attributes[name]
	end
	return part
end

local function load(parts: { any }?)
	return Harness.Load("lib/World/SafeAreas.luau", {
		services = {
			CollectionService = {
				GetTagged = function(_self, tag: string)
					return if tag == "VLUXYAI_SAFE" then parts or {} else {}
				end,
			},
		},
	})
end

return {
	["InBox is inside the part's own box, rotation included"] = function(expect)
		local SafeAreas = load()
		local box = CFrame.new(0, 0, 0)
		expect.truthy(SafeAreas.InBox(box, Vector3.new(10, 4, 2), Vector3.new(4.9, 1.9, 0.9)))
		expect.falsy(SafeAreas.InBox(box, Vector3.new(10, 4, 2), Vector3.new(0, 0, 1.1)))

		local turned = CFrame.new(0, 0, 0) * CFrame.Angles(0, math.rad(90), 0)
		expect.truthy(SafeAreas.InBox(turned, Vector3.new(10, 4, 2), Vector3.new(0, 0, 4.9)), "long side now along Z")
		expect.falsy(SafeAreas.InBox(turned, Vector3.new(10, 4, 2), Vector3.new(4.9, 0, 0)))
	end,

	["Contains finds an enabled area around the point, and returns it"] = function(expect)
		local room = safePart(Vector3.new(8, 3, 8), Vector3.new(15, 6, 15))
		local SafeAreas = load({ room })
		local inside, area = SafeAreas.Contains(Vector3.new(8, 1, 8))
		expect.truthy(inside)
		expect.equal(area, room)
		expect.falsy(SafeAreas.Contains(Vector3.new(30, 1, 8)))
	end,

	["an area with VLUXYAI_SAFE/Enabled = false is not safe; a missing attribute means on"] = function(expect)
		local off = safePart(Vector3.new(0, 3, 0), Vector3.new(10, 6, 10), false)
		local on = safePart(Vector3.new(40, 3, 0), Vector3.new(10, 6, 10), nil)
		local SafeAreas = load({ off, on })
		expect.falsy(SafeAreas.IsEnabled(off))
		expect.truthy(SafeAreas.IsEnabled(on))
		expect.falsy(SafeAreas.Contains(Vector3.new(0, 1, 0)), "switched off")
		expect.truthy(SafeAreas.Contains(Vector3.new(40, 1, 0)))
	end,

	["with no CollectionService nothing is safe, and nothing errors"] = function(expect)
		local SafeAreas = Harness.Load("lib/World/SafeAreas.luau")
		expect.falsy(SafeAreas.Contains(Vector3.new(0, 0, 0)))
	end,
}
