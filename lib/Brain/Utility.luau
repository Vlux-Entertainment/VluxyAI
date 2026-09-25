--!strict

--[[
	Utility scoring for choosing targets inside a state: which player to chase, which node to
	search, which door to cut off through. Each candidate is scored by a list of considerations,
	each of which reads a raw value, normalises it into [0, 1], runs it through a response curve,
	and multiplies into the candidate's score. Pure Luau.

	This chooses targets, never modes. Mode changes are the brain's transitions, which are
	deterministic and readable; a bad score here gives an odd choice, never an oscillating AI.
]]

local FormatMessage = require(script.Parent.Parent.Utility.FormatMessage)
local Types = require(script.Parent.Parent.Types)

------------------------------------------------------------------------------------------------------------------------

local sharedRandom: Random? = nil

--[=[
	@class Utility

	Scores candidates by considerations and picks the best or a weighted-random one. Use it inside
	a state to choose what to act on; use transitions to choose what to do.

	```lua
	local chaseConsiderations = {
		{ Input = function(agent, root) return (root.Position - agent:GetPosition()).Magnitude end,
		  Max = 60, Invert = true, Curve = VluxyAI.Utility.Curves.Quadratic },
		{ Input = function(agent, root) return if agent.Blackboard.SeenTarget == root then 1 else 0 end },
	}

	local root = VluxyAI.Utility.Best(agent, agent.Blackboard.NearbyTargets, chaseConsiderations)
	```
]=]
local Utility = {}

--[=[
	@within Utility
	@prop Curves { Linear: Curve, Quadratic: Curve, SquareRoot: Curve, Power: (exponent: number) -> Curve, Logistic: (steepness: number?, midpoint: number?) -> Curve, Threshold: (at: number) -> Curve }

	Response curves for [Types.Consideration]. Each maps `[0, 1]` to `[0, 1]`.

	- `Linear`: `x`.
	- `Quadratic`: `x^2`. Rewards the top end.
	- `SquareRoot`: `sqrt(x)`. Rewards the bottom end.
	- `Power(exponent)`: `x^exponent`.
	- `Logistic(steepness?, midpoint?)`: an S curve, steepness default 10, midpoint default 0.5.
	- `Threshold(at)`: `0` below `at`, `1` at and above. A hard veto.
]=]
Utility.Curves = {
	Linear = function(x: number): number
		return x
	end,
	Quadratic = function(x: number): number
		return x * x
	end,
	SquareRoot = function(x: number): number
		return math.sqrt(x)
	end,
	Power = function(exponent: number): Types.Curve
		return function(x: number): number
			return x ^ exponent
		end
	end,
	Logistic = function(steepness: number?, midpoint: number?): Types.Curve
		local k = steepness or 10
		local mid = midpoint or 0.5
		-- Rescaled so the curve hits exactly 0 at x = 0 and 1 at x = 1 instead of the asymptotes.
		local low = 1 / (1 + math.exp(-k * (0 - mid)))
		local high = 1 / (1 + math.exp(-k * (1 - mid)))
		return function(x: number): number
			local raw = 1 / (1 + math.exp(-k * (x - mid)))
			return (raw - low) / (high - low)
		end
	end,
	Threshold = function(at: number): Types.Curve
		return function(x: number): number
			return if x >= at then 1 else 0
		end
	end,
}

------------------------------------------------------------------------------------------------------------------------

--[[
	Checks a consideration is usable, naming the index in the message.
]]
local function checkConsideration(consideration: any, index: number)
	if type(consideration) ~= "table" then
		FormatMessage.Error(`Considerations[{index}] must be a table, got a {typeof(consideration)}`, 3)
	end
	if type(consideration.Input) ~= "function" then
		FormatMessage.Error(`Considerations[{index}].Input must be a function, got a {typeof(consideration.Input)}`, 3)
	end

	local min = consideration.Min or 0
	local max = consideration.Max or 1
	if type(min) ~= "number" or type(max) ~= "number" or min == max then
		FormatMessage.Error(
			`Considerations[{index}] has Min {tostring(min)} and Max {tostring(max)}; they must be different numbers`,
			3
		)
	end
	if consideration.Curve ~= nil and type(consideration.Curve) ~= "function" then
		FormatMessage.Error(`Considerations[{index}].Curve must be a function, got a {typeof(consideration.Curve)}`, 3)
	end
end

--[[
	Scores one consideration for one candidate: normalise, invert, curve, clamp.
]]
local function scoreConsideration<T>(consideration: Types.Consideration<T>, agent: Types.Agent, candidate: T): number
	local raw = consideration.Input(agent, candidate)
	if type(raw) ~= "number" or raw ~= raw then
		return 0
	end

	local min = consideration.Min or 0
	local max = consideration.Max or 1
	local normalised = math.clamp((raw - min) / (max - min), 0, 1)

	if consideration.Invert then
		normalised = 1 - normalised
	end

	local curve = consideration.Curve or Utility.Curves.Linear

	return math.clamp(curve(normalised), 0, 1)
end

------------------------------------------------------------------------------------------------------------------------

--[=[
	@within Utility
	@param agent Agent
	@param candidate T
	@param considerations { Consideration<T> }
	@return number -- In `[0, 1]`.
	@error string -- A consideration is malformed.

	Scores one candidate: the product of its considerations. A consideration whose `Input` returns
	something that is not a number scores `0`, which vetoes the candidate.
]=]
function Utility.Score<T>(agent: Types.Agent, candidate: T, considerations: { Types.Consideration<T> }): number
	local score = 1

	for index, consideration in considerations do
		checkConsideration(consideration, index)
		score *= scoreConsideration(consideration, agent, candidate)
		if score == 0 then
			break
		end
	end

	return score
end

--[=[
	@within Utility
	@param agent Agent
	@param candidates { T }
	@param considerations { Consideration<T> }
	@return { Scored<T> } -- Sorted best first. Stable for ties.

	Scores every candidate. Candidates that score `0` are kept, so a debug view can show why
	nothing was chosen.
]=]
function Utility.ScoreAll<T>(
	agent: Types.Agent,
	candidates: { T },
	considerations: { Types.Consideration<T> }
): { Types.Scored<T> }
	local scores: { number } = {}
	local order: { number } = {}

	for index, candidate in candidates do
		scores[index] = Utility.Score(agent, candidate, considerations)
		order[index] = index
	end

	-- Sorting indices keeps ties in input order, which table.sort alone does not promise.
	table.sort(order, function(a, b)
		if scores[a] ~= scores[b] then
			return scores[a] > scores[b]
		end
		return a < b
	end)

	local scored: { Types.Scored<T> } = {}
	for _, index in order do
		table.insert(scored, { Candidate = candidates[index], Score = scores[index] })
	end

	return scored
end

--[=[
	@within Utility
	@param agent Agent
	@param candidates { T }
	@param considerations { Consideration<T> }
	@return T? -- The best candidate, or `nil` when there are none or every one scored `0`.
	@return number -- Its score.

	Picks the highest scoring candidate. Earlier candidates win ties, so a stable input order gives
	a stable choice.
]=]
function Utility.Best<T>(agent: Types.Agent, candidates: { T }, considerations: { Types.Consideration<T> }): (T?, number)
	local bestCandidate: T? = nil
	local bestScore = 0

	for _, candidate in candidates do
		local score = Utility.Score(agent, candidate, considerations)
		if score > bestScore then
			bestCandidate = candidate
			bestScore = score
		end
	end

	return bestCandidate, bestScore
end

--[=[
	@within Utility
	@param agent Agent
	@param candidates { T }
	@param considerations { Consideration<T> }
	@param random Random? -- Seed one for a reproducible pick. Default a shared `Random`.
	@return T? -- A candidate chosen with probability proportional to its score, or `nil` when every one scored `0`.
	@return number -- Its score.

	Picks a weighted-random candidate. Use it when the best choice every time reads as robotic;
	a candidate that scores twice as much is picked twice as often.
]=]
function Utility.Weighted<T>(
	agent: Types.Agent,
	candidates: { T },
	considerations: { Types.Consideration<T> },
	random: Random?
): (T?, number)
	local scored = Utility.ScoreAll(agent, candidates, considerations)

	local total = 0
	for _, row in scored do
		total += row.Score
	end
	if total <= 0 then
		return nil, 0
	end

	if random == nil then
		-- Made on first use so requiring the module does nothing Roblox-specific.
		sharedRandom = sharedRandom or Random.new()
	end
	local generator = random or sharedRandom :: Random
	local roll = generator:NextNumber() * total

	for _, row in scored do
		roll -= row.Score
		if roll <= 0 then
			return row.Candidate, row.Score
		end
	end

	-- Floating point can leave a sliver; the last positive row takes it.
	for index = #scored, 1, -1 do
		if scored[index].Score > 0 then
			return scored[index].Candidate, scored[index].Score
		end
	end

	return nil, 0
end

return Utility
