--!strict

--[[
	Discovers and runs every `*.spec.luau` under `tests/`, using Lune rather than Roblox. Package
	modules are loaded through `tests/Support/Harness` with `script`, `require` and the Roblox
	globals faked; anything that needs a real DataModel is a Studio play-test in the test place.

	Usage:  lune run tests/runner [--json] [pattern]
	Exit:   0 = all passed, 1 = a test failed, 2 = the runner itself failed
	        (including finding no spec at all to run).

	A spec returns a table of `["name"] = function(expect)` cases. The runner passes in the
	assertion helpers, so a spec requires nothing but its subject. A spec that returns anything
	else, or a table with no cases, fails as `<load>`: a file that tests nothing must never read
	as green.
]]

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local TESTS_DIRECTORY = "tests"

local jsonOutput = false
local filter: string? = nil

for _, argument in process.args do
	if argument == "--json" then
		jsonOutput = true
	else
		filter = argument
	end
end

--[[
	Fails the current case with a message. Level 0 keeps the reported text to the assertion.
]]
local function fail(message: string): never
	error(message, 0)
end

--[[
	The assertion helpers handed to every case. Deliberately small.
]]
local expect = {}

function expect.equal(actual: any, wanted: any, label: string?)
	if actual ~= wanted then
		fail(`{label or "expected"}: got {tostring(actual)}, wanted {tostring(wanted)}`)
	end
end

function expect.truthy(value: any, label: string?)
	if not value then
		fail(`{label or "expected a truthy value"}: got {tostring(value)}`)
	end
end

function expect.falsy(value: any, label: string?)
	if value then
		fail(`{label or "expected a falsy value"}: got {tostring(value)}`)
	end
end

--[[
	Asserts the call raises and returns the error text so the case can assert on it.
]]
function expect.errors(callback: () -> (), label: string?): string
	local ok, err = pcall(callback)
	if ok then
		fail(`{label or "expected an error"}: the call succeeded`)
	end
	return tostring(err)
end

--[[
	Asserts a string contains a plain substring; the usual follow-up to `errors`.
]]
function expect.includes(text: string, wanted: string, label: string?)
	if not string.find(text, wanted, 1, true) then
		fail(`{label or "expected text to include"} "{wanted}": got "{text}"`)
	end
end

function expect.near(actual: number, wanted: number, tolerance: number?, label: string?)
	local allowed = tolerance or 1e-6
	if math.abs(actual - wanted) > allowed then
		fail(`{label or "expected"}: got {actual}, wanted {wanted} (tolerance {allowed})`)
	end
end

--[[
	Asserts two lists hold the same values in the same order.
]]
function expect.sequence(actual: { any }, wanted: { any }, label: string?)
	local prefix = label or "expected sequence"
	if #actual ~= #wanted then
		fail(
			`{prefix}: got {#actual} items [{table.concat(actual, ", ")}], wanted {#wanted} [{table.concat(wanted, ", ")}]`
		)
	end
	for index, value in wanted do
		if actual[index] ~= value then
			fail(`{prefix}: item {index} is {tostring(actual[index])}, wanted {tostring(value)}`)
		end
	end
end

export type Expect = typeof(expect)
export type Spec = { [string]: (Expect) -> () }

local function collectSpecs(directory: string): { string }
	local found = {}

	for _, entry in fs.readDir(directory) do
		local path = `{directory}/{entry}`
		if fs.isDir(path) then
			for _, nested in collectSpecs(path) do
				table.insert(found, nested)
			end
		elseif string.match(entry, "%.spec%.luau$") then
			table.insert(found, path)
		end
	end

	table.sort(found)
	return found
end

local function runSpec(path: string): { { name: string, ok: boolean, err: string? } }
	local results = {}

	local withoutExtension = string.gsub(path, "%.luau$", "")
	local loaded, spec = pcall(require, `../{withoutExtension}`)
	if not loaded then
		table.insert(results, { name = "<load>", ok = false, err = tostring(spec) })
		return results
	end

	if type(spec) ~= "table" then
		table.insert(
			results,
			{ name = "<load>", ok = false, err = `the spec returned a {type(spec)}, not a table of cases` }
		)
		return results
	end

	local names = {}
	for name, case in pairs(spec :: Spec) do
		if type(case) ~= "function" then
			table.insert(
				results,
				{ name = tostring(name), ok = false, err = `the case is a {type(case)}, not a function` }
			)
			continue
		end
		table.insert(names, name)
	end
	table.sort(names)

	if #names == 0 and #results == 0 then
		table.insert(results, { name = "<load>", ok = false, err = "the spec has no cases" })
		return results
	end

	for _, name in names do
		local ok, err = pcall((spec :: Spec)[name], expect)
		table.insert(results, { name = name, ok = ok, err = if ok then nil else tostring(err) })
	end

	return results
end

local function abort(message: string): never
	if jsonOutput then
		print(serde.encode("json", { passed = 0, failed = 0, failures = {}, error = message }))
	else
		print(`Runner failed: {message}`)
	end
	return process.exit(2)
end

if not fs.isDir(TESTS_DIRECTORY) then
	abort(`{TESTS_DIRECTORY} is not a directory; run from the repo root`)
end

local specs = collectSpecs(TESTS_DIRECTORY)
local passed, failed = 0, 0
local failures = {}
local ran = 0

for _, path in specs do
	if filter and not string.find(path, filter, 1, true) then
		continue
	end

	ran += 1
	local label = string.gsub(string.sub(path, #TESTS_DIRECTORY + 2), "%.spec%.luau$", "")

	for _, result in runSpec(path) do
		if result.ok then
			passed += 1
		else
			failed += 1
			table.insert(failures, { case = `{label} > {result.name}`, error = result.err or "" })
		end
	end
end

if ran == 0 then
	abort(
		if filter then `no spec under {TESTS_DIRECTORY} matches "{filter}"` else `no spec found under {TESTS_DIRECTORY}`
	)
end

if jsonOutput then
	print(serde.encode("json", { passed = passed, failed = failed, failures = failures }))
else
	for _, failure in failures do
		print(`FAIL  {failure.case}`)
		print(`      {failure.error}`)
	end
	print("")
	print(`Tests: {passed} passed, {failed} failed.`)
end

process.exit(if failed == 0 then 0 else 1)
