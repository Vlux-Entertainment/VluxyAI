--!strict

--[[
	The client half of the playground. One Replica per enemy rig, in mirror mode: the rig is the
	server's own and replicates by itself, so this only runs the visuals and presents kills. The
	messages come over the VluxyAISync RemoteEvent the server made, in the shape Playground
	sends: Snapshot, State and Event, each carrying the rig as its Id.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Kills = require(script.Parent.Kills)
local Visuals = require(script.Parent.Visuals)
local VluxyAI = require(ReplicatedStorage.Packages.VluxyAI)

local sync = ReplicatedStorage:WaitForChild("VluxyAISync") :: RemoteEvent

local replicas: { [Model]: VluxyAI.Replica } = {}

--[[
	The replica for a rig, made on first sight with that enemy's visuals.
]]
local function replicaFor(model: Model, name: string): VluxyAI.Replica
	local existing = replicas[model]
	if existing then
		return existing
	end

	local replica = VluxyAI.Sync.Replica.new({
		Entity = model,
		Visuals = (Visuals :: any)[name],
	})
	replica:On("Kill", function(payload)
		Kills.Present(replica, payload)
	end)
	replica:On("KillCancelled", function(payload)
		Kills.Cancel(payload)
	end)
	replicas[model] = replica

	model.Destroying:Once(function()
		replica:Destroy()
		replicas[model] = nil
	end)

	return replica
end

sync.OnClientEvent:Connect(function(message: any)
	local model = message.Id :: Model?
	if model == nil then
		return
	end

	local replica = replicaFor(model, message.Name)

	if message.Kind == "Snapshot" then
		replica:ApplySnapshot(message.Snapshot)
	elseif message.Kind == "State" then
		replica:SetState(message.State)
	elseif message.Kind == "Position" then
		replica:SetPosition(message.Position, message.Yaw)
	elseif message.Kind == "Event" then
		replica:Receive(message.Event, message.Payload)
	end
end)
