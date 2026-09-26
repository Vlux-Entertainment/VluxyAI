--!strict

--[[
	Where a mover starts on a path it was just handed. Shared by every mover so they all skip the
	same steps: the ones under the rig and the ones it is already past. A path re-planned while
	the agent walks usually starts a step behind it, and walking back to that step is a visible
	jerk. Pure.
]]

local Tables = require(script.Parent.Parent.Utility.Tables)
local Types = require(script.Parent.Parent.Types)

local Start = {}

--[=[
	@class MoverStart

	The step a mover walks toward first. [HumanoidMover] and [CFrameMover] both use it, and a
	mover of your own should too.
]=]

--[=[
	@within MoverStart
	@param path Path
	@param position Vector3 -- Where the rig is.
	@param skipDistance number -- Horizontal distance within which a leading step is already reached.
	@return number -- The index of the first step to walk toward; `#path + 1` only when the path is empty.

	Skips the run of leading plain `Walk` steps that sit within `skipDistance` of `position`, or
	that the rig is already past (it is at least as close to the step after as that step is). A
	labelled, `Jump` or `Custom` step is never skipped, even one under the agent: it carries
	meaning (a door at the agent's feet) that `StepReached` must report. The last step is never
	skipped either, so there is always something to walk toward.
]=]
function Start.Choose(path: Types.Path, position: Vector3, skipDistance: number): number
	local index = 1
	while index < #path do
		local step = path[index]
		local plain = step.Action == "Walk" and step.Label == nil
		if not plain then
			break
		end
		local nextPosition = path[index + 1].Position
		local under = Tables.FlatDistance(step.Position, position) <= skipDistance
		local past = Tables.FlatDistance(position, nextPosition) <= Tables.FlatDistance(step.Position, nextPosition)
		if not under and not past then
			break
		end
		index += 1
	end

	return index
end

return Start
