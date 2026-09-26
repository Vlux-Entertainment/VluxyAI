--!strict

--[[
	The collision groups agents live in, so the pieces that care (doors agents walk through, safe
	areas they cannot enter) agree on one group instead of each naming its own.

	The one decision: rigs get a group of their own, and a part is made passable to them by moving
	it into a second group that does not collide with the first, so it stays solid to players and
	everything else. Nothing touches Roblox at module scope.
]]

local Cleaner = require(script.Parent.Parent.Utility.Cleaner)

------------------------------------------------------------------------------------------------------------------------

local RIG_GROUP = "VluxyAIRigs"
local PASSABLE_GROUP = "VluxyAIPassable"

local Collision = {}

--[=[
	@class Collision

	Collision groups for agents. Call [Collision.Setup] once on the server, put each rig in the rig
	group with [Collision.AddRig], and make a part agents walk through (a door, a curtain, a bead
	screen) with [Collision.LetRigsThrough]; it stays solid to players. [SafeAreas] uses the same
	rig group.

	```lua
	VluxyAI.Collision.Setup()
	VluxyAI.Collision.AddRig(model)
	VluxyAI.Collision.LetRigsThrough(workspace.Doors.Front)
	```
]=]

--[=[
	@within Collision
	@prop RIG_GROUP "VluxyAIRigs"
]=]
Collision.RIG_GROUP = RIG_GROUP

--[=[
	@within Collision
	@prop PASSABLE_GROUP "VluxyAIPassable"

	Parts in this group are solid to everything but rigs.
]=]
Collision.PASSABLE_GROUP = PASSABLE_GROUP

--[[
	Registers a group unless it already is.
]]
local function register(name: string)
	local PhysicsService = game:GetService("PhysicsService")
	if not PhysicsService:IsCollisionGroupRegistered(name) then
		PhysicsService:RegisterCollisionGroup(name)
	end
end

--[=[
	@within Collision

	Registers the rig and passable groups and makes them not collide with each other. Safe to call
	more than once.
]=]
function Collision.Setup()
	register(RIG_GROUP)
	register(PASSABLE_GROUP)
	game:GetService("PhysicsService"):CollisionGroupSetCollidable(RIG_GROUP, PASSABLE_GROUP, false)
end

--[=[
	@within Collision
	@param model Model -- The rig.
	@param group string? -- Default [Collision.RIG_GROUP].
	@return Cleaner -- Destroy it to stop assigning parts added later.

	Puts every part of the rig, now and as parts are added, in the rig group.
]=]
function Collision.AddRig(model: Model, group: string?): Cleaner.Cleaner
	Collision.Setup()
	local name = group or RIG_GROUP
	local cleaner = Cleaner.new()
	local function assign(part: Instance)
		if part:IsA("BasePart") then
			part.CollisionGroup = name
		end
	end
	for _, part in model:GetDescendants() do
		assign(part)
	end
	cleaner:Connect(model.DescendantAdded, assign)
	return cleaner
end

--[=[
	@within Collision
	@param part BasePart
	@param passable boolean? -- `false` puts it back in `Default`, solid to rigs again (a door that was locked). Default `true`.

	Makes a part something agents walk through while it stays solid to players.
]=]
function Collision.LetRigsThrough(part: BasePart, passable: boolean?)
	Collision.Setup()
	part.CollisionGroup = if passable == false then "Default" else PASSABLE_GROUP
end

return Collision
