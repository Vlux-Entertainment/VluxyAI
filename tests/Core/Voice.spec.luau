--!strict

--[[
	Voice: which line, when, and never over itself. A manual clock drives the timing and a custom
	`Play` records each line, so no Sound is made; the default on-rig playback is play-tested.
]]

local Harness = require("../Support/Harness")

local function setup(options: any, state: string?)
	local clock = Harness.ManualClock(100)
	local Voice = Harness.Load("lib/Animator/Voice.luau", { globals = { os = clock.os } })

	local played = {}
	local emitted = {}
	local agent = {
		Name = "Fake",
		Blackboard = {},
		Data = {},
		State = state,
	}
	function agent.GetState(self)
		return self.State
	end
	function agent.Emit(_self, name, payload)
		table.insert(emitted, { name, payload })
	end

	local given = table.clone(options)
	local length = given.Length or 1
	given.Length = nil
	given.Play = function(_agent, line)
		table.insert(played, line)
		return length
	end
	local voice = Voice.new(given)

	return {
		Voice = Voice,
		voice = voice,
		agent = agent,
		clock = clock,
		played = played,
		emitted = emitted,
	}
end

return {
	["Pick never repeats the last line when there is another"] = function(expect)
		local Voice = Harness.Load("lib/Animator/Voice.luau")
		local random = Harness.FakeRandom.new(1)
		local last = nil
		for _ = 1, 50 do
			local line = Voice.Pick({ 1, 2, 3 }, last, random)
			expect.truthy(line ~= last, "no line twice in a row")
			last = line
		end
		expect.equal(Voice.Pick({ 7 }, 7, random), 7, "a single line is all there is")
		expect.equal(Voice.Pick({}, nil, random), nil)
	end,

	["NextDelay stays inside the interval"] = function(expect)
		local Voice = Harness.Load("lib/Animator/Voice.luau")
		local random = Harness.FakeRandom.new(2)
		for _ = 1, 50 do
			local delay = Voice.NextDelay({ 4, 9 }, random)
			expect.truthy(delay >= 4 and delay <= 9)
		end
	end,

	["a state with lines speaks on its interval and announces each line"] = function(expect)
		local s = setup({ Lines = { Patrol = { 11, 12 } }, Interval = { 5, 5 }, OnEnter = 0 }, "Patrol")
		s.voice:Tick(s.agent, 0.1)
		expect.equal(#s.played, 0, "OnEnter 0: nothing on entry")

		s.clock:Advance(4.9)
		s.voice:Tick(s.agent, 0.1)
		expect.equal(#s.played, 0)
		s.clock:Advance(0.2)
		s.voice:Tick(s.agent, 0.1)
		expect.equal(#s.played, 1)
		expect.equal(s.emitted[1][1], "Voice")
		expect.equal(s.emitted[1][2].Line, s.played[1])
		expect.equal(s.emitted[1][2].State, "Patrol")

		s.clock:Advance(5.1)
		s.voice:Tick(s.agent, 0.1)
		expect.equal(#s.played, 2)
		expect.truthy(s.played[2] ~= s.played[1], "the other line this time")
	end,

	["OnEnter 1 speaks as the state is entered; a state with no pool is silent unless * has one"] = function(expect)
		local s = setup({ Lines = { Hunt = { 21 } }, Interval = { 5, 5 }, OnEnter = 1 }, "Patrol")
		s.voice:Tick(s.agent, 0.1)
		s.clock:Advance(20)
		s.voice:Tick(s.agent, 0.1)
		expect.equal(#s.played, 0, "Patrol has no lines and there is no *")

		s.agent.State = "Hunt"
		s.voice:Tick(s.agent, 0.1)
		expect.equal(#s.played, 1, "spoke on entering Hunt")
		expect.equal(s.played[1], 21)

		local any = setup({ Lines = { ["*"] = { 31 } }, Interval = { 5, 5 }, OnEnter = 1 }, "Anything")
		any.voice:Tick(any.agent, 0.1)
		expect.equal(any.played[1], 31, "* covers every state")
	end,

	["a line is never talked over: the next waits for it to end"] = function(expect)
		local s = setup({ Lines = { Patrol = { 1, 2 } }, Interval = { 2, 2 }, OnEnter = 1, Length = 6 }, "Patrol")
		s.voice:Tick(s.agent, 0.1)
		expect.equal(#s.played, 1)
		s.clock:Advance(3)
		s.voice:Tick(s.agent, 0.1)
		expect.equal(#s.played, 1, "the first line runs 6 seconds")
		s.clock:Advance(3.1)
		s.voice:Tick(s.agent, 0.1)
		expect.equal(#s.played, 2)
	end,

	["bad Lines or Interval are refused"] = function(expect)
		local Voice = Harness.Load("lib/Animator/Voice.luau")
		expect.includes(
			expect.errors(function()
				Voice.new({ Lines = {} })
			end),
			"Lines"
		)
		expect.includes(
			expect.errors(function()
				Voice.new({ Lines = { Patrol = { 1 } }, Interval = { 5, 2 } })
			end),
			"Interval"
		)
	end,

	["OnEnter may be a table of chances by state"] = function(expect)
		local s = setup({
			Lines = { Stare = { 41 }, Patrol = { 42 } },
			Interval = { 30, 30 },
			OnEnter = { Stare = 1, ["*"] = 0 },
		}, "Patrol")
		s.voice:Tick(s.agent, 0.1)
		expect.equal(#s.played, 0, "Patrol falls to *: never on entry")
		s.agent.State = "Stare"
		s.voice:Tick(s.agent, 0.1)
		expect.equal(s.played[1], 41, "Stare always speaks on entry")
	end,
}
