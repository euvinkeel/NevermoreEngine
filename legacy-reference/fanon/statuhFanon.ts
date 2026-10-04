// As an implementation of a FANON system using Statuh
// we need to know if a component is replicated or not.
// Any Statuh entity with a shared component is replicated.

import Bimap from "shared/utils/primitives/bimap";
import { StatuhComponent, StatuhEntity, StatuhWorld } from "../../statuh/statuhTypes";
import { _LocalName, AuthorId, StatuhFanonName } from "./statuhFanonName";
import deque from "shared/utils/primitives/deque";
import { ActionRecord } from "./statuhFanonAction";
import unorderedSet from "shared/utils/primitives/unorderedSet";

export interface StatuhFanonRuntime {
	_statuh_world: StatuhWorld;
	_author_name: AuthorId | undefined;

	_local_name_counter: number;
	_local_name_w_statuh_entity: Bimap<_LocalName, StatuhEntity>;
	_registered_names: unorderedSet<_LocalName>;

	_replicated_components: Set<StatuhComponent>;
	_component_w_number_key: Bimap<StatuhComponent, number>;

	_accumulated_action_records: deque<ActionRecord>;
}

// Creates a blank runtime state and auto-populates replicates components (giving them a numerical key)
// and creates a local name for each entity.
export const initStatuhFanonRuntime = (
	statuh_world: StatuhWorld,
	replicated_components: StatuhComponent[],
	replicated_entities: StatuhEntity[],
	author_name?: AuthorId, // Leave blank to wait for author name later.
	// (Will be locked until a valid author name is set)
) => {
	const newRuntime: StatuhFanonRuntime = {
		_statuh_world: statuh_world,
		_author_name: author_name,
		_local_name_counter: 1,
		_local_name_w_statuh_entity: new Bimap(),
		_registered_names: new unorderedSet(),
		_replicated_components: new Set(),
		_component_w_number_key: new Bimap(),
		_accumulated_action_records: new deque<ActionRecord>(),
	};

	let component_key = 0;
	for (const component of replicated_components) {
		newRuntime._component_w_number_key.set(component, component_key);
		newRuntime._replicated_components.add(component);
		component_key++;
	}

	for (const entity of replicated_entities) {
		const localName = StatuhFanonName.generateLocalName(newRuntime);
		StatuhFanonName.registerLocalNameWithStatuhEntity(newRuntime, localName, entity);
	}

	return newRuntime;
};

export const resetStatuhFanonRuntime = (runtime: StatuhFanonRuntime) => {
	// print("[RESET] Resetting Statuh Fanon Runtime");
	// never reset the name counter... i think we require it to be unique counter
	runtime._local_name_w_statuh_entity.clear();
	runtime._registered_names.clear();
	// runtime._replicated_components.clear();
	// runtime._component_w_number_key.clear();
	runtime._accumulated_action_records.clear();
};
