export type StatuhEntity<TypedData = unknown> = {
	readonly __nominal_StatuhEntity: unique symbol;
	readonly __type_TypedData: TypedData; // for when the entity is a component.
} & number;

export type StatuhComponent<TypedData = unknown> = StatuhEntity<TypedData>;

export type StatuhPair<Predicate = unknown, Object = unknown> = {
	readonly __nominal_StatuhPair: unique symbol;
	readonly __type_Predicate: Predicate;
	readonly __type_Object: Object;
} & number;

// For some reason, four terms specifically are the maximum for a get() call.
export type StatuhTerms =
	| [StatuhTerm]
	| [StatuhTerm, StatuhTerm]
	| [StatuhTerm, StatuhTerm, StatuhTerm]
	| [StatuhTerm, StatuhTerm, StatuhTerm, StatuhTerm];

// A term is used in queries; to get data about an entity.
// May be used to get attached data about a relation to another entity or a component.
export type StatuhTerm<TypedData = unknown> =
	| StatuhEntity<TypedData>
	| StatuhPair<TypedData, unknown>
	| StatuhPair<undefined, TypedData>;

// If passed an Entity (that is a component), returns the typed data.
// If passed a Pair, returns the predicate or object who has typed data.
export type InferTypedData<StatuhTerm> =
	StatuhTerm extends StatuhEntity<infer TypedData>
		? TypedData
		: StatuhTerm extends StatuhPair<infer Predicate, infer Object>
			? Predicate extends undefined
				? Object
				: Predicate
			: never;
type InferTypedDatas<A extends StatuhTerm[]> = { [K in keyof A]: InferTypedData<A[K]> };
type FlattenTuple<T extends unknown[]> = T extends [infer U] ? U : LuaTuple<T>;
type Nullable<T extends unknown[]> = { [K in keyof T]: T[K] | undefined };

export interface StatuhWorld {
	// Entity management
	create_entity(): StatuhEntity;
	// create_entity_in_range(range_begin: number, range_end: number): StatuhEntity;
	delete_entity(entity: StatuhEntity): void;
	contains_entity(entity: StatuhEntity): boolean;
	get_all_entities(): StatuhEntity[];
	delete_all_entities(): void;
	order_entities(entityA: StatuhEntity, entityB: StatuhEntity): boolean;
	entity_to_string(entity: StatuhEntity): string;
	entity_to_number(entity: StatuhEntity): number;

	get_entity_count(): number;

	// Component management
	is_term_pair(term: StatuhTerm): term is StatuhPair<unknown, unknown>;
	is_term_component(term: StatuhTerm): term is StatuhEntity<unknown>;
	get_pair_predicate(pair: StatuhPair<unknown, unknown>): StatuhEntity<unknown>;
	get_pair_object(pair: StatuhPair<unknown, unknown>): StatuhEntity<unknown>;

	register_component<TypedData = unknown>(): StatuhEntity<TypedData>;
	set_component_name(component: StatuhEntity, name: string): void;
	get_component_name(component: StatuhEntity): string;

	get_all_components(): StatuhEntity[];
	add_component<C extends StatuhTerm>(
		entity: StatuhEntity,
		component: undefined extends InferTypedData<C> ? C : StatuhTerm<undefined>,
	): void;
	set_component_data<E extends StatuhTerm>(entity: StatuhEntity, component: E, data: InferTypedData<E>): void;
	remove_component(entity: StatuhEntity, component: StatuhTerm): void;
	has_component(entity: StatuhEntity, component: StatuhTerm): boolean;
	get_component_datas<T extends StatuhTerms>(
		entity: StatuhEntity,
		...components: T
	): LuaTuple<Nullable<InferTypedDatas<T>>>;
	get_component_data<T extends StatuhTerm>(entity: StatuhEntity, component: T): InferTypedData<T>;

	// Hooks
	// Called right after a component is added to an entity (either after add_component or after set_component_data).
	add_component_hook_added<C extends StatuhTerm>(
		component: C,
		hook: (entity: StatuhEntity, id: StatuhEntity<unknown>, data: InferTypedData<C>) => void,
	): void;
	// Called right after a (non tag, data-associated) component is set on an entity (after set_component_data).
	add_component_hook_setted<C extends StatuhTerm>(
		component: C,
		hook: (entity: StatuhEntity, id: StatuhEntity<unknown>, data: InferTypedData<C>) => void,
	): void;
	// Called right before a component is removed from an entity (after remove_component or entity deletion).
	// This should fire right before the component is removed from the entity, hence the data is still available.
	add_component_hook_removed<C extends StatuhTerm>(
		component: C,
		hook: (entity: StatuhEntity, id: StatuhEntity<unknown>, data: InferTypedData<C>) => void,
	): void;

	// Relationship hooks (per predicate component)
	// Called when a pair (predicate, target) is added to a source entity. Fires after add and also on first set.
	add_relationship_hook_added<P, O>(
		predicate: StatuhEntity<P>,
		hook: (
			source: StatuhEntity,
			predicateId: StatuhEntity<P>,
			target: StatuhEntity<O>,
			data: InferTypedData<StatuhPair<P, O>>,
		) => void,
	): void;
	// Called on every set of the pair's data (including the first set after add).
	add_relationship_hook_setted<P, O>(
		predicate: StatuhEntity<P>,
		hook: (
			source: StatuhEntity,
			predicateId: StatuhEntity<P>,
			target: StatuhEntity<O>,
			data: InferTypedData<StatuhPair<P, O>>,
		) => void,
	): void;
	// Called right before a pair (predicate, target) is removed from a source entity (including entity deletion).
	add_relationship_hook_removed<P, O>(
		predicate: StatuhEntity<P>,
		hook: (
			source: StatuhEntity,
			predicateId: StatuhEntity<P>,
			target: StatuhEntity<O>,
			data: InferTypedData<StatuhPair<P, O>>,
		) => void,
	): void;

	// Entity hooks
	// Called during delete_entity after all component removed hooks have run and
	// relationships are cleared, but before the entity is fully purged from the world.
	add_entity_hook_deleted(hook: (entity: StatuhEntity) => void): void;

	// Relationships
	get_relationship_targets(source_entity: StatuhEntity, relcomponent: StatuhTerm): StatuhEntity[];
	get_relationship_target(source_entity: StatuhEntity, relcomponent: StatuhTerm): StatuhEntity | undefined;
	get_relationship_sources(target_entity: StatuhEntity, relcomponent: StatuhTerm): StatuhEntity[];
	get_relationship_source(target_entity: StatuhEntity, relcomponent: StatuhTerm): StatuhEntity | undefined;

	// Queries
	query_entities_of_archetype(with_components?: StatuhTerm[], without_components?: StatuhTerm[]): StatuhEntity[];

	get_wildcard(): StatuhEntity;

	[key: string]: any;
}

export interface StatuhImplementation {
	statuh_create_world(): StatuhWorld;
	statuh_pair<P, O>(predicate: StatuhEntity<P>, object: StatuhEntity<O>): StatuhPair<P, O>;
}
