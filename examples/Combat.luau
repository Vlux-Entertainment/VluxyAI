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
}

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
	A state that strikes once on entry and leaves when its cooldown is over.
]]
function Combat.AttackState(options: AttackOptions): VluxyAI.State
	return {
		Enter = function(agent: VluxyAI.Agent)
			agent:Stop()
			agent:StartTimer("Attack", options.Cooldown)
			Locomotion.PlayAttack(agent)
			Combat.Hurt(agent.Blackboard[options.TargetKey], options.Damage)
		end,
		Transitions = {
			{
				To = options.Then,
				When = function(agent: VluxyAI.Agent)
					return agent:TimerDone("Attack")
				end,
			},
		},
	}
end

return Combat
