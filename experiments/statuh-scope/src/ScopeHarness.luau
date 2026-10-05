--!strict
--[[
	Drives a StatuhScope with one ClientReplica per connected player and checks invariants after
	every frame. Tests build a world through it, edit the world, then call `step()`.

	Invariants checked every step (each failure says which one):
	0. jecs's own bookkeeping is consistent (JecsWorkarounds.checkIntegrity). The engine and the
	   oracle both read the world, so damage to it would get past every other check.
	1. The protocol: replicas apply every frame without error (see ClientReplica).
	2. Engine scope equals ScopeOracle's from-scratch answer, for every entity and viewer.
	3. No message mentions a net id the receiver isn't authorized for (except LEAVE/DEL/ROLLBACK).
	4. Each replica equals the projection of the server world onto its delivered scope, with each
	   component's own visibility computed from scratch.
	5. Delivered scope equals authorization: nothing unauthorized is held, and everything authorized
	   is delivered (or pending, under a budget).
	6. LEAVE only for entities still alive, DEL only for entities that are gone; likewise HIDE only
	   for components that still exist, REM only for components that are gone.
	7. Inheritance groups enter whole: if a parent enters, its in-scope inheritors enter that frame.
]]

local ClientReplica = require("./ClientReplica")
local Jecs = require("./Jecs")
local JecsWorkarounds = require("../../jecs-findings/JecsWorkarounds")
local ScopeOracle = require("./ScopeOracle")
local StatuhScope = require("./StatuhScope")

local REDACTED = StatuhScope.REDACTED
local mapRefs = StatuhScope.mapRefs

local ScopeHarness = {}
ScopeHarness.__index = ScopeHarness

export type Options = {
	enterBudget: number?,
	-- Skip the oracle comparison (for scenarios using minted entities, which the oracle can't see).
	skipOracle: boolean?,
}

function ScopeHarness.new(options: Options?)
	local self = setmetatable({}, ScopeHarness) :: any
	self.options = options or {}
	self.jecs = Jecs
	self.world = Jecs.world()
	self.scope = StatuhScope.new(Jecs, self.world, { enterBudget = self.options.enterBudget })
	self.Net = self.scope.Net
	self.replicas = {} :: { [number]: any } -- viewer index -> ClientReplica
	self.entityOfNet = {} :: { [number]: number } -- every net id ever seen -> entity
	self.lastMessages = {} :: { [number]: { { any } } }
	self.frames = 0
	return self
end

-- A new entity with these component values and tags (or pairs), replicated unless told otherwise.
function ScopeHarness.spawn(self: any, values: { [number]: any }?, tags: { number }?, replicated: boolean?): number
	local entity = self.world:entity()
	for component, value in values or {} :: { [number]: any } do
		self.world:set(entity, component, value)
	end
	for _, tag in tags or {} :: { number } do
		self.world:add(entity, tag)
	end
	if replicated ~= false then
		self.world:add(entity, self.Net.Replicated)
	end
	return entity
end

function ScopeHarness.connect(self: any, player: number): number
	local index = self.scope.addViewer(player)
	self.replicas[index] = ClientReplica.new(self.scope.replicatedComponents())
	return index
end

function ScopeHarness.disconnect(self: any, player: number)
	self.replicas[self.scope.viewerIndexOf(player)] = nil
	self.scope.removeViewer(player)
end

function ScopeHarness.replicaOf(self: any, player: number): any
	return self.replicas[self.scope.viewerIndexOf(player)]
end

function ScopeHarness.netId(self: any, entity: number): number?
	return self.scope.netIdOf(entity)
end

-- The messages `player` received in the last step.
function ScopeHarness.messagesFor(self: any, player: number): { { any } }
	return self.lastMessages[self.scope.viewerIndexOf(player)] or {}
end

-- Has `player`'s replica got this entity?
function ScopeHarness.sees(self: any, player: number, entity: number): boolean
	local netId = self.scope.netIdOf(entity)
	return netId ~= nil and self:replicaOf(player).entities[netId] ~= nil
end

-- The kind of the last removal `player` got for net id `netId` (LEAVE, DEL, ROLLBACK), or for
-- its component `key` (HIDE, REM).
function ScopeHarness.lastRemoval(self: any, player: number, netId: number, key: number?): string?
	return self:replicaOf(player):lastRemoval(netId, key)
end

local function fail(self: any, invariant: string, detail: string)
	error(`[frame {self.frames}] invariant {invariant}: {detail}`, 0)
end

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

function ScopeHarness.step(self: any)
	local world, scope, Net = self.world, self.scope, self.Net
	local damage = JecsWorkarounds.checkIntegrity(world)
	if damage then
		fail(self, "0 (jecs integrity)", damage)
	end

	-- Net ids are recorded before the frame too, so DELs of entities removed since can be looked up.
	local function recordNetIds()
		for entity in world:query(Net.Replicated) do
			self.entityOfNet[scope.netIdOf(entity)] = entity
		end
	end
	recordNetIds()
	local deliveredBefore = {}
	for index in self.replicas do
		deliveredBefore[index] = scope.deliveredTo(index)
	end
	local frames = scope.frame()
	self.frames += 1
	self.lastMessages = frames
	recordNetIds()

	local oracle = if self.options.skipOracle then nil else ScopeOracle.compute(world, scope)
	local components = scope.replicatedComponents()

	if oracle then -- 2: engine scope equals the oracle.
		for entity in world:query(Net.Replicated) do
			local lo, hi = scope.scopeBits(entity)
			for index in self.replicas do
				if StatuhScope.hasBit(lo, hi, index) ~= (oracle[index].auth[entity] == true) then
					fail(self, "2 (engine vs oracle)", `entity {entity} viewer {index}`)
				end
			end
		end
	end

	for index, replica in self.replicas do
		local messages = frames[index] or {}
		local ok, err = pcall(replica.apply, replica, messages)
		if not ok then
			fail(self, "1 (protocol)", `viewer {index}: {err}`)
		end
		local auth = oracle and oracle[index].auth
		local delivered = scope.deliveredTo(index)
		local enteredNow: { [number]: boolean } = {}

		for _, message in messages do
			local kind, netId, key = message[1], message[2], message[3]
			local entity = self.entityOfNet[netId]
			local alive = entity ~= nil and world:contains(entity)
			-- 6: LEAVE vs DEL, HIDE vs REM.
			if kind == "LEAVE" and not alive then
				fail(self, "6 (LEAVE vs DEL)", `LEAVE for net id {netId}, which was destroyed`)
			elseif kind == "DEL" and alive and world:has(entity, Net.Replicated) then
				fail(self, "6 (LEAVE vs DEL)", `DEL for net id {netId}, which still exists`)
			elseif
				(kind == "HIDE" or kind == "REM")
				and (kind == "HIDE") ~= (alive and world:has(entity, components[key].component))
			then
				fail(self, "6 (HIDE vs REM)", `{kind} for net id {netId} key {key}`)
			end
			-- 3: every net id it mentions is authorized.
			if auth and kind ~= "LEAVE" and kind ~= "DEL" and kind ~= "ROLLBACK" then
				local function check(id: any): any
					if id ~= REDACTED and not auth[self.entityOfNet[id] or -1] then
						fail(self, "3 (out-of-scope id on the wire)", `viewer {index} got net id {id} in {kind}`)
					end
					return id
				end
				check(netId)
				if kind == "PAIR_ADD" or kind == "PAIR_REM" then
					check(message[4])
				elseif kind == "SET" then
					mapRefs(components[key].refs, message[4], check)
				elseif kind == "ENTER" then
					enteredNow[entity] = true
					for k, value in message[3] do
						mapRefs(components[k].refs, value, check)
					end
				end
			end
		end

		-- 4: the replica equals the projection of the server world onto its delivered scope.
		local viewer = scope.viewerList()[index].entity
		local projection = {}
		for entity in delivered do
			local comps, pairs = {}, {}
			for _, info in components do
				if
					world:has(entity, info.component)
					and ScopeOracle.componentVisible(world, scope, info, entity, viewer)
				then
					comps[info.key] = mapRefs(info.refs, world:get(entity, info.component), function(ref)
						return if delivered[ref] then scope.netIdOf(ref) else REDACTED
					end)
				end
			end
			for key, relation in scope.relationList() do
				for _, target in targets(world, entity, relation) do
					if delivered[target] then
						pairs[key] = pairs[key] or {}
						pairs[key][scope.netIdOf(target)] = true
					end
				end
			end
			projection[scope.netIdOf(entity)] = { comps = comps, pairs = pairs }
		end
		local difference = replica:compareWithProjection(projection)
		if difference then
			fail(self, "4 (replica vs projection)", `viewer {index}: {difference}`)
		end

		if auth then
			-- 5: delivered scope equals authorization.
			for entity in delivered do
				if not auth[entity] then
					fail(
						self,
						"5 (delivered within authorization)",
						`viewer {index} holds unauthorized entity {entity}`
					)
				end
			end
			for entity in auth do
				local pending = self.options.enterBudget ~= nil and scope.isPendingEnter(entity, index)
				if not delivered[entity] and not pending then
					fail(self, "5 (in scope means delivered)", `viewer {index} is missing in-scope entity {entity}`)
				end
			end
			-- 7: groups enter whole.
			for child in if next(enteredNow) then world:query(Net.Replicated) else {} :: any do
				local parent = world:target(child, Net.VisibleThrough, 0)
				if
					parent
					and enteredNow[parent]
					and auth[child]
					and not deliveredBefore[index][child]
					and not enteredNow[child]
				then
					fail(
						self,
						"7 (groups enter whole)",
						`viewer {index}: parent {parent} entered without child {child}`
					)
				end
			end
		end
	end
	return frames
end

return ScopeHarness
