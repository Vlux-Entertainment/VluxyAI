--!strict

--[[
	Claims: one holder per thing, release by the holder only, release on the holder's death, and
	the consideration for utility scoring.
]]

local Fakes = require("../Support/Fakes")
local Harness = require("../Support/Harness")

local function load()
	return Harness.Load("lib/Utility/Claims.luau")
end

--[[
	An agent with a Destroyed signal and IsDestroyed, the two things Claims asks of one.
]]
local function agent(name: string)
	local Signal = Fakes.Signal()
	local self = { Name = name, Destroyed = Signal.new(), Dead = false }
	function self.IsDestroyed(this)
		return this.Dead
	end
	function self.Destroy(this)
		this.Dead = true
		this.Destroyed:Fire()
	end
	return self
end

return {
	["a free thing can be claimed; a held one only by its holder"] = function(expect)
		local Claims = load()
		local claims = Claims.new()
		local a, b = agent("A"), agent("B")
		local root = { Name = "Root" }

		expect.equal(claims:ClaimedBy(root), nil)
		expect.truthy(claims:IsFree(root))
		expect.truthy(claims:Claim(root, a))
		expect.equal(claims:ClaimedBy(root), a)
		expect.truthy(claims:Claim(root, a), "claiming again is fine")
		expect.falsy(claims:Claim(root, b), "held by A")
		expect.truthy(claims:IsFree(root, a), "free for its holder")
		expect.falsy(claims:IsFree(root, b))
		expect.falsy(claims:IsFree(root))
	end,

	["only the holder releases, and ReleaseAll drops everything of one agent"] = function(expect)
		local Claims = load()
		local claims = Claims.new()
		local a, b = agent("A"), agent("B")
		local one, two, three = {}, {}, {}

		claims:Claim(one, a)
		claims:Claim(two, a)
		claims:Claim(three, b)
		claims:Release(one, b)
		expect.equal(claims:ClaimedBy(one), a, "B cannot release A's claim")
		claims:Release(one, a)
		expect.equal(claims:ClaimedBy(one), nil)

		expect.equal(#claims:Owned(a), 1)
		claims:ReleaseAll(a)
		expect.equal(#claims:Owned(a), 0)
		expect.equal(claims:ClaimedBy(three), b, "B keeps its own")
	end,

	["a destroyed holder's claims go with it"] = function(expect)
		local Claims = load()
		local claims = Claims.new()
		local a, b = agent("A"), agent("B")
		local root = {}

		claims:Claim(root, a)
		a:Destroy()
		expect.equal(claims:ClaimedBy(root), nil)
		expect.truthy(claims:Claim(root, b))

		local quiet = {
			Name = "Quiet",
			IsDestroyed = function(this)
				return this.Dead == true
			end,
		}
		local spot = {}
		claims:Claim(spot, quiet :: any)
		quiet.Dead = true
		expect.equal(claims:ClaimedBy(spot), nil, "a dead agent without a signal is checked on read")
	end,

	["Consideration scores free and own candidates 1 and taken ones the given score"] = function(expect)
		local Claims = load()
		local claims = Claims.new()
		local a, b = agent("A"), agent("B")
		local mine, theirs, free = {}, {}, {}
		claims:Claim(mine, a)
		claims:Claim(theirs, b)

		local consideration = claims:Consideration(0.25)
		expect.equal(consideration.Input(a, mine), 1)
		expect.equal(consideration.Input(a, free), 1)
		expect.equal(consideration.Input(a, theirs), 0.25)
		expect.equal(claims:Consideration().Input(a, theirs), 0, "a veto by default")
	end,

	["Destroy forgets everything"] = function(expect)
		local Claims = load()
		local claims = Claims.new()
		local a = agent("A")
		local root = {}
		claims:Claim(root, a)
		claims:Destroy()
		expect.equal(claims:ClaimedBy(root), nil)
		a:Destroy()
		expect.truthy(true, "no error from a disconnected watcher")
	end,
}
