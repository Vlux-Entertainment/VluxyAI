--!strict

--[[
	Watched: the observer's cone, the observer's eye, the observer's ray, and how long it has been
	since anyone looked. Observers are fake characters and `workspace.Raycast` is faked.
]]

local Harness = require("../Support/Harness")
local SenseFakes = require("./SenseFakes")

local roblox = require("@lune/roblox")
local Vector3 = roblox.Vector3

local AGENT_AT = Vector3.new(0, 0, 0)
local TOWARDS_AGENT = Vector3.new(0, 0, 1)
local AWAY = Vector3.new(0, 0, -1)

local function setup(options: { watched: any?, hit: any?, rays: { SenseFakes.Ray }? }?)
	local resolved = options or {}
	local clock = Harness.ManualClock(100)
	local Watched = Harness.Load("lib/Senses/Watched.luau", {
		globals = SenseFakes.Globals({ clock = clock, hit = resolved.hit, rays = resolved.rays }),
	})

	local agent = SenseFakes.Agent(AGENT_AT)
	local watched = Watched.new(resolved.watched)

	return {
		watched = watched,
		agent = agent,
		blackboard = agent.Blackboard,
		clock = clock,
	}
end

--[[
	A character standing `distance` studs down -Z from the agent, facing it (or not).
]]
local function observer(name: string, distance: number, facing: any?, headFacing: any?)
	return SenseFakes.Character(name, Vector3.new(0, 0, -distance), facing or TOWARDS_AGENT, headFacing)
end

return {
	["an observer facing the agent within range is watching"] = function(expect)
		local watcher = observer("A", 10)
		local s = setup({ watched = { Targets = SenseFakes.Targets({ watcher.Root }) } })

		s.watched:Tick(s.agent, 0.1)
		expect.equal(#s.blackboard.WatchedBy, 1)
		expect.equal(s.blackboard.WatchedBy[1], watcher.Root)
		expect.truthy(s.blackboard.IsWatched)
		expect.equal(s.blackboard.WatchedAt, 100)
		expect.equal(s.blackboard.UnwatchedFor, 0)
	end,

	["an observer facing away is not watching"] = function(expect)
		local watcher = observer("A", 10, AWAY)
		local s = setup({ watched = { Targets = SenseFakes.Targets({ watcher.Root }) } })

		s.watched:Tick(s.agent, 0.1)
		expect.equal(#s.blackboard.WatchedBy, 0)
		expect.falsy(s.blackboard.IsWatched)
		expect.equal(s.blackboard.WatchedAt, nil)
		expect.equal(s.blackboard.UnwatchedFor, math.huge)
	end,

	["an observer beyond Range is not watching"] = function(expect)
		local watcher = observer("A", 61)
		local s = setup({ watched = { Range = 60, Targets = SenseFakes.Targets({ watcher.Root }) } })

		s.watched:Tick(s.agent, 0.1)
		expect.falsy(s.blackboard.IsWatched)
	end,

	["the FieldOfView is the observer's"] = function(expect)
		-- The observer looks 30 degrees off the agent: inside a 90 degree cone, outside a 45 one.
		local sideways = Vector3.new(math.sin(math.rad(30)), 0, math.cos(math.rad(30)))
		local watcher = observer("A", 10, sideways)

		local wide = setup({ watched = { FieldOfView = 90, Targets = SenseFakes.Targets({ watcher.Root }) } })
		wide.watched:Tick(wide.agent, 0.1)
		expect.truthy(wide.blackboard.IsWatched)

		local narrow = setup({ watched = { FieldOfView = 45, Targets = SenseFakes.Targets({ watcher.Root }) } })
		narrow.watched:Tick(narrow.agent, 0.1)
		expect.falsy(narrow.blackboard.IsWatched)
	end,

	["the observer looks out of its Head when it has one"] = function(expect)
		local headTurned = observer("A", 10, AWAY, TOWARDS_AGENT)
		local s = setup({ watched = { Targets = SenseFakes.Targets({ headTurned.Root }) } })

		s.watched:Tick(s.agent, 0.1)
		expect.truthy(s.blackboard.IsWatched, "the head faces the agent though the root does not")
		expect.equal(s.blackboard.WatchedBy[1], headTurned.Root, "reported by its root")

		local bodyOnly = observer("B", 10, TOWARDS_AGENT, AWAY)
		local t = setup({ watched = { Targets = SenseFakes.Targets({ bodyOnly.Root }) } })
		t.watched:Tick(t.agent, 0.1)
		expect.falsy(t.blackboard.IsWatched, "the head looks away though the root faces the agent")
	end,

	["an obstructed observer is not watching"] = function(expect)
		local watcher = observer("A", 10)
		local s = setup({
			watched = { Targets = SenseFakes.Targets({ watcher.Root }) },
			hit = function()
				return SenseFakes.Hit(nil)
			end,
		})

		s.watched:Tick(s.agent, 0.1)
		expect.falsy(s.blackboard.IsWatched)
	end,

	["a ray that reaches the agent's entity counts as clear"] = function(expect)
		local watcher = observer("A", 10)
		local s
		s = setup({
			watched = { Targets = SenseFakes.Targets({ watcher.Root }) },
			hit = function()
				return SenseFakes.Hit(s.agent.Entity)
			end,
		})

		s.watched:Tick(s.agent, 0.1)
		expect.truthy(s.blackboard.IsWatched)
	end,

	["the ray goes from the observer's eye to the agent's pivot, through the observer's character and Ignore"] = function(
		expect
	)
		local rays: { SenseFakes.Ray } = {}
		local watcher = observer("A", 10, AWAY, TOWARDS_AGENT)
		local glass = { Name = "Glass" }
		local s = setup({
			watched = {
				Targets = SenseFakes.Targets({ watcher.Root }),
				Ignore = function()
					return { glass }
				end,
			},
			rays = rays,
		})

		s.watched:Tick(s.agent, 0.1)
		expect.equal(#rays, 1)
		expect.equal(rays[1].From, (watcher.Head :: any).Position)
		expect.equal(rays[1].Direction, AGENT_AT - (watcher.Head :: any).Position)
		local filter = rays[1].Params.FilterDescendantsInstances
		expect.equal(#filter, 2)
		expect.equal(filter[1], glass)
		expect.equal(filter[2], watcher.Model)
	end,

	["the agent's own entity is not in the observer's filter"] = function(expect)
		local rays: { SenseFakes.Ray } = {}
		local watcher = observer("A", 10)
		local s = setup({ watched = { Targets = SenseFakes.Targets({ watcher.Root }) }, rays = rays })

		s.watched:Tick(s.agent, 0.1)
		local filter = rays[1].Params.FilterDescendantsInstances
		expect.equal(#filter, 1)
		expect.equal(filter[1], watcher.Model)
	end,

	["a root with no character is its own eye and its own filter"] = function(expect)
		local rays: { SenseFakes.Ray } = {}
		local loose = SenseFakes.Part(Vector3.new(0, 0, -10), TOWARDS_AGENT)
		local s = setup({ watched = { Targets = SenseFakes.Targets({ loose }) }, rays = rays })

		s.watched:Tick(s.agent, 0.1)
		expect.truthy(s.blackboard.IsWatched)
		expect.equal(rays[1].Params.FilterDescendantsInstances[1], loose)
	end,

	["RequireLineOfSight off trusts the cone and casts nothing"] = function(expect)
		local rays: { SenseFakes.Ray } = {}
		local watcher = observer("A", 10)
		local s = setup({
			watched = { RequireLineOfSight = false, Targets = SenseFakes.Targets({ watcher.Root }) },
			hit = function()
				return SenseFakes.Hit(nil)
			end,
			rays = rays,
		})

		s.watched:Tick(s.agent, 0.1)
		expect.truthy(s.blackboard.IsWatched)
		expect.equal(#rays, 0)
	end,

	["no ray is cast for an observer whose cone misses"] = function(expect)
		local rays: { SenseFakes.Ray } = {}
		local watcher = observer("A", 10, AWAY)
		local s = setup({ watched = { Targets = SenseFakes.Targets({ watcher.Root }) }, rays = rays })

		s.watched:Tick(s.agent, 0.1)
		expect.equal(#rays, 0)
	end,

	["watchers are listed nearest first"] = function(expect)
		local far = observer("Far", 30)
		local near = observer("Near", 5)
		local away = observer("Away", 8, AWAY)
		local t = setup({ watched = { Targets = SenseFakes.Targets({ far.Root, away.Root, near.Root }) } })
		t.watched:Tick(t.agent, 0.1)
		expect.equal(#t.blackboard.WatchedBy, 2)
		expect.equal(t.blackboard.WatchedBy[1], near.Root)
		expect.equal(t.blackboard.WatchedBy[2], far.Root)
	end,

	["UnwatchedFor counts up from the last look and WatchedAt keeps it"] = function(expect)
		local targets = { observer("A", 10).Root }
		local s = setup({
			watched = {
				Targets = function()
					return targets
				end,
			},
		})

		s.watched:Tick(s.agent, 0.1)
		s.clock:Advance(2)
		s.watched:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.WatchedAt, 102)
		expect.equal(s.blackboard.UnwatchedFor, 0)

		table.clear(targets)
		s.clock:Advance(1.5)
		s.watched:Tick(s.agent, 0.1)
		expect.falsy(s.blackboard.IsWatched)
		expect.equal(s.blackboard.WatchedAt, 102, "kept")
		expect.near(s.blackboard.UnwatchedFor, 1.5)

		s.clock:Advance(10)
		s.watched:Tick(s.agent, 0.1)
		expect.near(s.blackboard.UnwatchedFor, 11.5)

		table.insert(targets, observer("B", 10).Root)
		s.watched:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.UnwatchedFor, 0)
		expect.equal(s.blackboard.WatchedAt, 113.5)
	end,

	["the default options are as documented"] = function(expect)
		local rays: { SenseFakes.Ray } = {}
		local atRange = observer("In", 60)
		local pastRange = observer("Out", 60.5)
		-- 44 degrees off is inside the 90 degree default cone; 46 is not.
		local edgeIn = observer("EdgeIn", 10, Vector3.new(math.sin(math.rad(44)), 0, math.cos(math.rad(44))))
		local edgeOut = observer("EdgeOut", 10, Vector3.new(math.sin(math.rad(46)), 0, math.cos(math.rad(46))))
		local s = setup({
			watched = { Targets = SenseFakes.Targets({ pastRange.Root, atRange.Root, edgeOut.Root, edgeIn.Root }) },
			rays = rays,
		})

		s.watched:Tick(s.agent, 0.1)
		expect.equal(#s.blackboard.WatchedBy, 2)
		expect.equal(s.blackboard.WatchedBy[1], edgeIn.Root)
		expect.equal(s.blackboard.WatchedBy[2], atRange.Root)
		expect.equal(#rays, 2, "RequireLineOfSight defaults on")
	end,

	["a negative Range is refused"] = function(expect)
		local Watched = Harness.Load("lib/Senses/Watched.luau", { globals = SenseFakes.Globals() })
		local message = expect.errors(function()
			Watched.new({ Range = -1 })
		end)
		expect.includes(message, "Range")
	end,

	["Destroy is safe to call"] = function(expect)
		local s = setup()
		s.watched:Destroy()
		expect.truthy(true)
	end,
}
