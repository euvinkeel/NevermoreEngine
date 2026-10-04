// Jecs-like API but for slower sanity checking.
import {
	StatuhEntity,
	StatuhWorld,
	StatuhTerm,
	StatuhTerms,
	InferTypedData,
	FlattenTuple,
	Nullable,
	InferTypedDatas,
	StatuhPair,
} from "shared/libs/statuh/statuhTypes";
import {
	Entity,
	Id,
	OnAdd,
	OnChange,
	OnRemove,
	pair as jecs_pair,
	Pair,
	world,
	World,
	Wildcard,
	IS_PAIR,
	pair_second,
	pair_first,
	Name,
	TagDiscriminator,
} from "../vendor/jecs";
import { objectAsPrettyString } from "shared/utils/tableUtil";

type EntityRuntime = Entity;
type PairRuntime = Pair;

type Ids = [Id] | [Id, Id] | [Id, Id, Id] | [Id, Id, Id, Id];

export class JecsStatuh implements StatuhWorld {
	private _world: World;
	private _entityset: Set<EntityRuntime>;
	private _componentset: Set<EntityRuntime>;
	private _component_to_addhooks: Map<
		EntityRuntime,
		Set<(entity: StatuhEntity, id: StatuhEntity<unknown>, data: unknown) => void>
	>;
	private _component_to_changehooks: Map<
		EntityRuntime,
		Set<(entity: StatuhEntity, id: StatuhEntity<unknown>, data: unknown) => void>
	>;
	private _component_to_removehooks: Map<
		EntityRuntime,
		Set<(entity: StatuhEntity, id: StatuhEntity<unknown>, data: unknown) => void>
	>;
	// Relationship predicate-scoped hook registries
	private _rel_predicate_to_addhooks: Map<
		EntityRuntime,
		Set<
			(
				source: StatuhEntity,
				predicateId: StatuhEntity<unknown>,
				target: StatuhEntity<unknown>,
				data: unknown,
			) => void
		>
	>;
	private _rel_predicate_to_changehooks: Map<
		EntityRuntime,
		Set<
			(
				source: StatuhEntity,
				predicateId: StatuhEntity<unknown>,
				target: StatuhEntity<unknown>,
				data: unknown,
			) => void
		>
	>;
	private _rel_predicate_to_removehooks: Map<
		EntityRuntime,
		Set<
			(
				source: StatuhEntity,
				predicateId: StatuhEntity<unknown>,
				target: StatuhEntity<unknown>,
				data: unknown,
			) => void
		>
	>;
	private _codehistory: string[] = []; // inspect to recreate any errors
	private _codehistory_enabled = false;
	private _entityDeletedHooks: Array<(entity: StatuhEntity) => void> = [];

	private _run_add_hooks(entity: StatuhEntity, id: StatuhEntity<unknown>) {
		const addhooks = this._component_to_addhooks.get(id as unknown as Entity);
		if (addhooks) {
			for (const hook of addhooks) {
				try {
					hook(entity, id, this.get_component_data(entity, id));
				} catch (e) {
					if (tostring(e).find("<SILENT>")) continue;
					warn(e);
				}
			}
		}
	}
	private _run_change_hooks(entity: StatuhEntity, id: StatuhEntity<unknown>) {
		const changehooks = this._component_to_changehooks.get(id as unknown as Entity);
		if (changehooks) {
			for (const hook of changehooks) {
				try {
					hook(entity, id, this.get_component_data(entity, id));
				} catch (e) {
					if (tostring(e).find("<SILENT>")) continue;
					warn(e);
				}
			}
		}
	}
	private _run_remove_hooks(entity: StatuhEntity, id: StatuhEntity<unknown>) {
		const removehooks = this._component_to_removehooks.get(id as unknown as Entity);
		if (removehooks) {
			for (const hook of removehooks) {
				try {
					hook(entity, id, this.get_component_data(entity, id));
				} catch (e) {
					if (tostring(e).find("<SILENT>")) continue;
					warn(e);
				}
			}
		}
	}

	private _codehistory_push(code: string) {
		if (this._codehistory_enabled) {
			if (this._codehistory.size() > 1000) {
				warn("Code history is too long! Clearing.");
				this._codehistory.clear();
			}
			this._codehistory.push(code);
		}
	}

	constructor() {
		this._world = world();
		this._entityset = new Set<EntityRuntime>();
		this._componentset = new Set<EntityRuntime>();
		this._component_to_addhooks = new Map<
			EntityRuntime,
			Set<(entity: StatuhEntity, id: StatuhEntity<unknown>, data: unknown) => void>
		>();
		this._component_to_removehooks = new Map<
			EntityRuntime,
			Set<(entity: StatuhEntity, id: StatuhEntity<unknown>, data: unknown) => void>
		>();
		this._component_to_changehooks = new Map<
			EntityRuntime,
			Set<(entity: StatuhEntity, id: StatuhEntity<unknown>, data: unknown) => void>
		>();

		this._rel_predicate_to_addhooks = new Map();
		this._rel_predicate_to_changehooks = new Map();
		this._rel_predicate_to_removehooks = new Map();

		this._codehistory_push("\n\n");
		this._codehistory_push("local jecs = require(game.ReplicatedStorage.TS.libs.vendor.jecs)");
		this._codehistory_push("local world = jecs.world()");
		this._codehistory_push("local statuhToRawMap = {}");
	}

	private _run_rel_added_hooks(source: StatuhEntity, predicate: StatuhEntity<unknown>, target: StatuhEntity) {
		const hooks = this._rel_predicate_to_addhooks.get(predicate as unknown as Entity);
		if (!hooks) return;
		const data = this.get_component_data(
			source,
			jecs_pair(predicate as unknown as Entity, target as unknown as Entity) as unknown as StatuhTerm,
		);
		for (const hook of hooks) {
			try {
				hook(source, predicate, target, data);
			} catch (e) {
				if (tostring(e).find("<SILENT>")) continue;
				warn(e);
			}
		}
	}

	private _run_rel_change_hooks(source: StatuhEntity, predicate: StatuhEntity<unknown>, target: StatuhEntity) {
		const hooks = this._rel_predicate_to_changehooks.get(predicate as unknown as Entity);
		if (!hooks) return;
		const data = this.get_component_data(
			source,
			jecs_pair(predicate as unknown as Entity, target as unknown as Entity) as unknown as StatuhTerm,
		);
		for (const hook of hooks) {
			try {
				hook(source, predicate, target, data);
			} catch (e) {
				if (tostring(e).find("<SILENT>")) continue;
				warn(e);
			}
		}
	}

	private _run_rel_remove_hooks(source: StatuhEntity, predicate: StatuhEntity<unknown>, target: StatuhEntity) {
		const hooks = this._rel_predicate_to_removehooks.get(predicate as unknown as Entity);
		if (!hooks) return;
		const data = this.get_component_data(
			source,
			jecs_pair(predicate as unknown as Entity, target as unknown as Entity) as unknown as StatuhTerm,
		);
		for (const hook of hooks) {
			try {
				hook(source, predicate, target, data);
			} catch (e) {
				if (tostring(e).find("<SILENT>")) continue;
				warn(e);
			}
		}
	}

	is_term_pair(term: StatuhTerm): term is StatuhPair<unknown, unknown> {
		return IS_PAIR(term as unknown as Entity);
	}

	is_term_component(term: StatuhTerm): term is StatuhEntity<unknown> {
		return !IS_PAIR(term as unknown as Entity);
	}

	get_pair_predicate(pair: StatuhPair<unknown, unknown>): StatuhEntity<unknown> {
		return pair_first(this._world, pair as unknown as Pair) as unknown as StatuhEntity;
	}

	get_pair_object(pair: StatuhPair<unknown, unknown>): StatuhEntity<unknown> {
		return pair_second(this._world, pair as unknown as Pair) as unknown as StatuhEntity;
	}

	create_entity(): StatuhEntity {
		const entity = this._world.entity();
		this._codehistory_push(`statuhToRawMap[${entity}] = world:entity()`);
		this._entityset.add(entity);
		return entity as unknown as StatuhEntity;
	}

	delete_entity(entity: StatuhEntity): void {
		// Manually run remove hooks before deletion.
		for (const component of this._componentset) {
			if (this._world.has(entity as unknown as Entity, component as unknown as Id<undefined>)) {
				this._run_remove_hooks(entity, component as unknown as StatuhEntity<unknown>);
			}
		}
		// Fire relationship removed hooks for pairs where this entity is the source
		for (const predicate of this._componentset) {
			let i = 0;
			while (true) {
				const target = this._world.target(entity as unknown as Entity, predicate as unknown as Entity, i);
				if (target === undefined) break;
				this._run_rel_remove_hooks(
					entity,
					predicate as unknown as StatuhEntity<unknown>,
					target as unknown as StatuhEntity,
				);
				i++;
			}
		}
		// Fire relationship removed hooks for pairs where this entity is the target
		for (const predicate of this._componentset) {
			for (const [source] of this._world.query(
				jecs_pair(predicate as unknown as Entity<unknown>, entity as unknown as Entity),
			)) {
				this._run_rel_remove_hooks(
					source as unknown as StatuhEntity,
					predicate as unknown as StatuhEntity<unknown>,
					entity,
				);
			}
		}
		// Fire entity deleted hooks before deletion in the world
		for (const hook of this._entityDeletedHooks) {
			try {
				hook(entity);
			} catch (e) {
				if (tostring(e).find("<SILENT>")) continue;
				warn(e);
			}
		}
		this._world.delete(entity as unknown as Entity);
		this._codehistory_push(`world:delete(statuhToRawMap[${entity}])`);
		this._entityset.delete(entity as unknown as Entity);
	}

	contains_entity(entity: StatuhEntity): boolean {
		const isInSet =
			this._entityset.has(entity as unknown as Entity) || this._componentset.has(entity as unknown as Entity);
		const isInWorld = this._world.contains(entity as unknown as Entity);
		this._codehistory_push(`print("get:", world:contains(statuhToRawMap[${entity}]))`);
		if (isInSet !== isInWorld) {
			warn(debug.traceback());
			error("Entity set and world state mismatch");
		}
		return isInWorld;
	}

	get_all_entities(): StatuhEntity[] {
		return [...this._entityset].map((e) => e as unknown as StatuhEntity);
	}

	get_entity_count(): number {
		// _entityset tracks alive entities only
		return this._entityset.size();
	}

	delete_all_entities(): void {
		this._codehistory_push(`-- delete_all_entities called`);
		this.get_all_entities().forEach((e) => this.delete_entity(e));
	}

	order_entities(entityA: StatuhEntity, entityB: StatuhEntity): boolean {
		const entityAIsANumber = entityA as number;
		const entityBIsANumber = entityB as number;
		return entityAIsANumber < entityBIsANumber;
	}

	entity_to_string(entity: StatuhEntity): string {
		return tostring(entity);
	}

	entity_to_number(entity: StatuhEntity): number {
		return entity as number;
	}

	// Component management
	register_component<TypedData = unknown>(): StatuhEntity<TypedData> {
		const component = this._world.component();
		this._codehistory_push(`statuhToRawMap[${component}] = world:component()`);
		this._componentset.add(component);
		return component as unknown as StatuhEntity<TypedData>;
	}

	set_component_name(component: StatuhEntity, name: string): void {
		this._world.set(component as unknown as EntityRuntime, Name, name);
	}

	get_component_name(component: StatuhEntity): string {
		return this._world.get(component as unknown as EntityRuntime, Name) as string;
	}

	get_all_components(): StatuhEntity[] {
		return [...this._componentset].map((c) => c as unknown as StatuhEntity);
	}

	add_component<C extends StatuhTerm>(
		entity: StatuhEntity,
		component: undefined extends InferTypedData<C> ? C : StatuhTerm<undefined>,
	): void {
		this._world.add(entity as unknown as Entity, component as unknown as Id<TagDiscriminator>);
		this._codehistory_push(`world:add(statuhToRawMap[${entity}], statuhToRawMap[${component}])`);
		this._run_add_hooks(entity, component as unknown as StatuhEntity<unknown>);
		// Relationship hook: added
		if (IS_PAIR(component as unknown as Entity)) {
			const pred = pair_first(this._world, component as unknown as Pair) as unknown as StatuhEntity<unknown>;
			const targ = pair_second(this._world, component as unknown as Pair) as unknown as StatuhEntity;
			this._run_rel_added_hooks(entity, pred, targ);
		}
	}

	set_component_data<E extends StatuhTerm>(entity: StatuhEntity, component: E, data: InferTypedData<E>): void {
		if (entity === undefined || !this.contains_entity(entity)) {
			error(`Entity ${entity} is not in the world`);
		}
		const wasPresent = this._world.has(entity as unknown as Entity, component as unknown as Id<TagDiscriminator>);
		this._world.set(entity as unknown as Entity, component as unknown as Id<TagDiscriminator>, data);
		if (typeOf(data) === "table") {
			this._codehistory_push(
				`world:set(statuhToRawMap[${entity}], statuhToRawMap[${component}], ${objectAsPrettyString(
					data as Record<string, unknown>,
				)})`,
			);
		} else {
			this._codehistory_push(`world:set(statuhToRawMap[${entity}], statuhToRawMap[${component}], ${data})`);
		}

		if (!wasPresent) {
			this._run_add_hooks(entity, component as unknown as StatuhEntity<unknown>);
		}
		this._run_change_hooks(entity, component as unknown as StatuhEntity<unknown>);
		// Relationship hooks: added (if first set) and setted (always)
		if (IS_PAIR(component as unknown as Entity)) {
			const pred = pair_first(this._world, component as unknown as Pair) as unknown as StatuhEntity<unknown>;
			const targ = pair_second(this._world, component as unknown as Pair) as unknown as StatuhEntity;
			if (!wasPresent) {
				this._run_rel_added_hooks(entity, pred, targ);
			}
			this._run_rel_change_hooks(entity, pred, targ);
		}
	}

	remove_component(entity: StatuhEntity, component: StatuhTerm): void {
		this._run_remove_hooks(entity, component as unknown as StatuhEntity<unknown>);
		// Relationship hook: removed (before actual removal)
		if (IS_PAIR(component as unknown as Entity)) {
			const pred = pair_first(this._world, component as unknown as Pair) as unknown as StatuhEntity<unknown>;
			const targ = pair_second(this._world, component as unknown as Pair) as unknown as StatuhEntity;
			this._run_rel_remove_hooks(entity, pred, targ);
		}
		this._world.remove(entity as unknown as Entity, component as unknown as Id<undefined>);
		this._codehistory_push(`world:remove(statuhToRawMap[${entity}], statuhToRawMap[${component}])`);
	}

	has_component(entity: StatuhEntity, component: StatuhTerm): boolean {
		if (entity === undefined || !this.contains_entity(entity)) {
			return false;
		}
		const result = this._world.has(entity as unknown as Entity, component as unknown as Id<undefined>);
		this._codehistory_push(`print("has:", world:has(statuhToRawMap[${entity}], statuhToRawMap[${component}]))`);
		return result;
	}

	get_component_datas<T extends StatuhTerms>(
		entity: StatuhEntity,
		...components: T
	): LuaTuple<Nullable<InferTypedDatas<T>>> {
		this._codehistory_push(
			`print("get:", world:get(statuhToRawMap[${entity}], ${components.map((c) => `statuhToRawMap[${c}]`).join(", ")}))`,
		);
		if (entity === undefined || !this.contains_entity(entity)) {
			return [] as unknown as LuaTuple<Nullable<InferTypedDatas<T>>>;
		}
		if (components.size() > 4) {
			// if it's more than 4, just iterate and get em all
			// cannot use slice or normal TS table utility type shit
			const aggregated = new Array<unknown>(components.size());
			for (let i = 0; i < components.size(); i++) {
				const term = components[i]!;
				const value = this.get_component_data(entity, term as unknown as StatuhTerm);
				aggregated[i] = value as unknown;
			}
			return aggregated as unknown as LuaTuple<Nullable<InferTypedDatas<T>>>;
		} else {
			const result = this._world.get(entity as unknown as Entity, ...(components as unknown as Ids)) as LuaTuple<
				Nullable<InferTypedDatas<T>>
			>;
			return result;
		}
	}

	get_component_data<T extends StatuhTerm>(entity: StatuhEntity, component: T): InferTypedData<T> {
		if (entity === undefined || !this.contains_entity(entity)) {
			return undefined as unknown as InferTypedData<T>;
		}
		const result = this._world.get(
			entity as unknown as Entity,
			component as unknown as Id<undefined>,
		) as InferTypedData<T>;
		this._codehistory_push(
			`print("get_data:", world:get(statuhToRawMap[${entity}], statuhToRawMap[${component}]))`,
		);
		return result;
	}

	// Hooks
	// Called right after a component is added to an entity (either after add_component or after set_component_data).
	add_component_hook_added<C extends StatuhTerm>(
		component: C,
		hook: (entity: StatuhEntity, id: StatuhEntity<unknown>, data: InferTypedData<C>) => void,
	): void {
		if (!this._component_to_addhooks.has(component as unknown as Entity)) {
			this._component_to_addhooks.set(
				component as unknown as Entity,
				new Set<(e: StatuhEntity, id: StatuhEntity<unknown>, data: unknown) => void>(),
			);
		}
		this._component_to_addhooks.get(component as unknown as Entity)!.add((e, id, data) => {
			hook(
				e as unknown as StatuhEntity,
				id as unknown as StatuhEntity<unknown>,
				data as unknown as InferTypedData<C>,
			);
		});
	}

	// Relationship hook registration
	add_relationship_hook_added<P, O>(
		predicate: StatuhEntity<P>,
		hook: (
			source: StatuhEntity,
			predicateId: StatuhEntity<P>,
			target: StatuhEntity<O>,
			data: InferTypedData<StatuhPair<P, O>>,
		) => void,
	): void {
		const key = predicate as unknown as Entity;
		if (!this._rel_predicate_to_addhooks.has(key)) {
			this._rel_predicate_to_addhooks.set(key, new Set());
		}
		this._rel_predicate_to_addhooks.get(key)!.add((source, pred, target, data) => {
			(
				hook as unknown as (
					source: StatuhEntity,
					predicateId: StatuhEntity<unknown>,
					target: StatuhEntity<unknown>,
					data: unknown,
				) => void
			)(source, pred, target, data);
		});
	}

	add_relationship_hook_setted<P, O>(
		predicate: StatuhEntity<P>,
		hook: (
			source: StatuhEntity,
			predicateId: StatuhEntity<P>,
			target: StatuhEntity<O>,
			data: InferTypedData<StatuhPair<P, O>>,
		) => void,
	): void {
		const key = predicate as unknown as Entity;
		if (!this._rel_predicate_to_changehooks.has(key)) {
			this._rel_predicate_to_changehooks.set(key, new Set());
		}
		this._rel_predicate_to_changehooks.get(key)!.add((source, pred, target, data) => {
			(
				hook as unknown as (
					source: StatuhEntity,
					predicateId: StatuhEntity<unknown>,
					target: StatuhEntity<unknown>,
					data: unknown,
				) => void
			)(source, pred, target, data);
		});
	}

	add_relationship_hook_removed<P, O>(
		predicate: StatuhEntity<P>,
		hook: (
			source: StatuhEntity,
			predicateId: StatuhEntity<P>,
			target: StatuhEntity<O>,
			data: InferTypedData<StatuhPair<P, O>>,
		) => void,
	): void {
		const key = predicate as unknown as Entity;
		if (!this._rel_predicate_to_removehooks.has(key)) {
			this._rel_predicate_to_removehooks.set(key, new Set());
		}
		this._rel_predicate_to_removehooks.get(key)!.add((source, pred, target, data) => {
			(
				hook as unknown as (
					source: StatuhEntity,
					predicateId: StatuhEntity<unknown>,
					target: StatuhEntity<unknown>,
					data: unknown,
				) => void
			)(source, pred, target, data);
		});
	}

	// Called right after a (non tag, data-associated) component is set on an entity (after set_component_data).
	add_component_hook_setted<C extends StatuhTerm>(
		component: C,
		hook: (entity: StatuhEntity, id: StatuhEntity<unknown>, data: InferTypedData<C>) => void,
	): void {
		if (!this._component_to_changehooks.has(component as unknown as Entity)) {
			this._component_to_changehooks.set(
				component as unknown as Entity,
				new Set<(e: StatuhEntity, id: StatuhEntity<unknown>, data: unknown) => void>(),
			);
		}
		this._component_to_changehooks.get(component as unknown as Entity)?.add((e, id, data) => {
			hook(
				e as unknown as StatuhEntity,
				id as unknown as StatuhEntity<unknown>,
				data as unknown as InferTypedData<C>,
			);
		});
	}

	// Called right before a component is removed from an entity (after remove_component or entity deletion).
	// This should fire right before the component is removed from the entity, hence the data is still available.
	add_component_hook_removed<C extends StatuhTerm>(
		component: C,
		hook: (entity: StatuhEntity, id: StatuhEntity<unknown>, data: InferTypedData<C>) => void,
	): void {
		if (!this._component_to_removehooks.has(component as unknown as Entity)) {
			this._component_to_removehooks.set(
				component as unknown as Entity,
				new Set<(e: StatuhEntity, id: StatuhEntity<unknown>, data: unknown) => void>(),
			);
		}
		this._component_to_removehooks.get(component as unknown as Entity)?.add((e, id, data) => {
			hook(
				e as unknown as StatuhEntity,
				id as unknown as StatuhEntity<unknown>,
				data as unknown as InferTypedData<C>,
			);
		});
	}

	// Relationships
	get_relationship_targets(source_entity: StatuhEntity, relcomponent: StatuhTerm): StatuhEntity[] {
		const targets: StatuhEntity[] = [];
		const MAX_I = 100000;
		let i = 0;
		while (i < MAX_I) {
			const target = this._world.target(
				source_entity as unknown as Entity,
				relcomponent as unknown as Entity<undefined>,
				i,
			);
			this._codehistory_push(
				`print("target:", world:target(statuhToRawMap[${source_entity}], statuhToRawMap[${relcomponent}], ${i}))`,
			);
			if (target === undefined) {
				break;
			}
			if (!this._world.contains(target as unknown as Entity)) {
				warn(debug.traceback());
				error("Relationship target is not in world, but not nil.");
			}
			this._codehistory_push(`print("contains:", world:contains(statuhToRawMap[${target}])) -- sanity check`);
			targets.push(target as unknown as StatuhEntity);
			i++;
		}
		if (i === MAX_I) {
			warn(debug.traceback());
			error("Relationship targets looped too many times.");
		}
		return targets;
	}
	get_relationship_target(source_entity: StatuhEntity, relcomponent: StatuhTerm): StatuhEntity | undefined {
		const target = this._world.target(
			source_entity as unknown as Entity,
			relcomponent as unknown as Entity<undefined>,
			0,
		);
		this._codehistory_push(
			`print("target:", world:target(statuhToRawMap[${source_entity}], statuhToRawMap[${relcomponent}], 0))`,
		);
		return target as unknown as StatuhEntity | undefined;
	}
	get_relationship_sources(target_entity: StatuhEntity, relcomponent: StatuhTerm): StatuhEntity[] {
		const sources: StatuhEntity[] = [];
		for (const [e] of this._world.query(
			jecs_pair(relcomponent as unknown as Entity<unknown>, target_entity as unknown as Entity),
		)) {
			sources.push(e as unknown as StatuhEntity);
		}
		this._codehistory_push(
			`print("query:", world:query(statuhToRawMap[${relcomponent}], statuhToRawMap[${target_entity}]))`,
		);
		return sources;
	}

	get_relationship_source(target_entity: StatuhEntity, relcomponent: StatuhTerm): StatuhEntity | undefined {
		let found: StatuhEntity | undefined = undefined;
		for (const [e] of this._world.query(
			jecs_pair(relcomponent as unknown as Entity<unknown>, target_entity as unknown as Entity),
		)) {
			found = e as unknown as StatuhEntity;
			break;
		}
		this._codehistory_push(
			`print("query:", world:query(statuhToRawMap[${relcomponent}], statuhToRawMap[${target_entity}]))`,
		);
		return found;
	}

	// Queries
	query_entities_of_archetype(
		with_components: StatuhTerm[] = [],
		without_components: StatuhTerm[] = [],
	): StatuhEntity[] {
		const entities: StatuhEntity[] = [];

		for (const [e] of this._world
			.query(...(with_components as unknown as Id<undefined>[]))
			.without(...(without_components as unknown as Id<undefined>[]))) {
			entities.push(e as unknown as StatuhEntity);
		}

		if (this._codehistory_enabled) {
			const componentsAsString = with_components?.map((c) => `statuhToRawMap[${c}]`).join(", ") || "";
			const withoutComponentsAsString = without_components?.map((c) => `statuhToRawMap[${c}]`).join(", ") || "";
			this._codehistory_push(
				`print("query:", world:query(${componentsAsString}):without(${withoutComponentsAsString}))`,
			);
		}
		return entities;
	}

	get_wildcard(): StatuhEntity {
		return Wildcard as unknown as StatuhEntity;
	}

	// Entity hooks
	add_entity_hook_deleted(hook: (entity: StatuhEntity) => void): void {
		this._entityDeletedHooks.push(hook);
	}
}

// Public API functions
export function create_world(): StatuhWorld {
	return new JecsStatuh();
}

export function printCodeHistory(world: StatuhWorld) {
	const jecsWorld = world as unknown as JecsStatuh;
	const fullCode =
		(jecsWorld as unknown as { _codehistory: string[] })._codehistory.join("\n") +
		`\nprint("statuhToRawMap:", statuhToRawMap)` +
		"\n\n";
	print(fullCode);
}

export function pair<P, O>(predicate: StatuhEntity<P>, object: StatuhEntity<O>): StatuhPair<P, O> {
	return jecs_pair(
		predicate as unknown as Entity<unknown>,
		object as unknown as Entity<unknown>,
	) as unknown as StatuhPair<P, O>;
}
