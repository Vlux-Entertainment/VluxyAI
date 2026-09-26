--!strict

--[[
	Look: the client reports the camera rotation when it turned, at most Rate times a second; the
	server keeps the latest per player, forgets leavers and stale reports, and Eye puts the
	rotation at the character's head.
]]

local Fakes = require("../Support/Fakes")
local Harness = require("../Support/Harness")
local SenseFakes = require("../Senses/SenseFakes")

local roblox = require("@lune/roblox")
local CFrame = roblox.CFrame
local Vector3 = roblox.Vector3

local function fakeRemote()
	local Signal = Fakes.Signal()
	local remote = { OnServerEvent = Signal.new(), Sent = {} :: { any } }
	function remote.FireServer(self, cframe)
		table.insert(self.Sent, cframe)
	end
	return remote
end

local function setup(options: { characters: { [any]: any }? }?)
	local resolved = options or {}
	local clock = Harness.ManualClock(100)
	local heartbeat = Harness.ManualHeartbeat()
	local Signal = Fakes.Signal()
	local camera = { CFrame = SenseFakes.Facing(Vector3.new(0, 10, 10), Vector3.new(0, 0, -1)) }
	local playerRemoving = Signal.new()
	local Look = Harness.Load("lib/Sync/Look.luau", {
		globals = { os = clock.os, workspace = { CurrentCamera = camera } },
		services = {
			RunService = { Heartbeat = heartbeat },
			Players = {
				PlayerRemoving = playerRemoving,
				GetPlayerFromCharacter = function(_self, character)
					return (resolved.characters or {})[character]
				end,
			},
		},
	})
	return {
		Look = Look,
		clock = clock,
		heartbeat = heartbeat,
		camera = camera,
		playerRemoving = playerRemoving,
		remote = fakeRemote(),
	}
end

return {
	["Report sends the camera CFrame at most Rate times a second and only when it turned"] = function(expect)
		local s = setup()
		local cleaner = s.Look.Report(s.remote, { Rate = 10, MinAngle = 0.05 })

		s.heartbeat:Fire(0.1)
		expect.equal(#s.remote.Sent, 1, "the first look is sent")
		s.heartbeat:Fire(0.2)
		expect.equal(#s.remote.Sent, 1, "unchanged: not sent again")

		local turned = SenseFakes.Facing(Vector3.new(0, 10, 10), Vector3.new(1, 0, 0))
		s.camera.CFrame = turned
		s.heartbeat:Fire(0.03)
		expect.equal(#s.remote.Sent, 2, "turned after the interval: sent at once")
		expect.equal(s.remote.Sent[2], turned)
		s.camera.CFrame = SenseFakes.Facing(Vector3.new(0, 10, 10), Vector3.new(0, 0, 1))
		s.heartbeat:Fire(0.05)
		expect.equal(#s.remote.Sent, 2, "turned again, but too soon")
		s.heartbeat:Fire(0.05)
		expect.equal(#s.remote.Sent, 3, "sent once the interval passed")

		cleaner:Destroy()
		s.camera.CFrame = SenseFakes.Facing(Vector3.new(0, 10, 10), Vector3.new(0, 0, 1))
		s.heartbeat:Fire(1)
		expect.equal(#s.remote.Sent, 3, "stopped")
	end,

	["Receive keeps the latest rotation per player and Eye places it at the head"] = function(expect)
		local watcher =
			SenseFakes.Character("Watcher", Vector3.new(5, 0, 5), Vector3.new(0, 0, -1), Vector3.new(0, 0, -1))
		local player = { Name = "Player" }
		local s = setup({ characters = { [watcher.Model] = player } })
		local receiver = s.Look.Receive(s.remote, { Timeout = 2 })

		expect.equal(receiver:EyeOf(watcher.Root), nil, "nothing reported yet")
		expect.equal(receiver.Eye(watcher.Root), nil)

		local cameraAt = SenseFakes.Facing(Vector3.new(0, 20, 30), Vector3.new(1, 0, 0))
		s.remote.OnServerEvent:Fire(player, cameraAt)
		local eye = receiver.Eye(watcher.Root)
		expect.truthy(eye ~= nil)
		expect.equal((eye :: any).Position, watcher.Head.Position, "at the head, not the camera")
		expect.near((eye :: any).LookVector.X, 1, 1e-4, "looking where the camera looks")

		s.remote.OnServerEvent:Fire(player, "not a cframe")
		expect.near((receiver.Eye(watcher.Root) :: any).LookVector.X, 1, 1e-4, "junk ignored")

		s.clock:Advance(2.5)
		expect.equal(receiver.Eye(watcher.Root), nil, "stale after Timeout")

		s.remote.OnServerEvent:Fire(player, cameraAt)
		s.playerRemoving:Fire(player)
		expect.equal(receiver:GetRotation(player), nil, "forgotten on leave")

		local stranger = SenseFakes.Character("Stranger", Vector3.new(0, 0, 0))
		expect.equal(receiver.Eye(stranger.Root), nil, "a root with no player")

		receiver:Destroy()
		s.remote.OnServerEvent:Fire(player, cameraAt)
		expect.equal(receiver:GetRotation(player), nil, "disconnected")
	end,
}
