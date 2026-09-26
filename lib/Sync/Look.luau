--!strict

--[[
	Where each player is really looking. A default rig's head turns with its body, so the Watched
	sense judges "looking" by the walk direction unless the game replicates the camera. This is
	that replication, in two halves over one RemoteEvent the game owns: Report runs on the client
	and sends the camera's rotation a few times a second when it changed; Receive runs on the
	server, keeps the latest per player, and offers `Eye`, which is exactly what Watched and
	Perception.SeenByAnyone take.

	The one decision worth knowing: the server puts the camera's rotation at the character's
	head, not at the camera's own position. In third person the camera floats behind and above
	the player, and a monster the camera can see over a wall is one the player cannot.
]]

local Cleaner = require(script.Parent.Parent.Utility.Cleaner)
local Options = require(script.Parent.Parent.Utility.Options)
local Perception = require(script.Parent.Parent.Senses.Perception)

------------------------------------------------------------------------------------------------------------------------

local REPORT_DEFAULTS = table.freeze({
	Rate = 10,
	MinAngle = 0.02,
})

--[=[
	@interface LookReportOptions
	@within Look

	.Rate number? -- Sends per second, at most. Default `10`.
	.MinAngle number? -- Radians the look direction must turn before a send. Default `0.02`.
]=]
export type LookReportOptions = {
	Rate: number?,
	MinAngle: number?,
}

local RECEIVE_DEFAULTS = table.freeze({
	Timeout = 2,
})

--[=[
	@interface LookReceiveOptions
	@within Look

	.Timeout number? -- Seconds after which a player's last report no longer counts. Default `2`.
]=]
export type LookReceiveOptions = {
	Timeout: number?,
}

type Entry = { Rotation: CFrame, At: number }

type self = {
	_looks: { [Player]: Entry },
	_timeout: number,
	_cleaner: Cleaner.Cleaner,
}

local LookReceiver = {}
LookReceiver.__index = LookReceiver

export type LookReceiver = typeof(setmetatable({} :: self, LookReceiver))

local Look = {}

--[=[
	@class Look

	Camera-direction replication for the senses that care where a player is looking. Exposed as
	`VluxyAI.Sync.Look`. The game makes one `RemoteEvent`; the client calls [Look.Report] with
	it, the server calls [Look.Receive] and hands the receiver's `Eye` to [Watched] or
	[Perception.SeenByAnyone].

	```lua
	-- client
	VluxyAI.Sync.Look.Report(ReplicatedStorage.Remotes.Look)

	-- server
	local looks = VluxyAI.Sync.Look.Receive(ReplicatedStorage.Remotes.Look)
	:AddSense(VluxyAI.Senses.Watched.new({ Eye = looks.Eye }))
	```

	A player who has not reported, or whose last report is older than `Timeout`, falls back to
	whatever the caller does without an eye: the head's facing for Watched.
]=]

--[=[
	@within Look
	@param remote RemoteEvent -- Fired with the camera's `CFrame`.
	@param options LookReportOptions?
	@return Cleaner -- Destroy it to stop reporting.

	Client side. Watches `workspace.CurrentCamera` on Heartbeat and fires `remote` at most
	`Rate` times a second, and only when the look direction turned by more than `MinAngle`.
]=]
function Look.Report(remote: RemoteEvent, options: LookReportOptions?): Cleaner.Cleaner
	local resolved = Options.Resolve("Look.Report", REPORT_DEFAULTS, options :: any)
	local RunService = game:GetService("RunService")

	local cleaner = Cleaner.new()
	local interval = 1 / resolved.Rate
	local sinceSend = interval
	local lastLook: Vector3? = nil
	local cosThreshold = math.cos(resolved.MinAngle)

	cleaner:Connect(RunService.Heartbeat, function(deltaTime: number)
		sinceSend += deltaTime
		if sinceSend < interval then
			return
		end

		local camera = workspace.CurrentCamera
		if camera == nil then
			return
		end

		local cframe = camera.CFrame
		local look = cframe.LookVector
		if lastLook ~= nil and lastLook:Dot(look) >= cosThreshold then
			return
		end

		sinceSend = 0
		lastLook = look
		remote:FireServer(cframe)
	end)

	return cleaner
end

--[=[
	@within Look
	@param remote RemoteEvent
	@param options LookReceiveOptions?
	@return LookReceiver

	Server side. Keeps the latest camera rotation per player and forgets a player who leaves.
]=]
function Look.Receive(remote: RemoteEvent, options: LookReceiveOptions?): LookReceiver
	local resolved = Options.Resolve("Look.Receive", RECEIVE_DEFAULTS, options :: any)
	local Players = game:GetService("Players")

	local cleaner = Cleaner.new()
	local self: self = {
		_looks = {},
		_timeout = resolved.Timeout,
		_cleaner = cleaner,
	}
	local receiver = setmetatable(self, LookReceiver)

	cleaner:Connect(remote.OnServerEvent, function(player: Player, cframe: any)
		if typeof(cframe) ~= "CFrame" then
			return
		end
		self._looks[player] = { Rotation = cframe - cframe.Position, At = os.clock() }
	end)

	cleaner:Connect(Players.PlayerRemoving, function(player: Player)
		self._looks[player] = nil
	end); -- Eye is a plain function, so it can be handed to an option as it is.
	(receiver :: any).Eye = function(root: BasePart): CFrame?
		return receiver:EyeOf(root)
	end

	return receiver
end

--[=[
	@class LookReceiver

	What [Look.Receive] returns: the latest camera rotation per player, and `Eye`, the function
	[Watched] and [Perception.SeenByAnyone] take.
]=]

--[=[
	@within LookReceiver
	@param player Player
	@return CFrame? -- The rotation of the player's last report, or `nil` when there is none or it is older than `Timeout`.
]=]
function LookReceiver.GetRotation(self: LookReceiver, player: Player): CFrame?
	local entry = self._looks[player]
	if entry == nil or os.clock() - entry.At > self._timeout then
		return nil
	end
	return entry.Rotation
end

--[=[
	@within LookReceiver
	@param root BasePart -- A player's root, as a sense hands it out.
	@return CFrame? -- The player's camera rotation placed at their head, or `nil` without a fresh report.

	What [Watched] and [Perception.SeenByAnyone] take as `Eye`. Also available as the plain
	function `receiver.Eye`.
]=]
function LookReceiver.EyeOf(self: LookReceiver, root: BasePart): CFrame?
	local Players = game:GetService("Players")

	local character = Perception.CharacterOf(root)
	local player = if character then Players:GetPlayerFromCharacter(character) else nil
	if player == nil then
		return nil
	end

	local rotation = self:GetRotation(player)
	if rotation == nil then
		return nil
	end

	local head = Perception.EyeOf(root)
	return CFrame.new(head.Position) * rotation
end

--[=[
	@within LookReceiver

	Disconnects from the remote and forgets every report.
]=]
function LookReceiver.Destroy(self: LookReceiver)
	self._cleaner:Destroy()
	table.clear(self._looks)
end

Look.Receiver = LookReceiver

return Look
