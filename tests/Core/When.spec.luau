--!strict

--[[
	The When predicates against a small fake agent: each builder reads what it says it reads,
	New acknowledges as it fires, and the combinators short-circuit.
]]

local Harness = require("../Support/Harness")

local function load()
	return Harness.Load("lib/Brain/When.luau")
end

--[[
	An agent with a blackboard, timers, a path status and the acknowledge pair, all set by hand.
]]
local function agent(blackboard: { [string]: any }?)
	local self = {
		Blackboard = blackboard or {},
		Data = {},
		Timers = {} :: { [string]: boolean },
		Status = "Idle",
		Acknowledged = {} :: { [string]: any },
		StateTime = 0,
	}
	function self.TimerDone(this, name: string): boolean
		return this.Timers[name] ~= false
	end
	function self.GetPathStatus(this): string
		return this.Status
	end
	function self.IsNew(this, key: string): boolean
		local value = this.Blackboard[key]
		return value ~= nil and value ~= this.Acknowledged[key]
	end
	function self.Acknowledge(this, key: string)
		this.Acknowledged[key] = this.Blackboard[key]
	end
	function self.TimeInState(this): number
		return this.StateTime
	end
	return self
end

return {
	["Has, Missing and Equals read the blackboard"] = function(expect)
		local When = load()
		local a = agent({ SeenTarget = "root", Mode = "Calm" })

		expect.truthy(When.Has("SeenTarget")(a))
		expect.falsy(When.Has("HeardAt")(a))
		expect.falsy(When.Missing("SeenTarget")(a))
		expect.truthy(When.Missing("HeardAt")(a))
		expect.truthy(When.Equals("Mode", "Calm")(a))
		expect.falsy(When.Equals("Mode", "Alert")(a))
	end,

	["Below and Above compare numbers and treat a missing key as neither"] = function(expect)
		local When = load()
		local a = agent({ SeenDistance = 3, Far = math.huge })

		expect.truthy(When.Below("SeenDistance", 4)(a))
		expect.falsy(When.Below("SeenDistance", 3)(a), "not strictly below")
		expect.truthy(When.Above("SeenDistance", 2)(a))
		expect.falsy(When.Below("Far", 100)(a), "math.huge is not below")
		expect.falsy(When.Below("Nothing", 100)(a))
		expect.falsy(When.Above("Nothing", 0)(a))
	end,

	["New fires once per value and acknowledges as it does"] = function(expect)
		local When = load()
		local a = agent({})
		local new = When.New("HeardAt")

		expect.falsy(new(a), "nothing heard")
		a.Blackboard.HeardAt = 10
		expect.truthy(new(a), "first sight of the value")
		expect.falsy(new(a), "acknowledged")
		expect.equal(a.Acknowledged.HeardAt, 10)
		a.Blackboard.HeardAt = 12
		expect.truthy(new(a), "a newer value")
		a.Blackboard.HeardAt = nil
		expect.falsy(new(a), "forgotten")
	end,

	["Timer, InStateFor and the path predicates ask the agent"] = function(expect)
		local When = load()
		local a = agent()

		expect.truthy(When.Timer("Search")(a), "never started counts as done")
		a.Timers.Search = false
		expect.falsy(When.Timer("Search")(a))

		a.StateTime = 2
		expect.truthy(When.InStateFor(2)(a))
		expect.falsy(When.InStateFor(2.5)(a))

		a.Status = "Moving"
		expect.falsy(When.PathDone(a))
		expect.falsy(When.Arrived(a))
		expect.falsy(When.PathFailed(a))
		a.Status = "Arrived"
		expect.truthy(When.PathDone(a))
		expect.truthy(When.Arrived(a))
		a.Status = "Failed"
		expect.truthy(When.PathDone(a))
		expect.truthy(When.PathFailed(a))
		expect.falsy(When.Arrived(a))
	end,

	["All, Any and Not combine and short-circuit"] = function(expect)
		local When = load()
		local a = agent({ A = true })
		local calls = 0
		local function counted(result: boolean)
			return function()
				calls += 1
				return result
			end
		end

		expect.truthy(When.All(When.Has("A"), counted(true))(a))
		expect.falsy(When.All(When.Missing("A"), counted(true))(a))
		expect.equal(calls, 1, "All stopped at the first false")

		calls = 0
		expect.truthy(When.Any(When.Has("A"), counted(true))(a))
		expect.equal(calls, 0, "Any stopped at the first true")
		expect.falsy(When.Any(When.Missing("A"), counted(false))(a))
		expect.equal(calls, 1)

		expect.truthy(When.Not(When.Missing("A"))(a))
		expect.falsy(When.Not(When.Has("A"))(a))
	end,
}
