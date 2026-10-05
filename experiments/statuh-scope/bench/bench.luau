--[[
	Per-frame cost of the scope core: 50 players x 2,000 entities, 10% of entities dirty per frame.

	lune run experiments/statuh-scope/bench/bench.luau [frames]

	jecs and StatuhScope are loaded with `luau.load(..., { codegenEnabled = true })` and their default
	environment (no injected globals), so builtins keep their fast paths. The test runner's
	per-module environments would make this several times slower.

	World: two team rooms of 25 players; 40% of entities public, 40% team-only, 10% owned by a
	player (owner-only component), 10% inheriting from a parent through ChildOf. Every entity has a
	cell under a camera rule (a restrict rule: 3x3 chunks around the player's camera). Each frame, 100
	entities change Health, 100 move to another cell, and 5 players move their camera, either by
	one chunk (pan, realistic) or to a random cell (teleport, worst case: 18 chunk keys change).
	The last case has no camera rule on entities; instead the Cell component itself goes only to
	players whose camera is near (component visibility, like positions in an arena).
]]
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")

local ROOT = "experiments/statuh-scope"

local function loadModule(path: string, ...: any): any
	local chunk = luau.load(fs.readFile(path), { debugName = "@" .. path, codegenEnabled = true })
	return chunk(...)
end

local jecs = loadModule("src/jecs/node_modules/@quentystudios/jecs/src/jecs.luau")
local StatuhScope = loadModule(ROOT .. "/src/StatuhScope.luau")

local FRAMES = tonumber(process.args[1]) or 300
local PLAYERS = 50
local ENTITIES = 2000
local GRID = 64 -- cells per side
local CHUNK = 8

local function run(
	label: string,
	options: { rules: boolean, budget: number?, smoothCamera: boolean?, nearCell: boolean? }
)
	local world = jecs.world()
	local scope = StatuhScope.new(jecs, world, { enterBudget = options.budget })
	local Net = scope.Net
	local Health = world:component()
	local Secret = world:component()
	local Cell = world:component()
	local Camera = world:component()
	local Spatial = world:component()

	local function chunkOf(e)
		local cell = world:get(e, Cell)
		return if cell then (cell // GRID // CHUNK) * 64 + (cell % GRID // CHUNK) else nil
	end
	local function chunksAroundCamera(p)
		local cell = world:get(p, Camera) or 0
		local cy, cx = cell // GRID // CHUNK, cell % GRID // CHUNK
		local keys = {}
		for dy = -1, 1 do
			for dx = -1, 1 do
				keys[(cy + dy) * 64 + (cx + dx)] = true
			end
		end
		return keys
	end
	if options.rules then
		scope.addScopeRule("camera", {
			mode = "restrict",
			appliesTo = Spatial,
			dependsOn = { Cell },
			viewerDependsOn = { Camera },
			key = chunkOf,
			viewerKeys = chunksAroundCamera,
		})
	end
	if options.nearCell then
		scope.addScopeRule("near", {
			mode = "restrict",
			dependsOn = { Cell },
			viewerDependsOn = { Camera },
			key = chunkOf,
			viewerKeys = chunksAroundCamera,
		})
	end

	scope.replicate(Health)
	scope.replicate(Secret, { visibleTo = "owner" })
	scope.replicate(Cell, { visibleTo = if options.nearCell then "near" else "all" })
	scope.replicateRelation(jecs.ChildOf)

	local seed = 12345
	local function rand(n: number): number
		seed = (seed * 1103515245 + 12345) % 2147483648
		return seed % n
	end

	local rooms = { world:entity(), world:entity() }
	local players = {}
	for i = 1, PLAYERS do
		local p = world:entity()
		world:set(p, Camera, rand(GRID * GRID))
		world:add(p, jecs.pair(Net.Member, rooms[1 + i % 2]))
		table.insert(players, p)
	end

	local entities = {}
	for i = 1, ENTITIES do
		local e = world:entity()
		world:set(e, Health, 100)
		world:set(e, Cell, rand(GRID * GRID))
		if options.rules then
			world:add(e, Spatial)
		end
		local roll = rand(10)
		if roll < 4 then
			world:add(e, Net.Public)
		elseif roll < 8 then
			world:add(e, jecs.pair(Net.Audience, rooms[1 + rand(2)]))
		elseif roll < 9 then
			world:add(e, jecs.pair(Net.Owner, players[1 + rand(PLAYERS)]))
			world:set(e, Secret, { gold = rand(1000) })
		elseif #entities > 0 then
			local parent = entities[1 + rand(#entities)]
			world:add(e, jecs.pair(jecs.ChildOf, parent))
			world:add(e, jecs.pair(Net.VisibleThrough, parent))
		end
		world:add(e, Net.Replicated)
		table.insert(entities, e)
	end

	-- Join: every player connects, then the first frame ENTERs everything (or budgets it).
	local t0 = os.clock()
	for _, p in players do
		scope.addViewer(p)
	end
	local joinOut = scope.frame()
	local joinMs = (os.clock() - t0) * 1000
	local joinEnters = 0
	for _, list in joinOut do
		for _, message in list do
			joinEnters += if message[1] == "ENTER" then 1 else 0
		end
	end

	local times = {}
	local messages = 0
	for _ = 1, FRAMES do
		for _ = 1, 100 do
			world:set(entities[1 + rand(ENTITIES)], Health, rand(100))
		end
		for _ = 1, 100 do
			world:set(entities[1 + rand(ENTITIES)], Cell, rand(GRID * GRID))
		end
		for _ = 1, 5 do
			local p = players[1 + rand(PLAYERS)]
			if options.smoothCamera then
				-- Pan one chunk in some direction, like a real camera.
				local cell = world:get(p, Camera)
				local x, y = cell % GRID, cell // GRID
				local dir = rand(4)
				if dir == 0 then
					x = math.min(GRID - 1, x + CHUNK)
				elseif dir == 1 then
					x = math.max(0, x - CHUNK)
				elseif dir == 2 then
					y = math.min(GRID - 1, y + CHUNK)
				else
					y = math.max(0, y - CHUNK)
				end
				world:set(p, Camera, y * GRID + x)
			else
				world:set(p, Camera, rand(GRID * GRID))
			end
		end
		local start = os.clock()
		local out = scope.frame()
		table.insert(times, (os.clock() - start) * 1000)
		for _, list in out do
			messages += #list
		end
	end
	table.sort(times)
	local sum = 0
	for _, t in times do
		sum += t
	end
	print(
		string.format(
			"%-34s join %7.1f ms (%d ENTERs) | per frame: avg %.2f ms, p50 %.2f, p95 %.2f, max %.2f | %.0f messages/frame",
			label,
			joinMs,
			joinEnters,
			sum / #times,
			times[math.ceil(#times * 0.5)],
			times[math.ceil(#times * 0.95)],
			times[#times],
			messages / FRAMES
		)
	)
end

print(`StatuhScope bench: {PLAYERS} players, {ENTITIES} entities, 10% dirty per frame, {FRAMES} frames (codegen on)`)
run("teams + public + owner + inherit", { rules = false })
run("... + camera rule, cameras pan", { rules = true, smoothCamera = true })
run("... + camera rule, cameras teleport", { rules = true })
run("... + ENTER budget 64/frame (teleport)", { rules = true, budget = 64 })
run("no camera rule; Cell near-only, pan", { rules = false, smoothCamera = true, nearCell = true })
