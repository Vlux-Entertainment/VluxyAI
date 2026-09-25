--!strict

--[[
	Resolves an options table against its defaults, so every constructor in the package behaves
	the same way: unknown keys are errors (a typo like `Speeed` would otherwise silently do
	nothing), given keys override defaults, and the result is a fresh table the caller owns.
	Pure.
]]

local FormatMessage = require(script.Parent.FormatMessage)
local Tables = require(script.Parent.Tables)

local Options = {}

--[[
	Returns a copy of `defaults` overlaid with `given`. `owner` names the constructor in the
	error, e.g. `Sight.new`. `allowed` lists keys that have no default (an optional callback) but
	are still valid.
]]
function Options.Resolve<T>(owner: string, defaults: T, given: { [string]: any }?, allowed: { string }?): T
	local resolved = table.clone(defaults :: any) :: { [string]: any }

	if given ~= nil then
		if type(given) ~= "table" then
			FormatMessage.Error(`{owner}: options must be a table, got a {typeof(given)}`, 3)
		end

		for key, value in given do
			local known = type(key) == "string"
				and ((defaults :: any)[key] ~= nil or (allowed ~= nil and table.find(allowed, key) ~= nil))
			if not known then
				local names = Tables.SortedKeys(defaults :: any)
				if allowed then
					for _, extra in allowed do
						table.insert(names, extra)
					end
				end
				table.sort(names)
				FormatMessage.Error(
					`{owner}: unknown option "{tostring(key)}"; expected one of {table.concat(names, ", ")}`,
					3
				)
			end

			resolved[key] = value
		end
	end

	return resolved :: any
end

return Options
