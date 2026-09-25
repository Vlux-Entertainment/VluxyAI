--!strict

--[[
	The attack every example shares, as a state factory: stop, start the cooldown, swing, hurt the
	target, and go back to the state named in `Then` when the cooldown ends. A brain drops it in
	as `Attack = Combat.AttackState({ ... })`, which is the tidy way to reuse a state between
	brains: a function that returns a fresh state table.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Locomotion = require(script.Parent.Locomotion)
local VluxyAI = require(ReplicatedStorage.Packages.VluxyAI)

export type AttackOptions = {
	Damage: number,
	Cooldown: number,
	-- Which blackboard key holds the victim's root part.
	TargetKey: string,
	-- The state to return to once the cooldown ends.
	Then: string,
	-- How a blow that would finish the victim is delivered. Default: plain damage. A live kill
	-- keeps the state until the hold ends, however short the cooldown.
	Kill: VluxyAI.KillKind?,
}

-- Roblox's own R15 animations for the live kill: a swing for the killer, a flail for the victim.
local KILLER_ANIMATION = 522635514
local VICTIM_ANIMATION = 507767968

local Combat = {}

--[[
	Hurts the humanoid behind a root part, if there is one.
]]
function Combat.Hurt(target: BasePart?, damage: number)
	local humanoid = if target then VluxyAI.Perception.HumanoidOf(target) else nil
	if humanoid then
		humanoid:TakeDamage(damage)
	end
end

--[[
	Strikes a target: a kill of the chosen kind when the blow would finish them, damage otherwise.
]]
function Combat.Strike(agent: VluxyAI.Agent, target: BasePart?, damage: number, kill: VluxyAI.KillKind?)
	local humanoid = if target then VluxyAI.Perception.HumanoidOf(target) else nil
	local character = if target then VluxyAI.Perception.CharacterOf(target) else nil
	if humanoid == nil or character == nil then
		return
	end

	if kill == nil or humanoid.Health > damage then
		Locomotion.PlayAttack(agent)
		humanoid:TakeDamage(damage)
		return
	end

	local handle
	if kill == "Live" then
		handle = VluxyAI.Combat.Kill.Live(agent, character, {
			KillerAnimation = KILLER_ANIMATION,
			VictimAnimation = VICTIM_ANIMATION,
		})
	else
		handle = VluxyAI.Combat.Kill.BlackBox(agent, character)
	end

	-- The attack state waits for the kill to end before it leaves, so the killer stands still.
	agent.Data.Killing = true
	handle.Finished:Once(function()
		agent.Data.Killing = false
	end)
end

--[[
	A state that strikes once on entry and leaves when its cooldown is over.
]]
function Combat.AttackState(options: AttackOptions): VluxyAI.State
	return {
		Enter = function(agent: VluxyAI.Agent)
			agent:Stop()
			agent:StartTimer("Attack", options.Cooldown)
			Combat.Strike(agent, agent.Blackboard[options.TargetKey], options.Damage, options.Kill)
		end,
		Transitions = {
			{
				To = options.Then,
				When = function(agent: VluxyAI.Agent)
					return agent:TimerDone("Attack") and not agent.Data.Killing
				end,
			},
		},
	}
end

return Combat
