--!nonstrict
local task = require("@lune/task")
local env = getfenv(0)
local proxy = function() return setmetatable({}, { __index = function() return function() end end }) end
env.game = { GetService = function(_, name) return setmetatable({ Name = name }, { __index = function() return function() end end }) end }
env.task = task
env.warn = function(...) print("[warn]", ...) end
env.debug = setmetatable({ profilebegin = function() end, profileend = function() end }, { __index = debug })
return true
