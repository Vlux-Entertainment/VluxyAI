--!strict

--[[
	Draws what an agent's senses cover, so ranges and cones are tuned by eye instead of by
	numbers: the sight cone from the eye (green while something is seen), circles for the
	hearing and proximity ranges, and markers at the last seen, predicted and last known
	positions. Handle adornments, not parts, so nothing collides and nothing is left on the
	navmesh. Opt-in, redrawn a few times a second, gone with Destroy.
]]

local Cleaner = require(script.Parent.Parent.Utility.Cleaner)
local Options = require(script.Parent.Parent.Utility.Options)
local Types = require(script.Parent.Parent.Types)

------------------------------------------------------------------------------------------------------------------------

local FOLDER_NAME = "VluxyAI_Debug"

local DEFAULT_OPTIONS = table.freeze({
	Rate = 10,
	SightColor = Color3.fromRGB(255, 200, 60),
	SeenColor = Color3.fromRGB(80, 220, 120),
	HearingColor = Color3.fromRGB(90, 160, 255),
	ProximityColor = Color3.fromRGB(255, 120, 120),
	MarkColor = Color3.fromRGB(255, 255, 255),
	Transparency = 0.7,
})

local ALLOWED_OPTIONS = { "Sight", "Hearing", "Proximity" }

--[=[
	@interface SenseVisualOptions
	@within SenseVisual

	.Sight { Range: number, FieldOfView: number, EyeOffset: Vector3? } | Sense? -- Draw the sight cone from these numbers, or from a [Sight] sense's own options.
	.Hearing number | Sense? -- Draw a circle of this radius, or a [Hearing] sense's `Range`.
	.Proximity number | Sense? -- Draw a circle of this radius, or a [Proximity] sense's `Range`.
	.Rate number? -- Redraws per second. Default `10`.
	.SightColor Color3? -- The cone when nothing is seen. Default amber.
	.SeenColor Color3? -- The cone while `SeenTarget` is set. Default green.
	.HearingColor Color3? -- Default blue.
	.ProximityColor Color3? -- Default red.
	.MarkColor Color3? -- The position markers. Default white.
	.Transparency number? -- Of every adornment. Default `0.7`.
]=]
export type SenseVisualOptions = {
	Sight: any?,
	Hearing: any?,
	Proximity: any?,
	Rate: number?,
	SightColor: Color3?,
	SeenColor: Color3?,
	HearingColor: Color3?,
	ProximityColor: Color3?,
	MarkColor: Color3?,
	Transparency: number?,
}

type ResolvedOptions = {
	Sight: any?,
	Hearing: any?,
	Proximity: any?,
	Rate: number,
	SightColor: Color3,
	SeenColor: Color3,
	HearingColor: Color3,
	ProximityColor: Color3,
	MarkColor: Color3,
	Transparency: number,
}

type self = {
	_agent: Types.Agent,
	_options: ResolvedOptions,
	_cleaner: Cleaner.Cleaner,
	_cone: ConeHandleAdornment?,
	_hearing: CylinderHandleAdornment?,
	_proximity: CylinderHandleAdornment?,
	_marks: { [string]: SphereHandleAdornment },
	_beam: LineHandleAdornment?,
	_destroyed: boolean,
}

local SenseVisual = {}
SenseVisual.__index = SenseVisual

export type SenseVisual = typeof(setmetatable({} :: self, SenseVisual))

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

--[[
	A number given directly, or read off a sense's options.
]]
local function numberOf(given: any, field: string): number?
	if type(given) == "number" then
		return given
	end
	if type(given) == "table" then
		if type(given[field]) == "number" then
			return given[field]
		end
		local options = given._options
		if type(options) == "table" and type(options[field]) == "number" then
			return options[field]
		end
	end
	return nil
end

local function vectorOf(given: any, field: string): Vector3?
	if type(given) == "table" then
		if typeof(given[field]) == "Vector3" then
			return given[field]
		end
		local options = given._options
		if type(options) == "table" and typeof(options[field]) == "Vector3" then
			return options[field]
		end
	end
	return nil
end

--[=[
	@class SenseVisual

	Debug view of an agent's perception: the sight cone, the hearing and proximity circles, and
	markers at `SeenPosition`, `PredictedPosition` and `LastKnownPosition`. Exposed as
	`VluxyAI.Debug.SenseVisual`. Make one after building the agent, hand it the senses (or their
	numbers), and destroy it with the agent.

	```lua
	local sight = VluxyAI.Senses.Sight.new({ Range = 40, FieldOfView = 120 })
	local agent = VluxyAI.new(rig):UseBrain(Brain):AddSense(sight):Build()
	local view = VluxyAI.Debug.SenseVisual.new(agent, { Sight = sight, Hearing = 30 })
	agent.Destroyed:Connect(function() view:Destroy() end)
	```
]=]

--[=[
	@within SenseVisual
	@param agent Agent
	@param options SenseVisualOptions?
	@return SenseVisual
]=]
function SenseVisual.new(agent: Types.Agent, options: SenseVisualOptions?): SenseVisual
	local resolved =
		Options.Resolve("SenseVisual.new", DEFAULT_OPTIONS, options :: any, ALLOWED_OPTIONS) :: ResolvedOptions

	local cleaner = Cleaner.new()
	local self: self = {
		_agent = agent,
		_options = resolved,
		_cleaner = cleaner,
		_cone = nil,
		_hearing = nil,
		_proximity = nil,
		_marks = {},
		_beam = nil,
		_destroyed = false,
	}
	local visual = setmetatable(self, SenseVisual)

	local folder = debugFolder()
	local root = (agent.Entity :: any).PrimaryPart

	if resolved.Sight ~= nil and root ~= nil then
		local cone = Instance.new("ConeHandleAdornment")
		cone.Name = `{agent.Name}_Sight`
		cone.Adornee = root
		cone.AlwaysOnTop = false
		cone.Transparency = resolved.Transparency
		cone.Color3 = resolved.SightColor
		cone.Parent = folder
		cleaner:Add(cone)
		self._cone = cone

		local beam = Instance.new("LineHandleAdornment")
		beam.Name = `{agent.Name}_Seen`
		beam.Adornee = root
		beam.Thickness = 3
		beam.Color3 = resolved.SeenColor
		beam.Visible = false
		beam.Parent = folder
		cleaner:Add(beam)
		self._beam = beam
	end

	local function circle(name: string, radius: number, color: Color3): CylinderHandleAdornment?
		if root == nil then
			return nil
		end
		local ring = Instance.new("CylinderHandleAdornment")
		ring.Name = `{agent.Name}_{name}`
		ring.Adornee = root
		ring.Radius = radius
		ring.Height = 0.2
		ring.CFrame = CFrame.Angles(math.pi / 2, 0, 0)
		ring.Transparency = math.min(0.95, resolved.Transparency + 0.15)
		ring.Color3 = color
		ring.Parent = folder
		cleaner:Add(ring)
		return ring
	end

	local hearingRange = numberOf(resolved.Hearing, "Range")
	if hearingRange ~= nil then
		self._hearing = circle("Hearing", hearingRange, resolved.HearingColor)
	end
	local proximityRange = numberOf(resolved.Proximity, "Range")
	if proximityRange ~= nil then
		self._proximity = circle("Proximity", proximityRange, resolved.ProximityColor)
	end

	local RunService = game:GetService("RunService")
	local interval = 1 / math.max(resolved.Rate, 1)
	local since = interval
	cleaner:Connect(RunService.Heartbeat, function(deltaTime: number)
		since += deltaTime
		if since < interval then
			return
		end
		since = 0
		visual:Refresh()
	end)

	cleaner:Connect(agent.Destroyed, function()
		visual:Destroy()
	end)

	visual:Refresh()
	return visual
end

--[[
	A marker at a world position, made on first use and hidden when the key is nil.
]]
function SenseVisual._mark(self: SenseVisual, key: string, position: Vector3?, folder: Folder, root: BasePart)
	local mark = self._marks[key]
	if position == nil then
		if mark then
			mark.Visible = false
		end
		return
	end

	if not mark then
		local created = Instance.new("SphereHandleAdornment")
		created.Name = `{self._agent.Name}_{key}`
		created.Adornee = root
		created.Radius = 0.6
		created.AlwaysOnTop = true
		created.Transparency = self._options.Transparency
		created.Color3 = self._options.MarkColor
		created.Parent = folder
		self._cleaner:Add(created)
		self._marks[key] = created
		mark = created
	end

	local sphere = mark :: SphereHandleAdornment
	sphere.Visible = true
	sphere.CFrame = root.CFrame:ToObjectSpace(CFrame.new(position))
end

--[=[
	@within SenseVisual

	Redraws from the agent's current blackboard. Called for you at `Rate`.
]=]
function SenseVisual.Refresh(self: SenseVisual)
	if self._destroyed then
		return
	end

	local agent = self._agent
	local root = (agent.Entity :: any).PrimaryPart
	if root == nil then
		return
	end
	local blackboard = agent.Blackboard
	local folder = debugFolder()

	local cone = self._cone
	if cone ~= nil then
		local range = numberOf(self._options.Sight, "Range") or 40
		local fieldOfView = numberOf(self._options.Sight, "FieldOfView") or 120
		local eyeOffset = vectorOf(self._options.Sight, "EyeOffset") or Vector3.new(0, 0, 0)
		local half = math.rad(math.clamp(fieldOfView, 1, 179) / 2)

		cone.Height = range
		cone.Radius = math.tan(half) * range
		-- The adornment's cone opens along +Z from its CFrame; the eye looks down -Z.
		cone.CFrame = CFrame.new(eyeOffset) * CFrame.Angles(0, math.pi, 0)
		cone.Color3 = if blackboard.SeenTarget ~= nil then self._options.SeenColor else self._options.SightColor
	end

	local beam = self._beam
	if beam ~= nil then
		local target = blackboard.SeenTarget
		local position = if target ~= nil then (target :: any).Position else nil
		if typeof(position) == "Vector3" then
			local eyeOffset = vectorOf(self._options.Sight, "EyeOffset") or Vector3.new(0, 0, 0)
			local from = root.CFrame:PointToObjectSpace(root.CFrame.Position) + eyeOffset
			local to = root.CFrame:PointToObjectSpace(position)
			local offset = to - from
			beam.Length = offset.Magnitude
			beam.CFrame = CFrame.lookAt(from, to)
			beam.Visible = beam.Length > 0
		else
			beam.Visible = false
		end
	end

	self:_mark("SeenPosition", blackboard.SeenPosition, folder, root)
	self:_mark("PredictedPosition", blackboard.PredictedPosition, folder, root)
	self:_mark("LastKnownPosition", blackboard.LastKnownPosition, folder, root)
	self:_mark("HeardPosition", blackboard.HeardPosition, folder, root)
end

--[=[
	@within SenseVisual

	Removes every adornment and stops redrawing. Safe to call twice.
]=]
function SenseVisual.Destroy(self: SenseVisual)
	if self._destroyed then
		return
	end
	self._destroyed = true
	self._cleaner:Destroy()
	table.clear(self._marks)
end

return SenseVisual
