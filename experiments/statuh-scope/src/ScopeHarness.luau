--!strict
--[[
	Drives a StatuhScope with one ClientReplica per connected player and checks invariants after
	every frame. Tests build a world through it, edit the world, then call `step()`.

	Invariants checked every step (each failure says which one):
	1. The protocol: replicas apply every frame without error (see ClientReplica).
	2. Engine scope equals ScopeOracle's from-scratch answer, for every entity and viewer.
	3. No message mentions a net id the receiver isn't authorized for (except LEAVE/DEL/ROLLBACK).
	4. Each replica equals the projection of the server world onto its delivered scope, with each
	   component's own visibility ("all", "owner", or a rule) computed from scratch.
	5. Delivered scope equals authorization: nothing unauthorized is held, and everything authorized
	   is delivered (or pending, under a budget).
	6. LEAVE only for entities still alive, DEL only for entities that are gone; likewise HIDE only
	   for components that still exist, REM only for components that are gone.
	7. Inheritance groups enter whole: if a parent enters, its in-scope inheritors enter that frame.
]]

local ClientReplica = require("./ClientReplica")
local Jecs = require("./Jecs")
local ScopeOracle = require("./ScopeOracle")
local StatuhScope = require("./StatuhScope")

local REDACTED = StatuhScope.REDACTED

local ScopeHarness = {}
ScopeHarness.__index = ScopeHarness

export type Options = {
	enterBudget: number?,
	-- Skip the oracle comparison (for scenarios using minted entities, which the oracle can't see).
	skipOracle: boolean?,
}

function ScopeHarness.new(options: Options?)
	local opts: Options = options or {}
	local world = Jecs.world()
	local self = setmetatable({}, ScopeHarness) :: any
	self.jecs = Jecs
	self.world = world
	self.options = opts
	self.scope = StatuhScope.new(Jecs, world, {
		enterBudget = opts.enterBudget,
	})
	self.Net = self.scope.Net
	self.rules = {} :: { [string]: any }
	self.refFields = {} :: { [number]: any }
	self.replicas = {} :: { [number]: any } -- viewer index -> ClientReplica
	self.entityOfNet = {} :: { [number]: number } -- every net id ever seen -> entity
	self.frames = 0
	self.lastMessages = {} :: { [number]: { { any } } }
	return self
end

function ScopeHarness.replicate(self: any, component: number, options: any?): number
	local key = self.scope.replicate(component, options)
	if options and options.isRef then
		self.refFields[key] = true
	elseif options and options.refFields then
		self.refFields[key] = options.refFields
	end
	return key
end

function ScopeHarness.addRule(self: any, name: string, rule: any)
	self.rules[name] = rule
	self.scope.addScopeRule(name, rule)
end

function ScopeHarness.connect(self: any, player: number): number
	local index = self.scope.addViewer(player)
	self.replicas[index] = ClientReplica.new(self.refFields)
	return index
end

function ScopeHarness.disconnect(self: any, player: number)
	local index = self.scope.viewerIndexOf(player)
	self.scope.removeViewer(player)
	self.replicas[index] = nil
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

local function fail(self: any, invariant: string, detail: string)
	error(`[frame {self.frames}] invariant {invariant}: {detail}`, 0)
end

function ScopeHarness.step(self: any)
	local world = self.world
	local scope = self.scope
	local Net = self.Net

	-- Record net ids before the frame, so DELs of entities removed since can be looked up.
	for entity in world:query(Net.Replicated) do
		local netId = scope.netIdOf(entity)
		if netId then
			self.entityOfNet[netId] = entity
		end
	end
	local deliveredBefore: { [number]: { [number]: boolean } } = {}
	for index in self.replicas do
		deliveredBefore[index] = scope.deliveredTo(index)
	end

	local frames = scope.frame()
	self.frames += 1
	self.lastMessages = frames
	for entity in world:query(Net.Replicated) do
		local netId = scope.netIdOf(entity)
		if netId then
			self.entityOfNet[netId] = entity
		end
	end

	local oracle = if self.options.skipOracle then nil else ScopeOracle.compute(Jecs, world, scope, self.rules)

	-- 1 and 3: protocol, and what goes on the wire.
	for index, replica in self.replicas do
		local messages = frames[index]
		local ok, err = pcall(replica.apply, replica, messages)
		if not ok then
			fail(self, "1 (protocol)", `viewer {index}: {err}`)
		end
		if oracle then
			local auth = oracle[index].auth
			local function checkMention(netId: any, message: { any })
				if netId == REDACTED or netId == nil then
					return
				end
				local entity = self.entityOfNet[netId]
				if entity == nil or not auth[entity] then
					fail(self, "3 (out-of-scope id on the wire)", `viewer {index} got net id {netId} in {message[1]}`)
				end
			end
			for _, message in messages or {} do
				local kind = message[1]
				if kind == "LEAVE" or kind == "DEL" or kind == "ROLLBACK" then
					local entity = self.entityOfNet[message[2]]
					-- 6: LEAVE vs DEL.
					if kind == "LEAVE" and (entity == nil or not world:contains(entity)) then
						fail(self, "6 (LEAVE vs DEL)", `LEAVE for net id {message[2]}, which was destroyed`)
					elseif
						kind == "DEL"
						and entity ~= nil
						and world:contains(entity)
						and world:has(entity, Net.Replicated)
					then
						fail(self, "6 (LEAVE vs DEL)", `DEL for net id {message[2]}, which still exists`)
					end
				else
					checkMention(message[2], message)
					if kind == "PAIR_ADD" or kind == "PAIR_REM" then
						checkMention(message[4], message)
					elseif kind == "HIDE" or kind == "REM" then
						-- 6: HIDE vs REM.
						local entity = self.entityOfNet[message[2]]
						local info = scope.replicatedComponents()[message[3]]
						local present = entity ~= nil and world:contains(entity) and world:has(entity, info.component)
						if kind == "HIDE" and not present then
							fail(
								self,
								"6 (HIDE vs REM)",
								`HIDE for net id {message[2]} key {message[3]}, which is gone`
							)
						elseif kind == "REM" and present then
							fail(self, "6 (HIDE vs REM)", `REM for net id {message[2]} key {message[3]}, which exists`)
						end
					elseif kind == "ENTER" then
						for key, value in message[3] do
							local spec = self.refFields[key]
							if spec == true then
								checkMention(value, message)
							elseif spec and type(value) == "table" then
								for _, field in spec do
									checkMention(value[field], message)
								end
							end
						end
					elseif kind == "SET" then
						local spec = self.refFields[message[3]]
						if spec == true then
							checkMention(message[4], message)
						elseif spec and type(message[4]) == "table" then
							for _, field in spec do
								checkMention(message[4][field], message)
							end
						end
					end
				end
			end
		end
	end

	-- 2: engine scope equals the oracle.
	if oracle then
		for entity in world:query(Net.Replicated) do
			local authLo, authHi = scope.scopeBits(entity)
			for index in self.replicas do
				local engineAuth = StatuhScope.hasBit(authLo, authHi, index)
				if engineAuth ~= (oracle[index].auth[entity] == true) then
					fail(self, "2 (engine vs oracle)", `entity {entity} viewer {index}: auth engine={engineAuth}`)
				end
			end
		end
	end

	-- 4, 5, 7.
	for index, replica in self.replicas do
		local delivered = scope.deliveredTo(index)
		local projection = {}
		local viewerEntity = scope.viewerList()[index].entity
		for entity in delivered do
			local comps = {}
			for _, info in scope.replicatedComponents() do
				if
					world:has(entity, info.component)
					and ScopeOracle.componentVisible(world, scope, self.rules, info, entity, viewerEntity)
				then
					local value = world:get(entity, info.component)
					local function wire(ref: any): any
						if ref == nil then
							return nil
						end
						if delivered[ref] then
							return scope.netIdOf(ref)
						end
						return REDACTED
					end
					if info.isRef then
						value = wire(value)
					elseif info.refFields and type(value) == "table" then
						value = table.clone(value)
						for _, field in info.refFields do
							if value[field] ~= nil then
								value[field] = wire(value[field])
							end
						end
					end
					comps[info.key] = value
				end
			end
			local pairs = {}
			for key, relation in scope.relationList() do
				local j = 0
				while true do
					local target = world:target(entity, relation, j)
					if target == nil then
						break
					end
					if delivered[target] then
						pairs[key] = pairs[key] or {}
						pairs[key][scope.netIdOf(target)] = true
					end
					j += 1
				end
			end
			projection[scope.netIdOf(entity)] = { comps = comps, pairs = pairs }
		end
		local difference = replica:compareWithProjection(projection)
		if difference then
			local netId = tonumber(string.match(difference, "net id (%d+)"))
			local entity = if netId then self.entityOfNet[netId] else nil
			local context = ""
			if entity then
				local holders = {}
				for other in scope.deliveredTo(index) do
					if scope.netIdOf(other) == netId then
						table.insert(holders, tostring(other))
					end
				end
				context =
					` (entity {entity}, alive={world:contains(entity)}, replicated={world:contains(entity) and world:has(
						entity,
						Net.Replicated
					)}, current net id {scope.netIdOf(entity)}, delivered holders of that id: {table.concat(
						holders,
						","
					)})`
			end
			fail(self, "4 (replica vs projection)", `viewer {index}: {difference}{context}`)
		end

		if oracle then
			local auth = oracle[index].auth
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
				if not delivered[entity] then
					if self.options.enterBudget == nil or not scope.isPendingEnter(entity, index) then
						fail(self, "5 (in scope means delivered)", `viewer {index} is missing in-scope entity {entity}`)
					end
				end
			end

			-- 7: groups enter whole.
			local enteredNow: { [number]: boolean } = {}
			for _, message in frames[index] or {} do
				if message[1] == "ENTER" then
					enteredNow[self.entityOfNet[message[2]]] = true
				end
			end
			for parent in enteredNow do
				for child in world:query(Net.Replicated) do
					if world:target(child, Net.VisibleThrough, 0) == parent then
						if auth[child] and not deliveredBefore[index][child] and not enteredNow[child] then
							fail(
								self,
								"7 (groups enter whole)",
								`viewer {index}: parent {parent} entered without child {child}`
							)
						end
					end
				end
			end
		end
	end
	return frames
end

-- Has `player`'s replica got this entity, and what kind was its last removal?
function ScopeHarness.sees(self: any, player: number, entity: number): boolean
	local netId = self.scope.netIdOf(entity)
	local replica = self:replicaOf(player)
	return netId ~= nil and replica.entities[netId] ~= nil
end

-- The kind ("HIDE" or "REM") of the last time `player` lost component `key` of `entity`.
function ScopeHarness.lastComponentRemoval(self: any, player: number, entity: number, key: number): string?
	local netId = self.scope.netIdOf(entity)
	local replica = self:replicaOf(player)
	for i = #replica.componentRemovals, 1, -1 do
		local removal = replica.componentRemovals[i]
		if removal.netId == netId and removal.key == key then
			return removal.kind
		end
	end
	return nil
end

function ScopeHarness.lastRemoval(self: any, player: number, netId: number): string?
	local replica = self:replicaOf(player)
	for i = #replica.removals, 1, -1 do
		if replica.removals[i].netId == netId then
			return replica.removals[i].kind
		end
	end
	return nil
end

return ScopeHarness
