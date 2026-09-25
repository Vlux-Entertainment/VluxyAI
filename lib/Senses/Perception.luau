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
	@return { BasePart } -- The `HumanoidRootPart` of every player whose character is alive.

	Every player character with a Humanoid whose Health is above zero, by its root. The default
	`Targets` of every sense.
]=]
function Perception.AliveRoots(): { BasePart }
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

		table.insert(roots, root :: BasePart)
	end

	return roots
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

--[=[
	@within Perception
	@param from Vector3
	@param to Vector3
	@param ignore { Instance } -- What the ray passes through.
	@param allow Instance? -- What the ray may hit and still count as clear, usually the target's own model.
	@return boolean

	Is the straight line from `from` to `to` clear? `true` when the ray hits nothing, or hits
	`allow` or something under it, which is how a target's own body does not block sight of it.
]=]
function Perception.LineOfSight(from: Vector3, to: Vector3, ignore: { Instance }, allow: Instance?): boolean
	local direction = to - from
	if direction.Magnitude == 0 then
		return true
	end

	local result = workspace:Raycast(from, direction, Perception.RaycastParams(ignore))
	if result == nil then
		return true
	end

	if allow ~= nil then
		local hit = result.Instance
		return hit == allow or hit:IsDescendantOf(allow)
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
