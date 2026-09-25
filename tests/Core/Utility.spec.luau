--!strict

--[[
	Utility scoring: the curves, normalisation, the product rule, stable ordering and the two
	pickers. Every number here is chosen so the expected value can be checked by hand.
]]

local Fakes = require("../Support/Fakes")
local Harness = require("../Support/Harness")

local function load()
	return Harness.Load("lib/Brain/Utility.luau")
end

local function constant(value: number)
	return {
		Input = function()
			return value
		end,
	}
end

return {
	["curves hit 0 at 0 and 1 at 1"] = function(expect)
		local Curves = load().Curves
		for name, curve in
			{
				Linear = Curves.Linear,
				Quadratic = Curves.Quadratic,
				SquareRoot = Curves.SquareRoot,
				Power3 = Curves.Power(3),
				Logistic = Curves.Logistic(),
				LogisticSteep = Curves.Logistic(20, 0.3),
			} :: { [string]: (number) -> number }
		do
			expect.near(curve(0), 0, 1e-9, `{name}(0)`)
			expect.near(curve(1), 1, 1e-9, `{name}(1)`)
		end
	end,

	["curves have the documented shape"] = function(expect)
		local Curves = load().Curves
		expect.near(Curves.Linear(0.5), 0.5)
		expect.near(Curves.Quadratic(0.5), 0.25)
		expect.near(Curves.SquareRoot(0.25), 0.5)
		expect.near(Curves.Power(3)(0.5), 0.125)
		expect.near(Curves.Logistic()(0.5), 0.5, 1e-9, "logistic midpoint")
		expect.truthy(Curves.Logistic()(0.25) < 0.25, "logistic below midpoint is squashed")
		expect.equal(Curves.Threshold(0.6)(0.59), 0)
		expect.equal(Curves.Threshold(0.6)(0.6), 1)
	end,

	["Score multiplies its considerations"] = function(expect)
		local Utility = load()
		local score = Utility.Score(Fakes.Agent(), "x", { constant(0.5), constant(0.5) })
		expect.near(score, 0.25)
	end,

	["Score with no considerations is 1"] = function(expect)
		local Utility = load()
		expect.equal(Utility.Score(Fakes.Agent(), "x", {}), 1)
	end,

	["Min and Max normalise and clamp the raw input"] = function(expect)
		local Utility = load()
		local consideration = {
			Input = function()
				return 30
			end,
			Min = 10,
			Max = 50,
		}
		expect.near(Utility.Score(Fakes.Agent(), "x", { consideration }), 0.5)

		local below = {
			Input = function()
				return 0
			end,
			Min = 10,
			Max = 50,
		}
		expect.equal(Utility.Score(Fakes.Agent(), "x", { below }), 0)

		local above = {
			Input = function()
				return 500
			end,
			Min = 10,
			Max = 50,
		}
		expect.equal(Utility.Score(Fakes.Agent(), "x", { above }), 1)
	end,

	["Invert flips the normalised input before the curve"] = function(expect)
		local Utility = load()
		local consideration = {
			Input = function()
				return 15
			end,
			Max = 60,
			Invert = true,
			Curve = Utility.Curves.Quadratic,
		}
		-- 15/60 = 0.25, inverted 0.75, squared 0.5625
		expect.near(Utility.Score(Fakes.Agent(), "x", { consideration }), 0.5625)
	end,

	["a consideration that returns a non-number vetoes"] = function(expect)
		local Utility = load()
		local bad = {
			Input = function()
				return nil
			end,
		}
		expect.equal(Utility.Score(Fakes.Agent(), "x", { constant(1), bad :: any, constant(1) }), 0)

		local nan = {
			Input = function()
				return 0 / 0
			end,
		}
		expect.equal(Utility.Score(Fakes.Agent(), "x", { nan }), 0)
	end,

	["a curve that returns NaN vetoes instead of poisoning the sort"] = function(expect)
		local Utility = load()
		local nan = {
			Input = function()
				return 1
			end,
			Curve = function()
				return 0 / 0
			end,
		}
		expect.equal(Utility.Score(Fakes.Agent(), "x", { nan }), 0)
		expect.equal(
			Utility.Score(
				Fakes.Agent(),
				"x",
				{ {
					Input = function()
						return 0.5
					end,
					Curve = Utility.Curves.Logistic(0),
				} }
			),
			0,
			"a flat logistic is a veto, not NaN"
		)

		local scored = Utility.ScoreAll(Fakes.Agent(), { "a", "b" }, { nan })
		expect.equal(scored[1].Score, 0)
		expect.equal(scored[2].Score, 0)
	end,

	["Min and Max must be finite"] = function(expect)
		local Utility = load()
		for _, bad in { { Min = 0 / 0 }, { Max = math.huge }, { Min = -math.huge, Max = 1 } } do
			local consideration = {
				Input = function()
					return 1
				end,
				Min = bad.Min,
				Max = bad.Max,
			}
			local message = expect.errors(function()
				Utility.Score(Fakes.Agent(), "x", { consideration })
			end)
			expect.includes(message, "finite")
		end
	end,

	["a curve result outside 0 to 1 is clamped"] = function(expect)
		local Utility = load()
		local wild = {
			Input = function()
				return 1
			end,
			Curve = function()
				return 7
			end,
		}
		expect.equal(Utility.Score(Fakes.Agent(), "x", { wild }), 1)
	end,

	["Input receives the agent and the candidate"] = function(expect)
		local Utility = load()
		local agent = Fakes.Agent({ Bias = 0.5 })
		local seen = nil
		local consideration = {
			Input = function(passed, candidate)
				seen = candidate
				return passed.Blackboard.Bias
			end,
		}
		expect.near(Utility.Score(agent, "target", { consideration }), 0.5)
		expect.equal(seen, "target")
	end,

	["a malformed consideration errors with its index"] = function(expect)
		local Utility = load()
		local message = expect.errors(function()
			Utility.Score(Fakes.Agent(), "x", { constant(1), {} :: any })
		end)
		expect.includes(message, "[VluxyAI] Considerations[2].Input must be a function")

		message = expect.errors(function()
			Utility.Score(
				Fakes.Agent(),
				"x",
				{ {
					Input = function()
						return 1
					end,
					Min = 3,
					Max = 3,
				} }
			)
		end)
		expect.includes(message, "Considerations[1] has Min 3 and Max 3")
	end,

	["ScoreAll sorts best first and keeps ties in input order"] = function(expect)
		local Utility = load()
		local candidates = { "low", "tieA", "high", "tieB", "zero" }
		local values = { low = 0.2, tieA = 0.5, high = 0.9, tieB = 0.5, zero = 0 }
		local consideration = {
			Input = function(_agent, candidate)
				return values[candidate]
			end,
		}

		local scored = Utility.ScoreAll(Fakes.Agent(), candidates, { consideration })
		local names = {}
		for _, row in scored do
			table.insert(names, row.Candidate)
		end
		expect.sequence(names, { "high", "tieA", "tieB", "low", "zero" })
		expect.near(scored[1].Score, 0.9)
	end,

	["Best returns the top candidate and its score"] = function(expect)
		local Utility = load()
		local values = { a = 0.3, b = 0.8, c = 0.8 }
		local consideration = {
			Input = function(_agent, candidate)
				return values[candidate]
			end,
		}

		local best, score = Utility.Best(Fakes.Agent(), { "a", "b", "c" }, { consideration })
		expect.equal(best, "b", "earlier candidate wins a tie")
		expect.near(score, 0.8)
	end,

	["Best returns nil when nothing scores above zero"] = function(expect)
		local Utility = load()
		local best, score = Utility.Best(Fakes.Agent(), { "a", "b" }, { constant(0) })
		expect.equal(best, nil)
		expect.equal(score, 0)

		best = Utility.Best(Fakes.Agent(), {}, { constant(1) })
		expect.equal(best, nil, "no candidates")
	end,

	["Weighted picks in proportion to score using the given random"] = function(expect)
		local Utility = load()
		local values = { a = 0.1, b = 0.3, c = 0.6 }
		local consideration = {
			Input = function(_agent, candidate)
				return values[candidate]
			end,
		}

		-- Scored order is c (0.6), b (0.3), a (0.1); the roll walks that order.
		local function rolling(unit: number)
			return {
				NextNumber = function()
					return unit
				end,
			}
		end

		local pick = Utility.Weighted(Fakes.Agent(), { "a", "b", "c" }, { consideration }, rolling(0.1))
		expect.equal(pick, "c")
		pick = Utility.Weighted(Fakes.Agent(), { "a", "b", "c" }, { consideration }, rolling(0.7))
		expect.equal(pick, "b")
		pick = Utility.Weighted(Fakes.Agent(), { "a", "b", "c" }, { consideration }, rolling(0.95))
		expect.equal(pick, "a")
	end,

	["Weighted never picks a zero-scoring candidate"] = function(expect)
		local Utility = load()
		local values = { a = 0, b = 0.5 }
		local consideration = {
			Input = function(_agent, candidate)
				return values[candidate]
			end,
		}
		local always = {
			NextNumber = function()
				return 0.999999
			end,
		}

		for _ = 1, 20 do
			local pick = Utility.Weighted(Fakes.Agent(), { "a", "b" }, { consideration }, always)
			expect.equal(pick, "b")
		end

		local none = Utility.Weighted(Fakes.Agent(), { "a" }, { consideration }, always)
		expect.equal(none, nil)
	end,

	["Weighted without a random still picks something"] = function(expect)
		local Utility = load()
		local pick = Utility.Weighted(Fakes.Agent(), { "only" }, { constant(0.5) })
		expect.equal(pick, "only")
	end,
}
