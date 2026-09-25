--!strict

--[[
	Test doubles the sense specs share: a fake agent with a pivot, parts and character models as
	plain tables, and the globals (`workspace`, `RaycastParams`, `os`) that let the real modules
	run under Lune. Not a spec: the runner only collects `*.spec.luau`.

	Orientation is built with `CFrame.fromMatrix` because Lune's `CFrame.lookAt` gets the sign of
	the look vector wrong along Z.
]]

local Harness = require("../Support/Harness")

local roblox = require("@lune/roblox")
local Vector3 = roblox.Vector3
local CFrame = roblox.CFrame

local SenseFakes = {}

--[[
	A CFrame at `position` whose LookVector is `direction`.
]]
function SenseFakes.Facing(position: any, direction: any): any
	local look = direction.Unit
	local back = -look
	local reference = if math.abs(look.Y) > 0.99 then Vector3.new(1, 0, 0) else Vector3.new(0, 1, 0)
	local right = reference:Cross(back).Unit
	local up = back:Cross(right)

	return CFrame.fromMatrix(position, right, up, back)
end

--[[
	A stand-in BasePart. `direction` gives it a CFrame that looks that way.
]]
function SenseFakes.Part(position: any, direction: any?)
	return {
		Position = position,
		CFrame = if direction then SenseFakes.Facing(position, direction) else CFrame.new(position),
	}
end

--[[
	A stand-in character: a Model table with a Humanoid, a root (and optionally a head) that find
	their way back to it through FindFirstAncestorOfClass, and FindFirstChildOfClass for the
	Humanoid.
]]
function SenseFakes.Character(name: string, rootPosition: any, rootDirection: any?, headDirection: any?)
	local model = { Name = name, ClassName = "Model" }
	local humanoid = { ClassName = "Humanoid", Health = 100 }
	local root = SenseFakes.Part(rootPosition, rootDirection)
	local head = if headDirection then SenseFakes.Part(rootPosition + Vector3.new(0, 1.5, 0), headDirection) else nil

	local function ancestor(_self, className: string)
		if className == "Model" then
			return model
		end
		return nil
	end
	root.FindFirstAncestorOfClass = ancestor
	if head then
		head.FindFirstAncestorOfClass = ancestor
	end

	function model.FindFirstChild(_self, childName: string)
		if childName == "Head" then
			return head
		end
		if childName == "HumanoidRootPart" then
			return root
		end
		return nil
	end

	function model.FindFirstChildOfClass(_self, className: string)
		if className == "Humanoid" then
			return humanoid
		end
		return nil
	end

	function model.IsDescendantOf(_self, _ancestor)
		return false
	end

	return { Model = model, Root = root, Head = head, Humanoid = humanoid }
end

--[[
	A fake agent at `position`, facing `direction` (default -Z). Its entity is a table with
	GetPivot and GetDescendants, which is all the senses ask of it.
]]
function SenseFakes.Agent(position: any?, direction: any?)
	local resolvedPosition = position or Vector3.new(0, 0, 0)
	local pivot = SenseFakes.Facing(resolvedPosition, direction or Vector3.new(0, 0, -1))

	local entity = { Name = "Rig", ClassName = "Model" }
	function entity.GetPivot(_self)
		return pivot
	end
	function entity.GetDescendants(_self)
		return {}
	end

	return {
		Name = "Fake",
		Blackboard = {},
		Data = {},
		Entity = entity,
		GetPosition = function(_self)
			return pivot.Position
		end,
	}
end

--[[
	A raycast hit whose Instance is a descendant of `owner` (or of nothing, when owner is nil).
]]
function SenseFakes.Hit(owner: any?)
	return {
		Instance = {
			IsDescendantOf = function(_self, ancestor)
				return owner ~= nil and ancestor == owner
			end,
		},
	}
end

export type Ray = { From: any, Direction: any, Params: any }

--[[
	Globals for Harness.Load: a `workspace` whose Raycast returns what `hit` returns for each ray
	(default nothing) and records every ray in `rays`, a `RaycastParams` that is a plain table, and
	the manual clock's `os`.
]]
function SenseFakes.Globals(options: { clock: any?, hit: ((ray: Ray) -> any)?, rays: { Ray }? }?)
	local resolved = options or {}
	local clock = resolved.clock or Harness.ManualClock(100)

	return {
		os = clock.os,
		workspace = {
			Raycast = function(_self, from, direction, params)
				local ray: Ray = { From = from, Direction = direction, Params = params }
				if resolved.rays then
					table.insert(resolved.rays, ray)
				end
				if resolved.hit then
					return resolved.hit(ray)
				end
				return nil
			end,
		},
		RaycastParams = {
			new = function()
				return {}
			end,
		},
	}
end

--[[
	A Targets function returning the given parts.
]]
function SenseFakes.Targets(parts: { any }): (agent: any) -> { any }
	return function(_agent)
		return parts
	end
end

return SenseFakes
