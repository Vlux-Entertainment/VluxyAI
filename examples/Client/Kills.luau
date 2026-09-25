--!strict

--[[
	How the client presents a kill, for the two kinds the package announces. Only the local
	player's own death gets the full treatment; someone else's is left to the world (a live kill
	is visible anyway, a black-box one just happens).

	Live: a red flash, and the camera locked on the victim for the hold, so you watch it happen.
	Black box: an immediate cut to black for the announced duration, a beat longer than the
	death so the respawn happens behind it.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local VluxyAI = require(ReplicatedStorage.Packages.VluxyAI)

local Kills = {}

local function screen(name: string, color: Color3, transparency: number): (ScreenGui, Frame)
	local gui = Instance.new("ScreenGui")
	gui.Name = name
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 100
	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = color
	frame.BackgroundTransparency = transparency
	frame.BorderSizePixel = 0
	frame.Parent = gui
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	return gui, frame
end

local function isMe(victim: Model): boolean
	return Players.LocalPlayer.Character == victim
end

--[[
	Presents a Kill event from an enemy's replica.
]]
function Kills.Present(replica: VluxyAI.Replica, event: VluxyAI.KillEvent)
	if not isMe(event.Victim) then
		return
	end

	if event.Kind == "BlackBox" then
		local gui = screen("BlackBox", Color3.new(0, 0, 0), 0)
		task.delay(event.Duration + 1.5, function()
			gui:Destroy()
		end)
		return
	end

	-- Live: a flash, then the camera holds on the scene until the victim dies.
	local gui, frame = screen("KillFlash", Color3.new(0.6, 0, 0), 0.3)
	TweenService:Create(frame, TweenInfo.new(event.Duration), { BackgroundTransparency = 1 }):Play()
	task.delay(event.Duration, function()
		gui:Destroy()
	end)

	local camera = workspace.CurrentCamera
	local previousType = camera.CameraType
	camera.CameraType = Enum.CameraType.Watch
	camera.CameraSubject = replica.Entity:FindFirstChildOfClass("Humanoid") or camera.CameraSubject
	task.delay(event.Duration + 0.5, function()
		camera.CameraType = previousType
	end)
end

return Kills
