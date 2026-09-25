--!strict

--[[
	A standard R15 character built at runtime from an empty HumanoidDescription, for tests,
	playgrounds and prototypes that want a rig with no Studio-authored model. Body parts take a
	colour so several are easy to tell apart. With `Humanoid = true` (the default) it walks with
	the Humanoid mover; without, the root is anchored and the CFrame mover pivots the whole rig,
	Motor6Ds and all, with the Humanoid kept only so the Animator can play animations on it.

	The Animate and Health scripts Roblox puts in a character are removed: they are LocalScripts
	meant for a player's own character and do nothing useful on a server NPC.
]]

local Options = require(script.Parent.Parent.Utility.Options)

------------------------------------------------------------------------------------------------------------------------

local DEFAULT_OPTIONS = table.freeze({
	Humanoid = true,
	Color = Color3.fromRGB(200, 200, 200),
	Transparency = 0,
	Speed = 16,
})

--[=[
	@interface RigOptions
	@within Rig

	.Humanoid boolean? -- `false` anchors the root for the CFrame mover. Default `true`.
	.Color Color3? -- Body colour. Default light grey.
	.Transparency number? -- Body transparency. Default `0`.
	.Speed number? -- The Humanoid's WalkSpeed. Default `16`.
]=]
export type RigOptions = {
	Humanoid: boolean?,
	Color: Color3?,
	Transparency: number?,
	Speed: number?,
}

type ResolvedOptions = {
	Humanoid: boolean,
	Color: Color3,
	Transparency: number,
	Speed: number,
}

local COLOR_PROPERTIES = { "HeadColor", "TorsoColor", "LeftArmColor", "RightArmColor", "LeftLegColor", "RightLegColor" }

local Rig = {}

--[=[
	@class Rig

	A stand-in R15 rig made at runtime, server side. Nothing in the package needs it; it exists so
	a test place or a story can spawn an enemy without authoring a model first.
]=]

--[=[
	@within Rig
	@yields
	@param name string
	@param options RigOptions?
	@return Model -- At the origin; pivot it into place. Server only.
]=]
function Rig.Create(name: string, options: RigOptions?): Model
	local Players = game:GetService("Players")
	local resolved = Options.Resolve("Rig.Create", DEFAULT_OPTIONS, options :: any) :: ResolvedOptions

	local description = Instance.new("HumanoidDescription")
	for _, property in COLOR_PROPERTIES do
		(description :: any)[property] = resolved.Color
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
	humanoid.WalkSpeed = resolved.Speed
	if humanoid:FindFirstChildOfClass("Animator") == nil then
		local animator = Instance.new("Animator")
		animator.Parent = humanoid
	end

	local root = model.PrimaryPart :: BasePart
	if not resolved.Humanoid then
		root.Anchored = true
	end

	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") and part ~= root then
			part.Transparency = resolved.Transparency
			if not resolved.Humanoid then
				part.CanCollide = false
			end
		end
	end

	return model
end

return Rig
