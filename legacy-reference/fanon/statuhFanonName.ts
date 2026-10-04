import { StatuhEntity } from "shared/libs/statuh/statuhTypes";
import { StatuhFanonRuntime } from "./statuhFanon";
import Object from "shared/libs/vendor/objectutils";

export type AuthorId = string;
export type _LocalName = string; // the name of the local entity

// Generating names and translation require internal state.
export namespace StatuhFanonName {
	export const generateLocalName = (runtime: StatuhFanonRuntime): _LocalName => {
		return `${runtime._author_name}_${runtime._local_name_counter++}`;
	};

	export const setAuthorName = (runtime: StatuhFanonRuntime, authorName: AuthorId) => {
		// if (runtime._author_name) error("Author name is already set");
		runtime._author_name = authorName;
	};

	export const isLocalName = (runtime: StatuhFanonRuntime, name: string): boolean => {
		const authorName = runtime._author_name;
		if (!authorName) error("Author name is not set");
		return string.sub(name, 1, authorName.size() + 1) === authorName;
	};

	export const registerLocalNameWithStatuhEntity = (
		runtime: StatuhFanonRuntime,
		name: _LocalName,
		statuhEntity: StatuhEntity,
	) => {
		// print("[FANON MAP ADD]", name, statuhEntity);
		assert(name !== undefined, "Name is undefined");
		assert(statuhEntity !== undefined, "Statuh entity is undefined");

		// When registering, an entity should be existant.
		if (!runtime._statuh_world.contains_entity(statuhEntity)) {
			error(`Statuh entity ${statuhEntity} is not in the world at time of registration with name ${name}`);
		}

		// But after registration, entities could be undefined or not in the world.
		// Mapping can happen when creating a brand new NAME and new ENTITY.
		// Mapping can also happen when applying a redundant diffstep.
		const nameEncountered = runtime._registered_names.has(name);
		const existingEntityUnderName = runtime._local_name_w_statuh_entity.getMappingToB(name);

		if (nameEncountered) {
			// This name was mapped before.
			const existingEntity = runtime._local_name_w_statuh_entity.getMappingToB(name);
			// assert(existingEntity !== undefined, `Familiar name ${name} is mapped to nothing!`);
			// this should be expected at some times.
			if (existingEntity) {
				if (runtime._statuh_world.contains_entity(existingEntity)) {
					error(`Familiar name ${name} is still mapped to an ALIVE entity ${existingEntity}!`);
				} else {
					// So entity is not undefined but the world doesn't contain it.
					// Expected i guess idk
				}
			}
		} else {
			if (existingEntityUnderName !== undefined) {
				print(runtime);
				error(
					`Name ${name} is not in active set, but somehow has a mapping to underlying entity ${existingEntityUnderName}`,
				);
			}
		}

		// We can assign the same names to multiple entities if an entity was destroyed and a new one was created.
		// We can will NEVER assign the same entity to multiple names.
		const entityHasName = runtime._local_name_w_statuh_entity.getMappingToA(statuhEntity);
		if (entityHasName && entityHasName !== name) {
			error(
				`Statuh entity ${statuhEntity} already has a local name ${entityHasName}, attempted to replace with ${name}`,
			);
		}

		runtime._registered_names.add(name);
		runtime._local_name_w_statuh_entity.set(name, statuhEntity);
	};

	export const cleanupNonexistentEntitiesFromNameMap = (runtime: StatuhFanonRuntime) => {
		const localNameToStatuhEntity = runtime._local_name_w_statuh_entity;
		const entitiesToDelete: StatuhEntity[] = [];
		for (const [localName, statuhEntity] of Object.entries(localNameToStatuhEntity.getAtoBMap())) {
			if (!runtime._statuh_world.contains_entity(statuhEntity)) {
				entitiesToDelete.push(statuhEntity);
			}
		}
		let cleaned = 0;
		for (const entity of entitiesToDelete) {
			// print("[FANON MAP DEL]", entity, localNameToStatuhEntity.getMappingToA(entity));
			localNameToStatuhEntity.deleteB(entity);
			cleaned++;
		}
		// warn(`Cleaned ${cleaned} nonexistent entities from name map`);
		return cleaned;
	};

	export const getFanonNameFromStatuhEntity = (
		runtime: StatuhFanonRuntime,
		statuhEntity: StatuhEntity,
	): _LocalName | undefined => {
		return runtime._local_name_w_statuh_entity.getMappingToA(statuhEntity);
	};

	export const getStatuhEntityFromLocalName = (
		runtime: StatuhFanonRuntime,
		localName: _LocalName,
	): StatuhEntity | undefined => {
		return runtime._local_name_w_statuh_entity.getMappingToB(localName);
	};
}
