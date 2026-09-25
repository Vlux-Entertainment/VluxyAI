--!strict

--[[
	Walks an AgentDefinition and errors on the first problem with the path of the field, so a
	mistake reads as `Definition.Brain.States.Hunt.Transitions[2].To = "Chase" names no state`
	rather than `attempt to index nil`. Pure Luau.

	The checks mirror Types.luau exactly. Unknown fields are errors, not warnings, because the
	usual cause is a typo (`Transition` for `Transitions`) that would otherwise silently do nothing.
]]

local FormatMessage = require(script.Parent.Parent.Utility.FormatMessage)
local Tables = require(script.Parent.Parent.Utility.Tables)

------------------------------------------------------------------------------------------------------------------------

local STATE_FIELDS = {
	Enter = true,
	Update = true,
	Exit = true,
	Transitions = true,
}

-- The 0.1 names, so the error can say what changed instead of "unknown field".
local LEGACY_STATE_FIELDS = {
	Start = "Enter",
	End = "Exit",
}

local DEFINITION_FIELDS = {
	Entity = true,
	Brain = true,
	Pathfinder = true,
	Mover = true,
	Senses = true,
	Blackboard = true,
	Data = true,
	Tick = true,
	Navigation = true,
	Name = true,
}

-- true = must be above zero; false = zero is meaningful ("re-plan on any movement").
local NAVIGATION_FIELDS = {
	RepathInterval = true,
	RepathDistance = false,
	MaxPathAge = true,
	ArriveDistance = false,
	ArriveHeight = false,
}

local MOVER_METHODS = { "Follow", "Stop", "GetPosition", "GetSpeed", "SetSpeed", "IsMoving" }
local MOVER_SIGNALS = { "StepReached", "Arrived" }

------------------------------------------------------------------------------------------------------------------------

local Validate = {}

--[[
	Raises a validation error for a field path. Level 0 keeps the message clean of a location,
	since the path already says where the problem is.
]]
local function fail(path: string, problem: string): never
	return FormatMessage.Error(`{path} {problem}`, 0)
end

--[[
	Describes a value for a message: its type, plus the value itself for strings and numbers.
]]
local function describe(value: any): string
	local kind = typeof(value)
	if kind == "string" then
		return `"{value}"`
	elseif kind == "number" or kind == "boolean" then
		return tostring(value)
	end

	return `a {kind}`
end

local function expectTable(value: any, path: string)
	if type(value) ~= "table" then
		fail(path, `must be a table, got {describe(value)}`)
	end
end

local function expectFunction(value: any, path: string)
	if type(value) ~= "function" then
		fail(path, `must be a function, got {describe(value)}`)
	end
end

local function expectOptionalFunction(value: any, path: string)
	if value ~= nil then
		expectFunction(value, path)
	end
end

local function expectString(value: any, path: string)
	if type(value) ~= "string" then
		fail(path, `must be a string, got {describe(value)}`)
	end
end

local function expectPositiveNumber(value: any, path: string)
	if type(value) ~= "number" or value ~= value or value <= 0 then
		fail(path, `must be a number above 0, got {describe(value)}`)
	end
end

local function expectNonNegativeNumber(value: any, path: string)
	if type(value) ~= "number" or value ~= value or value < 0 then
		fail(path, `must be a number of 0 or more, got {describe(value)}`)
	end
end

local function expectKnownFields(value: { [any]: any }, known: { [string]: boolean }, path: string)
	for key in value do
		if type(key) ~= "string" or known[key] == nil then
			fail(
				`{path}.{tostring(key)}`,
				`is not a field VluxyAI knows; expected one of {table.concat(Tables.SortedKeys(known), ", ")}`
			)
		end
	end
end

--[[
	A method table is anything with the named functions. Methods are looked up with indexing rather
	than rawget so metatable classes pass.
]]
local function expectMethods(value: any, methods: { string }, path: string)
	expectTable(value, path)
	for _, method in methods do
		if type(value[method]) ~= "function" then
			fail(`{path}.{method}`, `must be a function, got {describe(value[method])}`)
		end
	end
end

local function expectSignals(value: any, signals: { string }, path: string)
	for _, name in signals do
		local signal = value[name]
		if type(signal) ~= "table" or type(signal.Connect) ~= "function" then
			fail(`{path}.{name}`, `must be a signal with Connect, got {describe(signal)}`)
		end
	end
end

------------------------------------------------------------------------------------------------------------------------

--[=[
	@class Validate

	Checks an [Types.AgentDefinition] or a [Types.Brain] and errors with the path of the first bad
	field. `Build()` and `VluxyAI.NewAgent` run it for you; call `VluxyAI.Validate` yourself to
	check content modules in a test.
]=]

--[=[
	@within Validate
	@param brain any -- The candidate brain.
	@param path string? -- The prefix for messages. Default `Brain`.
	@error string -- The path and problem of the first bad field.

	Checks a brain table: `Initial` names a state, every state's functions are functions, every
	transition targets a state, and no field is misspelled. The 0.1 names `Start` and `End` are
	called out by name.
]=]
function Validate.Brain(brain: any, path: string?)
	local root = path or "Brain"

	expectTable(brain, root)
	expectKnownFields(brain, { Initial = true, States = true }, root)
	expectString(brain.Initial, `{root}.Initial`)
	expectTable(brain.States, `{root}.States`)

	if next(brain.States) == nil then
		fail(`{root}.States`, "has no states")
	end

	for name, state in brain.States do
		if type(name) ~= "string" then
			fail(`{root}.States[{describe(name)}]`, "must be keyed by a string name")
		end

		local statePath = `{root}.States.{name}`
		expectTable(state, statePath)

		for key in state do
			local replacement = LEGACY_STATE_FIELDS[key]
			if replacement then
				fail(`{statePath}.{key}`, `is the VluxyAI 0.1 name; it is called "{replacement}" now`)
			end
		end
		expectKnownFields(state, STATE_FIELDS, statePath)

		expectOptionalFunction(state.Enter, `{statePath}.Enter`)
		expectOptionalFunction(state.Update, `{statePath}.Update`)
		expectOptionalFunction(state.Exit, `{statePath}.Exit`)

		if state.Transitions ~= nil then
			local transitionsPath = `{statePath}.Transitions`
			expectTable(state.Transitions, transitionsPath)

			local count = 0
			for index, transition in state.Transitions do
				count += 1
				local transitionPath = `{transitionsPath}[{tostring(index)}]`

				if type(index) ~= "number" then
					fail(transitionPath, "must be in a list, not keyed")
				end

				expectTable(transition, transitionPath)
				expectKnownFields(transition, { To = true, When = true }, transitionPath)
				expectString(transition.To, `{transitionPath}.To`)
				expectFunction(transition.When, `{transitionPath}.When`)

				if brain.States[transition.To] == nil then
					fail(`{transitionPath}.To`, `= "{transition.To}" names no state`)
				end
			end

			if count ~= #state.Transitions then
				fail(transitionsPath, "must be a list with no holes")
			end
		end
	end

	if brain.States[brain.Initial] == nil then
		fail(`{root}.Initial`, `= "{brain.Initial}" names no state`)
	end
end

--[=[
	@within Validate
	@param definition any -- The candidate definition.
	@error string -- The path and problem of the first bad field.

	Checks a whole definition against [Types.AgentDefinition]: the entity, the brain (through
	[Validate.Brain]), that a pathfinder and a mover come as a pair and have their methods, that
	every sense has `Tick`, and that the numbers are numbers.

	The entity may be a plain table in a headless test; a real `Instance` must be a `Model` with a
	`PrimaryPart`.
]=]
function Validate.Definition(definition: any)
	local root = "Definition"

	expectTable(definition, root)
	expectKnownFields(definition, DEFINITION_FIELDS, root)

	local entity = definition.Entity
	if typeof(entity) == "Instance" then
		if not (entity :: Instance):IsA("Model") then
			fail(`{root}.Entity`, `must be a Model, got a {(entity :: Instance).ClassName}`)
		end
		if (entity :: Model).PrimaryPart == nil then
			fail(`{root}.Entity`, `({(entity :: Model):GetFullName()}) has no PrimaryPart`)
		end
	elseif type(entity) ~= "table" then
		fail(`{root}.Entity`, `must be a Model, got {describe(entity)}`)
	end

	if definition.Name ~= nil then
		expectString(definition.Name, `{root}.Name`)
	end

	Validate.Brain(definition.Brain, `{root}.Brain`)

	local hasPathfinder = definition.Pathfinder ~= nil
	local hasMover = definition.Mover ~= nil
	if hasPathfinder ~= hasMover then
		local missing = if hasPathfinder then "Mover" else "Pathfinder"
		local present = if hasPathfinder then "Pathfinder" else "Mover"
		fail(`{root}.{missing}`, `is missing; a {present} needs a {missing} to go with it`)
	end

	if hasPathfinder then
		expectMethods(definition.Pathfinder, { "FindPath" }, `{root}.Pathfinder`)
		if definition.Pathfinder.Blocked ~= nil then
			expectSignals(definition.Pathfinder, { "Blocked" }, `{root}.Pathfinder`)
		end
		expectMethods(definition.Mover, MOVER_METHODS, `{root}.Mover`)
		expectSignals(definition.Mover, MOVER_SIGNALS, `{root}.Mover`)
	end

	if definition.Senses ~= nil then
		expectTable(definition.Senses, `{root}.Senses`)
		local seen: { [any]: number } = {}
		for index, sense in definition.Senses do
			if type(index) ~= "number" then
				fail(`{root}.Senses[{describe(index)}]`, "must be in a list, not keyed")
			end
			expectMethods(sense, { "Tick" }, `{root}.Senses[{index}]`)
			if seen[sense] then
				fail(`{root}.Senses[{index}]`, `is the same sense as Senses[{seen[sense]}]; it would tick twice`)
			end
			seen[sense] = index
		end
	end

	if definition.Blackboard ~= nil then
		expectTable(definition.Blackboard, `{root}.Blackboard`)
	end

	if definition.Data ~= nil then
		expectTable(definition.Data, `{root}.Data`)
	end

	if definition.Tick ~= nil then
		expectPositiveNumber(definition.Tick, `{root}.Tick`)
	end

	if definition.Navigation ~= nil then
		local navigationPath = `{root}.Navigation`
		expectTable(definition.Navigation, navigationPath)
		expectKnownFields(definition.Navigation, NAVIGATION_FIELDS :: any, navigationPath)
		for key, mustBePositive in NAVIGATION_FIELDS do
			local value = definition.Navigation[key]
			if value == nil then
				continue
			end
			if mustBePositive then
				expectPositiveNumber(value, `{navigationPath}.{key}`)
			else
				expectNonNegativeNumber(value, `{navigationPath}.{key}`)
			end
		end
	end
end

return Validate
