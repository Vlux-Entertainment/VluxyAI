--!strict

--[[
	Sight: the cone, the ray and the memory. Targets are plain tables and `workspace.Raycast` is
	faked, so every decision path runs without a DataModel.
]]

local Harness = require("../Support/Harness")
local SenseFakes = require("./SenseFakes")

local roblox = require("@lune/roblox")
local Vector3 = roblox.Vector3

local AHEAD = Vector3.new(0, 0, -1)

local function setup(options: { sight: any?, hit: any?, rays: { SenseFakes.Ray }?, agentAt: any?, facing: any? }?)
	local resolved = options or {}
	local clock = Harness.ManualClock(100)
	local Sight = Harness.Load("lib/Senses/Sight.luau", {
		globals = SenseFakes.Globals({ clock = clock, hit = resolved.hit, rays = resolved.rays }),
	})

	local agent = SenseFakes.Agent(resolved.agentAt or Vector3.new(0, 0, 0), resolved.facing or AHEAD)
	local sight = Sight.new(resolved.sight)

	return {
		sight = sight,
		agent = agent,
		blackboard = agent.Blackboard,
		clock = clock,
	}
end

return {
	["a target ahead within range with a clear ray is seen"] = function(expect)
		local target = SenseFakes.Part(Vector3.new(0, 0, -10))
		local s = setup({ sight = { Targets = SenseFakes.Targets({ target }) } })

		s.sight:Tick(s.agent, 0.1)
		expect.equal(#s.blackboard.SeenTargets, 1)
		expect.equal(s.blackboard.SeenTargets[1], target)
		expect.equal(s.blackboard.SeenTarget, target)
		expect.near(s.blackboard.SeenDistance, 10)
		expect.equal(s.blackboard.SeenPosition, Vector3.new(0, 0, -10))
		expect.equal(s.blackboard.SeenAt, 100)
	end,

	["a target behind is not seen"] = function(expect)
		local s = setup({ sight = { Targets = SenseFakes.Targets({ SenseFakes.Part(Vector3.new(0, 0, 10)) }) } })

		s.sight:Tick(s.agent, 0.1)
		expect.equal(#s.blackboard.SeenTargets, 0)
		expect.equal(s.blackboard.SeenTarget, nil)
		expect.equal(s.blackboard.SeenDistance, math.huge, "no distance to measure")
		expect.equal(s.blackboard.SeenPosition, nil)
		expect.equal(s.blackboard.SeenAt, nil)
	end,

	["a target beyond Range is not seen"] = function(expect)
		local s = setup({
			sight = { Range = 20, Targets = SenseFakes.Targets({ SenseFakes.Part(Vector3.new(0, 0, -21)) }) },
		})

		s.sight:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.SeenTarget, nil)
	end,

	["a target outside the FieldOfView is not seen"] = function(expect)
		local beside = SenseFakes.Part(Vector3.new(10, 0, -1))
		local s = setup({ sight = { FieldOfView = 60, Targets = SenseFakes.Targets({ beside }) } })

		s.sight:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.SeenTarget, nil)

		local wide = setup({ sight = { FieldOfView = 180, Targets = SenseFakes.Targets({ beside }) } })
		wide.sight:Tick(wide.agent, 0.1)
		expect.equal(wide.blackboard.SeenTarget, beside)
	end,

	["an obstructed target is not seen"] = function(expect)
		local s = setup({
			sight = { Targets = SenseFakes.Targets({ SenseFakes.Part(Vector3.new(0, 0, -10)) }) },
			hit = function()
				return SenseFakes.Hit(nil)
			end,
		})

		s.sight:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.SeenTarget, nil)
	end,

	["a ray that hits the target's own model still sees it"] = function(expect)
		local character = SenseFakes.Character("Player", Vector3.new(0, 0, -10))
		local s = setup({
			sight = { Targets = SenseFakes.Targets({ character.Root }) },
			hit = function()
				return SenseFakes.Hit(character.Model)
			end,
		})

		s.sight:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.SeenTarget, character.Root)
	end,

	["a ray that hits another target's model is an obstruction"] = function(expect)
		local blocker = SenseFakes.Character("Blocker", Vector3.new(0, 0, -5))
		local behind = SenseFakes.Character("Behind", Vector3.new(0, 0, -10))
		local s = setup({
			sight = { Targets = SenseFakes.Targets({ behind.Root }) },
			hit = function()
				return SenseFakes.Hit(blocker.Model)
			end,
		})

		s.sight:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.SeenTarget, nil)
	end,

	["seen targets are nearest first and the nearest is SeenTarget"] = function(expect)
		local far = SenseFakes.Part(Vector3.new(0, 0, -30))
		local near = SenseFakes.Part(Vector3.new(1, 0, -5))
		local middle = SenseFakes.Part(Vector3.new(-2, 0, -15))
		local s = setup({ sight = { Targets = SenseFakes.Targets({ far, near, middle }) } })

		s.sight:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.SeenTargets[1], near)
		expect.equal(s.blackboard.SeenTargets[2], middle)
		expect.equal(s.blackboard.SeenTargets[3], far)
		expect.equal(s.blackboard.SeenTarget, near)
		expect.near(s.blackboard.SeenDistance, Vector3.new(1, 0, -5).Magnitude)
	end,

	["the ray goes from the eye to the target, passing through Ignore"] = function(expect)
		local rays: { SenseFakes.Ray } = {}
		local ignored = { Name = "Hat" }
		local s = setup({
			sight = {
				EyeOffset = Vector3.new(0, 2, 0),
				Targets = SenseFakes.Targets({ SenseFakes.Part(Vector3.new(0, 2, -10)) }),
				Ignore = function()
					return { ignored }
				end,
			},
			rays = rays,
		})

		s.sight:Tick(s.agent, 0.1)
		expect.equal(#rays, 1)
		expect.equal(rays[1].From, Vector3.new(0, 2, 0))
		expect.equal(rays[1].Direction, Vector3.new(0, 0, -10))
		expect.equal(rays[1].Params.FilterDescendantsInstances[1], ignored)
		expect.equal(rays[1].Params.FilterType, roblox.Enum.RaycastFilterType.Exclude)
	end,

	["the default Ignore is the agent's entity alone; the filter covers its descendants"] = function(expect)
		local rays: { SenseFakes.Ray } = {}
		local s = setup({
			sight = { Targets = SenseFakes.Targets({ SenseFakes.Part(Vector3.new(0, 0, -10)) }) },
			rays = rays,
		})

		s.sight:Tick(s.agent, 0.1)
		local filter = rays[1].Params.FilterDescendantsInstances
		expect.equal(#filter, 1)
		expect.equal(filter[1], s.agent.Entity)
	end,

	["no ray is cast for a target outside the cone"] = function(expect)
		local rays: { SenseFakes.Ray } = {}
		local s = setup({
			sight = { Targets = SenseFakes.Targets({ SenseFakes.Part(Vector3.new(0, 0, 10)) }) },
			rays = rays,
		})

		s.sight:Tick(s.agent, 0.1)
		expect.equal(#rays, 0)
	end,

	["EyeOffset moves the eye, so range and the cone are measured from it"] = function(expect)
		local target = SenseFakes.Part(Vector3.new(0, 10, -30))
		local s = setup({
			sight = { Range = 30, EyeOffset = Vector3.new(0, 10, 0), Targets = SenseFakes.Targets({ target }) },
		})

		s.sight:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.SeenTarget, target)
		expect.near(s.blackboard.SeenDistance, 30)
	end,

	["the eye turns with the entity"] = function(expect)
		local target = SenseFakes.Part(Vector3.new(10, 0, 0))
		local s = setup({ sight = { Targets = SenseFakes.Targets({ target }) }, facing = Vector3.new(1, 0, 0) })

		s.sight:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.SeenTarget, target)
	end,

	["SeenPosition and SeenAt outlive the sighting by Memory seconds"] = function(expect)
		local targets = { SenseFakes.Part(Vector3.new(0, 0, -10)) }
		local s = setup({
			sight = {
				Memory = 3,
				Targets = function()
					return targets
				end,
			},
		})

		s.sight:Tick(s.agent, 0.1)
		table.clear(targets)
		s.clock:Advance(1)
		s.sight:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.SeenTarget, nil)
		expect.equal(s.blackboard.SeenDistance, math.huge)
		expect.equal(#s.blackboard.SeenTargets, 0)
		expect.equal(s.blackboard.SeenPosition, Vector3.new(0, 0, -10), "remembered")
		expect.equal(s.blackboard.SeenAt, 100, "the sighting time, not now")

		s.clock:Advance(2)
		s.sight:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.SeenPosition, Vector3.new(0, 0, -10), "still remembered at Memory")

		s.clock:Advance(0.01)
		s.sight:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.SeenPosition, nil, "forgotten")
		expect.equal(s.blackboard.SeenAt, nil)
	end,

	["a state that clears SeenAt forgets SeenPosition too"] = function(expect)
		local targets = { SenseFakes.Part(Vector3.new(0, 0, -10)) }
		local s = setup({
			sight = {
				Targets = function()
					return targets
				end,
			},
		})

		s.sight:Tick(s.agent, 0.1)
		table.clear(targets)
		s.blackboard.SeenAt = nil
		s.sight:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.SeenPosition, nil)
	end,

	["SeenPosition follows the target while it is visible"] = function(expect)
		local target = SenseFakes.Part(Vector3.new(0, 0, -10))
		local s = setup({ sight = { Targets = SenseFakes.Targets({ target }) } })

		s.sight:Tick(s.agent, 0.1)
		target.Position = Vector3.new(3, 0, -12)
		s.clock:Advance(1)
		s.sight:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.SeenPosition, Vector3.new(3, 0, -12))
		expect.equal(s.blackboard.SeenAt, 101)
	end,

	["the default options are as documented"] = function(expect)
		local justInside = SenseFakes.Part(Vector3.new(0, 0, -40))
		local justOutside = SenseFakes.Part(Vector3.new(0, 0, -40.5))
		-- 59 degrees off centre: inside the 120 degree default; 61 is outside.
		local edgeIn = SenseFakes.Part(Vector3.new(math.sin(math.rad(59)), 0, -math.cos(math.rad(59))) * 10)
		local edgeOut = SenseFakes.Part(Vector3.new(math.sin(math.rad(61)), 0, -math.cos(math.rad(61))) * 10)
		local s = setup({ sight = { Targets = SenseFakes.Targets({ justInside, justOutside, edgeIn, edgeOut }) } })

		s.sight:Tick(s.agent, 0.1)
		expect.equal(#s.blackboard.SeenTargets, 2)
		expect.equal(s.blackboard.SeenTargets[1], edgeIn)
		expect.equal(s.blackboard.SeenTargets[2], justInside)
	end,

	["a negative Range is refused"] = function(expect)
		local Sight = Harness.Load("lib/Senses/Sight.luau", { globals = SenseFakes.Globals() })
		local message = expect.errors(function()
			Sight.new({ Range = -1 })
		end)
		expect.includes(message, "[VluxyAI]")
	end,

	["an unknown option is refused, naming the module"] = function(expect)
		local Sight = Harness.Load("lib/Senses/Sight.luau", { globals = SenseFakes.Globals() })
		local message = expect.errors(function()
			Sight.new({ Rnage = 10 } :: any)
		end)
		expect.includes(message, "[VluxyAI] Sight.new")
		expect.includes(message, "Rnage")
	end,

	["Destroy is safe to call"] = function(expect)
		local s = setup()
		s.sight:Destroy()
		expect.truthy(true)
	end,

	["Visibility scales the range per target and is written for the nearest"] = function(expect)
		local dark = SenseFakes.Part(Vector3.new(0, 0, -30))
		local lit = SenseFakes.Part(Vector3.new(3, 0, -35))
		local s = setup({
			sight = {
				Range = 40,
				Targets = SenseFakes.Targets({ dark, lit }),
				Visibility = function(_agent, target)
					return if target == lit then 1 else 0.5
				end,
			},
		})

		s.sight:Tick(s.agent, 0.1)
		expect.equal(#s.blackboard.SeenTargets, 1, "the dark one is out of its halved range")
		expect.equal(s.blackboard.SeenTarget, lit)
		expect.equal(s.blackboard.SeenVisibility, 1)

		s.blackboard.SeenTargets = nil
		local blind = setup({
			sight = {
				Targets = SenseFakes.Targets({ SenseFakes.Part(Vector3.new(0, 0, -5)) }),
				Visibility = function()
					return 0
				end,
			},
		})
		blind.sight:Tick(blind.agent, 0.1)
		expect.equal(blind.blackboard.SeenTarget, nil, "zero visibility is invisible")
		expect.equal(blind.blackboard.SeenVisibility, 0)
	end,

	["without Visibility every seen target has visibility 1"] = function(expect)
		local s = setup({ sight = { Targets = SenseFakes.Targets({ SenseFakes.Part(Vector3.new(0, 0, -10)) }) } })
		s.sight:Tick(s.agent, 0.1)
		expect.equal(s.blackboard.SeenVisibility, 1)
	end,

	["SeeThrough lets the ray look past glass but not past a wall"] = function(expect)
		local glass = { Name = "Window", Transparency = 0.6 }
		local wall = { Name = "Wall", Transparency = 0 }
		local target = SenseFakes.Part(Vector3.new(0, 0, -10))
		local function blockedBy(part)
			return function(ray)
				if table.find(ray.Params.FilterDescendantsInstances, part) then
					return nil
				end
				return {
					Instance = setmetatable(
						part,
						{ __index = {
							IsDescendantOf = function()
								return false
							end,
						} }
					),
				}
			end
		end

		local seesGlass = setup({
			sight = {
				Targets = SenseFakes.Targets({ target }),
				SeeThrough = function(part)
					return part.Transparency >= 0.5
				end,
			},
			hit = blockedBy(glass),
		})
		seesGlass.sight:Tick(seesGlass.agent, 0.1)
		expect.equal(seesGlass.blackboard.SeenTarget, target, "glass does not block")

		local wallStops = setup({
			sight = {
				Targets = SenseFakes.Targets({ target }),
				SeeThrough = function(part)
					return part.Transparency >= 0.5
				end,
			},
			hit = blockedBy(wall),
		})
		wallStops.sight:Tick(wallStops.agent, 0.1)
		expect.equal(wallStops.blackboard.SeenTarget, nil, "a wall still blocks")
	end,
}
