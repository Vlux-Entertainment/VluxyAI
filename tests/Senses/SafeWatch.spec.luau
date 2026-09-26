--!strict

--[[
	SafeWatch: who it notices in a safe room, and where it moves its own agent when a room turns
	on around it. Players, the tagged room and the rays are all fakes; PushOut is pure.
]]

local Harness = require("../Support/Harness")
local SenseFakes = require("./SenseFakes")

local roblox = require("@lune/roblox")
local CFrame = roblox.CFrame
local Vector3 = roblox.Vector3

--[[
	A tagged safe room: a box with attributes, as SafeAreas reads one.
]]
local function room(position: any, size: any)
	return {
		CFrame = CFrame.new(position),
		Size = size,
		IsA = function(_self, className: string)
			return className == "BasePart"
		end,
		GetAttribute = function()
			return nil
		end,
	}
end

local function setup(options: {
	characters: { any }?,
	rooms: { any }?,
	hit: any?,
	sense: any?,
	agentAt: any?,
})
	local SafeWatch = Harness.Load("lib/Senses/SafeWatch.luau", {
		globals = SenseFakes.Globals({ hit = options.hit }),
		services = {
			Players = {
				GetPlayers = function()
					local players = {}
					for _, character in options.characters or {} do
						table.insert(players, { Character = character.Model })
					end
					return players
				end,
			},
			CollectionService = {
				GetTagged = function(_self, tag: string)
					return if tag == "AI_SAFE" then options.rooms or {} else {}
				end,
			},
		},
	})
	local agent = SenseFakes.Agent(options.agentAt or Vector3.new(0, 3, 0), Vector3.new(0, 0, -1))
	local teleports = {}
	agent.Teleport = function(_self, position)
		table.insert(teleports, position)
	end
	return {
		SafeWatch = SafeWatch,
		sense = SafeWatch.new(options.sense),
		agent = agent,
		blackboard = agent.Blackboard,
		teleports = teleports,
	}
end

return {
	["a visible player in a safe room is the SafeTarget; one outside is not"] = function(expect)
		local inside = SenseFakes.Character("Inside", Vector3.new(0, 3, -20))
		local outside = SenseFakes.Character("Outside", Vector3.new(0, 3, -10))
		local s = setup({
			characters = { inside, outside },
			rooms = { room(Vector3.new(0, 3, -20), Vector3.new(10, 6, 10)) },
		})

		s.sense:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.SafeTarget, inside.Root)
		expect.equal(s.blackboard.SafePosition, Vector3.new(0, 3, -20))
		expect.near(s.blackboard.SafeDistance, 20)
	end,

	["a wall between, or too far, and there is no SafeTarget"] = function(expect)
		local inside = SenseFakes.Character("Inside", Vector3.new(0, 3, -20))
		local walled = setup({
			characters = { inside },
			rooms = { room(Vector3.new(0, 3, -20), Vector3.new(10, 6, 10)) },
			hit = function()
				return SenseFakes.Hit(nil)
			end,
		})
		walled.sense:Tick(walled.agent, 0.1)
		expect.equal(walled.blackboard.SafeTarget, nil)
		expect.equal(walled.blackboard.SafeDistance, math.huge)

		local far = setup({
			characters = { inside },
			rooms = { room(Vector3.new(0, 3, -20), Vector3.new(10, 6, 10)) },
			sense = { Range = 10 },
		})
		far.sense:Tick(far.agent, 0.1)
		expect.equal(far.blackboard.SafePosition, nil)
	end,

	["an agent inside a safe room is moved to the nearest spot outside every room"] = function(expect)
		local s = setup({
			rooms = { room(Vector3.new(0, 3, 0), Vector3.new(10, 6, 10)) },
			sense = { Spots = { Vector3.new(0, 0, 0), Vector3.new(16, 0, 0), Vector3.new(40, 0, 0) } },
		})
		s.sense:Tick(s.agent, 0.1)
		expect.equal(#s.teleports, 1)
		expect.equal(s.teleports[1], Vector3.new(16, 3, 0), "the spot inside the room is skipped; Height is added")
	end,

	["Spots may be a graph, and an agent outside every room is left alone"] = function(expect)
		local graph = {
			GetNodes = function()
				return { { Position = Vector3.new(0, 0, 0) }, { Position = Vector3.new(0, 0, 20) } }
			end,
		}
		local s = setup({ rooms = { room(Vector3.new(0, 3, 0), Vector3.new(10, 6, 10)) }, sense = { Spots = graph } })
		s.sense:Tick(s.agent, 0.1)
		expect.equal(s.teleports[1], Vector3.new(0, 3, 20))

		local outside = setup({
			rooms = { room(Vector3.new(0, 3, 0), Vector3.new(10, 6, 10)) },
			agentAt = Vector3.new(30, 3, 0),
			sense = { Spots = graph },
		})
		outside.sense:Tick(outside.agent, 0.1)
		expect.equal(#outside.teleports, 0)

		local kept = setup({
			rooms = { room(Vector3.new(0, 3, 0), Vector3.new(10, 6, 10)) },
			sense = { Spots = graph, Evict = false },
		})
		kept.sense:Tick(kept.agent, 0.1)
		expect.equal(#kept.teleports, 0, "Evict = false leaves it where it is")
	end,

	["with no spots it is pushed out through the nearest side face"] = function(expect)
		local s =
			setup({ rooms = { room(Vector3.new(0, 3, 0), Vector3.new(10, 6, 10)) }, agentAt = Vector3.new(4, 3, 1) })
		s.sense:Tick(s.agent, 0.1)
		expect.equal(s.teleports[1], Vector3.new(8, 3, 1), "5 studs to the +X face, plus 3")

		local PushOut = s.SafeWatch.PushOut
		expect.equal(
			PushOut(CFrame.new(0, 3, 0), Vector3.new(10, 6, 10), Vector3.new(1, 3, -4.5), 2),
			Vector3.new(1, 3, -7)
		)
	end,

	["the one it was chasing counts in a safe room even out of sight, and the chase memory is wiped"] = function(
		expect
	)
		local runner = SenseFakes.Character("Runner", Vector3.new(0, 3, -20))
		local s = setup({
			characters = { runner },
			rooms = { room(Vector3.new(0, 3, -20), Vector3.new(10, 6, 10)) },
			hit = function()
				return SenseFakes.Hit(nil)
			end,
		})
		-- Sight was on them a moment ago, and remembers where.
		s.blackboard.SeenTarget = runner.Root
		s.blackboard.SeenPosition = Vector3.new(0, 3, -12)
		s.blackboard.SeenAt = 100
		s.blackboard.PredictedPosition = Vector3.new(0, 3, -16)
		s.sense:Tick(s.agent, 0.1)

		-- Now they are in the room, behind a wall, and Sight has lost them.
		s.blackboard.SeenTarget = nil
		s.sense:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.SafeTarget, runner.Root, "a wall does not hide the one it was chasing")
		expect.equal(s.blackboard.SafeWasChased, true)
		expect.equal(s.blackboard.SeenPosition, nil, "nothing left to follow")
		expect.equal(s.blackboard.SeenAt, nil)
		expect.equal(s.blackboard.PredictedPosition, nil)
	end,
}
