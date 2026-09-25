--!strict

--[[
	The test rig: a model whose only body is a cylinder, with a small dark "eye" on the front so
	you can see which way it faces. With `Humanoid = true` it walks with a Humanoid and the
	Humanoid mover; without, the root is anchored and the CFrame mover pivots it.

	The cylinder look comes from a SpecialMesh on an ordinary block Part, so the part stays
	axis-aligned and the Humanoid turns it about the right axis.
]]

local HEIGHT = 5
local DIAMETER = 4

export type CylinderOptions = {
	Humanoid: boolean?,
	Color: Color3?,
	Transparency: number?,
	Speed: number?,
}

local Cylinder = {}

--[[
	Makes a cylinder rig named `name` at the origin. Pivot it into place afterwards.
]]
function Cylinder.Create(name: string, options: CylinderOptions?): Model
	local resolved: CylinderOptions = options or {}
	local withHumanoid = resolved.Humanoid ~= false

	local model = Instance.new("Model")
	model.Name = name

	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(DIAMETER, HEIGHT, DIAMETER)
	root.Color = resolved.Color or Color3.fromRGB(200, 200, 200)
	root.Transparency = resolved.Transparency or 0
	root.Material = Enum.Material.SmoothPlastic
	root.TopSurface = Enum.SurfaceType.Smooth
	root.BottomSurface = Enum.SurfaceType.Smooth
	root.Anchored = not withHumanoid
	root.CanCollide = withHumanoid
	root.Parent = model

	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Cylinder
	mesh.Parent = root

	local eye = Instance.new("Part")
	eye.Name = "Eye"
	eye.Size = Vector3.new(1.2, 0.8, 0.4)
	eye.Color = Color3.fromRGB(20, 20, 25)
	eye.Material = Enum.Material.Neon
	eye.CanCollide = false
	eye.CanQuery = false
	eye.Massless = true
	eye.CFrame = root.CFrame * CFrame.new(0, HEIGHT * 0.3, -DIAMETER / 2)
	eye.Parent = model

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = root
	weld.Part1 = eye
	weld.Parent = eye

	model.PrimaryPart = root

	if withHumanoid then
		local humanoid = Instance.new("Humanoid")
		humanoid.RigType = Enum.HumanoidRigType.R6
		humanoid.RequiresNeck = false
		humanoid.AutoRotate = true
		humanoid.HipHeight = 0
		humanoid.WalkSpeed = resolved.Speed or 12
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		humanoid.Parent = model

		local animator = Instance.new("Animator")
		animator.Parent = humanoid
	end

	return model
end

return Cylinder
