--!strict
--[[
	The reference semantics of scope, computed from scratch with no caching or indexes. Tests compare
	the incremental core against it every frame, and use it to check the monotonicity property.

	It reads rule applicability from the world as it is now, so tests that use it must not add or
	remove a rule's `appliesTo` component after an entity starts replicating (the core latches rules
	at that point).
]]

local ScopeOracle = {}

export type ViewerScope = {
	auth: { [number]: boolean },
	owner: { [number]: boolean },
	-- Component key -> entities whose component data this viewer may hold (restricted components
	-- only: authorized, present, and visible).
	comps: { [number]: { [number]: boolean } },
}

-- Whether a client (by its player entity) may see `info` on `entity`, given it has the entity.
function ScopeOracle.componentVisible(
	world: any,
	scope: any,
	rules: { [string]: any },
	info: any,
	entity: number,
	viewerEntity: number
): boolean
	if info.visibleTo == "all" then
		return true
	elseif info.visibleTo == "owner" then
		local i = 0
		while true do
			local owner = world:target(entity, scope.Net.Owner, i)
			if owner == nil then
				return false
			end
			if owner == viewerEntity then
				return true
			end
			i += 1
		end
	end
	local rule = rules[info.visibleTo]
	local key = rule.key(entity)
	return key ~= nil and rule.viewerKeys(viewerEntity)[key] == true
end

-- Returns viewer index -> scope sets, for every connected viewer.
function ScopeOracle.compute(jecs: any, world: any, scope: any, rules: { [string]: any }): { [number]: ViewerScope }
	local Net = scope.Net
	local viewers = scope.viewerList()

	local result: { [number]: ViewerScope } = {}
	for index in viewers do
		result[index] = { auth = {}, owner = {}, comps = {} }
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

	-- What one entity says about itself for one viewer: its own grants (before inheritance) and its
	-- restrictions.
	local function own(entity: number, index: number): (boolean, boolean)
		local viewerEntity = viewers[index].entity
		local isOwner = table.find(targets(entity, Net.Owner), viewerEntity) ~= nil

		local granted = isOwner or world:has(entity, Net.Public)
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

		for _, rule in rules do
			if rule.appliesTo ~= nil and world:has(entity, rule.appliesTo) then
				local key = rule.key(entity)
				local passes = key ~= nil and rule.viewerKeys(viewerEntity)[key] == true
				if rule.mode == "restrict" then
					restricted = restricted and passes
				else
					granted = granted or passes
				end
			end
		end
		return granted, restricted
	end

	-- final(e) = (grants(e) or final(parent)) and restrictions(e), following pair(VisibleThrough,
	-- target) up from the entity until the chain ends, reaches an entity that isn't replicated, or
	-- comes back to one it already visited.
	local function evaluate(entity: number, index: number): boolean
		local chain = { entity }
		local visited = { [entity] = true }
		local current = entity
		while true do
			local parent = world:target(current, Net.VisibleThrough, 0)
			if parent == nil or visited[parent] or not world:has(parent, Net.Replicated) then
				break
			end
			table.insert(chain, parent)
			visited[parent] = true
			current = parent
		end
		local auth = false
		for i = #chain, 1, -1 do
			local granted, restricted = own(chain[i], index)
			auth = (granted or auth) and restricted
		end
		return auth
	end

	for entity in world:query(Net.Replicated) do
		local owners = targets(entity, Net.Owner)
		for index, viewer in viewers do
			if evaluate(entity, index) then
				result[index].auth[entity] = true
				for _, info in scope.replicatedComponents() do
					if
						info.visibleTo ~= "all"
						and world:has(entity, info.component)
						and ScopeOracle.componentVisible(world, scope, rules, info, entity, viewer.entity)
					then
						local set = result[index].comps[info.key]
						if not set then
							set = {}
							result[index].comps[info.key] = set
						end
						set[entity] = true
					end
				end
			end
			if table.find(owners, viewer.entity) then
				result[index].owner[entity] = true
			end
		end
	end
	return result
end

-- True when every (entity, viewer) authorized in `after` was authorized in `before`, and the same
-- for every restricted component's data.
function ScopeOracle.isSubset(after: { [number]: ViewerScope }, before: { [number]: ViewerScope }): (boolean, string?)
	for index, scope in after do
		local was = before[index]
		for entity in scope.auth do
			if not (was and was.auth[entity]) then
				return false, `entity {entity} became authorized for viewer {index}`
			end
		end
		for key, entities in scope.comps do
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
