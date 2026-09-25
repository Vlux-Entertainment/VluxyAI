--!strict

--[[
	The test rig: a standard R15 character built at runtime from an empty HumanoidDescription, so
	the playground needs no Studio-authored model. Body parts take the enemy's colour so the six
	are easy to tell apart. With `Humanoid = true` (the default) it walks with the Humanoid mover;
	without, the root is anchored and the CFrame mover pivots the whole rig, Motor6Ds and all, and
	the Humanoid stays only so the Animator can play animations on it.

	The Animate and Health scripts Roblox puts in a character are removed: they are LocalScripts
	meant for a player's own character and do nothing useful on a server NPC.
]]

local Players = game:GetService("Players")

export type RigOptions = {
	Humanoid: boolean?,
	Color: Color3?,
	Transparency: number?,
	Speed: number?,
}

local COLOR_PROPERTIES = { "HeadColor", "TorsoColor", "LeftArmColor", "RightArmColor", "LeftLegColor", "RightLegColor" }

local Rig = {}

--[[
	Makes an R15 rig named `name` at the origin. Pivot it into place afterwards. Yields while the
	default body assets load.
]]
function Rig.Create(name: string, options: RigOptions?): Model
	local resolved: RigOptions = options or {}
	local withHumanoid = resolved.Humanoid ~= false
	local color = resolved.Color or Color3.fromRGB(200, 200, 200)

	local description = Instance.new("HumanoidDescription")
	for _, property in COLOR_PROPERTIES do
		(description :: any)[property] = color
	end

	local model = Players:CreateHumanoidModelFromDescription(description, Enum.HumanoidRigType.R15)
	model.Name = name

	for _, child in model:GetChildren() do
		if child:IsA("LuaSourceContainer") then
			child:Destroy()
		end
	end

	local humanoid = model:FindFirstChildOfClass("Humanoid") :: Humanoid
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.WalkSpeed = resolved.Speed or 16
	if humanoid:FindFirstChildOfClass("Animator") == nil then
		local animator = Instance.new("Animator")
		animator.Parent = humanoid
	end

	local root = model.PrimaryPart :: BasePart
	if not withHumanoid then
		root.Anchored = true
	end

	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") and part ~= root then
			part.Transparency = resolved.Transparency or 0
			if not withHumanoid then
				part.CanCollide = false
			end
		end
	end

	return model
end

return Rig
