--!strict

--[[
	Draws an agent's current path as a row of small balls, redrawn whenever the navigator plans.
	Opt-in and the only thing in the package that creates workspace parts, apart from StateLabel.
	Parts go under one shared `VluxyAI_Debug` folder in Workspace, made on first use.
]]

local FormatMessage = require(script.Parent.Parent.Utility.FormatMessage)
local Options = require(script.Parent.Parent.Utility.Options)
local Trove = require(script.Parent.Parent.Utility.Trove)
local Types = require(script.Parent.Parent.Types)

------------------------------------------------------------------------------------------------------------------------

local FOLDER_NAME = "VluxyAI_Debug"

local DEFAULT_OPTIONS = {
	Color = Color3.fromRGB(80, 220, 120),
	EndColor = Color3.fromRGB(255, 255, 255),
	Size = 0.5,
}
table.freeze(DEFAULT_OPTIONS)

type ResolvedOptions = {
	Color: Color3,
	EndColor: Color3,
	Size: number,
}

--[=[
	@interface PathVisualOptions
	@within PathVisual

	.Color Color3? -- Colour of the step balls. Default green.
	.EndColor Color3? -- Colour of the last ball. Default white.
	.Size number? -- Diameter of a step ball in studs; the last one is twice that. Default `0.5`.
]=]
export type PathVisualOptions = {
	Color: Color3?,
	EndColor: Color3?,
	Size: number?,
}

type self = {
	_agent: Types.Agent,
	_options: ResolvedOptions,
	_trove: Trove.Trove,
	_parts: Trove.Trove,
}

local PathVisual = {}
PathVisual.__index = PathVisual

export type PathVisual = typeof(setmetatable({} :: self, PathVisual))

--[[
	The shared debug folder, made once.
]]
local function debugFolder(): Folder
	local Workspace = game:GetService("Workspace")

	local existing = Workspace:FindFirstChild(FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		return existing
	end

	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
	folder.Parent = Workspace

	return folder
end

--[=[
	@class PathVisual

	Debug view of an agent's path: a ball per step, the last one white. Make one after building
	the agent and destroy it with the agent. Only agents with a navigator have paths.

	```lua
	local visual = VluxyAI.Debug.PathVisual.new(agent)
	```
]=]

--[=[
	@within PathVisual
	@param agent Agent
	@param options PathVisualOptions?
	@return PathVisual
]=]
function PathVisual.new(agent: Types.Agent, options: PathVisualOptions?): PathVisual
	local resolved = Options.Resolve("PathVisual.new", DEFAULT_OPTIONS, options :: any) :: ResolvedOptions

	local trove = Trove.new()
	local self: self = {
		_agent = agent,
		_options = resolved,
		_trove = trove,
		_parts = trove:Extend(),
	}

	local visual = setmetatable(self, PathVisual)

	local navigator = agent.Navigator
	if navigator == nil then
		FormatMessage.Warn(`{agent.Name}: PathVisual needs a navigator; nothing will be drawn`)
		return visual
	end

	trove:Connect(navigator.PathChanged, function(path: Types.Path?)
		visual:_draw(path)
	end)
	visual:_draw(navigator:GetPath())

	return visual
end

--[[
	Replaces the drawn balls with one per step of the path.
]]
function PathVisual._draw(self: PathVisual, path: Types.Path?)
	self._parts:Clean()
	if path == nil then
		return
	end

	local folder = debugFolder()
	local count = #path

	for index, step in path do
		local part = Instance.new("Part")
		part.Name = `{self._agent.Name}_Step{index}`
		part.Shape = Enum.PartType.Ball
		part.Size = Vector3.one * (if index == count then self._options.Size * 2 else self._options.Size)
		part.Position = step.Position
		part.Color = if index == count then self._options.EndColor else self._options.Color
		part.Material = Enum.Material.Neon
		part.Transparency = 0.3
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = false
		part.Locked = true
		part.Parent = folder

		self._parts:Add(part)
	end
end

--[=[
	@within PathVisual

	Removes the balls and stops listening.
]=]
function PathVisual.Destroy(self: PathVisual)
	self._trove:Destroy()
end

return PathVisual
