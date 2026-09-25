--!strict

--[[
	What each enemy looks like from the client's side, keyed by enemy name: a table of client
	states in the same Enter, Update, Exit shape as a brain, with the replica in place of the
	agent. This is the custom client logic hook: anything an enemy needs to do on your screen
	lives here, and the server never knows.

	These are deliberately simple: a Highlight while an enemy is hunting, a shout bubble while the
	Guardian raises the alarm, a creeping vignette while the Watcher advances unseen.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local VluxyAI = require(ReplicatedStorage.Packages.VluxyAI)

local Visuals = {}

--[[
	A Highlight on the rig, made once and kept in the replica's Data.
]]
local function highlight(replica: VluxyAI.Replica, color: Color3): Highlight
	local existing = replica.Data.Highlight :: Highlight?
	if existing then
		existing.FillColor = color
		existing.OutlineColor = color
		return existing
	end

	local created = Instance.new("Highlight")
	created.FillColor = color
	created.OutlineColor = color
	created.FillTransparency = 0.6
	created.Enabled = false
	created.Parent = replica.Entity
	replica.Data.Highlight = created
	return created
end

local function glowWhile(color: Color3): VluxyAI.ClientState
	return {
		Enter = function(replica: VluxyAI.Replica)
			highlight(replica, color).Enabled = true
		end,
		Exit = function(replica: VluxyAI.Replica)
			highlight(replica, color).Enabled = false
		end,
	}
end

--[[
	A screen-space vignette for the Watcher: the closer it gets while you are not looking, the
	darker the edges. Update runs every frame, so it tracks distance.
]]
local function vignetteState(): VluxyAI.ClientState
	return {
		Enter = function(replica: VluxyAI.Replica)
			local Players = game:GetService("Players")
			local gui = Instance.new("ScreenGui")
			gui.Name = "WatcherVignette"
			gui.IgnoreGuiInset = true
			gui.ResetOnSpawn = false
			local frame = Instance.new("Frame")
			frame.Size = UDim2.fromScale(1, 1)
			frame.BackgroundColor3 = Color3.new(0.1, 0, 0)
			frame.BackgroundTransparency = 1
			frame.BorderSizePixel = 0
			frame.Parent = gui
			gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
			replica.Data.Vignette = frame
			replica.Data.VignetteGui = gui
		end,
		Update = function(replica: VluxyAI.Replica)
			local Players = game:GetService("Players")
			local character = Players.LocalPlayer.Character
			local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
			local frame = replica.Data.Vignette :: Frame?
			if not root or not frame then
				return
			end
			local distance = (replica.Entity:GetPivot().Position - root.Position).Magnitude
			frame.BackgroundTransparency = math.clamp(0.4 + distance / 60, 0.4, 1)
		end,
		Exit = function(replica: VluxyAI.Replica)
			local gui = replica.Data.VignetteGui :: ScreenGui?
			if gui then
				gui:Destroy()
			end
			replica.Data.Vignette = nil
			replica.Data.VignetteGui = nil
		end,
	}
end

Visuals.Stalker = {
	Hunt = glowWhile(Color3.fromRGB(255, 60, 60)),
	Search = glowWhile(Color3.fromRGB(255, 160, 60)),
} :: VluxyAI.Visuals

Visuals.Hunter = {
	Hunt = glowWhile(Color3.fromRGB(255, 140, 0)),
	Rest = glowWhile(Color3.fromRGB(120, 120, 120)),
} :: VluxyAI.Visuals

Visuals.Guardian = {
	Alert = {
		Enter = function(replica: VluxyAI.Replica)
			local billboard = Instance.new("BillboardGui")
			billboard.Size = UDim2.fromOffset(120, 40)
			billboard.StudsOffsetWorldSpace = Vector3.new(0, 5, 0)
			billboard.AlwaysOnTop = true
			local label = Instance.new("TextLabel")
			label.Size = UDim2.fromScale(1, 1)
			label.BackgroundTransparency = 1
			label.TextScaled = true
			label.Font = Enum.Font.GothamBold
			label.TextColor3 = Color3.fromRGB(255, 230, 80)
			label.Text = "INTRUDER!"
			label.Parent = billboard
			billboard.Parent = replica.Entity
			replica.Data.Shout = billboard
		end,
		Exit = function(replica: VluxyAI.Replica)
			local shout = replica.Data.Shout :: BillboardGui?
			if shout then
				shout:Destroy()
			end
			replica.Data.Shout = nil
		end,
	},
	Chase = glowWhile(Color3.fromRGB(80, 160, 255)),
} :: VluxyAI.Visuals

Visuals.Watcher = {
	Advance = vignetteState(),
} :: VluxyAI.Visuals

return Visuals
