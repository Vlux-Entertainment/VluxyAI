--!strict

--[[
	The maths and world queries the senses share, as a plain function table. Nothing here is a
	sense and nothing here writes a blackboard.

	Two kinds of function live here. `InCone`, `SortByDistance` and `PositionOf` are pure and are
	specced under Lune. `AliveRoots`, `RaycastParams` and `LineOfSight` talk to Roblox and are
	play-tested; they fetch `Players` and use `workspace` inside the function, never at module
	scope, so a spec can hand in fakes through the harness globals.

	Everything that takes a part reads it duck-typed: `.Position` on a target, `.CFrame` on an
	eye, `:FindFirstChild` and `:FindFirstAncestorOfClass` looked up before they are called. That
	is what lets a spec pass `{ Position = Vector3 }` where a game passes a `BasePart`.
]]

local Types = require(script.Parent.Parent.Types)

local Perception = {}

------------------------------------------------------------------------------------------------------------------------

--[[
	The `HumanoidRootPart` of every player whose character is alive: has a Humanoid with Health
	above zero. The default `Targets` of every sense.
]]
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

--[[
	The agent's entity and everything under it, as a flat list for a raycast filter. The default
	`Ignore` of a sense that casts from the agent outwards.
]]
function Perception.Descendants(agent: Types.Agent): { Instance }
	local entity = agent.Entity
	local list: { Instance } = { entity }

	for _, descendant in entity:GetDescendants() do
		table.insert(list, descendant)
	end

	return list
end

--[[
	Where the agent is: its mover's position when it has one, else its entity's pivot. The real
	Agent has `GetPosition`; a spec's fake may not.
]]
function Perception.PositionOf(agent: Types.Agent): Vector3
	local getPosition = (agent :: any).GetPosition
	if type(getPosition) == "function" then
		return agent:GetPosition()
	end

	return agent.Entity:GetPivot().Position
end

--[[
	The Model a part belongs to, or nil when it has none or is a fake without the method.
]]
function Perception.ModelOf(part: BasePart): Instance?
	local find = (part :: any).FindFirstAncestorOfClass
	if type(find) ~= "function" then
		return nil
	end

	return find(part, "Model")
end

--[[
	The part to look out of for a character: its `Head` when it has one, else the root itself.
]]
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

--[[
	Raycast parameters that pass through `ignore` (and their descendants) and water.
]]
function Perception.RaycastParams(ignore: { Instance }): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	params.IgnoreWater = true

	return params
end

--[[
	Is the straight line from `from` to `to` clear? True when the ray hits nothing, or hits
	`allow` or something under it, which is how a target's own body does not block sight of it.
]]
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

--[[
	Is `position` inside the cone that opens `fieldOfViewDegrees` wide (the full angle) around
	`origin.LookVector`, within `range` studs? The angle is the true angle in three dimensions, so
	something high above is outside just as something off to the side is. A position at the origin
	counts as inside.

	Also returns the dot product between the look vector and the direction to the position: `1`
	dead ahead, `0` beside, `-1` behind. A consideration can score on it.
]]
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

--[[
	A new list of `parts`, nearest to `origin` first. Stable: parts at the same distance keep
	their order. `parts` is not touched.
]]
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
