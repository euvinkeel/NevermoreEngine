--!strict
--[[
	The reference semantics of scope, computed from scratch with no caching or indexes. Tests compare
	the incremental core against it every frame, and use it to check that removing a constraint
	never widens visibility.

	It reads rule applicability from the world as it is now, so tests that use it must not add or
	remove a rule's `appliesTo` component after an entity starts replicating (the core latches rules
	at that point).
]]

local ScopeOracle = {}

export type ViewerScope = {
	auth: { [number]: boolean },
	-- Component key -> entities whose component this viewer may hold (only components whose
	-- visibility isn't "all": authorized, present, and visible).
	comps: { [number]: { [number]: boolean } },
}

local function targets(world: any, entity: number, relation: number): { number }
	local list = {}
	while true do
		local target = world:target(entity, relation, #list)
		if target == nil then
			return list
		end
		table.insert(list, target)
	end
end

-- Whether a viewer (by its player entity) holds a principal of the built-in space: itself or one
-- of its rooms. (Everyone, the third, is Net.Public, handled where it's granted.)
local function holds(world: any, Net: any, jecs: any, viewer: number, principals: { number }): boolean
	for _, principal in principals do
		if principal == viewer or world:has(viewer, jecs.pair(Net.Member, principal)) then
			return true
		end
	end
	return false
end

local function ruleHolds(rule: any, entity: number, viewer: number): boolean
	local key = rule.key(entity)
	return key ~= nil and rule.viewerKeys(viewer)[key] == true
end

-- Whether a client (by its player entity) may see `info` on `entity`, given it has the entity.
function ScopeOracle.componentVisible(world: any, scope: any, info: any, entity: number, viewer: number): boolean
	if info.visibleTo == "all" then
		return true
	elseif info.visibleTo == "owner" then
		return holds(world, scope.Net, scope.jecs, viewer, targets(world, entity, scope.Net.Owner))
	end
	return ruleHolds(scope.ruleList()[info.visibleTo], entity, viewer)
end

-- Returns viewer index -> scope sets, for every connected viewer.
function ScopeOracle.compute(world: any, scope: any): { [number]: ViewerScope }
	local Net, jecs = scope.Net, scope.jecs

	-- What one entity says about itself for one viewer: whether it grants itself to the viewer,
	-- and whether the viewer meets its needs.
	local function own(entity: number, viewer: number): (boolean, boolean)
		local owners = targets(world, entity, Net.Owner)
		local granted = world:has(entity, Net.Public)
			or holds(world, Net, jecs, viewer, owners)
			or holds(world, Net, jecs, viewer, targets(world, entity, Net.Audience))
		local allowed = true
		if world:has(entity, Net.VisibleTo) then
			local value = world:get(entity, Net.VisibleTo)
			local principals = if value == "owner" then owners elseif type(value) == "number" then { value } else {}
			allowed = holds(world, Net, jecs, viewer, principals)
		end
		for _, rule in scope.ruleList() do
			if rule.appliesTo ~= nil and world:has(entity, rule.appliesTo) then
				if rule.mode == "grant" then
					granted = granted or ruleHolds(rule, entity, viewer)
				else
					allowed = allowed and ruleHolds(rule, entity, viewer)
				end
			end
		end
		return granted, allowed
	end

	-- final(e) = (granted(e) or final(target)) and allowed(e), following pair(VisibleThrough,
	-- target) up from the entity until the chain ends, reaches an entity that isn't replicated, or
	-- comes back to one it already visited.
	local function visible(entity: number, viewer: number): boolean
		local chain = { entity }
		while true do
			local target = world:target(chain[#chain], Net.VisibleThrough, 0)
			if target == nil or table.find(chain, target) or not world:has(target, Net.Replicated) then
				break
			end
			table.insert(chain, target)
		end
		local result = false
		for i = #chain, 1, -1 do
			local granted, allowed = own(chain[i], viewer)
			result = (granted or result) and allowed
		end
		return result
	end

	local result: { [number]: ViewerScope } = {}
	for index, viewer in scope.viewerList() do
		local viewerScope: ViewerScope = { auth = {}, comps = {} }
		result[index] = viewerScope
		for entity in world:query(Net.Replicated) do
			if visible(entity, viewer.entity) then
				viewerScope.auth[entity] = true
				for _, info in scope.replicatedComponents() do
					if
						info.visibleTo ~= "all"
						and world:has(entity, info.component)
						and ScopeOracle.componentVisible(world, scope, info, entity, viewer.entity)
					then
						viewerScope.comps[info.key] = viewerScope.comps[info.key] or {}
						viewerScope.comps[info.key][entity] = true
					end
				end
			end
		end
	end
	return result
end

-- True when every (entity, viewer) authorized in `after` was authorized in `before`, and the same
-- for every restricted component's data.
function ScopeOracle.isSubset(after: { [number]: ViewerScope }, before: { [number]: ViewerScope }): (boolean, string?)
	for index, now in after do
		local was = before[index]
		for entity in now.auth do
			if not (was and was.auth[entity]) then
				return false, `entity {entity} became authorized for viewer {index}`
			end
		end
		for key, entities in now.comps do
			for entity in entities do
				if not (was and was.comps[key] and was.comps[key][entity]) then
					return false, `component {key} of entity {entity} became visible to viewer {index}`
				end
			end
		end
	end
	return true, nil
end

return ScopeOracle
