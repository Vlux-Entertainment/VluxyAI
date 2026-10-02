--!strict

--[[
	What the playground hands every example enemy: the package, the map, a shared noise signal,
	the group's Neighbours sense, the maze's node graph (one Graph shared by every enemy, since it
	keeps no per-agent state) and a seeded Random. Kept in one place so the enemy modules read
	the same.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Map = require(script.Parent.Map)
local VluxyAI = require(ReplicatedStorage.Packages.VluxyAI)

export type Context = {
	Map: Map.BuiltMap,
	-- A noise: where, how loud, and what it was ("Running", "Door", "Alarm", "Jump", "Pad",
	-- "Footstep"). Hearing uses the first two; the clue map weighs each kind (Clues.luau).
	Noises: VluxyAI.NoiseSignal,
	Crowd: VluxyAI.Sense,
	Graph: VluxyAI.Pathfinder,
	-- Where a player might be: every cell, warmed by noises and sightings (see Playground).
	Interest: VluxyAI.Interest,
	Random: Random,
}

--[[
	An enemy module is a function from a rig and the context to a built, unstarted agent.
]]
export type Enemy = (model: Model, context: Context) -> VluxyAI.Agent

return {}
