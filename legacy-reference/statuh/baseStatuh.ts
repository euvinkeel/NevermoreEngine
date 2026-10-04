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

// Runtime shapes for entities and pairs
interface EntityRuntime {
	__id: number;
	__kind: "entity" | "component";
}

interface PairRuntime {
	predicate: StatuhEntity;
	object: StatuhEntity;
	__kind: "pair";
}

// Global pair cache for canonicalization
const pairCache = new Map<StatuhEntity, Map<StatuhEntity, StatuhPair>>();

export class BaseStatuh implements StatuhWorld {
	private _nextId = 0;

	// Entity and component tracking
	private _entities = new Set<StatuhEntity>();
	private _components = new Set<StatuhEntity>();
	private _wildcard: StatuhEntity;

	// Per-entity component data (core of Option B)
	private _data = new Map<StatuhEntity, Map<StatuhTerm, unknown>>();

	// Per-entity component membership tracking
	private _componentSets = new Map<StatuhEntity, Set<StatuhTerm>>();

	// Relationships (directed edges)
	private _relOut = new Map<StatuhEntity, Map<StatuhEntity, Set<StatuhEntity>>>();
	private _relIn = new Map<StatuhEntity, Map<StatuhEntity, Set<StatuhEntity>>>();

	// Pair meta-information
	private _pairInfo = new Set<StatuhPair>();

	// Hook registries
	private _addedHooks = new Map<
		StatuhTerm,
		Array<(entity: StatuhEntity, id: StatuhEntity<unknown>, data: unknown) => void>
	>();
	private _setHooks = new Map<
		StatuhTerm,
		Array<(entity: StatuhEntity, id: StatuhEntity<unknown>, data: unknown) => void>
	>();
	private _removedHooks = new Map<
		StatuhTerm,
		Array<(entity: StatuhEntity, id: StatuhEntity<unknown>, data: unknown) => void>
	>();
	// Relationship predicate-scoped hook registries
	private _relAddedHooks = new Map<
		StatuhEntity,
		Array<
			(
				source: StatuhEntity,
				predicateId: StatuhEntity<unknown>,
				target: StatuhEntity<unknown>,
				data: unknown,
			) => void
		>
	>();
	private _relSetHooks = new Map<
		StatuhEntity,
		Array<
			(
				source: StatuhEntity,
				predicateId: StatuhEntity<unknown>,
				target: StatuhEntity<unknown>,
				data: unknown,
			) => void
		>
	>();
	private _relRemovedHooks = new Map<
		StatuhEntity,
		Array<
			(
				source: StatuhEntity,
				predicateId: StatuhEntity<unknown>,
				target: StatuhEntity<unknown>,
				data: unknown,
			) => void
		>
	>();
	private _entityDeletedHooks: Array<(entity: StatuhEntity) => void> = [];
	private _componentNames = new Map<StatuhEntity, string>();
	private _entityCount = 0;

	constructor() {
		this._nextId = 0;
		this._wildcard = {
			__id: ++this._nextId,
			__kind: "wildcard" as const,
		} as unknown as StatuhEntity;
	}

	// Hook helper methods
	private runAddedHooks(component: StatuhTerm, entity: StatuhEntity, data: unknown): void {
		const hooks = this._addedHooks.get(component);
		if (hooks) {
			for (const hook of hooks) {
				try {
					hook(entity, component as StatuhEntity<unknown>, data);
				} catch (error) {
					if (tostring(error).find("<SILENT>")) continue;
					warn(`Hook error in added hook: ${error}`);
				}
			}
		}
	}

	private runRelAddedHooks(predicate: StatuhEntity, source: StatuhEntity, target: StatuhEntity): void {
		const hooks = this._relAddedHooks.get(predicate);
		if (!hooks) return;
		const data = this.get_component_data(source, {
			predicate,
			object: target,
			__kind: "pair",
		} as unknown as StatuhTerm);
		for (const hook of hooks) {
			try {
				hook(
					source,
					predicate as unknown as StatuhEntity<unknown>,
					target as unknown as StatuhEntity<unknown>,
					data,
				);
			} catch (error) {
				if (tostring(error).find("<SILENT>")) continue;
				warn(`Hook error in relationship added hook: ${error}`);
			}
		}
	}

	private runRelSetHooks(predicate: StatuhEntity, source: StatuhEntity, target: StatuhEntity): void {
		const hooks = this._relSetHooks.get(predicate);
		if (!hooks) return;
		const data = this.get_component_data(source, {
			predicate,
			object: target,
			__kind: "pair",
		} as unknown as StatuhTerm);
		for (const hook of hooks) {
			try {
				hook(
					source,
					predicate as unknown as StatuhEntity<unknown>,
					target as unknown as StatuhEntity<unknown>,
					data,
				);
			} catch (error) {
				if (tostring(error).find("<SILENT>")) continue;
				warn(`Hook error in relationship set hook: ${error}`);
			}
		}
	}

	private runRelRemovedHooks(predicate: StatuhEntity, source: StatuhEntity, target: StatuhEntity): void {
		const hooks = this._relRemovedHooks.get(predicate);
		if (!hooks) return;
		const data = this.get_component_data(source, {
			predicate,
			object: target,
			__kind: "pair",
		} as unknown as StatuhTerm);
		for (const hook of hooks) {
			try {
				hook(
					source,
					predicate as unknown as StatuhEntity<unknown>,
					target as unknown as StatuhEntity<unknown>,
					data,
				);
			} catch (error) {
				if (tostring(error).find("<SILENT>")) continue;
				warn(`Hook error in relationship removed hook: ${error}`);
			}
		}
	}

	private runSetHooks(component: StatuhTerm, entity: StatuhEntity, data: unknown): void {
		const hooks = this._setHooks.get(component);
		if (hooks) {
			for (const hook of hooks) {
				try {
					hook(entity, component as StatuhEntity<unknown>, data);
				} catch (error) {
					if (tostring(error).find("<SILENT>")) continue;
					warn(`Hook error in set hook: ${error}`);
				}
			}
		}
	}

	private runRemovedHooks(component: StatuhTerm, entity: StatuhEntity, data: unknown): void {
		const hooks = this._removedHooks.get(component);
		if (hooks) {
			for (const hook of hooks) {
				try {
					hook(entity, component as StatuhEntity<unknown>, data);
				} catch (error) {
					if (tostring(error).find("<SILENT>")) continue;
					warn(`Hook error in removed hook: ${error}`);
				}
			}
		}
	}

	// Helper methods
	private ensureEntity(entity: StatuhEntity): void {
		const isAnEntity = this._entities.has(entity);
		const isAComponent = this._components.has(entity);
		if (!isAnEntity && !isAComponent) {
			warn(this);
			error("Entity does not exist");
		}
	}

	private idUsed(id: number): boolean {
		for (const entity of this._entities) {
			if ((entity as unknown as EntityRuntime).__id === id) {
				return true;
			}
		}
		for (const component of this._components) {
			if ((component as unknown as EntityRuntime).__id === id) {
				return true;
			}
		}
		return false;
	}

	private updateRelationships(entity: StatuhEntity, pair: StatuhPair): void {
		const pairRuntime = pair as unknown as PairRuntime;
		const predicate = pairRuntime.predicate;
		const target = pairRuntime.object;

		// Update outgoing relationships (entity -> predicate -> target)
		let outMap = this._relOut.get(entity);
		if (!outMap) {
			outMap = new Map();
			this._relOut.set(entity, outMap);
		}
		let targetSet = outMap.get(predicate);
		if (!targetSet) {
			targetSet = new Set();
			outMap.set(predicate, targetSet);
		}
		targetSet.add(target);

		// Update incoming relationships (target -> predicate -> entity)
		let inMap = this._relIn.get(target);
		if (!inMap) {
			inMap = new Map();
			this._relIn.set(target, inMap);
		}
		let sourceSet = inMap.get(predicate);
		if (!sourceSet) {
			sourceSet = new Set();
			inMap.set(predicate, sourceSet);
		}
		sourceSet.add(entity);
	}

	private clearEntityRelationships(entity: StatuhEntity): void {
		// Clear outgoing relationships
		const outMap = this._relOut.get(entity);
		if (outMap) {
			for (const [predicate, targets] of outMap) {
				for (const target of targets) {
					const inMap = this._relIn.get(target);
					if (inMap) {
						const sourceSet = inMap.get(predicate);
						if (sourceSet) {
							sourceSet.delete(entity);
							if (sourceSet.size() === 0) {
								inMap.delete(predicate);
							}
						}
						if (inMap.size() === 0) {
							this._relIn.delete(target);
						}
					}
				}
			}
			this._relOut.delete(entity);
		}

		// Clear incoming relationships
		const inMap = this._relIn.get(entity);
		if (inMap) {
			for (const [predicate, sources] of inMap) {
				for (const source of sources) {
					const outMap = this._relOut.get(source);
					if (outMap) {
						const targetSet = outMap.get(predicate);
						if (targetSet) {
							targetSet.delete(entity);
							if (targetSet.size() === 0) {
								outMap.delete(predicate);
							}
						}
						if (outMap.size() === 0) {
							this._relOut.delete(source);
						}
					}
				}
			}
			this._relIn.delete(entity);
		}
	}

	private bootstrapEntity(entity: StatuhEntity): void {
		this._entities.add(entity);
		this._data.set(entity, new Map());
		this._componentSets.set(entity, new Set());
	}

	is_term_pair(term: StatuhTerm): term is StatuhPair<unknown, unknown> {
		return (term as unknown as PairRuntime).__kind === "pair";
	}

	is_term_component(term: StatuhTerm): term is StatuhEntity<unknown> {
		return (term as unknown as EntityRuntime).__kind === "component";
	}

	get_pair_predicate(pair: StatuhPair<unknown, unknown>): StatuhEntity<unknown> {
		return (pair as unknown as PairRuntime).predicate;
	}

	get_pair_object(pair: StatuhPair<unknown, unknown>): StatuhEntity<unknown> {
		return (pair as unknown as PairRuntime).object;
	}

	// Entity management
	create_entity(): StatuhEntity {
		const entity = {
			__id: ++this._nextId,
			__kind: "entity" as const,
		} as unknown as StatuhEntity;

		this.bootstrapEntity(entity);
		return entity;
	}

	create_entity_in_range(range_begin: number, range_end: number): StatuhEntity {
		for (let id = range_begin; id <= range_end; id++) {
			if (!this.idUsed(id)) {
				const entity = {
					__id: id,
					__kind: "entity" as const,
				} as unknown as StatuhEntity;

				this.bootstrapEntity(entity);
				return entity;
			}
		}
		error("No available ID in range");
	}

	delete_entity(entity: StatuhEntity): void {
		const componentSet = this._componentSets.get(entity);
		if (componentSet) {
			// Iterate over a copy as `remove_component` modifies the set.
			for (const component of [...componentSet]) {
				this.remove_component(entity, component);
			}
		}

		// Fire relationship removed hooks where this entity is source
		const outMap = this._relOut.get(entity);
		if (outMap) {
			for (const [predicate, targets] of outMap) {
				for (const target of targets) {
					this.runRelRemovedHooks(predicate, entity, target);
				}
			}
		}

		// Fire relationship removed hooks where this entity is target
		const inMap = this._relIn.get(entity);
		if (inMap) {
			for (const [predicate, sources] of inMap) {
				for (const source of sources) {
					this.runRelRemovedHooks(predicate, source, entity);
				}
			}
		}

		// Clear all relationships where this entity is a source or a target.
		this.clearEntityRelationships(entity);

		// Fire entity deleted hooks before purging from world state
		for (const hook of this._entityDeletedHooks) {
			try {
				hook(entity);
			} catch (error) {
				if (tostring(error).find("<SILENT>")) continue;
				warn(`Hook error in entity_deleted hook: ${error}`);
			}
		}

		this._entities.delete(entity);
		this._components.delete(entity);
		this._data.delete(entity);
		this._componentSets.delete(entity);
	}

	contains_entity(entity: StatuhEntity): boolean {
		return this._entities.has(entity);
	}

	get_all_entities(): StatuhEntity[] {
		const result: StatuhEntity[] = [];
		for (const entity of this._entities) {
			if (this._components.has(entity)) continue;
			result.push(entity);
		}
		return result;
	}

	get_entity_count(): number {
		let count = 0;
		for (const entity of this._entities) {
			if (!this._components.has(entity)) {
				count++;
			}
		}
		return count;
	}

	delete_all_entities(): void {
		// Create a copy of entities to safely iterate while deleting
		const allEntities = [...this._entities];
		for (const entity of allEntities) {
			const isComponent = this._components.has(entity);
			if (!isComponent) {
				this.delete_entity(entity);
			}
		}
	}

	// Component management
	register_component<TypedData = unknown>(): StatuhEntity<TypedData> {
		const component = {
			__id: ++this._nextId,
			__kind: "component" as const,
		} as unknown as StatuhEntity<TypedData>;

		this._components.add(component as StatuhEntity);
		this.bootstrapEntity(component as StatuhEntity);
		return component;
	}

	set_component_name(component: StatuhEntity, name: string): void {
		this._componentNames.set(component, name);
	}

	get_component_name(component: StatuhEntity): string {
		return this._componentNames.get(component) as string;
	}

	get_all_components(): StatuhEntity[] {
		return [...this._components];
	}

	add_component<C extends StatuhTerm>(
		entity: StatuhEntity,
		component: undefined extends InferTypedData<C> ? C : StatuhTerm<undefined>,
	): void {
		this.ensureEntity(entity);
		const componentMap = this._data.get(entity)!;
		const componentSet = this._componentSets.get(entity)!;

		componentMap.set(component, undefined);
		componentSet.add(component);

		// Check if this is a pair and update relationships
		if (globalPairInfo.has(component as StatuhPair)) {
			this.updateRelationships(entity, component as StatuhPair);
			// Relationship added hook (no data yet)
			const pr = component as unknown as PairRuntime;
			this.runRelAddedHooks(pr.predicate, entity, pr.object);
		}

		// Fire added hook (component added with undefined data)
		this.runAddedHooks(component, entity, undefined);
	}

	set_component_data<E extends StatuhTerm>(entity: StatuhEntity, component: E, data: InferTypedData<E>): void {
		this.ensureEntity(entity);
		const componentMap = this._data.get(entity)!;
		const componentSet = this._componentSets.get(entity)!;

		// Check if this is the first time the component is being added
		const wasPresent = componentSet.has(component);

		componentMap.set(component, data);
		componentSet.add(component);

		// Check if this is a pair and update relationships
		if (globalPairInfo.has(component as StatuhPair)) {
			this.updateRelationships(entity, component as StatuhPair);
			const pr = component as unknown as PairRuntime;
			if (!wasPresent) {
				this.runRelAddedHooks(pr.predicate, entity, pr.object);
			}
			this.runRelSetHooks(pr.predicate, entity, pr.object);
		}

		// Fire appropriate hooks
		if (!wasPresent) {
			// First time adding this component - fire added hook
			this.runAddedHooks(component, entity, data);
		}
		// Always fire set hook for set_component_data
		this.runSetHooks(component, entity, data);
	}

	has_component(entity: StatuhEntity, component: StatuhTerm): boolean {
		const componentSet = this._componentSets.get(entity);
		if (!componentSet) {
			return false;
		}

		const componentAsPair = component as unknown as PairRuntime;
		if (componentAsPair.__kind === "pair" && componentAsPair.object === this._wildcard) {
			for (const term of componentSet) {
				const termAsPair = term as unknown as PairRuntime;
				if (termAsPair.__kind === "pair" && termAsPair.predicate === componentAsPair.predicate) {
					return true;
				}
			}
			return false;
		}

		return componentSet.has(component);
	}

	get_component_datas<T extends StatuhTerms>(
		entity: StatuhEntity,
		...components: T
	): LuaTuple<Nullable<InferTypedDatas<T>>> {
		const componentMap = this._data.get(entity);
		const result = components.map((c) => componentMap?.get(c));
		return result as LuaTuple<Nullable<InferTypedDatas<T>>>;
	}

	get_component_data<T extends StatuhTerm>(entity: StatuhEntity, component: T): InferTypedData<T> {
		const componentMap = this._data.get(entity);
		return componentMap?.get(component) as InferTypedData<T>;
	}

	// Relationships
	get_relationship_targets(source_entity: StatuhEntity, relcomponent: StatuhTerm): StatuhEntity[] {
		const outMap = this._relOut.get(source_entity);
		if (!outMap) return [];
		const targetSet = outMap.get(relcomponent as StatuhEntity);
		if (!targetSet) return [];
		const result: StatuhEntity[] = [];
		for (const target of targetSet) {
			result.push(target);
		}
		return result;
	}

	get_relationship_target(source_entity: StatuhEntity, relcomponent: StatuhTerm): StatuhEntity | undefined {
		const targets = this.get_relationship_targets(source_entity, relcomponent);
		return targets[0] || undefined;
	}

	get_relationship_sources(target_entity: StatuhEntity, relcomponent: StatuhTerm): StatuhEntity[] {
		const inMap = this._relIn.get(target_entity);
		if (!inMap) return [];
		const sourceSet = inMap.get(relcomponent as StatuhEntity);
		if (!sourceSet) return [];
		const result: StatuhEntity[] = [];
		for (const source of sourceSet) {
			result.push(source);
		}
		return result;
	}

	get_relationship_source(target_entity: StatuhEntity, relcomponent: StatuhTerm): StatuhEntity | undefined {
		const inMap = this._relIn.get(target_entity);
		if (!inMap) return undefined;
		const sourceSet = inMap.get(relcomponent as StatuhEntity);
		if (!sourceSet) return undefined;
		for (const source of sourceSet) {
			return source;
		}
		return undefined;
	}

	// Queries
	query_entities_of_archetype(with_components?: StatuhTerm[], without_components?: StatuhTerm[]): StatuhEntity[] {
		// 1. Normalise inputs
		const required = new Set(with_components?.filter((x) => x !== undefined) ?? []);
		const forbidden = new Set(without_components?.filter((x) => x !== undefined) ?? []);

		// 2. Fast-exit if with_components is empty and there are no exclusion rules with wildcards
		if (required.size() === 0) {
			const hasWildcardExclusion = [...forbidden].some(
				(term) =>
					(term as unknown as PairRuntime).__kind === "pair" &&
					(term as unknown as PairRuntime).object === this._wildcard,
			);
			if (required.size() === 0 && !hasWildcardExclusion) {
				return [];
			}
		}

		const matches: StatuhEntity[] = [];
		for (const e of this._entities) {
			const entityComponentSet = this._componentSets.get(e);
			if (!entityComponentSet) continue; // Should not happen for valid entities

			let isMatch = true;

			// Check required components
			for (const requiredComp of required) {
				const isPair = (requiredComp as unknown as PairRuntime).__kind === "pair";
				let found = false;
				if (isPair) {
					const requiredPair = requiredComp as unknown as PairRuntime;
					if (requiredPair.object === this._wildcard) {
						// Wildcard match: (Predicate, *)
						for (const entityComp of entityComponentSet) {
							const entityPair = entityComp as unknown as PairRuntime;
							if (entityPair.__kind === "pair" && entityPair.predicate === requiredPair.predicate) {
								found = true;
								break;
							}
						}
					} else {
						// Regular pair check
						found = entityComponentSet.has(requiredComp);
					}
				} else {
					// Regular component check
					found = entityComponentSet.has(requiredComp);
				}

				if (!found) {
					isMatch = false;
					break;
				}
			}

			if (!isMatch) continue;

			// Check forbidden components
			for (const forbiddenComp of forbidden) {
				const isPair = (forbiddenComp as unknown as PairRuntime).__kind === "pair";
				let found = false;
				if (isPair) {
					const forbiddenPair = forbiddenComp as unknown as PairRuntime;
					if (forbiddenPair.object === this._wildcard) {
						// Wildcard exclusion: (Predicate, *)
						for (const entityComp of entityComponentSet) {
							const entityPair = entityComp as unknown as PairRuntime;
							if (entityPair.__kind === "pair" && entityPair.predicate === forbiddenPair.predicate) {
								found = true;
								break;
							}
						}
					} else {
						// Regular pair check
						found = entityComponentSet.has(forbiddenComp);
					}
				} else {
					// Regular component check
					found = entityComponentSet.has(forbiddenComp);
				}

				if (found) {
					isMatch = false;
					break;
				}
			}

			if (isMatch) {
				matches.push(e);
			}
		}

		// 5. Deterministic order
		matches.sort((a, b) => this.order_entities(a, b));
		return matches;
	}

	// Hook registration methods
	add_component_hook_added<C extends StatuhTerm>(
		component: C,
		hook: (entity: StatuhEntity, id: StatuhEntity<unknown>, data: InferTypedData<C>) => void,
	): void {
		if (!this._addedHooks.has(component)) {
			this._addedHooks.set(component, []);
		}
		this._addedHooks
			.get(component)!
			.push(hook as (entity: StatuhEntity, id: StatuhEntity<unknown>, data: unknown) => void);
	}

	// Relationship hook registration methods
	add_relationship_hook_added<P, O>(
		predicate: StatuhEntity<P>,
		hook: (
			source: StatuhEntity,
			predicateId: StatuhEntity<P>,
			target: StatuhEntity<O>,
			data: InferTypedData<StatuhPair<P, O>>,
		) => void,
	): void {
		if (!this._relAddedHooks.has(predicate as unknown as StatuhEntity)) {
			this._relAddedHooks.set(predicate as unknown as StatuhEntity, []);
		}
		this._relAddedHooks
			.get(predicate as unknown as StatuhEntity)!
			.push(
				hook as unknown as (
					source: StatuhEntity,
					predicateId: StatuhEntity<unknown>,
					target: StatuhEntity<unknown>,
					data: unknown,
				) => void,
			);
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
		if (!this._relSetHooks.has(predicate as unknown as StatuhEntity)) {
			this._relSetHooks.set(predicate as unknown as StatuhEntity, []);
		}
		this._relSetHooks
			.get(predicate as unknown as StatuhEntity)!
			.push(
				hook as unknown as (
					source: StatuhEntity,
					predicateId: StatuhEntity<unknown>,
					target: StatuhEntity<unknown>,
					data: unknown,
				) => void,
			);
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
		if (!this._relRemovedHooks.has(predicate as unknown as StatuhEntity)) {
			this._relRemovedHooks.set(predicate as unknown as StatuhEntity, []);
		}
		this._relRemovedHooks
			.get(predicate as unknown as StatuhEntity)!
			.push(
				hook as unknown as (
					source: StatuhEntity,
					predicateId: StatuhEntity<unknown>,
					target: StatuhEntity<unknown>,
					data: unknown,
				) => void,
			);
	}

	add_component_hook_setted<C extends StatuhTerm>(
		component: C,
		hook: (entity: StatuhEntity, id: StatuhEntity<unknown>, data: InferTypedData<C>) => void,
	): void {
		if (!this._setHooks.has(component)) {
			this._setHooks.set(component, []);
		}
		this._setHooks
			.get(component)!
			.push(hook as (entity: StatuhEntity, id: StatuhEntity<unknown>, data: unknown) => void);
	}

	add_component_hook_removed<C extends StatuhTerm>(
		component: C,
		hook: (entity: StatuhEntity, id: StatuhEntity<unknown>, data: InferTypedData<C>) => void,
	): void {
		if (!this._removedHooks.has(component)) {
			this._removedHooks.set(component, []);
		}
		this._removedHooks
			.get(component)!
			.push(hook as (entity: StatuhEntity, id: StatuhEntity<unknown>, data: unknown) => void);
	}

	// Component removal
	remove_component(entity: StatuhEntity, component: StatuhTerm): void {
		const componentMap = this._data.get(entity);
		const componentSet = this._componentSets.get(entity);

		if (componentMap && componentSet && componentSet.has(component)) {
			// Get data before removing for the hook
			const data = componentMap.get(component);

			// Fire removed hooks before actual removal
			this.runRemovedHooks(component, entity, data);

			// Relationship removed hooks (before data removal)
			if ((component as unknown as PairRuntime).__kind === "pair") {
				const pr = component as unknown as PairRuntime;
				this.runRelRemovedHooks(pr.predicate, entity, pr.object);
			}

			// Remove from data structures
			componentMap.delete(component);
			componentSet.delete(component);

			// Handle pair relationship cleanup
			if (globalPairInfo.has(component as StatuhPair)) {
				// Clear relationships for this specific pair
				const pairRuntime = component as unknown as PairRuntime;
				const predicate = pairRuntime.predicate;
				const target = pairRuntime.object;

				// Remove from outgoing relationships
				const outMap = this._relOut.get(entity);
				if (outMap) {
					const targetSet = outMap.get(predicate);
					if (targetSet) {
						targetSet.delete(target);
						if (targetSet.size() === 0) {
							outMap.delete(predicate);
						}
					}
					if (outMap.size() === 0) {
						this._relOut.delete(entity);
					}
				}

				// Remove from incoming relationships
				const inMap = this._relIn.get(target);
				if (inMap) {
					const sourceSet = inMap.get(predicate);
					if (sourceSet) {
						sourceSet.delete(entity);
						if (sourceSet.size() === 0) {
							inMap.delete(predicate);
						}
					}
					if (inMap.size() === 0) {
						this._relIn.delete(target);
					}
				}
			}
		}
	}

	order_entities(entityA: StatuhEntity, entityB: StatuhEntity): boolean {
		return (entityA as unknown as EntityRuntime).__id < (entityB as unknown as EntityRuntime).__id;
	}

	entity_to_string(entity: StatuhEntity): string {
		return tostring((entity as unknown as EntityRuntime).__id);
	}

	entity_to_number(entity: StatuhEntity): number {
		return (entity as unknown as EntityRuntime).__id!;
	}

	get_wildcard(): StatuhEntity {
		return this._wildcard;
	}

	// Entity hooks
	add_entity_hook_deleted(hook: (entity: StatuhEntity) => void): void {
		this._entityDeletedHooks.push(hook);
	}
}

// Global pair info set for all worlds
const globalPairInfo = new Set<StatuhPair>();

// Public API functions
export function create_world(): StatuhWorld {
	return new BaseStatuh();
}

export function pair<P, O>(predicate: StatuhEntity<P>, object: StatuhEntity<O>): StatuhPair<P, O> {
	// Get or create the nested map for this predicate
	let byObject = pairCache.get(predicate);
	if (!byObject) {
		byObject = new Map();
		pairCache.set(predicate, byObject);
	}

	// Get or create the pair for this predicate-object combination
	let pairResult = byObject.get(object);
	if (!pairResult) {
		pairResult = {
			predicate,
			object,
			__kind: "pair" as const,
		} as unknown as StatuhPair<P, O>;

		byObject.set(object, pairResult);
		globalPairInfo.add(pairResult);
	}

	return pairResult as StatuhPair<P, O>;
}
