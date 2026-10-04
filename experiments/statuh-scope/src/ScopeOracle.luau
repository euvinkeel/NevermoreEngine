--!strict
--[[
	The reference semantics of scope, computed from scratch with no caching or indexes. Tests compare
	the incremental core against it every frame, and use it to check the monotonicity property.

	It reads rule applicability from the world as it is now, so tests that use it must not add or
	remove a rule's `appliesTo` component after an entity starts replicating (the core latches rules
	at that point).
]]

local StatuhScope = require("./StatuhScope")

local ScopeOracle = {}

export type ViewerScope = {
	auth: { [number]: boolean },
	rel: { [number]: boolean },
	owner: { [number]: boolean },
}

-- Returns viewer index -> scope sets, for every connected viewer.
function ScopeOracle.compute(
	jecs: any,
	world: any,
	scope: any,
	rules: { [string]: any },
	maxDepth: number?
): { [number]: ViewerScope }
	local Net = scope.Net
	local maxInheritDepth = maxDepth or 8
	local viewers = scope.viewerList()

	local result: { [number]: ViewerScope } = {}
	for index in viewers do
		result[index] = { auth = {}, rel = {}, owner = {} }
	end

	local function targets(entity: number, relation: number): { number }
		local list = {}
		local i = 0
		while true do
			local target = world:target(entity, relation, i)
			if target == nil then
				break
			end
			table.insert(list, target)
			i += 1
		end
		return list
	end

	local function isMember(viewerEntity: number, room: number): boolean
		return world:has(viewerEntity, jecs.pair(Net.Member, room))
	end

	-- Memoized per (entity, viewer) to keep it simple: returns auth, rel, depth.
	local memo: { [number]: { [number]: { auth: boolean, rel: boolean, depth: number } } } = {}
	local visiting: { [number]: boolean } = {}

	local function evaluate(entity: number, index: number): (boolean, boolean, number)
		local cached = memo[entity] and memo[entity][index]
		if cached then
			return cached.auth, cached.rel, cached.depth
		end
		local viewerEntity = viewers[index].entity
		local owners = targets(entity, Net.Owner)
		local isOwner = table.find(owners, viewerEntity) ~= nil

		local auth = false
		local rel = true
		local depth = 0

		local through = world:target(entity, Net.VisibleThrough, 0)
		if through ~= nil then
			local parent = world:target(entity, through, 0)
			local ok = false
			if parent ~= nil and world:has(parent, Net.Replicated) and not visiting[parent] then
				visiting[entity] = true
				local parentAuth, parentRel, parentDepth = evaluate(parent, index)
				visiting[entity] = nil
				depth = parentDepth + 1
				if depth <= maxInheritDepth and not (parentDepth > maxInheritDepth) then
					auth = parentAuth
					rel = parentRel
					ok = true
				end
			end
			if not ok then
				depth = maxInheritDepth + 1
			end
		end

		if world:has(entity, Net.Public) then
			auth = true
		else
			for _, room in targets(entity, Net.Audience) do
				if isMember(viewerEntity, room) then
					auth = true
				end
			end
			if isOwner then
				auth = true
			end
		end

		-- Restrictions apply after every grant (including grant rules below).
		local restricted = true
		if world:has(entity, Net.VisibleTo) then
			local value = world:get(entity, Net.VisibleTo)
			if value == "owner" then
				restricted = isOwner
			elseif type(value) == "number" then
				restricted = isMember(viewerEntity, value)
			else
				restricted = false
			end
		end

		for _, rule in rules do
			if world:has(entity, rule.appliesTo) then
				local key = rule.key(entity)
				local passes = key ~= nil and rule.viewerKeys(viewerEntity)[key] == true
				if rule.mode == "relevance" then
					rel = rel and passes
				elseif rule.mode == "restrict" then
					restricted = restricted and passes
				else
					auth = auth or passes
				end
			end
		end
		auth = auth and restricted

		memo[entity] = memo[entity] or {}
		memo[entity][index] = { auth = auth, rel = rel, depth = depth }
		return auth, rel, depth
	end

	for entity in world:query(Net.Replicated) do
		local owners = targets(entity, Net.Owner)
		for index, viewer in viewers do
			local auth, rel = evaluate(entity, index)
			if auth then
				result[index].auth[entity] = true
			end
			if rel then
				result[index].rel[entity] = true
			end
			if table.find(owners, viewer.entity) then
				result[index].owner[entity] = true
			end
		end
	end
	return result
end

-- True when every (entity, viewer) visible in `after` was visible in `before`.
function ScopeOracle.isSubset(after: { [number]: ViewerScope }, before: { [number]: ViewerScope }): (boolean, string?)
	for index, scope in after do
		local was = before[index]
		for entity in scope.auth do
			if scope.rel[entity] and not (was and was.auth[entity] and was.rel[entity]) then
				return false, `entity {entity} became visible to viewer {index}`
			end
		end
	end
	return true, nil
end

return ScopeOracle
