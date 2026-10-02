--!strict

--[[
	Safe areas: parts tagged VLUXYAI_SAFE that agents never enter while the part's VLUXYAI_SAFE/Enabled
	attribute is not false. Enforced at every layer that could take an agent inside, so no single
	miss lets one through: the navmesh prices the area out, a Graph skips nodes in it, a Straight
	line refuses to cross it, a player standing in it stops being a target for every sense, and,
	after Setup, its volume is solid to agent rigs and nothing else.

	The one decision: a safe part is a volume, not a wall. Players walk through it freely (its
	collision group only collides with the rig group), and "inside" is the part's own box, so a
	room is one part the size of the room.

	Nothing touches Roblox at module scope; `Contains` answers false when CollectionService is not
	there, so pure code that asks stays testable.
]]

local Cleaner = require(script.Parent.Parent.Utility.Cleaner)
local Collision = require(script.Parent.Collision)
local FormatMessage = require(script.Parent.Parent.Utility.FormatMessage)
local Options = require(script.Parent.Parent.Utility.Options)

------------------------------------------------------------------------------------------------------------------------

local TAG = "VLUXYAI_SAFE"
local ENABLED_ATTRIBUTE = "VLUXYAI_SAFE/Enabled"
local LABEL = "VLUXYAI_SAFE"
local SAFE_GROUP = "VluxyAISafe"

local DEFAULT_SETUP_OPTIONS = table.freeze({
	RigGroup = Collision.RIG_GROUP,
})

--[=[
	@interface SafeAreaSetupOptions
	@within SafeAreas

	.RigGroup string? -- The collision group your agent rigs are in. A safe area is solid to it and to nothing else. Default [Collision.RIG_GROUP], the group [Collision.AddRig] puts rigs in.
]=]
export type SafeAreaSetupOptions = {
	RigGroup: string?,
}

local SafeAreas = {}

--[=[
	@class SafeAreas

	Places agents never go. Tag a part `VLUXYAI_SAFE` and it is a safe area for as long as its
	`VLUXYAI_SAFE/Enabled` attribute is not `false`; set the attribute to switch it off and on.
	Call [SafeAreas.Setup] once on the server so the part gets its navmesh modifier and is solid
	to agent rigs. The rest is automatic: [Navmesh] never plans through an enabled area, [Straight]
	never walks a line across one, [Graph] skips nodes in one when given `Avoid =
	SafeAreas.Contains`, and a player standing in one is left out of
	[Perception.AliveRoots], so no sense targets them.

	```lua
	VluxyAI.SafeAreas.Setup({ RigGroup = "Monsters" })
	```
]=]

--[=[
	@within SafeAreas
	@prop TAG "VLUXYAI_SAFE"
]=]
SafeAreas.TAG = TAG

--[=[
	@within SafeAreas
	@prop ENABLED_ATTRIBUTE "VLUXYAI_SAFE/Enabled"

	`false` switches an area off. Missing means on.
]=]
SafeAreas.ENABLED_ATTRIBUTE = ENABLED_ATTRIBUTE

--[=[
	@within SafeAreas
	@prop LABEL "VLUXYAI_SAFE"

	The `PathfindingModifier` label [SafeAreas.Setup] gives an enabled area, and the cost
	[Navmesh] prices at `math.huge`.
]=]
SafeAreas.LABEL = LABEL

--[=[
	@within SafeAreas
	@param part Instance
	@return boolean -- `false` only when `VLUXYAI_SAFE/Enabled` is `false`.
]=]
function SafeAreas.IsEnabled(part: Instance): boolean
	return part:GetAttribute(ENABLED_ATTRIBUTE) ~= false
end

--[=[
	@within SafeAreas
	@param cframe CFrame -- The box's CFrame.
	@param size Vector3 -- The box's size.
	@param point Vector3
	@return boolean -- `true` when `point` is inside the box, rotation included.

	Pure.
]=]
function SafeAreas.InBox(cframe: CFrame, size: Vector3, point: Vector3): boolean
	local localPoint = cframe:PointToObjectSpace(point)
	return math.abs(localPoint.X) <= size.X / 2
		and math.abs(localPoint.Y) <= size.Y / 2
		and math.abs(localPoint.Z) <= size.Z / 2
end

--[[
	The tagged parts, or none when there is no CollectionService (a pure test).
]]
local function tagged(): { Instance }
	local ok, parts = pcall(function()
		return game:GetService("CollectionService"):GetTagged(TAG)
	end)
	if ok and type(parts) == "table" then
		return parts
	end
	return {}
end

--[=[
	@within SafeAreas
	@param point Vector3
	@return boolean -- `true` when `point` is inside an enabled safe area.
	@return BasePart? -- That area.

	The check every layer uses. A floor position counts as inside a room whose part reaches the
	floor; give a safe part a little depth below the floor if yours sits on it exactly.
]=]
function SafeAreas.Contains(point: Vector3): (boolean, BasePart?)
	for _, part in tagged() do
		if part:IsA("BasePart") and SafeAreas.IsEnabled(part) and SafeAreas.InBox(part.CFrame, part.Size, point) then
			return true, part
		end
	end
	return false, nil
end

-- The rig group Setup was given, for Refresh.
local rigGroup = Collision.RIG_GROUP

--[=[
	@within SafeAreas

	Makes safe areas solid to the rig group and to no other collision group, including groups
	registered since [SafeAreas.Setup] (a new group collides with everything by default). Setup
	calls it, and so does every safe area added later; call it yourself after registering a
	collision group of your own.
]=]
function SafeAreas.Refresh()
	local PhysicsService = game:GetService("PhysicsService")
	for _, group in { SAFE_GROUP, rigGroup } do
		if not PhysicsService:IsCollisionGroupRegistered(group) then
			PhysicsService:RegisterCollisionGroup(group)
		end
	end
	for _, other in PhysicsService:GetRegisteredCollisionGroups() do
		PhysicsService:CollisionGroupSetCollidable(SAFE_GROUP, other.name, other.name == rigGroup)
	end
end

--[=[
	@within SafeAreas
	@param options SafeAreaSetupOptions?
	@return Cleaner -- Destroy it to stop watching the tag.
	@error "unknown option"

	Server setup, once. Every tagged part, now and later, gets a `PathfindingModifier` (labelled
	`VLUXYAI_SAFE` while enabled, so [Navmesh] prices it out) and goes in a collision group that only
	collides with `RigGroup`, solid while enabled and not while off. Players and everything else
	pass through it.
]=]
function SafeAreas.Setup(options: SafeAreaSetupOptions?): Cleaner.Cleaner
	local resolved = Options.Resolve("SafeAreas.Setup", DEFAULT_SETUP_OPTIONS, options :: any) :: { RigGroup: string }
	local CollectionService = game:GetService("CollectionService")
	rigGroup = resolved.RigGroup
	Collision.Setup()
	SafeAreas.Refresh()

	local cleaner = Cleaner.new()

	local function watch(instance: Instance)
		if not instance:IsA("BasePart") then
			FormatMessage.Warn(`SafeAreas: {instance:GetFullName()} is tagged {TAG} but is not a part; it is ignored`)
			return
		end
		local part = instance :: BasePart

		local modifier = part:FindFirstChild("VLUXYAI_SAFE_Modifier")
		if modifier == nil or not modifier:IsA("PathfindingModifier") then
			local created = Instance.new("PathfindingModifier")
			created.Name = "VLUXYAI_SAFE_Modifier"
			created.Parent = part
			modifier = created
		end

		local pathModifier = modifier :: PathfindingModifier
		-- Groups registered since Setup would collide with it by default.
		SafeAreas.Refresh()
		local function apply()
			local enabled = SafeAreas.IsEnabled(part)
			pathModifier.Label = if enabled then LABEL else ""
			part.CollisionGroup = SAFE_GROUP
			part.CanCollide = enabled
		end
		apply()
		cleaner:Connect(part:GetAttributeChangedSignal(ENABLED_ATTRIBUTE), apply)
	end

	for _, instance in CollectionService:GetTagged(TAG) do
		watch(instance)
	end
	cleaner:Connect(CollectionService:GetInstanceAddedSignal(TAG), watch)

	return cleaner
end

return SafeAreas
