--!strict
--[[
	A client's view of the replicated world, rebuilt only from the frames StatuhScope sends it. Applying
	a frame checks the protocol as it goes; `compareWithProjection` checks the result against what the
	server says this client should see.

	Protocol checks:
	- Messages come in phase order: ENTER, SET/HIDE/REM, PAIR_REM/PAIR_ADD, LEAVE, DEL, ROLLBACK.
	- Every net id a message mentions (subject, pair target, reference value) is one this client has
	  at that point, except the subject of ENTER and ROLLBACK. REDACTED stands in for the others.
	- HIDE and REM only remove a component the client holds, and LEAVE and DEL an entity it has.
	  Each is recorded by kind, so tests can tell "hidden from you" from "removed".
	- Losing an entity strips pairs to it and redacts references to it, with no cleanup cascade.
]]

local StatuhScope = require("./StatuhScope")

local REDACTED = StatuhScope.REDACTED

local PHASE = { ENTER = 1, SET = 2, HIDE = 2, REM = 2, PAIR_REM = 3, PAIR_ADD = 3, LEAVE = 4, DEL = 5, ROLLBACK = 6 }

export type ReplicaEntity = {
	comps: { [number]: any },
	pairs: { [number]: { [number]: boolean } },
}

type Removal = { kind: string, netId: number, key: number? }

local ClientReplica = {}
ClientReplica.__index = ClientReplica

export type ClientReplica = typeof(setmetatable(
	{} :: {
		entities: { [number]: ReplicaEntity },
		removals: { Removal },
		components: { { refs: (boolean | { string })? } },
	},
	ClientReplica
))

-- `components` is the scope's replicated component list (key -> its `refs`).
function ClientReplica.new(components: { { refs: (boolean | { string })? } }): ClientReplica
	return setmetatable({ entities = {}, removals = {}, components = components }, ClientReplica)
end

local function describe(message: { any }): string
	local parts = {}
	for i, part in message do
		parts[i] = if part == REDACTED then "REDACTED" elseif type(part) == "table" then "{...}" else tostring(part)
	end
	return table.concat(parts, " ")
end

function ClientReplica._checkRefs(self: ClientReplica, key: number, value: any, message: { any })
	StatuhScope.mapRefs(self.components[key].refs, value, function(ref)
		if ref ~= REDACTED and not self.entities[ref] then
			error(`reference to net id {ref} the client doesn't have, in: {describe(message)}`, 0)
		end
		return ref
	end)
end

function ClientReplica._remove(self: ClientReplica, netId: number, kind: string)
	self.entities[netId] = nil
	for _, entity in self.entities do
		for _, targets in entity.pairs do
			targets[netId] = nil
		end
		for key, value in entity.comps do
			entity.comps[key] = StatuhScope.mapRefs(self.components[key].refs, value, function(ref)
				return if ref == netId then REDACTED else ref
			end)
		end
	end
	table.insert(self.removals, { kind = kind, netId = netId })
end

function ClientReplica.apply(self: ClientReplica, messages: { { any } }?)
	local phase = 0
	for _, message in messages or {} :: { { any } } do
		local kind: string, netId, key = message[1], message[2], message[3]
		local messagePhase = PHASE[kind]
		if not messagePhase then
			error(`unknown message {kind}`, 0)
		elseif messagePhase < phase then
			error(`{kind} after a later phase, in: {describe(message)}`, 0)
		end
		phase = messagePhase
		local entity = self.entities[netId]
		if kind == "ENTER" then
			if entity then
				error(`ENTER for net id {netId} the client already has`, 0)
			end
			self.entities[netId] = { comps = table.clone(message[3]), pairs = {} }
			for k, value in message[3] do
				self:_checkRefs(k, value, message)
			end
		elseif kind == "ROLLBACK" then
			table.insert(self.removals, { kind = kind :: string, netId = netId })
		elseif not entity then
			error(`{kind} for net id {netId} the client doesn't have`, 0)
		elseif kind == "SET" then
			entity.comps[key] = message[4]
			self:_checkRefs(key, message[4], message)
		elseif kind == "REM" or kind == "HIDE" then
			if entity.comps[key] == nil then
				error(`{kind} for a component the client doesn't hold: {describe(message)}`, 0)
			end
			entity.comps[key] = nil
			table.insert(self.removals, { kind = kind :: string, netId = netId, key = key })
		elseif kind == "PAIR_ADD" or kind == "PAIR_REM" then
			local target = message[4]
			if not self.entities[target] then
				error(`{kind} to net id {target} the client doesn't have`, 0)
			end
			local set = entity.pairs[key] or {}
			entity.pairs[key] = set
			if (kind == "PAIR_ADD") == (set[target] == true) then
				error(
					`{if set[target] then "duplicate PAIR_ADD" else "PAIR_REM for a missing pair"}: {describe(message)}`,
					0
				)
			end
			set[target] = if kind == "PAIR_ADD" then true else nil
		else -- LEAVE or DEL
			self:_remove(netId, kind)
		end
	end
end

-- The kind of the last removal of an entity (key nil) or of one of its components.
function ClientReplica.lastRemoval(self: ClientReplica, netId: number, key: number?): string?
	for i = #self.removals, 1, -1 do
		local removal = self.removals[i]
		if removal.netId == netId and removal.key == key then
			return removal.kind
		end
	end
	return nil
end

local function show(value: any): string
	if value == REDACTED then
		return "REDACTED"
	elseif type(value) ~= "table" then
		return tostring(value)
	end
	local parts = {}
	for k, v in value do
		table.insert(parts, `{k}={show(v)}`)
	end
	table.sort(parts)
	return "{" .. table.concat(parts, ",") .. "}"
end

--[=[
	`expected` is netId -> { comps = key -> wire value, pairs = key -> target net id set }.
	Returns nil when the replica matches, or a description of the first difference.
]=]
function ClientReplica.compareWithProjection(self: ClientReplica, expected: { [number]: ReplicaEntity }): string?
	for netId in self.entities do
		if not expected[netId] then
			return `client has net id {netId}, which it shouldn't`
		end
	end
	for netId, want in expected do
		local have = self.entities[netId]
		if not have then
			return `client is missing net id {netId}`
		end
		local havePairs = {}
		for key, targets in have.pairs do
			if next(targets) then
				havePairs[key] = targets
			end
		end
		for label, sides in
			{ comps = { have.comps, want.comps }, pairs = { havePairs, want.pairs } } :: { [string]: { any } }
		do
			if show(sides[1]) ~= show(sides[2]) then
				return `net id {netId} {label}: client has {show(sides[1])}, expected {show(sides[2])}`
			end
		end
	end
	return nil
end

return ClientReplica
