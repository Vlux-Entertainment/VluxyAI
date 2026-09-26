--!strict

--[[
	Who has dibs on what. Several enemies sharing one map should not all chase the same player
	or all walk to the same noise; a Claims table is the one place they ask before committing. A
	thing (a player's root, a search spot, a door) is claimed by one agent until it releases it
	or is destroyed. Pure Luau; the table is the game's, passed to each enemy through Data.

	The one decision worth knowing: the owner map is weak-keyed on the thing, so a player root
	that leaves the game does not keep a stale claim alive, and a destroyed agent's claims go
	with it through its Destroyed signal.
]]

local Types = require(script.Parent.Parent.Types)

------------------------------------------------------------------------------------------------------------------------

type self = {
	_owners: { [any]: Types.Agent },
	_watched: { [Types.Agent]: Types.Connection },
}

local Claims = {}
Claims.__index = Claims

export type Claims = typeof(setmetatable({} :: self, Claims))

--[=[
	@class Claims

	A shared "who is on what" table for a group of agents, so two enemies never chase the same
	player or investigate the same noise unless you want them to. Exposed as
	`VluxyAI.Claims`. Make one per group and hand it to each enemy through `SetData`.

	```lua
	local claims = VluxyAI.Claims.new()
	-- in a state
	local target = agent.Blackboard.SeenTarget
	if target and claims:Claim(target, agent) then
		agent:MoveTo(target.Position)
	end
	-- in a Utility.Best call, so a claimed player scores low for everyone else
	{ Input = claims:Consideration(0.2) }
	```

	Claims are released by the owner, by `ReleaseAll`, or when the owning agent is destroyed.
]=]

--[=[
	@within Claims
	@return Claims
]=]
function Claims.new(): Claims
	local self: self = {
		_owners = setmetatable({}, { __mode = "k" }) :: any,
		_watched = setmetatable({}, { __mode = "k" }) :: any,
	}

	return setmetatable(self, Claims)
end

--[[
	A destroyed agent owns nothing.
]]
local function alive(agent: Types.Agent?): boolean
	if agent == nil then
		return false
	end
	local isDestroyed = (agent :: any).IsDestroyed
	return type(isDestroyed) ~= "function" or not agent:IsDestroyed()
end

--[[
	Releases everything an agent owns when it is destroyed, once per agent.
]]
function Claims._watch(self: Claims, agent: Types.Agent)
	if self._watched[agent] ~= nil then
		return
	end

	local destroyed = (agent :: any).Destroyed
	if type(destroyed) ~= "table" or type(destroyed.Connect) ~= "function" then
		return
	end

	self._watched[agent] = destroyed:Connect(function()
		self:ReleaseAll(agent)
	end)
end

--[=[
	@within Claims
	@param thing any -- A root, a position key, a door: anything usable as a table key.
	@return Agent? -- The live agent holding it, or `nil` when it is free.
]=]
function Claims.ClaimedBy(self: Claims, thing: any): Types.Agent?
	local owner = self._owners[thing]
	if owner ~= nil and not alive(owner) then
		self._owners[thing] = nil
		return nil
	end
	return owner
end

--[=[
	@within Claims
	@param thing any
	@param agent Agent
	@return boolean -- `true` when `agent` holds it now: it was free, or already theirs.

	Takes `thing` for `agent` unless another live agent holds it.
]=]
function Claims.Claim(self: Claims, thing: any, agent: Types.Agent): boolean
	local owner = self:ClaimedBy(thing)
	if owner ~= nil and owner ~= agent then
		return false
	end

	self._owners[thing] = agent
	self:_watch(agent)
	return true
end

--[=[
	@within Claims
	@param thing any
	@param agent Agent
	@return boolean -- `true` when `thing` is free or held by `agent`.
]=]
function Claims.IsFree(self: Claims, thing: any, agent: Types.Agent?): boolean
	local owner = self:ClaimedBy(thing)
	return owner == nil or owner == agent
end

--[=[
	@within Claims
	@param thing any
	@param agent Agent -- Only the holder can release.
]=]
function Claims.Release(self: Claims, thing: any, agent: Types.Agent)
	if self._owners[thing] == agent then
		self._owners[thing] = nil
	end
end

--[=[
	@within Claims
	@param agent Agent

	Releases everything `agent` holds. Called for you when the agent is destroyed.
]=]
function Claims.ReleaseAll(self: Claims, agent: Types.Agent)
	for thing, owner in self._owners do
		if owner == agent then
			self._owners[thing] = nil
		end
	end

	local connection = self._watched[agent]
	if connection ~= nil then
		connection:Disconnect()
		self._watched[agent] = nil
	end
end

--[=[
	@within Claims
	@param agent Agent
	@return { any } -- Everything `agent` holds, in no particular order.
]=]
function Claims.Owned(self: Claims, agent: Types.Agent): { any }
	local owned = {}
	for thing, owner in self._owners do
		if owner == agent then
			table.insert(owned, thing)
		end
	end
	return owned
end

--[=[
	@within Claims
	@param takenScore number? -- The input for a candidate another agent holds. Default `0`, a veto.
	@return Consideration<any> -- `1` for a free candidate or one this agent holds, `takenScore` otherwise.

	For [Utility.Best] and [Utility.Weighted]: makes the scoring prefer targets nobody else is on.
]=]
function Claims.Consideration(self: Claims, takenScore: number?): Types.Consideration<any>
	local taken = takenScore or 0
	return {
		Input = function(agent: Types.Agent, candidate: any): number
			return if self:IsFree(candidate, agent) then 1 else taken
		end,
	}
end

--[=[
	@within Claims

	Forgets every claim and stops watching every agent.
]=]
function Claims.Destroy(self: Claims)
	for _, connection in self._watched do
		connection:Disconnect()
	end
	table.clear(self._watched)
	table.clear(self._owners)
end

return Claims
