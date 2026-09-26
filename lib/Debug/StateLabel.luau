--!strict

--[[
	A billboard above an agent showing its name, state, navigator status and any blackboard keys
	you ask for. Opt-in; refreshes on state changes and on a slow timer for the values.
]]

local Cleaner = require(script.Parent.Parent.Utility.Cleaner)
local Options = require(script.Parent.Parent.Utility.Options)
local Types = require(script.Parent.Parent.Types)

------------------------------------------------------------------------------------------------------------------------

local DEFAULT_OPTIONS = {
	Keys = {} :: { string },
	Offset = Vector3.new(0, 4, 0),
	Interval = 0.25,
	TextSize = 14,
}
table.freeze(DEFAULT_OPTIONS)

type ResolvedOptions = {
	Keys: { string },
	Offset: Vector3,
	Interval: number,
	TextSize: number,
}

--[=[
	@interface StateLabelOptions
	@within StateLabel

	.Keys { string }? -- Blackboard keys to show under the state. Default none.
	.Offset Vector3? -- World offset of the billboard from the root. Default `(0, 4, 0)`.
	.Interval number? -- Seconds between value refreshes. Default `0.25`.
	.TextSize number? -- Default `14`.
]=]
export type StateLabelOptions = {
	Keys: { string }?,
	Offset: Vector3?,
	Interval: number?,
	TextSize: number?,
}

type self = {
	_agent: Types.Agent,
	_options: ResolvedOptions,
	_label: TextLabel,
	_cleaner: Cleaner.Cleaner,
}

local StateLabel = {}
StateLabel.__index = StateLabel

export type StateLabel = typeof(setmetatable({} :: self, StateLabel))

--[[
	A short, readable rendering of a blackboard value.
]]
local function describe(value: any): string
	local kind = typeof(value)
	if kind == "Instance" then
		return (value :: Instance).Name
	elseif kind == "Vector3" then
		local vector = value :: Vector3
		return `({math.round(vector.X)}, {math.round(vector.Y)}, {math.round(vector.Z)})`
	elseif kind == "number" then
		local number = value :: number
		if number == math.huge then
			return "inf"
		end
		return string.format("%.2f", number)
	elseif kind == "table" then
		return `[{#(value :: { any })}]`
	end

	return tostring(value)
end

--[=[
	@class StateLabel

	Debug billboard for an agent: name, current state, navigator status and chosen blackboard
	keys. Make one after building the agent and destroy it with the agent.

	```lua
	local label = VluxyAI.Debug.StateLabel.new(agent, { Keys = { "SeenTarget", "IsWatched" } })
	```
]=]

--[=[
	@within StateLabel
	@param agent Agent
	@param options StateLabelOptions?
	@return StateLabel
]=]
function StateLabel.new(agent: Types.Agent, options: StateLabelOptions?): StateLabel
	local RunService = game:GetService("RunService")

	local resolved = Options.Resolve("StateLabel.new", DEFAULT_OPTIONS, options :: any) :: ResolvedOptions

	local cleaner = Cleaner.new()

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "VluxyAI_StateLabel"
	billboard.AlwaysOnTop = true
	billboard.Size = UDim2.fromOffset(220, 28 + 18 * (2 + #resolved.Keys))
	billboard.StudsOffsetWorldSpace = resolved.Offset
	billboard.MaxDistance = 200
	billboard.ResetOnSpawn = false

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 0.4
	label.BackgroundColor3 = Color3.new(0, 0, 0)
	label.BorderSizePixel = 0
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.Code
	label.TextSize = resolved.TextSize
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Top
	label.RichText = true
	label.Parent = billboard

	billboard.Adornee = agent.Entity.PrimaryPart or agent.Entity
	billboard.Parent = agent.Entity
	cleaner:Add(billboard)

	local self: self = {
		_agent = agent,
		_options = resolved,
		_label = label,
		_cleaner = cleaner,
	}

	local stateLabel = setmetatable(self, StateLabel)

	cleaner:Connect(agent.StateChanged, function()
		stateLabel:Refresh()
	end)

	local elapsed = 0
	cleaner:Connect(RunService.Heartbeat, function(deltaTime: number)
		elapsed += deltaTime
		if elapsed < resolved.Interval then
			return
		end
		elapsed = 0
		stateLabel:Refresh()
	end)

	stateLabel:Refresh()

	return stateLabel
end

--[=[
	@within StateLabel

	Redraws the text now.
]=]
function StateLabel.Refresh(self: StateLabel)
	local agent = self._agent
	local lines = {
		`<b>{agent.Name}</b>  <font color="#9ad">{agent:GetState() or "-"}</font>`,
		`nav: {if agent.Navigator then agent.Navigator:GetStatus() else "none"}`,
	}

	for _, key in self._options.Keys do
		table.insert(lines, `{key}: {describe(agent.Blackboard[key])}`)
	end

	self._label.Text = table.concat(lines, "\n")
end

--[=[
	@within StateLabel
]=]
function StateLabel.Destroy(self: StateLabel)
	self._cleaner:Destroy()
end

return StateLabel
