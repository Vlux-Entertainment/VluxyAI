--!strict

--[[
	Loads a real package module under Lune with `script`, `require`, `game` and the Roblox
	datatypes faked, so a spec exercises the module's own code rather than a copy of it. Not a
	spec: the runner only collects `*.spec.luau`.

	`script` is a proxy that tracks a filesystem path. `script.Parent.Parent.Types` from
	`lib/Brain/Runner.luau` walks to `lib/Types`, which resolves to `lib/Types.luau`; a module
	folder resolves to its `init.luau`. The package has no dependencies, so every require resolves
	inside the repo.

	Every module resolved during one Load is cached for that Load only, so two specs never share
	module state.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local task = require("@lune/task")

export type Options = {
	-- module path without extension -> what `require` returns for it, e.g. ["lib/Combat/Kill"]
	modules: { [string]: any }?,
	-- service name -> the value `game:GetService` returns; anything else is a bare proxy
	services: { [string]: any }?,
	-- extra or replacement globals (`os`, `workspace`, ...)
	globals: { [string]: any }?,
	-- receives every `warn`; default silences them
	warn: ((...any) -> ())?,
}

local Harness = {}

local PATH_KEY = newproxy(false)

local function dirname(path: string): string
	local parent = string.match(path, "^(.*)/[^/]+$")
	if parent == nil or parent == "" then
		return "."
	end
	return parent
end

local function basename(path: string): string
	return string.match(path, "([^/]+)$") or path
end

local function join(directory: string, name: string): string
	if directory == "." then
		return name
	end
	return `{directory}/{name}`
end

--[[
	A stand-in Instance that only records the filesystem path walked to reach it.
]]
local function pathProxy(path: string): any
	local proxy = {}
	proxy[PATH_KEY] = path

	return setmetatable(proxy, {
		__index = function(_self, key: string)
			if key == "Parent" then
				return pathProxy(dirname(path))
			elseif key == "Name" then
				return basename(path)
			elseif key == "WaitForChild" or key == "FindFirstChild" then
				return function(_proxy, name: string)
					return pathProxy(join(path, name))
				end
			elseif key == "GetFullName" then
				return function()
					return path
				end
			end

			return pathProxy(join(path, key))
		end,
		__tostring = function()
			return path
		end,
	})
end

--[[
	Returns the path of a proxy made by this harness, or nil for anything else.
]]
function Harness.PathOf(value: any): string?
	if type(value) == "table" then
		return rawget(value, PATH_KEY)
	end
	return nil
end

--[[
	Finds the file for a module path, or nil.
]]
local function resolveFile(modulePath: string): string?
	for _, candidate in { `{modulePath}.luau`, `{modulePath}.lua`, `{modulePath}/init.luau`, `{modulePath}/init.lua` } do
		if fs.isFile(candidate) then
			return candidate
		end
	end

	return nil
end

--[[
	The `script` path for a file: the file without its extension, or the folder for an init file.
]]
local function scriptPathFor(filePath: string): string
	local withoutExtension = string.gsub(filePath, "%.luau?$", "")
	if basename(withoutExtension) == "init" then
		return dirname(withoutExtension)
	end
	return withoutExtension
end

--[[
	A deterministic stand-in for `Random`, since Lune has none. A linear congruential generator
	seeded from the argument, so a seeded pick is reproducible across runs.
]]
local FakeRandom = {}
FakeRandom.__index = FakeRandom

function FakeRandom.new(seed: number?)
	return setmetatable({ _state = math.floor((seed or 1) * 7919) % 2147483647 }, FakeRandom)
end

function FakeRandom.NextNumber(self, min: number?, max: number?): number
	self._state = (self._state * 48271) % 2147483647
	local unit = self._state / 2147483647
	if min ~= nil and max ~= nil then
		return min + unit * (max - min)
	end
	return unit
end

function FakeRandom.NextInteger(self, min: number, max: number): number
	return math.floor(self:NextNumber(min, max + 1))
end

Harness.FakeRandom = FakeRandom

--[[
	Loads the module at `sourcePath` (relative to the repo root) with the given fakes and returns
	whatever it returns.
]]
function Harness.Load(sourcePath: string, options: Options?): any
	local resolved = options or {}
	local overrides = resolved.modules or {}
	local services = resolved.services or {}
	local cache: { [string]: any } = {}

	local warnHandler = resolved.warn or function(...)
		local _ = ...
	end

	local game = {
		GetService = function(_self, name: string)
			local service = services[name]
			if service == nil then
				return pathProxy(name)
			end
			return service
		end,
	}

	local loadFile: (filePath: string) -> any

	local function requireFrom(requester: string, target: any): any
		local modulePath = Harness.PathOf(target)
		if modulePath == nil then
			error(`Harness: {requester} required a non-path value ({tostring(target)})`, 2)
		end

		if overrides[modulePath] ~= nil then
			return overrides[modulePath]
		end

		if cache[modulePath] ~= nil then
			return cache[modulePath]
		end

		local filePath = resolveFile(modulePath)
		if filePath == nil then
			error(`Harness: {requester} required {modulePath}, which is not a file under the repo or Packages/`, 2)
		end

		local result = loadFile(filePath)
		cache[modulePath] = result
		return result
	end

	loadFile = function(filePath: string): any
		local scriptPath = scriptPathFor(filePath)

		local environment: { [string]: any } = {
			task = task,
			warn = warnHandler,
			game = game,
			script = pathProxy(scriptPath),
			require = function(target: any)
				return requireFrom(filePath, target)
			end,
			Vector3 = roblox.Vector3,
			CFrame = roblox.CFrame,
			Color3 = roblox.Color3,
			Enum = roblox.Enum,
			Instance = roblox.Instance,
			Random = FakeRandom,
		}

		for name, value in resolved.globals or {} do
			environment[name] = value
		end

		local chunk = luau.load(fs.readFile(filePath), {
			debugName = filePath,
			environment = environment,
			injectGlobals = true,
		})

		return chunk()
	end

	return loadFile(sourcePath)
end

--[[
	A stand-in for RunService.Heartbeat that fires only when a test calls `Fire`, so a spec
	controls exactly how much time the agent thinks has passed.
]]
function Harness.ManualHeartbeat()
	local handlers: { (number) -> () } = {}

	local heartbeat = {}

	function heartbeat.Connect(_self, callback: (number) -> ())
		table.insert(handlers, callback)
		return {
			Connected = true,
			Disconnect = function(connection)
				local index = table.find(handlers, callback)
				if index then
					table.remove(handlers, index)
				end
				connection.Connected = false
			end,
		}
	end

	function heartbeat.Fire(_self, deltaTime: number)
		for _, callback in table.clone(handlers) do
			callback(deltaTime)
		end
	end

	function heartbeat.Count(_self): number
		return #handlers
	end

	return heartbeat
end

--[[
	A clock a spec can move by hand, to test cadences without sleeping. Pass `{ os = clock.os }`
	as `globals`.
]]
function Harness.ManualClock(start: number?)
	local now = start or 0

	local clock = {}
	clock.os = setmetatable({
		clock = function()
			return now
		end,
	}, { __index = os })

	function clock.Advance(_self, seconds: number)
		now += seconds
	end

	function clock.Now(_self): number
		return now
	end

	return clock
end

return Harness
