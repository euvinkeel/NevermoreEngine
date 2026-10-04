import { _LocalName, StatuhFanonName } from "./statuhFanonName";
import { StatuhFanonRuntime } from "./statuhFanon";
import { statuh_pair } from "shared/libs/statuh/statuhRuntime";
import { StatuhFanonHandle } from "./statuhFanonHandle";
import Bimap from "shared/utils/primitives/bimap";
import { tableinlinestr } from "shared/utils/miscUtil";
import Object from "shared/libs/vendor/objectutils";
import { StatuhEntity } from "shared/libs/statuh/statuhTypes";

export type _ComponentKey = number;
export enum DiffstepOperation {
	NEW = 0,
	DEL = 1,
	ADD = 2,
	SET = 3,
	REM = 4,
	ADDREL = 5,
	SETREL = 6,
	REMREL = 7,
}

const _MAX_DIFFSTEPS = 1000;

export type NameDiffstepOperation = DiffstepOperation.NEW | DiffstepOperation.DEL;
export type CompDiffstepOperation = DiffstepOperation.ADD | DiffstepOperation.SET | DiffstepOperation.REM;
export type RelDiffstepOperation = DiffstepOperation.ADDREL | DiffstepOperation.SETREL | DiffstepOperation.REMREL;

export type NameDiffstep = [NameDiffstepOperation, _LocalName];
export type CompDiffstep = [CompDiffstepOperation, _LocalName, _ComponentKey, unknown?];
export type RelDiffstep = [RelDiffstepOperation, _LocalName, _ComponentKey, _LocalName, unknown?];
export type Diffstep = NameDiffstep | CompDiffstep | RelDiffstep;
export type Diffsteps = Diffstep[];

export namespace StatuhFanonDiffstep {
	export namespace Make {
		export const NEW = (name: _LocalName): NameDiffstep => {
			return [DiffstepOperation.NEW, name];
		};
		export const DEL = (name: _LocalName): NameDiffstep => {
			return [DiffstepOperation.DEL, name];
		};
		export const ADD = (name: _LocalName, comp: _ComponentKey): CompDiffstep => {
			return [DiffstepOperation.ADD, name, comp];
		};
		export const SET = (name: _LocalName, comp: _ComponentKey, data: defined): CompDiffstep => {
			return [DiffstepOperation.SET, name, comp, data];
		};
		export const REM = (name: _LocalName, comp: _ComponentKey): CompDiffstep => {
			return [DiffstepOperation.REM, name, comp];
		};
		export const ADDREL = (name: _LocalName, comp: _ComponentKey, rel: _LocalName): RelDiffstep => {
			return [DiffstepOperation.ADDREL, name, comp, rel];
		};
		export const SETREL = (name: _LocalName, comp: _ComponentKey, rel: _LocalName, data: defined): RelDiffstep => {
			return [DiffstepOperation.SETREL, name, comp, rel, data];
		};
		export const REMREL = (name: _LocalName, comp: _ComponentKey, rel: _LocalName): RelDiffstep => {
			return [DiffstepOperation.REMREL, name, comp, rel];
		};
	}

	export const is_name_diffstep = (diffstep: Diffstep): diffstep is NameDiffstep => {
		return diffstep[0] === DiffstepOperation.NEW || diffstep[0] === DiffstepOperation.DEL;
	};
	export const is_comp_diffstep = (diffstep: Diffstep): diffstep is CompDiffstep => {
		return (
			diffstep[0] === DiffstepOperation.ADD ||
			diffstep[0] === DiffstepOperation.SET ||
			diffstep[0] === DiffstepOperation.REM
		);
	};
	export const is_rel_diffstep = (diffstep: Diffstep): diffstep is RelDiffstep => {
		return (
			diffstep[0] === DiffstepOperation.ADDREL ||
			diffstep[0] === DiffstepOperation.SETREL ||
			diffstep[0] === DiffstepOperation.REMREL
		);
	};
	export const is_removal_diffstep = (diffstep: Diffstep): boolean => {
		return (
			diffstep[0] === DiffstepOperation.DEL ||
			diffstep[0] === DiffstepOperation.REM ||
			diffstep[0] === DiffstepOperation.REMREL
		);
	};
	export const diffstep_to_str = (diffstep: Diffstep): string => {
		const opToName = {
			[DiffstepOperation.NEW]: "NEW",
			[DiffstepOperation.DEL]: "DEL",
			[DiffstepOperation.ADD]: "ADD",
			[DiffstepOperation.SET]: "SET",
			[DiffstepOperation.REM]: "REM",
			[DiffstepOperation.ADDREL]: "ADDREL",
			[DiffstepOperation.SETREL]: "SETREL",
			[DiffstepOperation.REMREL]: "REMREL",
		};
		const tostr = (arg: unknown) => {
			if (typeOf(arg) === "table") {
				return tableinlinestr(arg as {});
			} else {
				if (arg === undefined) return "";
				return tostring(arg);
			}
		};
		const arg0tostr = diffstep[0]! as DiffstepOperation;
		const arg1tostr = tostr(diffstep[1]);
		const arg2tostr = tostr(diffstep[2]);
		const arg3tostr = tostr(diffstep[3]);
		const arg4tostr = tostr(diffstep[4]);
		return `${opToName[arg0tostr]} ${arg1tostr} ${arg2tostr} ${arg3tostr} ${arg4tostr}`;
	};
	export const diffsteps_to_str = (diffsteps: Diffsteps): string => {
		return diffsteps.map(diffstep_to_str).join("\n");
	};

	export const applyDiffstepsToWorld = (
		runtime: StatuhFanonRuntime,
		diffsteps: Diffsteps,
		handle?: StatuhFanonHandle,
		lenient: boolean = false,
		warn_on_invalid: boolean = false,
	) => {
		debug.profilebegin("applyDiffstepsToWorld");
		const ensure_entity_from_name = (name: _LocalName) => {
			const entity = StatuhFanonName.getStatuhEntityFromLocalName(runtime, name);
			if (entity === undefined) {
				if (lenient) {
					if (warn_on_invalid) warn(`LENIENT: entity ${name} not found in localNameToStatuhEntity`);
					return undefined;
				} else {
					error(`entity ${name} not found in localNameToStatuhEntity`);
				}
			}
			return entity;
		};
		const ensure_entity_contained_by_world = (entity: StatuhEntity, name?: _LocalName) => {
			// No leniency here.

			// maybe we should have leniency here because we're trying to blindly apply diffsteps to world?
			// when we do optimistic updates?
			if (!world.contains_entity(entity)) {
				if (name !== undefined) {
					if (lenient) {
						if (warn_on_invalid)
							warn(`LENIENT: entity ${entity} (despite having a name ${name}) is not alive in world`);
						return undefined;
					}
					error(`entity ${entity} (despite having a name ${name}) is not alive in world`);
				} else {
					if (lenient) {
						if (warn_on_invalid) warn(`LENIENT: entity ${entity} is not alive in world`);
						return undefined;
					}
					error(`entity ${entity} is not alive in world`);
				}
			}
			return entity;
		};
		const world = handle ?? runtime._statuh_world;
		for (const diffstep of diffsteps) {
			const op = diffstep[0];
			const subjectName = diffstep[1];

			if (is_name_diffstep(diffstep)) {
				// We have a name that's supposed to be new or re-activated.
				// If we already have a LIVE, ACTIVE entity mapped to this, we leave it alone.
				// Otherwise, we'd have to create a new entity... because the diffstep dictates it must exist.
				const mappedStatuhEntity = StatuhFanonName.getStatuhEntityFromLocalName(runtime, subjectName);
				if (op === DiffstepOperation.NEW) {
					if (mappedStatuhEntity === undefined) {
						const newEntity = world.create_entity();
						StatuhFanonName.registerLocalNameWithStatuhEntity(runtime, subjectName, newEntity);
					} else {
						if (world.contains_entity(mappedStatuhEntity)) {
							// If it does contain the entity, we don't have to do anything.
						} else {
							// We would have to revive the entity if it was deleted before (and a name was mapped to it in the past.)
							const newEntity = world.create_entity();
							StatuhFanonName.registerLocalNameWithStatuhEntity(runtime, subjectName, newEntity);
						}
					}
				} else if (op === DiffstepOperation.DEL) {
					if (mappedStatuhEntity !== undefined) {
						if (world.contains_entity(mappedStatuhEntity)) {
							world.delete_entity(mappedStatuhEntity);
						} else {
							// If it doesn't contain the entity, we don't have to do anything.
						}
					}
				}
			} else if (is_comp_diffstep(diffstep)) {
				const subjectEntity = ensure_entity_from_name(subjectName);
				if (subjectEntity === undefined) continue;
				const contained = ensure_entity_contained_by_world(subjectEntity, subjectName);
				if (contained === undefined) continue;

				const component = runtime._component_w_number_key.getMappingToA(diffstep[2])!;
				assert(component !== undefined, `component ${diffstep[2]} not found in component_w_number_key`);
				if (op === DiffstepOperation.ADD) {
					world.add_component(subjectEntity, component);
				} else if (op === DiffstepOperation.SET) {
					world.set_component_data(subjectEntity, component, diffstep[3]);
				} else if (op === DiffstepOperation.REM) {
					world.remove_component(subjectEntity, component);
				}
			} else if (is_rel_diffstep(diffstep)) {
				const subjectEntity = ensure_entity_from_name(subjectName);
				if (subjectEntity === undefined) continue;
				const contained = ensure_entity_contained_by_world(subjectEntity, subjectName);
				if (contained === undefined) continue;

				const component = runtime._component_w_number_key.getMappingToA(diffstep[2])!;
				assert(component !== undefined, `component ${diffstep[2]} not found in component_w_number_key`);

				const targetEntity = ensure_entity_from_name(diffstep[3]);
				if (targetEntity === undefined) continue;
				const containedTarget = ensure_entity_contained_by_world(targetEntity, diffstep[3]);
				if (containedTarget === undefined) continue;

				if (op === DiffstepOperation.ADDREL) {
					world.add_component(subjectEntity, statuh_pair(component, targetEntity));
				} else if (op === DiffstepOperation.SETREL) {
					world.set_component_data(subjectEntity, statuh_pair(component, targetEntity), diffstep[4]);
				} else if (op === DiffstepOperation.REMREL) {
					world.remove_component(subjectEntity, statuh_pair(component, targetEntity));
				}
			}
		}
		debug.profileend();
	};

	export class DiffstepBuilder {
		public _diffsteps: Diffsteps = [];

		// The indices of the diffsteps that are currently active and not removed.
		public _active_indices: Set<number> = new Set();
		public _name_op_to_index: Map<string, number> = new Map();
		public _comp_op_to_index: Map<string, number> = new Map();
		public _rel_op_to_index: Map<string, number> = new Map();

		public _mark_w_index: Bimap<number, number> = new Bimap();
		public _last_mark: number = 0;

		// From a localname, know the indices of all diffsteps that mention that name.
		public _name_to_related_indices: Map<_LocalName, number[]> = new Map();

		public _add_related_index(name: _LocalName, index: number) {
			const relatedIndices = this._name_to_related_indices.get(name);
			if (relatedIndices === undefined) {
				this._name_to_related_indices.set(name, [index]);
			} else {
				relatedIndices.push(index);
			}
		}

		constructor(prepopulate: Diffsteps = []) {
			for (const diffstep of prepopulate) {
				this.add_diffstep(diffstep);
			}
		}

		get_raw_diffsteps(): Diffsteps {
			return this._diffsteps;
		}

		has_mark(mark: number): boolean {
			return this._mark_w_index.containsA(mark);
		}

		mark_last_operation(mark: number): void {
			// warn("\n");
			// this.print_debug();

			// 9-1-2025
			// i broke something by having an action not do anything or have any diffsteps at all.... hmmm
			// what if i didnt skip this? might break something more...

			if (this._diffsteps.size() === 0) {
				warn("mark_last_operation: no diffsteps, skipping");
				return;
			}

			const last_index = this._diffsteps.size() - 1;
			// warn(`mark_last_operation: attempting to mark ${mark} at index ${last_index}`);
			if (this._mark_w_index.containsMappingToA(last_index)) {
				warn(`mark_last_operation: mark already exists at index ${last_index}, overwriting`);
			}
			this._last_mark = mark;
			this._mark_w_index.set(mark, last_index);
			// warn(`mark_last_operation: mark ${mark} at index ${last_index}`);
			// this.print_debug();
			// warn("\n");
		}

		rebuild_after_mark_and_reevaluate(mark: number): void {
			debug.profilebegin("additive_diffstep: rebuild_after_mark_and_reevaluate");
			// warn(`rebuild_after_mark_and_reevaluate: mark ${mark}`);
			// This method is used when we get a new server canon and we're figuring out what unaddressed local diffsteps
			// to re-apply. (inverse stuff is handled by the inverse diffstep builder.)
			// We just have to find the active additive diffsteps after the mark.
			// To ensure correctness, first see if adding EVERY additive diffstep after the mark would be valid.
			// like we did with inverse
			// (TODO: then we can see if we can just re-apply the ACTIVE ones instead)
			const markedIndex = this._mark_w_index.getMappingToB(mark);
			if (markedIndex === undefined) {
				// TODO: currently testing that the same operation could be marked and thus can overwrite
				// previously set marks, which could break this

				// We have not found the mark the server has given us.
				// this should be impossible, since any mark we ever send should have been guaranteed marked here.
				error(`Server-given mark ${mark} not found in mark_w_index`);
				// } else {
				// warn(`Server-given mark ${mark} found in mark_w_index at index ${markedIndex}`);
			}

			const diffstep_arr: Diffsteps = [];
			const mark_arr: (number | false)[] = [];
			for (let i = markedIndex + 1; i < this._diffsteps.size(); i++) {
				if (this._mark_w_index.containsB(i)) {
					const mark = this._mark_w_index.getMappingToA(i)!;
					diffstep_arr.push(this._diffsteps[i]);
					mark_arr.push(mark);
				} else {
					diffstep_arr.push(this._diffsteps[i]);
					mark_arr.push(false);
				}
			}

			this.clear();

			for (let i = 0; i < diffstep_arr.size(); i++) {
				const diffstep = diffstep_arr[i];
				const mark = mark_arr[i];
				this.add_diffstep(diffstep);
				if (mark !== false) {
					this.mark_last_operation(mark);
				}
			}
			debug.profileend();
		}

		add_diffstep(diffstep: Diffstep): void {
			debug.profilebegin("additive_diffstep: add_diffstep");
			const subjectName = diffstep[1];
			this._diffsteps.push(diffstep);
			const newIndex = this._diffsteps.size() - 1;
			this._active_indices.add(newIndex);
			this._add_related_index(subjectName, newIndex);

			if (StatuhFanonDiffstep.is_name_diffstep(diffstep)) {
				// NEW/DEL
				const key = `${tostring(subjectName)}`;
				const foundIndex = this._name_op_to_index.get(key);
				if (foundIndex !== undefined) this._active_indices.delete(foundIndex);
				this._name_op_to_index.set(subjectName, newIndex);
				if (diffstep[0] === DiffstepOperation.DEL) {
					// If it's DEL, every operation referring to it must be deactivated.
					const relatedIndices = this._name_to_related_indices.get(diffstep[1]);
					if (relatedIndices !== undefined) {
						for (const index of relatedIndices) {
							if (index === newIndex) continue;
							this._active_indices.delete(index);
						}
					}
				}
			} else if (StatuhFanonDiffstep.is_comp_diffstep(diffstep)) {
				// ADD/SET/REM
				const compKey = diffstep[2];
				const key = `${tostring(subjectName)}*${tostring(compKey)}`;
				const foundIndex = this._comp_op_to_index.get(key);
				if (foundIndex !== undefined) this._active_indices.delete(foundIndex);
				this._comp_op_to_index.set(key, newIndex);
			} else if (StatuhFanonDiffstep.is_rel_diffstep(diffstep)) {
				// ADDREL/SETREL/REMREL
				const compKey = diffstep[2];
				const targetName = diffstep[3];
				const key = `${tostring(subjectName)}*${tostring(compKey)}*${tostring(targetName)}`;
				const foundIndex = this._rel_op_to_index.get(key);
				if (foundIndex !== undefined) this._active_indices.delete(foundIndex);
				this._rel_op_to_index.set(key, newIndex);
				this._add_related_index(targetName, newIndex);
			} else {
				error("Invalid diffstep type");
			}
			debug.profileend();
		}

		add_diffsteps(diffsteps: Diffsteps): void {
			for (const diffstep of diffsteps) {
				this.add_diffstep(diffstep);
			}
		}

		get_diffsteps(): Diffsteps {
			// Get all active indices.
			const sortedActiveIndices: number[] = [];
			this._active_indices.forEach((value, val2, set) => {
				sortedActiveIndices.push(value);
			});
			sortedActiveIndices.sort();
			const diffsteps: Diffsteps = [];
			for (const index of sortedActiveIndices) {
				diffsteps.push(this._diffsteps[index]);
			}
			return diffsteps;
		}

		print_debug(): void {
			// print every single diffstep we have in memory
			// alongside them on the left side, indicate if they are active
			print(`Additive Builder (${this._diffsteps.size()} steps):`);
			for (let i = 0; i < this._diffsteps.size(); i++) {
				const diffstep = this._diffsteps[i];
				const isActive = this._active_indices.has(i);
				const hasMark = this._mark_w_index.getMappingToA(i);
				print(
					`${hasMark !== undefined ? `[${hasMark}]` : "[ ]"} ${isActive ? "*" : " "} ${i}: ${diffstep_to_str(diffstep)}`,
				);
			}
		}

		clear(): void {
			this._diffsteps = [];
			this._active_indices.clear();
			this._name_op_to_index.clear();
			this._comp_op_to_index.clear();
			this._rel_op_to_index.clear();
			this._name_to_related_indices.clear();
			this._mark_w_index.clear();
		}

		cleanup_inactive(delete_removals: boolean = false): void {
			debug.profilebegin("additive_diffstep: cleanup_inactive");
			// For huge, cumulative diffsteps,
			// delete_removals should be true.
			// It will remove any operation that is DEL, REM, or REMREL.
			// warn("cleanup_inactive: deleting removals");
			const new_diffsteps: Diffsteps = [];

			let index = -1;
			for (const diffstep of this._diffsteps) {
				index++;
				if (this._active_indices.has(index)) {
					if (delete_removals && is_removal_diffstep(diffstep)) {
						continue;
					} else {
						new_diffsteps.push(diffstep);
					}
				}
			}

			this.clear();
			this.add_diffsteps(new_diffsteps);
			debug.profileend();
		}
	}

	export class InverseDiffstepBuilder {
		public _inverse_diffsteps: Diffsteps = [];

		// The indices of the diffsteps that are currently active and not removed.
		public _active_indices: Set<number> = new Set();
		public _name_op_to_index: Map<string, number> = new Map();
		public _comp_op_to_index: Map<string, number> = new Map();
		public _rel_op_to_index: Map<string, number> = new Map();

		public _mark_w_index: Bimap<number, number> = new Bimap();
		public _blacklist_names: Set<_LocalName> = new Set();
		public _last_mark: number = 0;

		// From a localname, know the indices of all diffsteps that mention that name.
		public _name_to_related_indices: Map<_LocalName, number[]> = new Map();

		public _add_related_index(name: _LocalName, index: number) {
			const relatedIndices = this._name_to_related_indices.get(name);
			if (relatedIndices === undefined) {
				this._name_to_related_indices.set(name, [index]);
			} else {
				relatedIndices.push(index);
			}
		}

		has_mark(mark: number): boolean {
			return this._mark_w_index.containsA(mark);
		}

		mark_last_operation(mark: number): void {
			this._last_mark = mark;
			if (this._inverse_diffsteps.size() === 0) {
				return;
			}
			this._mark_w_index.set(mark, this._inverse_diffsteps.size() - 1);
		}

		rebuild_after_mark_and_reevaluate(mark: number): void {
			debug.profilebegin("inverse_diffstep: rebuild_after_mark_and_reevaluate");
			// Normally, getting *rendered* diffsteps would sort NEW calls up front and reverse the rest.
			// This is not a render method; this re-evaluates internal diffsteps.
			// This method is used when we get a new server canon and we're figuring out what unaddressed local diffsteps
			// to re-apply, and *also preserve their inverse operations* which includes INACTIVE inverse diffsteps.
			// This also preserves marks.

			const markedIndex = this._mark_w_index.getMappingToB(mark);
			if (markedIndex === undefined) {
				// We have not found the mark the server has given us.
				// this should be impossible, since any mark we ever send should have been guaranteed marked here.
				error(`Server-given mark ${mark} not found in mark_w_index`);
			}

			const diffstep_arr: Diffsteps = [];
			const mark_arr: (number | false)[] = [];
			for (let i = markedIndex + 1; i < this._inverse_diffsteps.size(); i++) {
				if (this._mark_w_index.containsB(i)) {
					const mark = this._mark_w_index.getMappingToA(i)!;
					diffstep_arr.push(this._inverse_diffsteps[i]);
					mark_arr.push(mark);
				} else {
					diffstep_arr.push(this._inverse_diffsteps[i]);
					mark_arr.push(false);
				}
			}

			this.clear();

			for (let i = 0; i < diffstep_arr.size(); i++) {
				const diffstep = diffstep_arr[i];
				const mark = mark_arr[i];
				this.attempt_add_diffstep(diffstep);
				if (mark !== false) {
					this.mark_last_operation(mark);
				}
			}
			debug.profileend();
		}

		constructor(prepopulate: Diffsteps = []) {
			for (const diffstep of prepopulate) {
				this.attempt_add_diffstep(diffstep);
			}
		}

		print_debug(): void {
			// print every single diffstep we have in memory
			// alongside them on the left side, indicate if they are active
			print(`Inverse Builder (${this._inverse_diffsteps.size()} steps):`);
			for (let i = 0; i < this._inverse_diffsteps.size(); i++) {
				const diffstep = this._inverse_diffsteps[i];
				const isActive = this._active_indices.has(i);
				const markNumber = this._mark_w_index.getMappingToA(i);
				print(
					`${markNumber !== undefined ? `[${markNumber}]` : "[ ]"} ${isActive ? "*" : " "} ${i}: ${diffstep_to_str(diffstep)}`,
				);
			}
		}

		attempt_add_diffstep(diffstep: Diffstep): void {
			debug.profilebegin("inverse_diffstep: attempt_add_diffstep");
			const subjectName = diffstep[1];
			const newIndex = this._inverse_diffsteps.size();
			this._inverse_diffsteps.push(diffstep);
			// Don't add to active indices just yet. We just needed to add to our history
			// so that we can re-build inverse diffsteps after updating our last server canon.

			if (this._inverse_diffsteps.size() > _MAX_DIFFSTEPS) {
				warn(`Inverse diffstep builder has too many diffsteps: ${this._inverse_diffsteps.size()}`);
			}

			if (this._blacklist_names.has(subjectName)) {
				debug.profileend();
				return;
			}

			if (StatuhFanonDiffstep.is_name_diffstep(diffstep)) {
				// NEW/DEL
				const key = `${tostring(subjectName)}`;
				const foundIndex = this._name_op_to_index.get(key);
				if (foundIndex === undefined) {
					this._name_op_to_index.set(key, newIndex);
					this._active_indices.add(newIndex);
				}
				if (diffstep[0] === DiffstepOperation.DEL) {
					this._blacklist_names.add(subjectName);
				}
			} else if (StatuhFanonDiffstep.is_comp_diffstep(diffstep)) {
				// ADD/SET/REM
				const compKey = diffstep[2];
				const key = `${tostring(subjectName)}*${tostring(compKey)}`;
				const foundIndex = this._comp_op_to_index.get(key);
				if (foundIndex === undefined) {
					this._comp_op_to_index.set(key, newIndex);
					this._active_indices.add(newIndex);
				}
			} else if (StatuhFanonDiffstep.is_rel_diffstep(diffstep)) {
				// ADDREL/SETREL/REMREL
				const compKey = diffstep[2];
				const targetName = diffstep[3];
				if (this._blacklist_names.has(targetName)) {
					debug.profileend();
					return;
				}
				const key = `${tostring(subjectName)}*${tostring(compKey)}*${tostring(targetName)}`;
				const foundIndex = this._rel_op_to_index.get(key);
				if (foundIndex === undefined) {
					this._rel_op_to_index.set(key, newIndex);
					this._active_indices.add(newIndex);
				}
			} else {
				error("Invalid diffstep type");
			}
			debug.profileend();
		}

		add_diffsteps(diffsteps: Diffsteps): void {
			for (const diffstep of diffsteps) {
				this.attempt_add_diffstep(diffstep);
			}
		}

		get_raw_diffsteps(): Diffsteps {
			// Unlike rendering, sometimes we just need the raw diffsteps currently residing.
			return this._inverse_diffsteps;
		}

		get_diffsteps(): Diffsteps {
			// To ensure we can OUTPUT valid diffsteps (which were inverted from regular calls),
			// we have to manually ensure all NEW calls are upfront.
			// Also, because this is inverse order, everything else is also reversed.

			// Get all active indices.
			const sortedActiveIndices: number[] = [];
			const newOpsIndices: number[] = [];
			this._active_indices.forEach((value, val2, set) => {
				const diffstep = this._inverse_diffsteps[value];
				if (diffstep[0] === DiffstepOperation.NEW) {
					newOpsIndices.push(value);
				} else {
					sortedActiveIndices.push(value);
				}
			});
			sortedActiveIndices.sort((a, b) => b < a);
			newOpsIndices.sort((a, b) => b < a);
			const diffsteps: Diffsteps = [];
			for (const index of newOpsIndices) {
				diffsteps.push(this._inverse_diffsteps[index]);
			}
			for (const index of sortedActiveIndices) {
				diffsteps.push(this._inverse_diffsteps[index]);
			}
			return diffsteps;
		}

		clear(): void {
			this._inverse_diffsteps = [];
			this._active_indices.clear();
			this._name_op_to_index.clear();
			this._comp_op_to_index.clear();
			this._rel_op_to_index.clear();
			this._name_to_related_indices.clear();
			this._blacklist_names.clear();
			this._mark_w_index.clear();
		}

		// cleanup_inactive(): void {
		// 	// This removes inactive diffsteps, which may screw with diffsteps.
		// 	// Inverse diffsteps are used within actions to reverse failed actions.
		// 	// On the server, they're used sparsely. On the client, they're used in between server packages.
		// 	// Actions that are committed are always cleared.
		// 	// So most of the management should be on the client.
		// 	const new_diffsteps: Diffsteps = [];
		// 	for (const [index, diffstep] of Object.entries(this._inverse_diffsteps)) {
		// 		if (this._active_indices.has(index)) {
		// 			new_diffsteps.push(diffstep);
		// 		}
		// 	}
		// 	this.clear();
		// 	this.add_diffsteps(new_diffsteps);
		// }
	}
}
