// Statuh utility functions
// (runtime agnostic)
// Useful utility functions based on a statuh system
import { StatuhWorld, StatuhTerm, StatuhEntity, InferTypedDatas, StatuhTerms, InferTypedData } from "./statuhTypes";
import { objectAsPrettyString } from "../../utils/tableUtil";
import { chooseFrom } from "shared/utils/randomUtil";
import { StatuhFanonRuntime } from "../fanon/statuh/statuhFanon";
import { StatuhFanonName } from "../fanon/statuh/statuhFanonName";
import { hashString, hashTable, hasKey } from "shared/utils/shims";
import Object, { deepCopy } from "../vendor/objectutils";
import { statuh_pair } from "./statuhRuntime";
import { ActionType, ActionTypeToGeneralInfo } from "shared/actionsLookup";
import { ActionHeader } from "../fanon/statuh/statuhFanonAction";
import { ppstr, tableinlinestr } from "shared/utils/miscUtil";
import { Diffstep, DiffstepOperation, Diffsteps, StatuhFanonDiffstep } from "../fanon/statuh/statuhFanonDiffstep";
import unorderedSet from "shared/utils/primitives/unorderedSet";

export const queryTuples = <T extends StatuhTerm[]>(
	world: StatuhWorld,
	withterms: [...T],
	withoutterms: StatuhTerm[] = [],
): Array<LuaTuple<[StatuhEntity, ...InferTypedDatas<T>]>> => {
	// Query the world for entities that match the given archetype constraints.
	const entities = world.query_entities_of_archetype(withterms, withoutterms);

	// Create and return an array of tuples instead of a generator
	const results: Array<LuaTuple<[StatuhEntity, ...InferTypedDatas<T>]>> = [];

	for (const entity of entities) {
		let data: InferTypedDatas<T> = [] as unknown as InferTypedDatas<T>;

		if (withterms.size() > 0) {
			// `get_component_data` can only accept up to 4 terms, but we cast here to satisfy the type system.
			data = [
				...world.get_component_datas(entity, ...(withterms as unknown as StatuhTerms)),
			] as unknown as InferTypedDatas<T>;
		} else {
			// When no withterms are provided, we simply skip the lookup.
			data = [] as unknown as InferTypedDatas<T>;
		}

		// Push the tuple [entity, ...data] to results
		// results.push([entity, ...(data as unknown as unknown[])] as unknown as LuaTuple<
		// 	[StatuhEntity, ...InferTypedDatas<T>]
		// >);
		results.push([entity, ...data] as unknown as LuaTuple<[StatuhEntity, ...InferTypedDatas<T>]>);
	}

	return results;
};

export const entityExists = (world: StatuhWorld, entity: StatuhEntity | undefined): entity is StatuhEntity => {
	return entity !== undefined && world.contains_entity(entity);
};

export const thereExistsA = <T extends StatuhTerm[]>(
	world: StatuhWorld,
	withterms: [...T],
	withoutterms: StatuhTerm[] = [],
): boolean => {
	return firstEntityOfQuery(world, withterms, withoutterms) !== undefined;
};

export const firstEntityOfQuery = <T extends StatuhTerm[]>(
	world: StatuhWorld,
	withterms: [...T],
	withoutterms: StatuhTerm[] = [],
): StatuhEntity | undefined => {
	for (const [entity] of queryTuples(world, withterms, withoutterms)) {
		return entity;
	}
	return undefined;
};

export const randomEntityOfQuery = <T extends StatuhTerm[]>(
	world: StatuhWorld,
	withterms: [...T],
	withoutterms: StatuhTerm[] = [],
): StatuhEntity | undefined => {
	const entities = world.query_entities_of_archetype(withterms, withoutterms);
	if (entities.size() === 0) return undefined;
	return chooseFrom(entities);
};

export const getNormalizedAdditiveDiffsteps = (diffsteps: Diffsteps) => {
	const diffstepsCopy = deepCopy(diffsteps);
	const normalized = diffstepsCopy
		.filter((diffstep) => !StatuhFanonDiffstep.is_removal_diffstep(diffstep))
		.sort((a, b) => StatuhFanonDiffstep.diffstep_to_str(a) < StatuhFanonDiffstep.diffstep_to_str(b));
	return normalized;
};

export const getNormalizedAdditiveDiffstepsString = (diffsteps: Diffsteps) => {
	const normalized = getNormalizedAdditiveDiffsteps(diffsteps);
	return normalized.map(StatuhFanonDiffstep.diffstep_to_str).join("\n");
};

export const hashDiffsteps = (diffsteps: Diffsteps) => {
	// diffsteps may vary in order
	// hashing them means checking if their effect, when applied, would be equivalent.
	// diffsteps should not be order dependent, so sorting should be fine
	const normalized = getNormalizedAdditiveDiffsteps(diffsteps);
	return hashTable(normalized as unknown as {});
};

export const actionHeaderToPrintableString = (actionHeader: ActionHeader) => {
	const actionId = actionHeader.actionId;
	const actionName = ActionTypeToGeneralInfo[actionId as ActionType].name;
	const actionArgs = actionHeader.actionArgs;
	const createdNames = actionHeader.createdNames;
	return `ACTION ${actionName} (${tableinlinestr(actionArgs)}), + ${tableinlinestr(createdNames)}`;
};

export const snapshotWorldPrintableString = (fanon_runtime: StatuhFanonRuntime) => {
	const IGNORED_FOR_HASH = new Set(["S_Position", "S_Direction", "S_Velocity"]);
	// Pretty-print only SHARED/REPLICATED state using fanon names and component keys
	const world = fanon_runtime._statuh_world;
	// Prepare replicated components ordered by numeric key for stable output
	const replicatedComponents = [...fanon_runtime._replicated_components].filter(
		(comp) => !IGNORED_FOR_HASH.has(world.get_component_name(comp)),
	);
	replicatedComponents.sort(
		(a, b) =>
			fanon_runtime._component_w_number_key.getMappingToB(a)! <
			fanon_runtime._component_w_number_key.getMappingToB(b)!,
	);

	// Prepare entity names in deterministic order
	const entityNames: string[] = [];
	fanon_runtime._registered_names.getList().forEach((n) => entityNames.push(tostring(n)));
	entityNames.sort();

	let result = "\n";

	for (const name of entityNames) {
		const entity = StatuhFanonName.getStatuhEntityFromLocalName(fanon_runtime, name as unknown as string);
		if (!entity) continue;
		if (!world.contains_entity(entity)) continue;

		// Determine if this entity has any replicated component or relationship
		let hasAny = false;
		for (const comp of replicatedComponents) {
			if (world.has_component(entity, comp)) {
				hasAny = true;
				break;
			}
			if (world.get_relationship_targets(entity, comp).size() > 0) {
				hasAny = true;
				break;
			}
		}
		// Print header (fanon name)
		result += `${name}\n`;
		if (!hasAny) {
			result += ` (blank)\n\n`;
			continue;
		}

		// Components first (replicated only), ordered by comp key
		for (const comp of replicatedComponents) {
			if (!world.has_component(entity, comp)) continue;
			const data = world.get_component_data(entity, comp);
			const compKey = fanon_runtime._component_w_number_key.getMappingToB(comp)!;
			const compName = world.get_component_name(comp);
			if (data !== undefined) {
				const dataStr =
					typeOf(data) === "table" ? tableinlinestr(data as Record<string, unknown>) : tostring(data);
				result += ` ├ ${compName}#${compKey}: ${dataStr}\n`;
			} else {
				result += ` ├ ${compName}#${compKey}\n`;
			}
		}

		// Relationships (replicated only). For each comp, list targets ordered by target fanon name
		for (const comp of replicatedComponents) {
			const compKey = fanon_runtime._component_w_number_key.getMappingToB(comp)!;
			const compName = world.get_component_name(comp);
			const targets = world.get_relationship_targets(entity, comp);
			// Build list with names for deterministic ordering
			const targetNames: string[] = [];
			for (const t of targets) {
				const tname = StatuhFanonName.getFanonNameFromStatuhEntity(fanon_runtime, t);
				if (tname) targetNames.push(tostring(tname));
			}
			targetNames.sort();
			for (const tname of targetNames) {
				const targetEntity = StatuhFanonName.getStatuhEntityFromLocalName(fanon_runtime, tname);
				if (!targetEntity) continue;
				const relData = world.get_component_data(entity, statuh_pair(comp, targetEntity));
				const dataStr = relData !== undefined ? objectAsPrettyString(relData as Record<string, unknown>) : "";
				result += ` ├ ${compName}#${compKey} -> ${tname} (${dataStr})\n`;
			}
		}

		result += "\n";
	}

	return result;
};

// Returns a deduplicated array of all entities that are part of replicated state.
// An entity is considered replicated if:
// - It has at least one replicated component, OR
// - It has at least one replicated relationship (as source), OR
// - It is the target of at least one replicated relationship from any replicated source.
export const getAllReplicatedEntities = (fanon_runtime: StatuhFanonRuntime): StatuhEntity[] => {
	const world = fanon_runtime._statuh_world;
	const replicatedComponents = [...fanon_runtime._replicated_components];

	// Use a set for deduplication
	const entitiesSet = new unorderedSet<StatuhEntity>();

	// 1) Entities that have any replicated component
	for (const comp of replicatedComponents) {
		const withComp = world.query_entities_of_archetype([comp]);
		for (const e of withComp) {
			entitiesSet.add(e);
		}
	}

	// 2) Entities that have any replicated relationship as source
	//    (predicate, *)
	const wildcard = world.get_wildcard();
	for (const comp of replicatedComponents) {
		const withRelAsSource = world.query_entities_of_archetype([statuh_pair(comp, wildcard)]);
		for (const e of withRelAsSource) {
			entitiesSet.add(e);
		}
	}

	// 3) Targets of replicated relationships from sources gathered above
	//    We snapshot the current set to iterate stable contents
	const currentEntities = entitiesSet.getList();
	for (const e of currentEntities) {
		for (const comp of replicatedComponents) {
			const targets = world.get_relationship_targets(e, comp);
			for (const t of targets) {
				entitiesSet.add(t);
			}
		}
	}

	// 4) Include any named entities still present (belt-and-suspenders)
	fanon_runtime._registered_names.getList().forEach((name) => {
		const e = StatuhFanonName.getStatuhEntityFromLocalName(fanon_runtime, name as unknown as string);
		if (e && world.contains_entity(e)) {
			entitiesSet.add(e);
		}
	});

	return entitiesSet.getList();
};

const normalizeValue = (v: unknown): unknown => {
	const t = typeOf(v);
	if (t === "nil" || v === undefined) return undefined;
	if (t === "boolean" || t === "number" || t === "string") return v;

	if (t === "Vector3") {
		const vv = v as Vector3;
		return { v3: [vv.X, vv.Y, vv.Z] };
	}
	if (t === "Vector2") {
		const vv = v as Vector2;
		return { v2: [vv.X, vv.Y] };
	}
	if (t === "Color3") {
		const c = v as Color3;
		return { c3: [c.R, c.G, c.B] };
	}
	if (t === "CFrame") {
		const cf = v as CFrame;
		const a = cf.GetComponents();
		// returns 12 numbers
		return { cf: a as unknown as number[] };
	}
	if (t === "UDim2") {
		const u = v as UDim2;
		return { u2: [u.X.Scale, u.X.Offset, u.Y.Scale, u.Y.Offset] };
	}
	if (t === "Instance") {
		return (v as Instance).GetFullName();
	}
	if (t === "table") {
		// Try array-like first (1..n numeric keys)
		const arr: defined[] = [];
		let i = 1;
		while (hasKey(v, i)) {
			arr.push(normalizeValue((v as Record<number, unknown>)[i]) as defined);
			i++;
		}
		if (arr.size() > 0) return arr;

		// Otherwise, treat as dictionary - sort by keys for deterministic output
		const out: Record<string, unknown> = {};
		const keys: string[] = [];
		for (const [k, _] of Object.entries(v as Record<string, unknown>)) {
			keys.push(tostring(k));
		}
		keys.sort();

		for (const k of keys) {
			const val = (v as Record<string, unknown>)[k];
			out[k] = normalizeValue(val);
		}
		return out;
	}

	// Fallback
	return tostring(v);
};

export const snapshotSharedWorldAsHash = (fanon_runtime: StatuhFanonRuntime): number => {
	const str = snapshotWorldPrintableString(fanon_runtime);
	return hashString(str);
};
