--!strict

--[[
	Hold Shift to sprint, for play-testing the enemies against a player who can run. Walk is
	Roblox's default 16, a sprint is 24, and stamina lasts SPRINT_TIME seconds and refills after a
	short rest, so running away works once and then has to be earned again. A bar at the bottom of
	the screen shows what is left.

	The one decision: the server is never told about sprinting. The character is owned by the
	client, so WalkSpeed set here moves it, and the playground hears a sprint by measuring how fast
	the root actually goes. There is no remote to spoof and nothing to keep in sync.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local WALK_SPEED = 16
local SPRINT_SPEED = 24
local SPRINT_TIME = 5 -- seconds of sprint from a full bar
local REFILL_TIME = 6 -- seconds from empty to full
local REFILL_DELAY = 1 -- seconds after letting go before the bar starts to refill
local MIN_TO_START = 0.2 -- a nearly empty bar cannot start a sprint, so tapping Shift does not stutter

local player = Players.LocalPlayer

local stamina = 1
local wantsSprint = false
local sprinting = false
local restingSince = 0

------------------------------------------------------------------------------------------------------------------------

local gui = Instance.new("ScreenGui")
gui.Name = "Sprint"
gui.ResetOnSpawn = false

local back = Instance.new("Frame")
back.AnchorPoint = Vector2.new(0.5, 1)
back.Position = UDim2.new(0.5, 0, 1, -24)
back.Size = UDim2.fromOffset(220, 8)
back.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
back.BackgroundTransparency = 0.3
back.BorderSizePixel = 0
back.Parent = gui

local fill = Instance.new("Frame")
fill.Size = UDim2.fromScale(1, 1)
fill.BackgroundColor3 = Color3.fromRGB(235, 235, 235)
fill.BorderSizePixel = 0
fill.Parent = back

gui.Parent = player:WaitForChild("PlayerGui")

------------------------------------------------------------------------------------------------------------------------

ContextActionService:BindAction("Sprint", function(_, inputState)
	wantsSprint = inputState == Enum.UserInputState.Begin
	return Enum.ContextActionResult.Pass
end, true, Enum.KeyCode.LeftShift, Enum.KeyCode.RightShift, Enum.KeyCode.ButtonL3)
ContextActionService:SetTitle("Sprint", "Run")

RunService.Heartbeat:Connect(function(deltaTime: number)
	local character = player.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	if humanoid == nil or humanoid.Health <= 0 then
		stamina = 1
		sprinting = false
		return
	end

	local moving = humanoid.MoveDirection.Magnitude > 0.1
	if wantsSprint and moving and (sprinting or stamina >= MIN_TO_START) and stamina > 0 then
		sprinting = true
		stamina = math.max(stamina - deltaTime / SPRINT_TIME, 0)
		restingSince = os.clock()
	else
		sprinting = false
		if os.clock() - restingSince >= REFILL_DELAY then
			stamina = math.min(stamina + deltaTime / REFILL_TIME, 1)
		end
	end

	humanoid.WalkSpeed = if sprinting then SPRINT_SPEED else WALK_SPEED
	fill.Size = UDim2.fromScale(stamina, 1)
	fill.BackgroundColor3 = if stamina < MIN_TO_START
		then Color3.fromRGB(220, 70, 70)
		else Color3.fromRGB(235, 235, 235)
	back.Visible = stamina < 1
end)
