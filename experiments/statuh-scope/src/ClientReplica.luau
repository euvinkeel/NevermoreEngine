--!strict
--[[
	A client's view of the replicated world, rebuilt only from the frames StatuhScope sends it. Applying
	a frame checks the protocol as it goes; `compareWithProjection` checks the result against what the
	server says this client should see.

	Protocol checks:
	- Messages come in phase order: ENTER, SET/HIDE/REM, PAIR_REM/PAIR_ADD, LEAVE, DEL, ROLLBACK.
	- Every net id a message mentions (subject, pair target, reference value) is one this client has
	  at that point, except the subject of ENTER and ROLLBACK. REDACTED stands in for hidden ones.
	- HIDE and REM only remove a component the client holds. Both are recorded by kind, so tests
	  can tell "hidden from this client" (HIDE) from "removed" (REM).
	- LEAVE and DEL remove an entity the client has, and strip pairs pointing at it without any
	  cleanup cascade. Removals are recorded by kind so tests can tell LEAVE from DEL.
]]

local StatuhScope = require("./StatuhScope")

local REDACTED = StatuhScope.REDACTED

local PHASE = {
	ENTER = 1,
	SET = 2,
	HIDE = 2,
	REM = 2,
	PAIR_REM = 3,
	PAIR_ADD = 3,
	LEAVE = 4,
	DEL = 5,
	ROLLBACK = 6,
}

-- Iterates a table that may be nil (the old solver can't iterate `t or {}`).
local function orEmpty<K, V>(t: { [K]: V }?): { [K]: V }
	return (t or {}) :: any
end

local ClientReplica = {}
ClientReplica.__index = ClientReplica

export type ReplicaEntity = {
	comps: { [number]: any },
	pairs: { [number]: { [number]: boolean } },
}

export type ClientReplica = typeof(setmetatable(
	{} :: {
		entities: { [number]: ReplicaEntity },
		removals: { { kind: string, netId: number, frame: number } },
		componentRemovals: { { kind: string, netId: number, key: number, frame: number } },
		frame: number,
		refFields: { [number]: { string } | boolean },
	},
	ClientReplica
))

-- `refFields` maps component key -> true (whole value is a ref) or a list of ref fields.
function ClientReplica.new(refFields: { [number]: { string } | boolean }): ClientReplica
	return setmetatable({
		entities = {},
		removals = {},
		componentRemovals = {},
		frame = 0,
		refFields = refFields,
	}, ClientReplica)
end

local function describe(message: { any }): string
	local parts = {}
	for i, part in message do
		parts[i] = if part == REDACTED then "REDACTED" elseif type(part) == "table" then "{...}" else tostring(part)
	end
	return table.concat(parts, " ")
end

function ClientReplica._checkRefs(self: ClientReplica, key: number, value: any, message: { any })
	local spec = self.refFields[key]
	if not spec or value == nil then
		return
	end
	local refs = {}
	if spec == true then
		table.insert(refs, value)
	elseif type(value) == "table" then
		for _, field in spec :: { string } do
			if value[field] ~= nil then
				table.insert(refs, value[field])
			end
		end
	end
	for _, ref in refs do
		if ref ~= REDACTED and not self.entities[ref] then
			error(`reference to net id {ref} the client doesn't have, in: {describe(message)}`, 0)
		end
	end
end

function ClientReplica._remove(self: ClientReplica, netId: number, kind: string)
	self.entities[netId] = nil
	for _, entity in self.entities do
		for _, targets in entity.pairs do
			targets[netId] = nil
		end
	end
	table.insert(self.removals, { kind = kind, netId = netId, frame = self.frame })
end

function ClientReplica.apply(self: ClientReplica, messages: { { any } }?)
	self.frame += 1
	local phase = 0
	for _, message in orEmpty(messages) do
		local kind = message[1]
		local netId = message[2]
		local messagePhase = PHASE[kind]
		if not messagePhase then
			error(`unknown message {kind}`, 0)
		end
		if messagePhase < phase then
			error(`{kind} after a later phase, in: {describe(message)}`, 0)
		end
		phase = messagePhase
		local entity = self.entities[netId]

		if kind == "ENTER" then
			if entity then
				error(`ENTER for net id {netId} the client already has`, 0)
			end
			local comps = {}
			for key, value in message[3] do
				comps[key] = value
			end
			self.entities[netId] = { comps = comps, pairs = {} }
			for key, value in comps do
				self:_checkRefs(key, value, message)
			end
		elseif kind == "ROLLBACK" then
			table.insert(self.removals, { kind = kind :: string, netId = netId :: number, frame = self.frame })
		else
			if not entity then
				error(`{kind} for net id {netId} the client doesn't have`, 0)
			end
			if kind == "SET" then
				entity.comps[message[3]] = message[4]
				self:_checkRefs(message[3], message[4], message)
			elseif kind == "REM" or kind == "HIDE" then
				local key = message[3]
				if entity.comps[key] == nil then
					error(`{kind} for a component the client doesn't hold: {describe(message)}`, 0)
				end
				entity.comps[key] = nil
				table.insert(
					self.componentRemovals,
					{ kind = kind :: string, netId = netId :: number, key = key :: number, frame = self.frame }
				)
			elseif kind == "PAIR_ADD" or kind == "PAIR_REM" then
				local target = message[4]
				if not self.entities[target] then
					error(`{kind} to net id {target} the client doesn't have`, 0)
				end
				local key = message[3]
				local set = entity.pairs[key]
				if kind == "PAIR_ADD" then
					if set and set[target] then
						error(`duplicate PAIR_ADD: {describe(message)}`, 0)
					end
					local pairsOfKey: { [number]: boolean } = set or {}
					entity.pairs[key] = pairsOfKey
					pairsOfKey[target] = true
				else
					if not (set and set[target]) then
						error(`PAIR_REM for a pair the client doesn't have: {describe(message)}`, 0)
					end
					set[target] = nil
				end
			elseif kind == "LEAVE" or kind == "DEL" then
				self:_remove(netId, kind)
			end
		end
	end
end

local function sameValue(a: any, b: any): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for k, v in a do
		if not sameValue(v, b[k]) then
			return false
		end
	end
	for k in b do
		if a[k] == nil then
			return false
		end
	end
	return true
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
		if not sameValue(have.comps, want.comps) then
			local function show(value: any): string
				if value == REDACTED then
					return "REDACTED"
				elseif type(value) == "table" then
					local parts = {}
					for k, v in value do
						table.insert(parts, `{k}={show(v)}`)
					end
					table.sort(parts)
					return "{" .. table.concat(parts, ",") .. "}"
				end
				return tostring(value)
			end
			local keys = {}
			for key in have.comps do
				keys[key] = true
			end
			for key in want.comps do
				keys[key] = true
			end
			for key in keys do
				if not sameValue(have.comps[key], want.comps[key]) then
					return `net id {netId} component {key}: client has {show(have.comps[key])}, expected {show(
						want.comps[key]
					)}`
				end
			end
		end
		local havePairs = {}
		for key, targets in have.pairs do
			if next(targets) then
				havePairs[key] = targets
			end
		end
		if not sameValue(havePairs, want.pairs) then
			local function show(set: { [number]: { [number]: boolean } }): string
				local parts = {}
				for key, targets in set do
					for target in targets do
						table.insert(parts, `{key}->{target}`)
					end
				end
				table.sort(parts)
				return "{" .. table.concat(parts, ",") .. "}"
			end
			return `net id {netId} pairs differ: client has {show(havePairs)}, expected {show(want.pairs)}`
		end
	end
	return nil
end

return ClientReplica
