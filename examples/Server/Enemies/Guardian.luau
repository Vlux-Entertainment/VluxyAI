--!strict

--[[
	Guardian: territory. It wanders a zone around where it spawned. When it sees an intruder
	inside the zone it stops and raises the alarm, which is nothing more than firing the shared
	noise signal loudly, so the Stalker hears it and comes running: two agents cooperating through
	a signal the game owns, with neither knowing the other exists. Then it chases, but only to a
	leash distance from home, and walks back when the intruder gets away.

	Shows: a brain built around a place (Data.Home), a leash implemented as two transitions,
	an agent producing a noise for others' Hearing, and a chase that follows where the intruder was
	heading until the leash pulls it home.

	Blackboard (from Sight): SeenTarget, SeenDistance, SeenPosition. Data: Home, Random, Noises.
	Timers: Attack, Alert, Wander.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Context = require(script.Parent.Parent.Context)
local VluxyAI = require(ReplicatedStorage.Packages.VluxyAI)

local WANDER_SPEED = 8
-- Above a walking player (16), so an intruder has to run; the leash keeps it fair.
local CHASE_SPEED = 18
local ZONE_RADIUS = 20
-- The maze's cell size (Map.luau) and the cells a wander may end in, as offsets from home.
local CELL = 16
local WANDER_CELLS = {
	Vector3.new(0, 0, 0),
	Vector3.new(1, 0, 0),
	Vector3.new(-1, 0, 0),
	Vector3.new(0, 0, 1),
	Vector3.new(0, 0, -1),
}
local LEASH_RADIUS = 34
local ATTACK_RANGE = 4
-- A player this close is noticed whichever way it faces, so creeping up behind it does not work.
local NOTICE_RADIUS = 10
-- Hearing hears a noise within Range * loudness; the Stalker's Range is 40, so 3 reaches 120
-- studs, most of the maze.
local ALARM_LOUDNESS = 3

local flat = VluxyAI.Tables.FlatDistance

local function intruder(agent: VluxyAI.Agent): boolean
	local seen = agent.Blackboard.SeenPosition
	return agent.Blackboard.SeenTarget ~= nil and seen ~= nil and flat(seen, agent.Data.Home) <= ZONE_RADIUS
end

local function beyondLeash(agent: VluxyAI.Agent): boolean
	local seen = agent.Blackboard.SeenPosition
	return seen == nil or flat(seen, agent.Data.Home) > LEASH_RADIUS
end

-- The one it was chasing just got into a safe room, or it sees someone in one and has not just
-- stood and stared at them.
local safeSighted = VluxyAI.When.SafeSighted()

-- A noise inside its zone that it has not already gone to look at.
local heardNew = VluxyAI.When.New("HeardAt")
local function heardInZone(agent: VluxyAI.Agent): boolean
	local heard = agent.Blackboard.HeardPosition
	return heard ~= nil and flat(heard, agent.Data.Home) <= LEASH_RADIUS and heardNew(agent)
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
				{ To = "Investigate", When = heardInZone },
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
					-- Its own cell or a neighbour's, near the middle: always open floor, never a wall.
					local random = agent.Data.Random :: Random
					local cell = WANDER_CELLS[random:NextInteger(1, #WANDER_CELLS)]
					local jitter = Vector3.new(random:NextNumber(-4, 4), 0, random:NextNumber(-4, 4))
					agent:MoveTo(agent.Data.Home + cell * CELL + jitter)
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
				agent.Data.Noises:Fire(agent:GetPosition(), ALARM_LOUDNESS, "Alarm")
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
				{ To = "Stare", When = safeSighted },
				{ To = "Return", When = beyondLeash },
				-- Reached where they were heading and nobody is there: go home.
				{
					To = "Return",
					When = function(agent: VluxyAI.Agent)
						return agent.Blackboard.SeenTarget == nil and arrivedOrFailed(agent)
					end,
				},
			},
			Update = function(agent: VluxyAI.Agent)
				local heading = agent.Blackboard.PredictedPosition or agent.Blackboard.SeenPosition
				if heading then
					agent:MoveTo(heading)
				end
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

		-- Something moved on its ground: go and look, then back to guarding.
		Investigate = VluxyAI.States.Investigate({
			Target = "HeardPosition",
			Speed = WANDER_SPEED + 2,
			Then = "Return",
			Transitions = { { To = "Alert", When = intruder } },
		}),

		-- The intruder reached a safe room: glare at them a moment, then back to guarding as normal,
		-- unless they step back out onto its ground where it can see them.
		Stare = VluxyAI.States.Stare({
			Target = "SafePosition",
			Duration = 4,
			Cooldown = 20,
			Then = "Guard",
			Transitions = { { To = "Chase", When = intruder } },
		}),

		Attack = VluxyAI.Combat.Attack.State({ Damage = 20, Cooldown = 1.2, TargetKey = "SeenTarget", Then = "Chase" }),
	},
}

local function Guardian(model: Model, context: Context.Context): VluxyAI.Agent
	return VluxyAI
		.Presets
		.Humanoid(model, {
			Graph = context.Graph,
			Doors = true,
			Mover = { Speed = WANDER_SPEED },
			Sight = { Range = 40, FieldOfView = 160, Memory = 5, Predict = 2, NoticeRadius = NOTICE_RADIUS },
		})
		:SetName("Guardian")
		:UseBrain(Brain)
		-- It hears footsteps on its ground too.
		:AddSense(
			VluxyAI.Senses.Hearing.new(context.Noises, { Range = 40, Memory = 4 })
		)
		-- Mostly quiet on guard; a growl as it chases, a laugh at the intruder who made it to safety.
		:AddSense(
			VluxyAI.Voice.new({
				Lines = {
					Guard = { 9113636681 },
					Chase = { 105926319962443, 129294628821291 },
					Stare = { 89425134113608 },
				},
				Interval = { 10, 20 },
				OnEnter = { Chase = 0.8, Stare = 1, ["*"] = 0 },
				Volume = 0.56,
			})
		)
		:AddSense(context.Crowd)
		:SetData({ Home = model:GetPivot().Position, Random = context.Random, Noises = context.Noises })
		:Build()
end

return Guardian :: Context.Enemy
