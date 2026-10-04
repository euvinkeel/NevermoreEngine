import { _LocalName, StatuhFanonName } from "./statuhFanonName";
import {
	InferTypedData,
	InferTypedDatas,
	Nullable,
	StatuhComponent,
	StatuhEntity,
	StatuhPair,
	StatuhTerm,
	StatuhTerms,
	StatuhWorld,
} from "shared/libs/statuh/statuhTypes";
import { StatuhFanonRuntime } from "./statuhFanon";
import { Diffsteps, StatuhFanonDiffstep } from "./statuhFanonDiffstep";
import { statuh_pair } from "shared/libs/statuh/statuhRuntime";
import { ActionId } from "./statuhFanonAction";
import deque from "shared/utils/primitives/deque";
const makestep = StatuhFanonDiffstep.Make;

export class StatuhFanonHandle implements StatuhWorld {
	public _statuh_world: StatuhWorld;
	public _statuh_fanon_runtime: StatuhFanonRuntime;
	public _accumulated_diffstep_builder: StatuhFanonDiffstep.DiffstepBuilder;
	public _accumulated_inverse_diffstep_builder: StatuhFanonDiffstep.InverseDiffstepBuilder;

	public _curr_action_diffstep_builder: StatuhFanonDiffstep.DiffstepBuilder;
	public _curr_action_inverse_diffstep_builder: StatuhFanonDiffstep.InverseDiffstepBuilder;

	public _tracking_action_id: ActionId | undefined;
	public _accumulated_names: _LocalName[] = [];

	// Used for replay mode, newly created entities will grab from here.
	public _new_name_queue: deque<_LocalName> = new deque();

	constructor(statuh_fanon_runtime: StatuhFanonRuntime) {
		this._statuh_fanon_runtime = statuh_fanon_runtime;
		this._statuh_world = statuh_fanon_runtime._statuh_world;
		this._accumulated_diffstep_builder = new StatuhFanonDiffstep.DiffstepBuilder();
		this._accumulated_inverse_diffstep_builder = new StatuhFanonDiffstep.InverseDiffstepBuilder();
		this._curr_action_diffstep_builder = new StatuhFanonDiffstep.DiffstepBuilder();
		this._curr_action_inverse_diffstep_builder = new StatuhFanonDiffstep.InverseDiffstepBuilder();
	}

	reset_all_handle_tracking_state(): void {
		this.reset_diffstep_builders();
		this.stop_tracking_action();
		this.clear_new_name_queue();
		this._accumulated_names = [];
	}

	enqueue_new_name_to_queue(name: _LocalName): void {
		this._new_name_queue.appendRight(name);
	}

	clear_new_name_queue(): void {
		this._new_name_queue.clear();
	}

	start_tracking_action(actionId: ActionId): void {
		if (this._tracking_action_id !== undefined) {
			warn(
				`You must stop tracking an action before starting a new one. Current action: ${this._tracking_action_id}`,
			);
		}
		this._tracking_action_id = actionId;
		this._accumulated_names = [];
	}

	stop_tracking_action(): void {
		// Should be called at the end of an action
		// whether or not it was successfully executed.
		this._tracking_action_id = undefined;
	}

	reject_tracked_action_and_get_correction_diffsteps(): Diffsteps {
		assert(this._tracking_action_id !== undefined, "You must start tracking an action before rejecting it");
		// If an action errors out, we have to reverse each operation we did.
		// At least reverse the diffstep structure,
		// and maybe salvage what we can from the underlying world?
		const correction_diffsteps = this._curr_action_inverse_diffstep_builder.get_diffsteps();
		this._curr_action_diffstep_builder.clear();
		this._curr_action_inverse_diffstep_builder.clear();
		return correction_diffsteps;
	}

	commit_tracked_action(): void {
		// When an action is successfully executed, we have to commit the diffsteps to accumulated diffsteps.
		// We also have to clear the current action diffsteps.
		this._accumulated_diffstep_builder.add_diffsteps(this._curr_action_diffstep_builder.get_diffsteps());
		this._accumulated_inverse_diffstep_builder.add_diffsteps(
			this._curr_action_inverse_diffstep_builder.get_raw_diffsteps(),
		);
		// print("After committing action", this._tracking_action_id);
		// print("Accumulated diffsteps:", this._accumulated_diffstep_builder);
		// print("Accumulated inverse diffsteps:", this._accumulated_inverse_diffstep_builder);
		this._curr_action_diffstep_builder.clear();
		this._curr_action_inverse_diffstep_builder.clear();
	}

	get_tracked_names(): _LocalName[] {
		if (this._tracking_action_id === undefined) {
			error("You must start tracking new names before getting tracked names");
		}
		return this._accumulated_names;
	}

	has_mark(mark: number): boolean {
		return (
			this._accumulated_diffstep_builder.has_mark(mark) &&
			this._accumulated_inverse_diffstep_builder.has_mark(mark)
		);
	}

	mark_last_operation(count: number): boolean {
		if (this._accumulated_diffstep_builder._diffsteps.size() === 0) {
			// will fail to mark; actions could be empty
			// and thus if the server sends us back this mark, we'd attempt to get something
			// that wasn't marked
			error("No diffsteps to mark");
		}
		if (this._accumulated_inverse_diffstep_builder._inverse_diffsteps.size() === 0) {
			error("No inverse diffsteps to mark");
		}
		this._accumulated_diffstep_builder.mark_last_operation(count);
		this._accumulated_inverse_diffstep_builder.mark_last_operation(count);
		return true;
	}

	rebuild_after_mark(mark: number): void {
		// print("Rebuild called. State before:");
		// print(this._accumulated_diffstep_builder);
		// print(this._accumulated_inverse_diffstep_builder);
		this._accumulated_diffstep_builder.rebuild_after_mark_and_reevaluate(mark);
		this._accumulated_inverse_diffstep_builder.rebuild_after_mark_and_reevaluate(mark);
	}

	reset_diffstep_builders(): void {
		this._accumulated_diffstep_builder.clear();
		this._accumulated_inverse_diffstep_builder.clear();
		this._curr_action_diffstep_builder.clear();
		this._curr_action_inverse_diffstep_builder.clear();
	}

	get_additive_diffstep_builder(): StatuhFanonDiffstep.DiffstepBuilder {
		return this._accumulated_diffstep_builder;
	}

	create_entity(): StatuhEntity {
		const newEntity = this._statuh_world.create_entity();
		const newReplayNameInQueue = this._new_name_queue.popq();
		let finalName: _LocalName;
		let usedQueuedName: boolean = false;
		if (newReplayNameInQueue === undefined) {
			// no replay name in queue, generate a new one.
			finalName = StatuhFanonName.generateLocalName(this._statuh_fanon_runtime);
		} else {
			// use the replay name.
			finalName = newReplayNameInQueue;
			usedQueuedName = true;
		}
		StatuhFanonName.registerLocalNameWithStatuhEntity(this._statuh_fanon_runtime, finalName, newEntity);
		assert(this._tracking_action_id !== undefined, "Handles must have a tracking action id");
		this._curr_action_inverse_diffstep_builder.attempt_add_diffstep(makestep.DEL(finalName));
		this._curr_action_diffstep_builder.add_diffstep(makestep.NEW(finalName));
		if (!usedQueuedName) {
			this._accumulated_names.push(finalName);
		}
		return newEntity;
	}

	private _get_component_stuff(term: StatuhComponent): {
		component: StatuhEntity<unknown>;
		componentKey: number;
	} {
		const componentKey = this._statuh_fanon_runtime._component_w_number_key.getMappingToB(term);
		if (componentKey === undefined) {
			warn(debug.traceback());
			warn(this._statuh_fanon_runtime._component_w_number_key);
			error(`component ${term} has no number key mapped in componentToNumberKey`);
		}
		return {
			component: term,
			componentKey,
		};
	}

	private _get_pair_stuff(pair: StatuhPair<unknown, unknown>): {
		relationComponent: StatuhEntity;
		relationComponentKey: number;
		target: StatuhEntity;
		relationTargetName: _LocalName;
	} {
		const relationComponent = this.get_pair_predicate(pair);
		const relationComponentKey =
			this._statuh_fanon_runtime._component_w_number_key.getMappingToB(relationComponent);
		if (relationComponentKey === undefined) {
			warn(debug.traceback());
			warn(this._statuh_fanon_runtime._component_w_number_key);
			error(`relation component ${relationComponent} has no number key mapped in componentToNumberKey`);
		}
		const target = this.get_pair_object(pair);
		assert(this._statuh_world.contains_entity(target), `object ${target} is not in the world`);
		const relationTargetName = StatuhFanonName.getFanonNameFromStatuhEntity(this._statuh_fanon_runtime, target);
		assert(relationTargetName, `relation target ${target} has no local name mapped in localNameToStatuhEntity`);

		return {
			relationComponent,
			relationComponentKey,
			target,
			relationTargetName,
		};
	}

	private _add_entity_last_state_diffstep(entity: StatuhEntity, localName: _LocalName): void {
		const replicated_components = this._statuh_fanon_runtime._replicated_components;
		const world = this._statuh_world;
		this._curr_action_inverse_diffstep_builder.attempt_add_diffstep(makestep.NEW(localName));

		for (const component of replicated_components) {
			const { componentKey } = this._get_component_stuff(component);
			if (world.has_component(entity, component)) {
				const lastData = world.get_component_data(entity, component);
				if (lastData === undefined) {
					this._curr_action_inverse_diffstep_builder.attempt_add_diffstep(
						makestep.ADD(localName, componentKey),
					);
				} else {
					this._curr_action_inverse_diffstep_builder.attempt_add_diffstep(
						makestep.SET(localName, componentKey, lastData as defined),
					);
				}
			}

			const relationship_targets = world.get_relationship_targets(entity, component);
			for (const relationship_target of relationship_targets) {
				// We know that there is a rel from entity -> component -> relationship_target.
				const targetName = StatuhFanonName.getFanonNameFromStatuhEntity(
					this._statuh_fanon_runtime,
					relationship_target,
				);
				assert(
					targetName,
					`relationship target ${relationship_target} has no local name mapped in localNameToStatuhEntity`,
				);
				const relData = world.get_component_data(entity, statuh_pair(component, relationship_target));
				if (relData === undefined) {
					this._curr_action_inverse_diffstep_builder.attempt_add_diffstep(
						makestep.ADDREL(localName, componentKey, targetName),
					);
				} else {
					this._curr_action_inverse_diffstep_builder.attempt_add_diffstep(
						makestep.SETREL(localName, componentKey, targetName, relData as defined),
					);
				}
			}
			const relationship_sources = world.get_relationship_sources(entity, component);
			for (const relationship_source of relationship_sources) {
				// We know that there is a rel from relationship_source -> component -> entity.
				const sourceName = StatuhFanonName.getFanonNameFromStatuhEntity(
					this._statuh_fanon_runtime,
					relationship_source,
				);
				assert(
					sourceName,
					`relationship source ${relationship_source} has no local name mapped in localNameToStatuhEntity`,
				);
				const relData = world.get_component_data(relationship_source, statuh_pair(component, entity));
				if (relData === undefined) {
					this._curr_action_inverse_diffstep_builder.attempt_add_diffstep(
						makestep.ADDREL(sourceName, componentKey, localName),
					);
				} else {
					this._curr_action_inverse_diffstep_builder.attempt_add_diffstep(
						makestep.SETREL(sourceName, componentKey, localName, relData as defined),
					);
				}
			}
		}
	}

	private _add_component_last_state_diffstep(entity: StatuhEntity, term: StatuhTerm, localName: _LocalName): void {
		// last state. Cases:
		// the component was there, with no data.
		// the component was there, with data.
		// the component was not there.
		if (this.is_term_pair(term)) {
			const { relationComponentKey, relationTargetName } = this._get_pair_stuff(term);
			if (this._statuh_world.has_component(entity, term)) {
				const lastData = this._statuh_world.get_component_data(entity, term);
				if (lastData === undefined) {
					this._curr_action_inverse_diffstep_builder.attempt_add_diffstep(
						makestep.ADDREL(localName, relationComponentKey, relationTargetName),
					);
				} else {
					this._curr_action_inverse_diffstep_builder.attempt_add_diffstep(
						makestep.SETREL(localName, relationComponentKey, relationTargetName, lastData as defined),
					);
				}
			} else {
				this._curr_action_inverse_diffstep_builder.attempt_add_diffstep(
					makestep.REMREL(localName, relationComponentKey, relationTargetName),
				);
			}
		} else {
			const { componentKey } = this._get_component_stuff(term);
			if (this._statuh_world.has_component(entity, term)) {
				const lastData = this._statuh_world.get_component_data(entity, term);
				if (lastData === undefined) {
					this._curr_action_inverse_diffstep_builder.attempt_add_diffstep(
						makestep.ADD(localName, componentKey),
					);
				} else {
					this._curr_action_inverse_diffstep_builder.attempt_add_diffstep(
						makestep.SET(localName, componentKey, lastData as defined),
					);
				}
			} else {
				this._curr_action_inverse_diffstep_builder.attempt_add_diffstep(makestep.REM(localName, componentKey));
			}
		}
	}

	add_component<C extends StatuhTerm>(
		entity: StatuhEntity,
		term: undefined extends InferTypedData<C> ? C : StatuhTerm<undefined>,
	): void {
		assert(this._tracking_action_id !== undefined, "Handles must have a tracking action id");
		assert(this._statuh_world.contains_entity(entity), `entity ${entity} is not in the world`);
		const localName = StatuhFanonName.getFanonNameFromStatuhEntity(this._statuh_fanon_runtime, entity);
		assert(localName, `entity ${entity} has no local name mapped in localNameToStatuhEntity`);
		if (this.is_term_pair(term)) {
			const { relationComponentKey, relationTargetName } = this._get_pair_stuff(term);
			this._add_component_last_state_diffstep(entity, term, localName);
			this._statuh_world.add_component(entity, term as StatuhTerm);
			this._curr_action_diffstep_builder.add_diffstep(
				makestep.ADDREL(localName, relationComponentKey, relationTargetName),
			);
		} else {
			const { componentKey } = this._get_component_stuff(term);
			this._add_component_last_state_diffstep(entity, term, localName);
			this._statuh_world.add_component(entity, term);
			this._curr_action_diffstep_builder.add_diffstep(makestep.ADD(localName, componentKey));
		}
	}
	set_component_data<E extends StatuhTerm>(entity: StatuhEntity, term: E, data: InferTypedData<E>): void {
		assert(this._tracking_action_id !== undefined, "Handles must have a tracking action id");
		assert(this._statuh_world.contains_entity(entity), `entity ${entity} is not in the world`);
		const localName = StatuhFanonName.getFanonNameFromStatuhEntity(this._statuh_fanon_runtime, entity);
		assert(localName, `entity ${entity} has no local name mapped in localNameToStatuhEntity`);

		if (this.is_term_pair(term)) {
			const { relationComponentKey, relationTargetName } = this._get_pair_stuff(term);
			this._add_component_last_state_diffstep(entity, term, localName);
			this._statuh_world.set_component_data(entity, term, data);
			this._curr_action_diffstep_builder.add_diffstep(
				makestep.SETREL(localName, relationComponentKey, relationTargetName, data as defined),
			);
		} else {
			const { componentKey } = this._get_component_stuff(term);
			this._add_component_last_state_diffstep(entity, term, localName);
			this._statuh_world.set_component_data(entity, term, data);
			this._curr_action_diffstep_builder.add_diffstep(makestep.SET(localName, componentKey, data as defined));
		}
	}
	remove_component(entity: StatuhEntity, term: StatuhTerm): void {
		assert(this._tracking_action_id !== undefined, "Handles must have a tracking action id");
		assert(this._statuh_world.contains_entity(entity), `entity ${entity} is not in the world`);
		const localName = StatuhFanonName.getFanonNameFromStatuhEntity(this._statuh_fanon_runtime, entity);
		assert(localName, `entity ${entity} has no local name mapped in localNameToStatuhEntity`);
		if (this.is_term_pair(term)) {
			const { relationComponentKey, relationTargetName } = this._get_pair_stuff(term);
			this._add_component_last_state_diffstep(entity, term, localName);
			this._statuh_world.remove_component(entity, term);
			this._curr_action_diffstep_builder.add_diffstep(
				makestep.REMREL(localName, relationComponentKey, relationTargetName),
			);
		} else {
			const { componentKey } = this._get_component_stuff(term);
			this._add_component_last_state_diffstep(entity, term, localName);
			this._statuh_world.remove_component(entity, term);
			this._curr_action_diffstep_builder.add_diffstep(makestep.REM(localName, componentKey));
		}
	}
	delete_entity(entity: StatuhEntity): void {
		assert(this._tracking_action_id !== undefined, "Handles must have a tracking action id");
		const localName = StatuhFanonName.getFanonNameFromStatuhEntity(this._statuh_fanon_runtime, entity);
		assert(localName, `entity ${entity} has no local name mapped in localNameToStatuhEntity`);
		this._add_entity_last_state_diffstep(entity, localName);
		if (this._statuh_world.contains_entity(entity)) {
			this._statuh_world.delete_entity(entity);
		} else {
			warn(`jecs: attempted delete, but entity ${entity} is not in the world`);
		}
		this._curr_action_diffstep_builder.add_diffstep(makestep.DEL(localName));
	}
	delete_all_entities(): void {
		assert(this._tracking_action_id !== undefined, "Handles must have a tracking action id");
		for (const localName of this._statuh_fanon_runtime._registered_names.getList()) {
			const entity = StatuhFanonName.getStatuhEntityFromLocalName(this._statuh_fanon_runtime, localName);
			if (entity) {
				this._add_entity_last_state_diffstep(entity, localName);
			}
		}
		this._statuh_world.delete_all_entities();
		for (const localName of this._statuh_fanon_runtime._registered_names.getList()) {
			this._curr_action_diffstep_builder.add_diffstep(makestep.DEL(localName));
		}
	}

	get_inverted_diffsteps() {
		return this._accumulated_inverse_diffstep_builder.get_diffsteps();
	}
	get_inverse_diffstep_builder() {
		return this._accumulated_inverse_diffstep_builder;
	}
	get_entity_count(): number {
		return this._statuh_world.get_entity_count();
	}

	// read only/non-middleware methods
	register_component<TypedData = unknown>(): StatuhEntity<TypedData> {
		warn(debug.traceback());
		error("You cannot register components on a StatuhFanonHandle");
	}
	set_component_name(component: StatuhEntity<unknown>, name: string): void {
		this._statuh_world.set_component_name(component, name);
	}
	get_component_name(component: StatuhEntity<unknown>): string {
		return this._statuh_world.get_component_name(component);
	}
	is_term_pair(term: StatuhTerm): term is StatuhPair<unknown, unknown> {
		return this._statuh_world.is_term_pair(term);
	}
	is_term_component(term: StatuhTerm): term is StatuhEntity<unknown> {
		return this._statuh_world.is_term_component(term);
	}
	get_pair_predicate(pair: StatuhPair<unknown, unknown>): StatuhEntity<unknown> {
		return this._statuh_world.get_pair_predicate(pair);
	}
	get_pair_object(pair: StatuhPair<unknown, unknown>): StatuhEntity<unknown> {
		return this._statuh_world.get_pair_object(pair);
	}
	contains_entity(entity: StatuhEntity): boolean {
		return this._statuh_world.contains_entity(entity);
	}
	get_all_entities(): StatuhEntity[] {
		return this._statuh_world.get_all_entities();
	}
	order_entities(entityA: StatuhEntity, entityB: StatuhEntity): boolean {
		return this._statuh_world.order_entities(entityA, entityB);
	}
	entity_to_string(entity: StatuhEntity): string {
		return this._statuh_world.entity_to_string(entity);
	}
	entity_to_number(entity: StatuhEntity): number {
		return this._statuh_world.entity_to_number(entity);
	}
	get_all_components(): StatuhEntity[] {
		return this._statuh_world.get_all_components();
	}
	has_component(entity: StatuhEntity, component: StatuhTerm): boolean {
		return this._statuh_world.has_component(entity, component);
	}
	get_component_datas<T extends StatuhTerms>(
		entity: StatuhEntity,
		...components: T
	): LuaTuple<Nullable<InferTypedDatas<T>>> {
		return this._statuh_world.get_component_datas(entity, ...components);
	}
	get_component_data<T extends StatuhTerm>(entity: StatuhEntity, component: T): InferTypedData<T> {
		return this._statuh_world.get_component_data(entity, component);
	}
	add_component_hook_added<C extends StatuhTerm>(
		component: C,
		hook: (entity: StatuhEntity, id: StatuhEntity<unknown>, data: InferTypedData<C>) => void,
	): void {
		this._statuh_world.add_component_hook_added(component, hook);
	}
	add_component_hook_setted<C extends StatuhTerm>(
		component: C,
		hook: (entity: StatuhEntity, id: StatuhEntity<unknown>, data: InferTypedData<C>) => void,
	): void {
		this._statuh_world.add_component_hook_setted(component, hook);
	}
	add_component_hook_removed<C extends StatuhTerm>(
		component: C,
		hook: (entity: StatuhEntity, id: StatuhEntity<unknown>, data: InferTypedData<C>) => void,
	): void {
		this._statuh_world.add_component_hook_removed(component, hook);
	}
	add_relationship_hook_added<P, O>(
		predicate: StatuhEntity<P>,
		hook: (
			source: StatuhEntity,
			predicateId: StatuhEntity<P>,
			target: StatuhEntity<O>,
			data: InferTypedData<StatuhPair<P, O>>,
		) => void,
	): void {
		this._statuh_world.add_relationship_hook_added(predicate, hook);
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
		this._statuh_world.add_relationship_hook_setted(predicate, hook);
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
		this._statuh_world.add_relationship_hook_removed(predicate, hook);
	}
	add_entity_hook_deleted(hook: (entity: StatuhEntity) => void): void {
		this._statuh_world.add_entity_hook_deleted(hook);
	}
	get_relationship_targets(source_entity: StatuhEntity, relcomponent: StatuhTerm): StatuhEntity[] {
		return this._statuh_world.get_relationship_targets(source_entity, relcomponent);
	}
	get_relationship_target(source_entity: StatuhEntity, relcomponent: StatuhTerm): StatuhEntity | undefined {
		return this._statuh_world.get_relationship_target(source_entity, relcomponent);
	}
	get_relationship_sources(target_entity: StatuhEntity, relcomponent: StatuhTerm): StatuhEntity[] {
		return this._statuh_world.get_relationship_sources(target_entity, relcomponent);
	}
	get_relationship_source(target_entity: StatuhEntity, relcomponent: StatuhTerm): StatuhEntity | undefined {
		return this._statuh_world.get_relationship_source(target_entity, relcomponent);
	}
	query_entities_of_archetype(with_components?: StatuhTerm[], without_components?: StatuhTerm[]): StatuhEntity[] {
		return this._statuh_world.query_entities_of_archetype(with_components, without_components);
	}
	get_wildcard(): StatuhEntity {
		return this._statuh_world.get_wildcard();
	}
}
