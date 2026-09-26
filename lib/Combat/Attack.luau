--!strict

--[[
	The one generic state in the package: strike a target on entry, wait out a cooldown, go back.
	A blow that would finish the victim can be delivered as a live or black-box kill instead of
	damage, and the state then waits for the kill to end so the killer stands still through it.
	With Kill = "Scare" every blow is a grab that lets go: the same hold, the Damage dealt at the
	end, no death. Health lives on the Humanoid unless a HealthProvider says otherwise.
	Everything else about a brain is content; this is here because kills are.
]]

local FormatMessage = require(script.Parent.Parent.Utility.FormatMessage)
local Kill = require(script.Parent.Kill)
local Locomotion = require(script.Parent.Parent.Animator.Locomotion)
local Perception = require(script.Parent.Parent.Senses.Perception)
local Types = require(script.Parent.Parent.Types)

------------------------------------------------------------------------------------------------------------------------

--[=[
	@interface StrikeOptions
	@within Attack

	.Kill KillKind? -- How a blow that would finish the victim is delivered; `"Scare"` makes every blow a hold that lets go. Default: plain damage.
	.Animation string? -- A one-shot loaded by [Locomotion] to play on a plain blow. Default `"Attack"`.
	.KillerAnimation number? -- Animation id for the killer in a live kill or scare. Default none.
	.VictimAnimation number? -- Animation id for the victim in a live kill or scare. Default none.
	.Health HealthProvider? -- Where the victim's health lives, when not on the Humanoid.
]=]
export type StrikeOptions = {
	Kill: Types.KillKind?,
	Animation: string?,
	KillerAnimation: number?,
	VictimAnimation: number?,
	Health: Types.HealthProvider?,
}

--[=[
	@interface AttackStateOptions
	@within Attack

	.Damage number
	.Cooldown number -- Seconds in the state after the blow.
	.TargetKey string -- The blackboard key holding the victim's root part.
	.Then string -- The state to enter when the cooldown ends (and any kill has finished).
	.Kill KillKind? -- As [Attack.StrikeOptions].
	.Animation string? -- As [Attack.StrikeOptions].
	.KillerAnimation number? -- As [Attack.StrikeOptions].
	.VictimAnimation number? -- As [Attack.StrikeOptions].
	.Health HealthProvider? -- As [Attack.StrikeOptions].
]=]
export type AttackStateOptions = {
	Damage: number,
	Cooldown: number,
	TargetKey: string,
	Then: string,
	Kill: Types.KillKind?,
	Animation: string?,
	KillerAnimation: number?,
	VictimAnimation: number?,
	Health: Types.HealthProvider?,
}

local DATA_KEY = "AttackKill"

local Attack = {}

--[=[
	@class Attack

	Striking and the attack state. `Attack.State` returns a fresh [Types.State] to drop into a
	brain; `Attack.Strike` is the blow on its own for a state of your own making.

	```lua
	Attack = VluxyAI.Combat.Attack.State({
		Damage = 34, Cooldown = 1.8, TargetKey = "SeenTarget", Then = "Hunt", Kill = "Live",
	}),
	```
]=]

--[=[
	@within Attack
	@param agent Agent
	@param target BasePart? -- The victim's root; nothing happens for `nil` or a part with no humanoid.
	@param damage number
	@param options StrikeOptions?
	@return KillHandle? -- The kill in progress, when the blow was a kill.

	Hurts the humanoid behind `target`. When `Kill` is set and the blow would bring the health to
	zero, a kill of that kind happens instead and its handle is returned.
]=]
function Attack.Strike(agent: Types.Agent, target: BasePart?, damage: number, options: StrikeOptions?): Kill.KillHandle?
	local resolved: StrikeOptions = options or {}
	local health = resolved.Health
	local humanoid = if target then Perception.HumanoidOf(target) else nil
	local character = if target then Perception.CharacterOf(target) else nil
	if character == nil or (humanoid == nil and health == nil) then
		-- Silence here hides a misspelled TargetKey behind an enemy that stands still.
		local what = if target == nil
			then "no target"
			else `a target ({tostring((target :: any).Name)}) with no Humanoid or character`
		FormatMessage.Warn(`{agent.Name}: Strike hit nothing: {what}. Check the TargetKey of the attack state`)
		return nil
	end

	if resolved.Kill == "Scare" then
		return Kill.Scare(agent, character, {
			Damage = damage,
			KillerAnimation = resolved.KillerAnimation,
			VictimAnimation = resolved.VictimAnimation,
			Health = health,
		})
	end

	local current = if health ~= nil then health.Get(character) elseif humanoid then humanoid.Health else 0
	if resolved.Kill == nil or current > damage then
		Locomotion.Play(agent, resolved.Animation or "Attack")
		if health ~= nil then
			health.Damage(character, damage)
		elseif humanoid then
			humanoid:TakeDamage(damage)
		end
		return nil
	end

	if resolved.Kill == "Live" then
		return Kill.Live(agent, character, {
			KillerAnimation = resolved.KillerAnimation,
			VictimAnimation = resolved.VictimAnimation,
			Health = health,
		})
	end

	return Kill.BlackBox(agent, character, { Health = health })
end

--[=[
	@within Attack
	@param options AttackStateOptions
	@return State

	A state that strikes once on entry and leaves for `Then` when the cooldown is over and any
	kill it started has finished. The agent is stopped on entry and stays stopped.
]=]
function Attack.State(options: AttackStateOptions): Types.State
	return {
		Enter = function(agent: Types.Agent)
			agent:Stop()
			agent:StartTimer("Attack", options.Cooldown)

			local handle = Attack.Strike(agent, agent.Blackboard[options.TargetKey], options.Damage, {
				Kill = options.Kill,
				Animation = options.Animation,
				KillerAnimation = options.KillerAnimation,
				VictimAnimation = options.VictimAnimation,
				Health = options.Health,
			})

			agent.Data[DATA_KEY] = handle
			if handle then
				handle.Finished:Once(function()
					agent.Data[DATA_KEY] = nil
				end)
			end
		end,
		Transitions = {
			{
				To = options.Then,
				When = function(agent: Types.Agent)
					return agent:TimerDone("Attack") and agent.Data[DATA_KEY] == nil
				end,
			},
		},
		Exit = function(agent: Types.Agent)
			-- Leaving early (a forced SetState) must not leave a victim held.
			local handle = agent.Data[DATA_KEY] :: Kill.KillHandle?
			if handle then
				handle:Cancel()
				agent.Data[DATA_KEY] = nil
			end
		end,
	}
end

return Attack
