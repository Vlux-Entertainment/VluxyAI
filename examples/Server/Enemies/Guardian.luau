--!strict

--[[
	Guardian: territory. It wanders a zone around where it spawned. When it sees an intruder
	inside the zone it stops and raises the alarm, which is nothing more than firing the shared
	noise signal loudly, so the Stalker hears it and comes running: two agents cooperating through
	a signal the game owns, with neither knowing the other exists. Then it chases, but only to a
	leash distance from home, and walks back when the intruder gets away.

	Shows: a brain built around a place (Data.Home), a leash implemented as two transitions,
	an agent producing a noise for others' Hearing, and Sight with a shorter Memory so it gives
	up chasing quickly.

	Blackboard (from Sight): SeenTarget, SeenDistance, SeenPosition. Data: Home, Random, Noises.
	Timers: Attack, Alert, Wander.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Context = require(script.Parent.Parent.Context)
local VluxyAI = require(ReplicatedStorage.Packages.VluxyAI)

local WANDER_SPEED = 8
local CHASE_SPEED = 14
local ZONE_RADIUS = 20
local LEASH_RADIUS = 34
local ATTACK_RANGE = 4
local ALARM_LOUDNESS = 3

local function flat(a: Vector3, b: Vector3): number
	return (Vector3.new(a.X, 0, a.Z) - Vector3.new(b.X, 0, b.Z)).Magnitude
end

local function intruder(agent: VluxyAI.Agent): boolean
	local seen = agent.Blackboard.SeenPosition
	return agent.Blackboard.SeenTarget ~= nil and seen ~= nil and flat(seen, agent.Data.Home) <= ZONE_RADIUS
end

local function beyondLeash(agent: VluxyAI.Agent): boolean
	local seen = agent.Blackboard.SeenPosition
	return seen == nil or flat(seen, agent.Data.Home) > LEASH_RADIUS
end

local function inReach(agent: VluxyAI.Agent): boolean
	return agent.Blackboard.SeenDistance <= ATTACK_RANGE
end

local function arrivedOrFailed(agent: VluxyAI.Agent): boolean
	local status = agent:GetPathStatus()
	return status == "Arrived" or status == "Failed"
end

local Brain: VluxyAI.Brain = {
	Initial = "Guard",
	States = {
		Guard = {
			Enter = function(agent: VluxyAI.Agent)
				agent:SetSpeed(WANDER_SPEED)
				agent:StartTimer("Wander", agent.Data.Random:NextNumber(2, 5))
				agent:Stop()
			end,
			Transitions = {
				{ To = "Alert", When = intruder },
				-- Re-enter to wait again once a wander ends.
				{
					To = "Guard",
					When = function(agent: VluxyAI.Agent)
						return agent:GetPathStatus() ~= "Idle" and arrivedOrFailed(agent)
					end,
				},
			},
			Update = function(agent: VluxyAI.Agent)
				if agent:GetPathStatus() == "Idle" and agent:TimerDone("Wander") then
					local random = agent.Data.Random :: Random
					local angle = random:NextNumber(0, math.pi * 2)
					local distance = random:NextNumber(4, ZONE_RADIUS)
					agent:MoveTo(
						agent.Data.Home + Vector3.new(math.cos(angle) * distance, 0, math.sin(angle) * distance)
					)
				end
				return nil
			end,
		},

		Alert = {
			Enter = function(agent: VluxyAI.Agent)
				agent:Stop()
				agent:StartTimer("Alert", 0.8)
				VluxyAI.Locomotion.Play(agent, "Attack")
				-- The alarm is a loud noise at the guardian's position; whoever listens, listens.
				agent.Data.Noises:Fire(agent:GetPosition(), ALARM_LOUDNESS)
			end,
			Transitions = {
				{
					To = "Chase",
					When = function(agent: VluxyAI.Agent)
						return agent:TimerDone("Alert")
					end,
				},
			},
		},

		Chase = {
			Enter = function(agent: VluxyAI.Agent)
				agent:SetSpeed(CHASE_SPEED)
			end,
			Transitions = {
				{ To = "Attack", When = inReach },
				{ To = "Return", When = beyondLeash },
			},
			Update = function(agent: VluxyAI.Agent)
				agent:MoveTo(agent.Blackboard.SeenPosition)
				return nil
			end,
		},

		Return = {
			Enter = function(agent: VluxyAI.Agent)
				agent:SetSpeed(WANDER_SPEED)
				agent:MoveTo(agent.Data.Home)
			end,
			Transitions = {
				{ To = "Alert", When = intruder },
				{ To = "Guard", When = arrivedOrFailed },
			},
		},

		Attack = VluxyAI.Combat.Attack.State({ Damage = 20, Cooldown = 1.2, TargetKey = "SeenTarget", Then = "Chase" }),
	},
}

local function Guardian(model: Model, context: Context.Context): VluxyAI.Agent
	return VluxyAI.new(model)
		:SetName("Guardian")
		:UseBrain(Brain)
		:UsePathfinder(VluxyAI.Pathfinders.Ladder.new({
			VluxyAI.Pathfinders.Straight.new(),
			VluxyAI.Pathfinders.Navmesh.new(),
		}))
		:UseMover(VluxyAI.Movers.Humanoid.new(model, { Speed = WANDER_SPEED }))
		:AddSense(VluxyAI.Senses.Sight.new({ Range = 40, FieldOfView = 160, Memory = 2 }))
		:SetData({ Home = model:GetPivot().Position, Random = context.Random, Noises = context.Noises })
		:SetNavigation({ RepathInterval = 0.25 })
		:Build()
end

return Guardian :: Context.Enemy
