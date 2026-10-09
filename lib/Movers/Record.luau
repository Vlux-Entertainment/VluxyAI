--!strict

--[[
	A mover with no Instance at all: the pivot is a CFrame held in a table, stepped by the agent.
	For enemies that exist on the server only as a row (position, yaw, state) while clients draw
	the bodies, so a server can run hundreds without one part each.

	It is a CFrameMover in Manual mode aimed at a plain pivot holder, so the walking, turning and
	stuck maths are the specced ones and nothing here duplicates them. Manual is not optional:
	there is no Instance for a Heartbeat to be about, and the agent's own Step is the clock.
]]

local CFrameMover = require(script.Parent.CFrameMover)
local FormatMessage = require(script.Parent.Parent.Utility.FormatMessage)
local Types = require(script.Parent.Parent.Types)

------------------------------------------------------------------------------------------------------------------------

-- Options that belong to Record; the rest go to CFrameMover as they are.
local OWN_KEYS = { "Position", "Yaw" }

local Record = {}

--[=[
	@class Record

	A [Types.Mover] for an agent with no Model: its pivot (position and yaw) lives in a table.
	Exposed as `VluxyAI.Movers.Record`. Build an agent on it with `VluxyAI.new()` (no entity) or
	`VluxyAI.Presets.Headless`; the agent's [Agent:GetPivot], [Agent:GetPosition] and
	[Agent:Teleport] all go through it, and the senses read it like they read a rig.

	```lua
	local agent = VluxyAI.new()
		:SetName("Goblin 12")
		:UseBrain(Brain)
		:UsePathfinder(VluxyAI.Pathfinders.Straight.new())
		:UseMover(VluxyAI.Movers.Record.new({ Position = spawn, Speed = 10 }))
		:Build()
		:Start(true)

	-- your scheduler, every frame or every few:
	agent:Step(deltaTime)
	local pivot = agent:GetPivot()
	```

	It moves only inside [Agent:Step], at the agent's tick rate, so a server that steps agents
	itself controls their whole cost. It is a [CFrameMover] in its `Manual` mode underneath and
	has all of its methods, plus `Step(deltaTime)`.
]=]

--[=[
	@interface RecordOptions
	@within Record

	.Position Vector3 -- Where the agent starts. With the default `HeightOffset` this is the floor point under it.
	.Yaw number? -- Starting yaw in radians; `0` faces -Z. Default `0`.
	.Speed number? -- As [CFrameMover]. Default `8`.
	.TurnSpeed number? -- As [CFrameMover]. Default `10`.
	.HeightOffset number? -- As [CFrameMover], but defaults to `0`, so the pivot stays the floor point.
	.StepDistance number? -- As [CFrameMover].
	.StuckTimeout number? -- As [CFrameMover].
	.Noise MoverNoise? -- As [CFrameMover]; fired with no source instance.
]=]
export type RecordOptions = {
	Position: Vector3,
	Yaw: number?,
	Speed: number?,
	TurnSpeed: number?,
	HeightOffset: number?,
	StepDistance: number?,
	StuckTimeout: number?,
	Noise: CFrameMover.MoverNoise?,
}

--[[
	The thing the CFrameMover steps: a CFrame and the two methods it calls.
]]
local function pivotHolder(pivot: CFrame)
	local holder = { Pivot = pivot }

	function holder.GetPivot(self: any): CFrame
		return self.Pivot
	end

	function holder.PivotTo(self: any, cframe: CFrame)
		self.Pivot = cframe
	end

	return holder
end

--[=[
	@within Record
	@param options RecordOptions
	@return Mover
	@error string -- `Position` is missing, or an option is unknown.
]=]
function Record.new(options: RecordOptions): Types.Mover
	if type(options) ~= "table" or typeof((options :: any).Position) ~= "Vector3" then
		FormatMessage.Error("Record.new: options.Position (a Vector3) is required", 2)
	end
	if options.Yaw ~= nil and type(options.Yaw) ~= "number" then
		FormatMessage.Error(`Record.new: Yaw must be a number, got {typeof(options.Yaw)}`, 2)
	end

	local moverOptions: any = table.clone(options :: any)
	for _, key in OWN_KEYS do
		moverOptions[key] = nil
	end
	if moverOptions.Manual ~= nil then
		FormatMessage.Error("Record.new: Manual is always on for a Record; leave it out", 2)
	end
	moverOptions.Manual = true
	if moverOptions.HeightOffset == nil then
		moverOptions.HeightOffset = 0
	end

	local pivot = CFrame.new(options.Position) * CFrame.Angles(0, options.Yaw or 0, 0)
	return CFrameMover.new(pivotHolder(pivot) :: any, moverOptions)
end

return Record
