--!strict

--[[
	Every user-facing warning and error goes through here so it carries the library name. Pure:
	only `warn` and `error`.
]]

local PREFIX = "[VluxyAI] "

local FormatMessage = {}

--[[
	Returns the message with the library prefix.
]]
function FormatMessage.Format(message: string): string
	return PREFIX .. message
end

--[[
	Warns with the library prefix.
]]
function FormatMessage.Warn(message: string)
	warn(PREFIX .. message)
end

--[[
	Errors with the library prefix. `level` follows `error`'s convention; it defaults to 2, the
	caller of the function that raised.
]]
function FormatMessage.Error(message: string, level: number?): never
	error(PREFIX .. message, if level == nil then 2 else level)
end

return FormatMessage
