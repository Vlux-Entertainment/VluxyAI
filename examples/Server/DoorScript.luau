--!strict

--[[
	The playground's door script: what a game's own door code looks like to VluxyAI. A door
	swings on its hinge, away from whoever opened it, and a prompt lets a player open or close it.
	Enemies open it through the `AI_DOOR/Open` attribute that `VluxyAI.Doors` sets, so neither
	side knows about the other.

	The one decision: doors never collide with enemies. VluxyAI.Collision puts the rigs and the
	doors in groups that pass through each other, and the navmesh modifier on the door is the only thing
	that says whether an enemy may go through: PassThrough while unlocked, solid while locked. An
	enemy therefore cannot get stuck on a door, even one that is closing on it; opening the door
	is for show and for the players. A locked door goes back to the default group and is solid to
	everyone.

	A door an enemy forced open closes itself after a few seconds, unless a player is in the way;
	a door a player opened stays open until someone closes it.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local SWING_ANGLE = math.rad(95)
local SWING_TIME = 0.4
local AUTO_CLOSE_SECONDS = 4 -- after an enemy forced it open
local RETRY_SECONDS = 1 -- how long an auto-close waits while a player stands in the doorway
local OPENER_SEARCH = 10 -- studs around the door to find who opened it

-- Free Creator Store audio, checked to load in Studio. Played on the server, so everyone hears it.
local OPEN_SOUND = "rbxassetid://125209584906878" -- a creak, about a second
local CLOSE_SOUND = "rbxassetid://75935302971787" -- a wooden thud, about a second

local VluxyAI = require(ReplicatedStorage.Packages.VluxyAI)

local DoorScript = {}

--[[
	The nearest character root around the door, which is taken to be whoever opened it.
]]
local function nearestRoot(door: BasePart): BasePart?
	local best: BasePart? = nil
	local bestDistance = math.huge
	for _, part in Workspace:GetPartBoundsInRadius(door.Position, OPENER_SEARCH) do
		if part.Name == "HumanoidRootPart" then
			local distance = (part.Position - door.Position).Magnitude
			if distance < bestDistance then
				best = part
				bestDistance = distance
			end
		end
	end
	return best
end

--[[
	Is a player standing where the door would swing shut?
]]
local function playerInDoorway(door: BasePart, closed: CFrame): boolean
	local reach = math.max(door.Size.X, door.Size.Z)
	for _, part in Workspace:GetPartBoundsInBox(closed, Vector3.new(reach, door.Size.Y, reach), OverlapParams.new()) do
		local model = part:FindFirstAncestorOfClass("Model")
		if model and Players:GetPlayerFromCharacter(model) then
			return true
		end
	end
	return false
end

--[[
	Makes `door` a working door. `onPlayerOpened` is called when a player opens it, so the
	playground can make that a noise; an enemy opening a door would otherwise hear itself.
]]
function DoorScript.Watch(door: BasePart, onPlayerOpened: (door: BasePart) -> ())
	local closed = door.CFrame
	local modifier = door:FindFirstChildOfClass("PathfindingModifier")

	-- The hinge is one end of the door's long side; `across` is the way through the doorway.
	local alongLocal = if door.Size.X >= door.Size.Z then Vector3.xAxis else Vector3.zAxis
	local acrossLocal = if alongLocal == Vector3.xAxis then Vector3.zAxis else Vector3.xAxis
	local halfWidth = math.max(door.Size.X, door.Size.Z) / 2
	local hinge = closed:PointToWorldSpace(-alongLocal * halfWidth)
	local along = closed:VectorToWorldSpace(alongLocal)
	local across = closed:VectorToWorldSpace(acrossLocal)

	local openedByPlayer = false
	local opened = 0

	local function sound(id: string, name: string): Sound
		local created = Instance.new("Sound")
		created.Name = name
		created.SoundId = id
		created.Volume = 0.56
		created.RollOffMode = Enum.RollOffMode.InverseTapered
		created.RollOffMinDistance = 6
		created.RollOffMaxDistance = 70
		created.Parent = door
		return created
	end
	local openSound = sound(OPEN_SOUND, "OpenSound")
	local closeSound = sound(CLOSE_SOUND, "CloseSound")

	local prompt = Instance.new("ProximityPrompt")
	prompt.MaxActivationDistance = 8
	prompt.RequiresLineOfSight = false
	prompt.Parent = door

	--[[
		The CFrame of the door swung away from `from`, or a default way when nobody is found.
	]]
	local function openCFrame(from: Vector3?): CFrame
		local side = if from then math.sign((from - closed.Position):Dot(across)) else 1
		-- A positive turn about Y moves the free end toward yAxis:Cross(along).
		local up = Vector3.new(0, 1, 0)
		local towards = up:Cross(along)
		local sign = if towards:Dot(across * -(if side == 0 then 1 else side)) > 0 then 1 else -1
		return CFrame.new(hinge) * CFrame.Angles(0, sign * SWING_ANGLE, 0) * CFrame.new(-hinge) * closed
	end

	local function swing(target: CFrame)
		TweenService:Create(door, TweenInfo.new(SWING_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			CFrame = target,
		}):Play()
	end

	local function refresh()
		local locked = door:GetAttribute("AI_DOOR/Locked") == true
		local isOpen = door:GetAttribute("AI_DOOR/Open") == true
		prompt.ObjectText = if locked then "Locked" else "Door"
		prompt.ActionText = if isOpen then "Close" else "Open"
		-- Enemies walk through it unless it is locked; players always collide with it.
		VluxyAI.Collision.LetRigsThrough(door, not locked)
		if modifier then
			modifier.PassThrough = not locked
		end
	end

	local function autoClose(token: number)
		while opened == token and not openedByPlayer and playerInDoorway(door, closed) do
			task.wait(RETRY_SECONDS)
		end
		if opened == token and not openedByPlayer then
			door:SetAttribute("AI_DOOR/Open", false)
		end
	end

	prompt.Triggered:Connect(function(player: Player)
		if door:GetAttribute("AI_DOOR/Locked") == true then
			return
		end
		if door:GetAttribute("AI_DOOR/Open") == true then
			door:SetAttribute("AI_DOOR/Open", false)
			return
		end
		openedByPlayer = true
		local character = player.Character
		local root = if character then character:FindFirstChild("HumanoidRootPart") :: BasePart? else nil
		swing(openCFrame(if root then root.Position else nil))
		door:SetAttribute("AI_DOOR/Open", true)
		onPlayerOpened(door)
	end)

	door:GetAttributeChangedSignal("AI_DOOR/Open"):Connect(function()
		refresh()
		if door:GetAttribute("AI_DOOR/Open") == true then
			openSound:Play()
			opened += 1
			if not openedByPlayer then
				-- An enemy forced it: swing away from it, and close again on our own.
				local root = nearestRoot(door)
				swing(openCFrame(if root then root.Position else nil))
				task.delay(AUTO_CLOSE_SECONDS, autoClose, opened)
			end
		else
			opened += 1
			openedByPlayer = false
			swing(closed)
			-- The thud lands as the swing ends.
			task.delay(SWING_TIME * 0.8, function()
				closeSound:Play()
			end)
		end
	end)

	door:GetAttributeChangedSignal("AI_DOOR/Locked"):Connect(function()
		if door:GetAttribute("AI_DOOR/Locked") == true and door:GetAttribute("AI_DOOR/Open") == true then
			door:SetAttribute("AI_DOOR/Open", false)
		end
		refresh()
	end)

	refresh()
end

return DoorScript
