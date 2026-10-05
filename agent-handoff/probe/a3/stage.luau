-- usage: lune run stage <nevermore/src> <outdir>
local fs = require("@lune/fs")
local process = require("@lune/process")
local SRC, OUT = process.args[1], process.args[2]
local index: { [string]: string } = {}
local dups = 0
local function scan(dir: string)
	for _, e in fs.readDir(dir) do
		if e == "node_modules" or e == ".git" or e == "test" then continue end
		local p = dir .. "/" .. e
		if fs.isDir(p) then scan(p) else
			local name = string.match(e, "^(.+)%.luau?$")
			if name and not string.find(name, "%.") and name ~= "init" then
				if index[name] then dups += 1 else index[name] = p end
			end
		end
	end
end
scan(SRC)
if fs.isDir(OUT) then fs.removeDir(OUT) end
fs.writeDir(OUT)
local n, rewritten, unresolved, leftover = 0, 0, 0, 0
for name, path in index do
	local src = fs.readFile(path)
	src = string.gsub(src, "\nlocal require = require%(script%.Parent%.loader%)%.load%(script%)", "\n-- (loader line stripped)")
	src = string.gsub(src, 'require%("([%w_]+)"%)', function(m)
		if index[m] then rewritten += 1; return `require("./{m}")` else unresolved += 1; return nil end
	end)
	if string.find(src, "require%(script") or string.find(src, "require%(loader") then leftover += 1 end
	fs.writeFile(`{OUT}/{name}.luau`, src)
	n += 1
end
print(`staged {n} modules, {dups} duplicate names skipped, {rewritten} requires rewritten, {unresolved} unresolved (third-party/missing), {leftover} files with instance-path requires left`)
