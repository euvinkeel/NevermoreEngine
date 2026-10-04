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

	-- final(e, n) = (grants(e) or final(parent, n - 1)) and restrictions(e), following VisibleThrough
	-- at most `maxInheritDepth` hops from the entity being evaluated. Relevance is
	-- relevanceRules(e) and relevance(parent, n - 1).
	local memo: { [string]: { auth: boolean, rel: boolean } } = {}

	local function evaluate(entity: number, index: number, budget: number): (boolean, boolean)
		local memoKey = `{entity}:{index}:{budget}`
		local cached = memo[memoKey]
		if cached then
			return cached.auth, cached.rel
		end
		local viewerEntity = viewers[index].entity
		local isOwner = table.find(targets(entity, Net.Owner), viewerEntity) ~= nil

		local inheritedAuth, inheritedRel = false, true
		local through = world:target(entity, Net.VisibleThrough, 0)
		if through ~= nil and budget > 0 and world:has(through, jecs.Exclusive) then
			local parent = world:target(entity, through, 0)
			if parent ~= nil and world:has(parent, Net.Replicated) then
				inheritedAuth, inheritedRel = evaluate(parent, index, budget - 1)
			end
		end

		local granted = inheritedAuth or isOwner or world:has(entity, Net.Public)
		for _, room in targets(entity, Net.Audience) do
			if isMember(viewerEntity, room) then
				granted = true
			end
		end

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

		local rel = inheritedRel
		for _, rule in rules do
			if world:has(entity, rule.appliesTo) then
				local key = rule.key(entity)
				local passes = key ~= nil and rule.viewerKeys(viewerEntity)[key] == true
				if rule.mode == "relevance" then
					rel = rel and passes
				elseif rule.mode == "restrict" then
					restricted = restricted and passes
				else
					granted = granted or passes
				end
			end
		end

		local auth = granted and restricted
		memo[memoKey] = { auth = auth, rel = rel }
		return auth, rel
	end

	for entity in world:query(Net.Replicated) do
		local owners = targets(entity, Net.Owner)
		for index, viewer in viewers do
			local auth, rel = evaluate(entity, index, maxInheritDepth)
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

-- True when every (entity, viewer) authorized in `after` was authorized in `before`. Relevance is
-- interest management, not a security boundary, so it isn't part of this check.
function ScopeOracle.isSubset(after: { [number]: ViewerScope }, before: { [number]: ViewerScope }): (boolean, string?)
	for index, scope in after do
		local was = before[index]
		for entity in scope.auth do
			if not (was and was.auth[entity]) then
				return false, `entity {entity} became authorized for viewer {index}`
			end
		end
	end
	return true, nil
end

return ScopeOracle
