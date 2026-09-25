--!strict

--[[
	Test doubles for the package's contracts. Each records what was done to it so a spec asserts
	on behaviour rather than on state the real thing would hide. The signals are the package's own
	Signal, loaded through the harness, so a fake mover fires exactly what a real one would.
]]

local Harness = require("./Harness")

local roblox = require("@lune/roblox")
local Vector3 = roblox.Vector3
local CFrame = roblox.CFrame

local Fakes = {}

--[[
	Fresh Signal class for each call, so fakes never share module state with the subject.
]]
function Fakes.Signal(): any
	return Harness.Load("lib/Utility/Signal.luau")
end

--[[
	A stand-in Model with a PrimaryPart and a pivot.
]]
function Fakes.Entity(name: string?, position: any?)
	local pivot = CFrame.new(position or Vector3.new(0, 0, 0))

	return {
		Name = name or "Rig",
		PrimaryPart = { Name = "HumanoidRootPart" },
		GetPivot = function()
			return pivot
		end,
		GetFullName = function()
			return `Workspace.{name or "Rig"}`
		end,
	}
end

--[[
	A pathfinder that returns whatever `plan` returns and records every call.
]]
function Fakes.Pathfinder(plan: ((from: any, to: any, agent: any) -> (any, string?))?)
	local pathfinder = {
		Calls = {} :: { { From: any, To: any } },
		Destroyed = false,
	}

	function pathfinder.FindPath(self, from, to, agent)
		table.insert(self.Calls, { From = from, To = to })
		if plan then
			return plan(from, to, agent)
		end
		return { { Position = from, Action = "Walk" }, { Position = to, Action = "Walk" } }, nil
	end

	function pathfinder.Destroy(self)
		self.Destroyed = true
	end

	return pathfinder
end

--[[
	A mover that records Follow and Stop, and lets the spec move it and fire its signals.
]]
function Fakes.Mover(position: any?)
	local Signal = Fakes.Signal()

	local mover = {
		Position = position or Vector3.new(0, 0, 0),
		Speed = 8,
		Followed = {} :: { any },
		Stops = 0,
		Moving = false,
		Destroyed = false,
		StepReached = Signal.new(),
		Arrived = Signal.new(),
	}

	function mover.Follow(self, path)
		table.insert(self.Followed, path)
		self.Moving = true
	end

	function mover.Stop(self)
		self.Stops += 1
		if self.Moving then
			self.Moving = false
			self.Arrived:Fire(false)
		end
	end

	function mover.GetPosition(self)
		return self.Position
	end

	function mover.GetSpeed(self)
		return self.Speed
	end

	function mover.SetSpeed(self, speed)
		self.Speed = speed
	end

	function mover.IsMoving(self)
		return self.Moving
	end

	function mover.Destroy(self)
		self.Destroyed = true
	end

	--[[
		The spec says the mover got to the end of its path (or gave up).
	]]
	function mover.Finish(self, reached: boolean)
		self.Moving = false
		self.Arrived:Fire(reached)
	end

	return mover
end

--[[
	A sense that appends its name to a shared log each tick.
]]
function Fakes.Sense(name: string, log: { string })
	local sense = { Destroyed = false }

	function sense.Tick(_self, _agent, _deltaTime)
		table.insert(log, name)
	end

	function sense.Destroy(self)
		self.Destroyed = true
	end

	return sense
end

--[[
	A brain whose states log Enter, Update and Exit to a shared list. `updates` maps a state name
	to what its Update returns.
]]
function Fakes.Brain(initial: string, names: { string }, log: { string }, updates: { [string]: () -> string? }?)
	local states = {}

	for _, name in names do
		states[name] = {
			Enter = function()
				table.insert(log, `enter {name}`)
			end,
			Update = function()
				table.insert(log, `update {name}`)
				local decide = updates and updates[name]
				if decide then
					return decide()
				end
				return nil
			end,
			Exit = function()
				table.insert(log, `exit {name}`)
			end,
		}
	end

	return { Initial = initial, States = states }
end

--[[
	A minimal agent for modules that only need a name and a blackboard.
]]
function Fakes.Agent(blackboard: { [string]: any }?)
	return {
		Name = "Fake",
		Blackboard = blackboard or {},
		Data = {},
	}
end

return Fakes
