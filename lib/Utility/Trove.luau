--!strict

--[[
	The one place the package reaches outside itself. Wally installs a dependency as a sibling of
	the package folder under the alias in wally.toml, so from here it is three parents up. The test
	place mounts the package and Trove side by side under ReplicatedStorage.Packages to match.
]]

local Trove = require(script.Parent.Parent.Parent.Trove)

export type Trove = Trove.Trove

return Trove
