--!strict

--[[
	What the playground hands every example enemy: the package, the map, a shared noise signal
	and a seeded Random. Kept in one place so the enemy modules read the same.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Map = require(script.Parent.Map)
local VluxyAI = require(ReplicatedStorage.Packages.VluxyAI)

export type Context = {
	Map: Map.BuiltMap,
	Noises: VluxyAI.Signal<(Vector3, number?)>,
	Random: Random,
}

--[[
	An enemy module is a function from a rig and the context to a built, unstarted agent.
]]
export type Enemy = (model: Model, context: Context) -> VluxyAI.Agent

return {}
