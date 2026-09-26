--!strict

--[[
	Pacing and shared knowledge for a group of enemies: one tension number that the game raises
	on close calls and kills and that drains by itself, a difficulty knob, and a table every
	agent in the group can read and write. The director never tells an enemy what to do; a brain
	reads the numbers off its blackboard through the director's sense and scales its own speed,
	memory and boldness. Pure Luau.

	The one decision worth knowing: tension decays lazily, computed from the clock when it is
	read, so the director needs no tick of its own and costs nothing between reads.
]]

local Options = require(script.Parent.Utility.Options)
local Types = require(script.Parent.Types)

------------------------------------------------------------------------------------------------------------------------

local DEFAULT_OPTIONS = table.freeze({
	Fall = 0.05,
	Difficulty = 1,
	Tension = 0,
})

--[=[
	@interface DirectorOptions
	@within Director

	.Fall number? -- Tension drained per second. Default `0.05`, so a full meter empties in twenty seconds of quiet.
	.Difficulty number? -- The starting difficulty. Default `1`.
	.Tension number? -- The starting tension. Default `0`.
]=]
export type DirectorOptions = {
	Fall: number?,
	Difficulty: number?,
	Tension: number?,
}

type ResolvedOptions = {
	Fall: number,
	Difficulty: number,
	Tension: number,
}

local SENSE_DEFAULTS = table.freeze({
	Prefix = "Director",
})

--[=[
	@interface DirectorSenseOptions
	@within Director

	.Prefix string? -- Prepended to the three keys. Default `"Director"`, so the keys are `DirectorTension`, `DirectorDifficulty` and `DirectorShared`.
]=]
export type DirectorSenseOptions = {
	Prefix: string?,
}

type self = {
	Blackboard: { [string]: any },

	_options: ResolvedOptions,
	_tension: number,
	_updatedAt: number,
	_difficulty: number,
}

local Director = {}
Director.__index = Director

export type Director = typeof(setmetatable({} :: self, Director))

--[=[
	@class Director

	The game's hand on the group: a tension meter, a difficulty number and a shared blackboard.
	Exposed as `VluxyAI.Director`. Make one per game (or per group), raise it from the events
	that matter, and give every enemy `director:Sense()` so its brain can read the numbers.

	```lua
	local director = VluxyAI.Director.new({ Fall = 0.05 })
	director.Blackboard.Alarm = nil

	-- each enemy
	:AddSense(director:Sense())

	-- the game
	agent.Events:Connect(function(name)
		if name == "Kill" then director:Raise(1) end
	end)

	-- a state
	agent:SetSpeed(director:Scale(BASE_SPEED, 0.5)) -- up to 50% faster at full tension
	if agent.Blackboard.DirectorTension > 0.8 then return "Retreat" end
	```

	Tension is a number in `[0, 1]` that drains by `Fall` per second; difficulty is any number
	the game chooses. `Blackboard` is a plain table shared by reference: an enemy writes the
	alarm position into it, the others read it on their next tick.
]=]

--[=[
	@within Director
	@param options DirectorOptions?
	@return Director
	@error "unknown option"
]=]
function Director.new(options: DirectorOptions?): Director
	local resolved = Options.Resolve("Director.new", DEFAULT_OPTIONS, options :: any) :: ResolvedOptions

	local self: self = {
		Blackboard = {},

		_options = resolved,
		_tension = math.clamp(resolved.Tension, 0, 1),
		_updatedAt = os.clock(),
		_difficulty = resolved.Difficulty,
	}

	return setmetatable(self, Director)
end

--[[
	Applies the drain since the last read.
]]
function Director._settle(self: Director)
	local now = os.clock()
	local elapsed = now - self._updatedAt
	if elapsed > 0 then
		self._tension = math.max(0, self._tension - self._options.Fall * elapsed)
		self._updatedAt = now
	end
end

--[=[
	@within Director
	@return number -- Tension in `[0, 1]`, drained for the time since it was last touched.
]=]
function Director.GetTension(self: Director): number
	self:_settle()
	return self._tension
end

--[=[
	@within Director
	@param amount number -- Added to the tension, clamped to `1`. A kill might be `1`, a near miss `0.3`.
]=]
function Director.Raise(self: Director, amount: number)
	self:_settle()
	self._tension = math.clamp(self._tension + amount, 0, 1)
end

--[=[
	@within Director
	@param amount number -- Taken off the tension, clamped to `0`.
]=]
function Director.Lower(self: Director, amount: number)
	self:Raise(-amount)
end

--[=[
	@within Director
	@param value number -- The new tension, clamped to `[0, 1]`.
]=]
function Director.SetTension(self: Director, value: number)
	self._tension = math.clamp(value, 0, 1)
	self._updatedAt = os.clock()
end

--[=[
	@within Director
	@return number
]=]
function Director.GetDifficulty(self: Director): number
	return self._difficulty
end

--[=[
	@within Director
	@param value number -- Any number the game means by difficulty; `1` is normal.
]=]
function Director.SetDifficulty(self: Director, value: number)
	self._difficulty = value
end

--[=[
	@within Director
	@param base number -- A speed, a memory, a cooldown.
	@param byTension number? -- How much a full meter changes it: `0.5` means `base * 1.5` at full tension. Default `0`.
	@param byDifficulty number? -- How much each unit of difficulty above `1` changes it. Default `0`.
	@return number -- `base * (1 + byTension * tension) * (1 + byDifficulty * (difficulty - 1))`.

	The one line a state needs to scale itself by the game's mood.
]=]
function Director.Scale(self: Director, base: number, byTension: number?, byDifficulty: number?): number
	local tension = self:GetTension()
	local tensionFactor = 1 + (byTension or 0) * tension
	local difficultyFactor = 1 + (byDifficulty or 0) * (self._difficulty - 1)
	return base * tensionFactor * difficultyFactor
end

--[=[
	@within Director
	@param options DirectorSenseOptions?
	@return Sense -- Writes `DirectorTension`, `DirectorDifficulty` and `DirectorShared` (the shared blackboard, by reference) each tick.

	One instance serves every agent in the group. Add it before the senses and states that read
	from it.
]=]
function Director.Sense(self: Director, options: DirectorSenseOptions?): Types.Sense
	local resolved = Options.Resolve("Director.Sense", SENSE_DEFAULTS, options :: any)
	local prefix: string = resolved.Prefix
	local director = self

	return {
		Tick = function(_sense: any, agent: Types.Agent, _deltaTime: number)
			local blackboard = agent.Blackboard
			blackboard[prefix .. "Tension"] = director:GetTension()
			blackboard[prefix .. "Difficulty"] = director._difficulty
			blackboard[prefix .. "Shared"] = director.Blackboard :: any
		end,
	}
end

--[=[
	@within Director

	Clears the shared blackboard. The senses handed out keep working; they read live values.
]=]
function Director.Destroy(self: Director)
	table.clear(self.Blackboard)
end

return Director
