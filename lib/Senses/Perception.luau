--!strict

--[[
	The maths and world queries the senses share, as a plain function table. Nothing here is a
	sense and nothing here writes a blackboard.

	Two kinds of function live here. `InCone`, `SortByDistance`, `PositionOf`, `ModelOf`, `EyeOf`,
	`CharacterOf`, `HumanoidOf` and `IgnoreList` are pure and are specced under Lune.
	`AliveRoots`, `RaycastParams` and `LineOfSight` talk to Roblox and are play-tested; they fetch
	`Players` and use `workspace` inside the function, never at module scope, so a spec can hand
	in fakes through the harness globals.

	Everything that takes a part reads it duck-typed: `.Position` on a target, `.CFrame` on an
	eye, `:FindFirstChild`, `:FindFirstChildOfClass` and `:FindFirstAncestorOfClass` looked up
	before they are called. That is what lets a spec pass `{ Position = Vector3 }` where a game
	passes a `BasePart`.
]]

local Types = require(script.Parent.Parent.Types)

--[=[
	@class Perception

	The helpers the built-in senses are made of, and the place to start when writing your own.
	A [Types.Sense] is any table with `Tick`; the work inside one is usually "who could I be
	looking at" (`AliveRoots`), "is it in front of me" (`InCone`), "is anything in the way"
	(`LineOfSight`), "which is nearest" (`SortByDistance`), and this module answers each of those
	on its own.

	Everything here is about *targets*: [Perception.HumanoidOf] takes a root a sense wrote to the
	blackboard and finds that character's humanoid. The agent's own humanoid is
	`agent.Entity:FindFirstChildOfClass("Humanoid")`, and the two look alike in code, so name
	the variable.

	`Targets` on every built-in sense defaults to [Perception.AliveRoots], and `Ignore` on
	[Sight] defaults to [Perception.IgnoreList]. A brain that acts on a target root a sense wrote
	to the blackboard reaches the rest of the character through [Perception.CharacterOf] and
	[Perception.HumanoidOf].

	Everything that takes a part reads it duck-typed, so a spec can pass plain tables.
]=]
local Perception = {}

------------------------------------------------------------------------------------------------------------------------

--[=[
	@within Perception
	@prop HIDDEN_ATTRIBUTE "AI_HIDDEN"

	The attribute name that hides a character from every sense: set it to `true` on the
	character (or on its root) while the player is in a locker, under a bed, or otherwise out of
	the game's sight rules, and [Perception.AliveRoots] leaves them out until it is cleared.
]=]
Perception.HIDDEN_ATTRIBUTE = "AI_HIDDEN"

--[=[
	@within Perception
	@param root BasePart -- A target root, or anything with `GetAttribute`.
	@return boolean -- `true` when the root or its character carries `AI_HIDDEN = true`.
]=]
function Perception.IsHidden(root: BasePart): boolean
	local function flagged(instance: any): boolean
		return instance ~= nil
			and type(instance.GetAttribute) == "function"
			and instance:GetAttribute(Perception.HIDDEN_ATTRIBUTE) == true
	end

	return flagged(root) or flagged(Perception.ModelOf(root))
end

--[[
	Every alive player root, with or without the hidden ones.
]]
local function aliveRoots(includeHidden: boolean): { BasePart }
	local Players = game:GetService("Players")

	local roots: { BasePart } = {}
	for _, player in Players:GetPlayers() do
		local character = player.Character
		if character == nil then
			continue
		end

		local humanoid = character:FindFirstChildOfClass("Humanoid")
		local root = character:FindFirstChild("HumanoidRootPart")
		if humanoid == nil or root == nil or humanoid.Health <= 0 then
			continue
		end

		if not includeHidden and Perception.IsHidden(root :: BasePart) then
			continue
		end

		table.insert(roots, root :: BasePart)
	end

	return roots
end

--[=[
	@within Perception
	@return { BasePart } -- The `HumanoidRootPart` of every player whose character is alive and not hidden.

	Every player character with a Humanoid whose Health is above zero, by its root, minus the
	ones hidden with [Perception.HIDDEN_ATTRIBUTE]. The default `Targets` of every sense, so
	hiding a player once hides them from Sight, Proximity and Watched together. Takes no
	arguments, so it can be a `Targets` function as it is.
]=]
function Perception.AliveRoots(): { BasePart }
	return aliveRoots(false)
end

--[=[
	@within Perception
	@return { BasePart } -- Every alive player root, hidden ones included.

	For the checks a hidden player still takes part in: [Perception.SeenByAnyone] uses it, since
	a player inside a locker can still see out of it.
]=]
function Perception.AllAliveRoots(): { BasePart }
	return aliveRoots(true)
end

--[=[
	@within Perception
	@param agent Agent
	@return { Instance } -- `{ agent.Entity }`.

	The raycast filter for a ray cast from the agent outwards: its entity alone, which
	`FilterDescendantsInstances` extends to everything under it. The default `Ignore` of [Sight].
]=]
function Perception.IgnoreList(agent: Types.Agent): { Instance }
	return { agent.Entity }
end

--[=[
	@within Perception
	@param agent Agent
	@return Vector3

	Where the agent is: its mover's position when it has one, else its entity's pivot. The real
	[Agent] has `GetPosition`; a spec's fake may not.
]=]
function Perception.PositionOf(agent: Types.Agent): Vector3
	local getPosition = (agent :: any).GetPosition
	if type(getPosition) == "function" then
		return agent:GetPosition()
	end

	return agent.Entity:GetPivot().Position
end

--[=[
	@within Perception
	@param part BasePart
	@return Instance? -- The nearest ancestor Model, or `nil`.

	The Model a part belongs to, or `nil` when it has none or is a fake without
	`FindFirstAncestorOfClass`. [Perception.CharacterOf] is the same lookup typed as a `Model`.
]=]
function Perception.ModelOf(part: BasePart): Instance?
	local find = (part :: any).FindFirstAncestorOfClass
	if type(find) ~= "function" then
		return nil
	end

	return find(part, "Model")
end

--[=[
	@within Perception
	@param part BasePart -- A root a sense wrote to the blackboard, or any part of a character.
	@return Model? -- The nearest ancestor Model, or `nil` when there is none.

	The character a part belongs to. What a brain calls on `SeenTarget` or `NearestTarget` when
	it wants the whole model rather than the root.
]=]
function Perception.CharacterOf(part: BasePart): Model?
	return Perception.ModelOf(part) :: Model?
end

--[=[
	@within Perception
	@param part BasePart -- A root a sense wrote to the blackboard, or any part of a character.
	@return Humanoid? -- The Humanoid inside the part's character, or `nil` when there is no character or no Humanoid.

	The Humanoid a brain damages, checks the health of, or reads the state of, found through
	[Perception.CharacterOf].
]=]
function Perception.HumanoidOf(part: BasePart): Humanoid?
	local character = Perception.CharacterOf(part)
	if character == nil then
		return nil
	end

	local find = (character :: any).FindFirstChildOfClass
	if type(find) ~= "function" then
		return nil
	end

	return find(character, "Humanoid")
end

--[=[
	@within Perception
	@param root BasePart
	@return BasePart -- The character's `Head` when it has one, else `root` itself.

	The part to look out of for a character. [Watched] judges an observer's look direction by
	this part's `CFrame`.
]=]
function Perception.EyeOf(root: BasePart): BasePart
	local model = Perception.ModelOf(root)
	if model == nil then
		return root
	end

	local head = model:FindFirstChild("Head")
	if head == nil then
		return root
	end

	return head :: BasePart
end

------------------------------------------------------------------------------------------------------------------------

--[=[
	@within Perception
	@param ignore { Instance } -- Passed through, with their descendants.
	@return RaycastParams

	Raycast parameters that exclude `ignore` (and their descendants) and water.
]=]
function Perception.RaycastParams(ignore: { Instance }): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	params.IgnoreWater = true

	return params
end

-- How many see-through parts one line of sight will look past before giving up.
local SEE_THROUGH_LIMIT = 8

-- A spot light's Face as a direction in its parent's space.
local NORMALS = {
	Front = Vector3.new(0, 0, -1),
	Back = Vector3.new(0, 0, 1),
	Right = Vector3.new(1, 0, 0),
	Left = Vector3.new(-1, 0, 0),
	Top = Vector3.new(0, 1, 0),
	Bottom = Vector3.new(0, -1, 0),
}

--[=[
	@within Perception
	@param threshold number? -- `Transparency` at or above which a part is see-through. Default `0.5`.
	@return (part: BasePart) -> boolean -- A `SeeThrough` predicate for [Perception.LineOfSight] and [Sight].

	Glass and fences: parts this transparent do not block sight.
]=]
function Perception.Transparent(threshold: number?): (part: BasePart) -> boolean
	local limit = threshold or 0.5
	return function(part: BasePart): boolean
		local transparency = (part :: any).Transparency
		return type(transparency) == "number" and transparency >= limit
	end
end

--[=[
	@within Perception
	@param from Vector3
	@param to Vector3
	@param ignore { Instance } -- What the ray passes through.
	@param allow Instance? -- What the ray may hit and still count as clear, usually the target's own model.
	@param seeThrough ((part: BasePart) -> boolean)? -- Parts this returns `true` for do not block; the ray is cast again past them, up to eight times.
	@return boolean

	Is the straight line from `from` to `to` clear? `true` when the ray hits nothing, or hits
	`allow` or something under it, which is how a target's own body does not block sight of it.
	Without `seeThrough`, anything else the ray hits blocks, glass included; pass
	[Perception.Transparent] or your own rule to look past it.
]=]
function Perception.LineOfSight(
	from: Vector3,
	to: Vector3,
	ignore: { Instance },
	allow: Instance?,
	seeThrough: ((part: BasePart) -> boolean)?
): boolean
	local direction = to - from
	if direction.Magnitude == 0 then
		return true
	end

	local excluded = ignore
	for _ = 1, SEE_THROUGH_LIMIT + 1 do
		local result = workspace:Raycast(from, direction, Perception.RaycastParams(excluded))
		if result == nil then
			return true
		end

		local hit = result.Instance
		if allow ~= nil and (hit == allow or hit:IsDescendantOf(allow)) then
			return true
		end

		if seeThrough == nil or not seeThrough(hit) then
			return false
		end

		-- Look past it: the same ray again with this part excluded too.
		if excluded == ignore then
			excluded = table.clone(ignore)
		end
		table.insert(excluded, hit)
	end

	return false
end

--[=[
	@within Perception
	@param from Vector3
	@param to Vector3
	@param ignore { Instance } -- What does not count, with descendants: the listener's entity, the source's part.
	@param limit number? -- Stop counting here. Default `3`.
	@param margin number? -- Hits within this many studs of `to` do not count, so a noise inside a body is not walled off by that body. Default `2`.
	@return number -- How many distinct parts the straight line crosses, up to `limit`.

	How many walls stand between a sound and a listener. [Hearing] and [Sounds] multiply the
	loudness by `Occlusion` once per wall.
]=]
function Perception.CountWalls(
	from: Vector3,
	to: Vector3,
	ignore: { Instance },
	limit: number?,
	margin: number?
): number
	local maxWalls = limit or 3
	local keep = margin or 2
	local direction = to - from
	local length = direction.Magnitude
	if length <= keep or maxWalls <= 0 then
		return 0
	end

	local excluded = table.clone(ignore)
	local walls = 0
	while walls < maxWalls do
		local result = workspace:Raycast(from, direction, Perception.RaycastParams(excluded))
		if result == nil or (result.Position - from).Magnitude >= length - keep then
			break
		end
		walls += 1
		table.insert(excluded, result.Instance)
	end

	return walls
end

------------------------------------------------------------------------------------------------------------------------

--[=[
	@within Perception
	@prop LIGHT_TAG "AI_LIGHT"

	The `CollectionService` tag a light must carry for [Perception.LightAt] to count it.
]=]
Perception.LIGHT_TAG = "AI_LIGHT"

--[=[
	@within Perception
	@param distance number -- Studs from the light.
	@param range number -- The light's `Range`.
	@param brightness number -- The light's `Brightness`.
	@return number -- `brightness` at the light, falling linearly to `0` at `range`. Pure.
]=]
function Perception.LightFalloff(distance: number, range: number, brightness: number): number
	if range <= 0 or brightness <= 0 or distance >= range then
		return 0
	end
	return brightness * (1 - math.max(0, distance) / range)
end

--[=[
	@within Perception
	@param light Light -- A `PointLight`, `SpotLight` or `SurfaceLight` on a part or an attachment.
	@param position Vector3
	@return number -- How much this light lights `position`: `0` when disabled, out of range, not on a part, or outside a spot light's cone.

	Read duck-typed (`Enabled`, `Brightness`, `Range`, `Parent`, and for a spot light `Angle` and
	`Face`), so a spec can pass a plain table.
]=]
function Perception.LightContribution(light: Light, position: Vector3): number
	local candidate = light :: any
	if candidate.Enabled ~= true then
		return 0
	end

	local parent = candidate.Parent
	if parent == nil or type(parent.IsA) ~= "function" then
		return 0
	end

	local origin: Vector3
	local cframe: CFrame
	if parent:IsA("Attachment") then
		origin = parent.WorldPosition
		cframe = parent.WorldCFrame
	elseif parent:IsA("BasePart") then
		origin = parent.Position
		cframe = parent.CFrame
	else
		return 0
	end

	local offset = position - origin
	local distance = offset.Magnitude
	local amount = Perception.LightFalloff(distance, candidate.Range or 0, candidate.Brightness or 0)
	if amount <= 0 then
		return 0
	end

	if type(candidate.IsA) == "function" and candidate:IsA("SpotLight") and distance > 0 then
		local face = candidate.Face
		local faceName = if typeof(face) == "EnumItem"
			then face.Name
			elseif type(face) == "string" then face
			else "Front"
		local normal = NORMALS[faceName] or NORMALS.Front
		local axis = cframe:VectorToWorldSpace(normal)
		local threshold = math.cos(math.rad(math.clamp(candidate.Angle or 90, 0, 360) / 2))
		if axis:Dot(offset / distance) < threshold then
			return 0
		end
	end

	return amount
end

--[=[
	@within Perception
	@param position Vector3
	@param ambient number? -- Light everywhere, added before the clamp. `0` is pitch black where no light reaches. Default `0`.
	@return number -- The light level at `position` in `[0, 1]`: `ambient` plus every tagged light's [Perception.LightContribution], clamped.

	How lit a spot is, from the lights tagged [Perception.LIGHT_TAG]. Tag the lights that matter
	to the AI (a flashlight, the ceiling lamps, a fire) and pass this as a [Sight] `Visibility`,
	and a player in the dark is invisible until a light finds them. Not physically accurate; a
	gameplay number.
]=]
function Perception.LightAt(position: Vector3, ambient: number?): number
	local CollectionService = game:GetService("CollectionService")

	local total = ambient or 0
	for _, light in CollectionService:GetTagged(Perception.LIGHT_TAG) do
		total += Perception.LightContribution(light :: Light, position)
		if total >= 1 then
			return 1
		end
	end

	return math.clamp(total, 0, 1)
end

--[=[
	@interface SeenByOptions
	@within Perception

	.FieldOfView number? -- The full angle of each observer's view cone. Default `100`.
	.Range number? -- Studs. Default `math.huge`.
	.Eye ((root: BasePart) -> CFrame?)? -- Where an observer looks from. Default: the character's head, else its root ([Perception.EyeOf]). A game that replicates the camera returns it here.
	.Ignore { Instance }? -- What the sight ray passes through. Default nothing.
	.Observers { BasePart }? -- Who may be looking. Default [Perception.AllAliveRoots], hidden players included.
]=]
export type SeenByOptions = {
	FieldOfView: number?,
	Range: number?,
	Eye: ((root: BasePart) -> CFrame?)?,
	Ignore: { Instance }?,
	Observers: { BasePart }?,
}

--[=[
	@within Perception
	@param position Vector3
	@param options SeenByOptions?
	@return boolean -- `true` when any observer has `position` inside their view cone with a clear line to it.

	"Would anyone see it happen here?" The check to run before a stalker teleports, spawns or
	vanishes, so it only ever does so off screen. The [Watched] sense is the same question asked
	about the agent every tick; this is the one-off version about any point.
]=]
function Perception.SeenByAnyone(position: Vector3, options: SeenByOptions?): boolean
	local resolved: SeenByOptions = options or {}
	local fieldOfView = resolved.FieldOfView or 100
	local range = resolved.Range or math.huge
	local ignore = resolved.Ignore or {}
	local observers: { BasePart } = resolved.Observers or Perception.AllAliveRoots()

	local eyeOf: ((root: BasePart) -> CFrame?)? = resolved.Eye
	for _, root in observers do
		local eye: CFrame? = if eyeOf ~= nil then (eyeOf :: (BasePart) -> CFrame?)(root) else nil
		if eye == nil then
			eye = Perception.EyeOf(root).CFrame
		end

		if not Perception.InCone(eye :: CFrame, position, fieldOfView, range) then
			continue
		end

		local ignored = table.clone(ignore)
		local character = Perception.ModelOf(root)
		table.insert(ignored, (character or root) :: Instance)
		if Perception.LineOfSight((eye :: CFrame).Position, position, ignored) then
			return true
		end
	end

	return false
end

------------------------------------------------------------------------------------------------------------------------

--[=[
	@within Perception
	@param origin CFrame -- The eye; its `LookVector` is the centre of the cone.
	@param position Vector3
	@param fieldOfViewDegrees number -- The full angle of the cone.
	@param range number -- Studs.
	@return boolean -- Inside the cone and within range.
	@return number -- The dot product between the look vector and the direction to `position`: `1` dead ahead, `0` beside, `-1` behind.

	Is `position` inside the cone that opens `fieldOfViewDegrees` wide around `origin.LookVector`,
	within `range` studs? The angle is the true angle in three dimensions, so something high above
	is outside just as something off to the side is. A position at the origin counts as inside.
	The dot is returned either way, so a consideration can score on it.
]=]
function Perception.InCone(
	origin: CFrame,
	position: Vector3,
	fieldOfViewDegrees: number,
	range: number
): (boolean, number)
	local offset = position - origin.Position
	local distance = offset.Magnitude
	if distance == 0 then
		return true, 1
	end

	local dot = offset.Unit:Dot(origin.LookVector)
	if distance > range then
		return false, dot
	end

	-- Comparing cosines avoids acos. The epsilon is float32-sized (Vector3 components are
	-- single precision) so a position exactly on the edge counts as inside.
	local threshold = math.cos(math.rad(math.clamp(fieldOfViewDegrees, 0, 360) / 2))
	return dot >= threshold - 1e-6, dot
end

--[=[
	@within Perception
	@param origin Vector3
	@param parts { BasePart }
	@return { BasePart } -- A new list, nearest first.

	A new list of `parts`, nearest to `origin` first. Stable: parts at the same distance keep
	their order. `parts` is not touched.
]=]
function Perception.SortByDistance(origin: Vector3, parts: { BasePart }): { BasePart }
	type Entry = { Part: BasePart, Distance: number, Index: number }

	local entries: { Entry } = {}
	for index, part in parts do
		table.insert(entries, {
			Part = part,
			Distance = (part.Position - origin).Magnitude,
			Index = index,
		})
	end

	table.sort(entries, function(a: Entry, b: Entry)
		if a.Distance ~= b.Distance then
			return a.Distance < b.Distance
		end
		return a.Index < b.Index
	end)

	local sorted: { BasePart } = {}
	for _, entry in entries do
		table.insert(sorted, entry.Part)
	end

	return sorted
end

return Perception
