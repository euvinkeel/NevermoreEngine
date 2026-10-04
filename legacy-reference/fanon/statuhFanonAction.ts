import { ReplicatedComponents, SharedComponents } from "shared/sharedcomponents";
import { StatuhFanonHandle } from "./statuhFanonHandle";
import { StatuhEntity } from "shared/libs/statuh/statuhTypes";
import { StatuhFanonRuntime } from "./statuhFanon";
import { _LocalName, AuthorId, StatuhFanonName } from "./statuhFanonName";
import { StatuhFanonDiffstep } from "./statuhFanonDiffstep";
import Object from "shared/libs/vendor/objectutils";
import { SignalInterface } from "shared/utils/primitives/signal";

export type ActionId = number;
export type ActionArgs = Record<string, ActionArgument>;
export interface ActionRecord {
	actionId: number;
	actionArgs: ActionArgs;
	createdNames: _LocalName[];
}

export type ActionSerializableValue = number | string | boolean | StatuhEntity | Vector3 | Vector2;
export type ActionArgument = ActionSerializableValue | ActionSerializableValue[];

export interface ActionRuntime<RCPs = ReplicatedComponents> {
	fanon_runtime: StatuhFanonRuntime;
	fanon_handle: StatuhFanonHandle;
	action_header_log: ActionHeader[];
	last_acknumber: number;
	rcps: RCPs;
	scps: SharedComponents;
}

export interface ActionExecutionCtx<T extends ActionArgs> {
	args: T;
}

export interface ActionReplayCtx<T extends ActionArgs> {
	args: T;
	authorEntity: StatuhEntity;
}

export type ActionConfig<T extends ActionArgs, R = unknown, RCPs = ReplicatedComponents> = {
	effect: (runtimeCtx: ActionRuntime<RCPs>, executionCtx: ActionExecutionCtx<T>) => R;
	validate: (runtimeCtx: ActionRuntime<RCPs>, replayCtx: ActionReplayCtx<T>) => string | true;
};

export interface ActionHeader {
	actionId: ActionId;
	actionArgs: ActionArgs;
	createdNames: _LocalName[];
	authorId: AuthorId;
}

export const makeActionHeader = (
	actionId: ActionId,
	actionArgs: ActionArgs,
	createdNames: _LocalName[],
	authorId: AuthorId,
): ActionHeader => {
	return {
		actionId,
		actionArgs,
		createdNames,
		authorId,
	};
};

export const prepareArgsFromEntityToName = (
	statuhFanonRuntime: StatuhFanonRuntime,
	args: ActionArgs,
	argNameFields: Record<string, boolean>,
) => {
	const realRuntimeArgs: Record<string, ActionArgument> = {};
	for (const [key, value] of Object.entries(args) as [string, ActionArgument][]) {
		if (argNameFields[key] === true) {
			const localName = StatuhFanonName.getFanonNameFromStatuhEntity(statuhFanonRuntime, value as StatuhEntity);
			if (localName === undefined) {
				warn(debug.traceback());
				error(`Fanon name for underlying entity ${value} not found`);
			}
			realRuntimeArgs[key] = localName;
		} else {
			realRuntimeArgs[key] = value;
		}
	}
	return realRuntimeArgs;
};

export const neuterEntityArgs = (args: ActionArgs, argNameFields: Record<string, boolean>) => {
	const realRuntimeArgs: Record<string, ActionArgument> = {};
	for (const [key, value] of Object.entries(args) as [string, ActionArgument][]) {
		if (argNameFields[key] === true) {
			realRuntimeArgs[key] = undefined as never;
		} else {
			realRuntimeArgs[key] = value;
		}
	}
	return realRuntimeArgs;
};

export const translateArgsFromNameToEntity = (
	statuhFanonRuntime: StatuhFanonRuntime,
	args: ActionArgs,
	argNameFields: Record<string, boolean>,
) => {
	const realRuntimeArgs: Record<string, ActionArgument> = {};
	for (const [key, value] of Object.entries(args) as [string, ActionArgument][]) {
		if (argNameFields[key] === true) {
			const statuhEntity = StatuhFanonName.getStatuhEntityFromLocalName(statuhFanonRuntime, value as _LocalName);
			if (statuhEntity === undefined) {
				error(`Statuh entity for fanon name ${value} not found in mappings`);
			}
			realRuntimeArgs[key] = statuhEntity;
		} else {
			realRuntimeArgs[key] = value;
		}
	}
	return realRuntimeArgs;
};

export const replayAction = (
	actionId: ActionId,
	actionRuntime: ActionRuntime,
	actionReplayCtx: ActionReplayCtx<ActionArgs>,
	actionExecutionCtx: ActionExecutionCtx<ActionArgs>,
	actionCreatedNames: _LocalName[],
	actionEffect: (runtimeCtx: ActionRuntime, executionCtx: ActionExecutionCtx<ActionArgs>) => void,
	actionValidate: (runtimeCtx: ActionRuntime, replayCtx: ActionReplayCtx<ActionArgs>) => string | boolean,
) => {
	// verifies the action.
	const validationResult = actionValidate(actionRuntime, actionReplayCtx);
	if (typeOf(validationResult) === "string") {
		// warn(`Action invalid ${actionId}: ${validationResult}`);
		return {
			returned: undefined,
			errmsg: validationResult,
		};
	}

	let result: unknown = undefined;
	let errmsg: string | undefined = undefined;
	actionRuntime.fanon_handle.start_tracking_action(actionId);
	for (const name of actionCreatedNames) {
		actionRuntime.fanon_handle.enqueue_new_name_to_queue(name);
	}
	try {
		result = actionEffect(actionRuntime, actionExecutionCtx);
		actionRuntime.fanon_handle.commit_tracked_action();
	} catch (e) {
		errmsg = `Error replaying action ${actionId}: ${e}`;
		const back_diffsteps = actionRuntime.fanon_handle.reject_tracked_action_and_get_correction_diffsteps();
		StatuhFanonDiffstep.applyDiffstepsToWorld(actionRuntime.fanon_runtime, back_diffsteps, undefined, true, true);
	} finally {
		// the handle should have created and mapped to the given names provided.
		actionRuntime.fanon_handle.clear_new_name_queue();
		actionRuntime.fanon_handle.stop_tracking_action();
	}

	return {
		returned: result,
		errmsg,
	};
};

// Used to run an action as a normal call
// Adds to outgoing queue
export const executeAction = <T extends ActionArgs, R, RCPs = ReplicatedComponents>(
	actionId: ActionId,
	actionRuntime: ActionRuntime<RCPs>,
	actionExecutionCtx: ActionExecutionCtx<T>,
	actionEffect: (runtimeCtx: ActionRuntime<RCPs>, executionCtx: ActionExecutionCtx<T>) => R,
	actionSignal?: SignalInterface<(...args: any) => void>,
	debugLogTable?: Array<defined>,
	argNameFields?: Record<string, boolean>,
): {
	returned: R | undefined;
	errmsg: string | undefined;
} => {
	let result: R | undefined = undefined;
	let errmsg: string | undefined = undefined;
	let trackedNames: _LocalName[] = [];

	actionRuntime.fanon_handle.start_tracking_action(actionId);
	try {
		result = actionEffect(actionRuntime, actionExecutionCtx);
		const translatedActionArgs = prepareArgsFromEntityToName(
			actionRuntime.fanon_runtime,
			actionExecutionCtx.args,
			argNameFields!,
		);
		trackedNames = actionRuntime.fanon_handle.get_tracked_names();
		actionRuntime.fanon_handle.commit_tracked_action();

		// ALWAYS translate args to networked names ASAP.
		assert(actionRuntime.fanon_runtime._author_name !== undefined, "Author name is undefined");
		const newHeader = makeActionHeader(
			actionId,
			translatedActionArgs,
			trackedNames,
			actionRuntime.fanon_runtime._author_name,
		);
		actionRuntime.action_header_log.push(newHeader);

		if (debugLogTable !== undefined) {
			assert(argNameFields !== undefined, "argNameFields is undefined");
			debugLogTable.push({
				actionId,
				actionArgs: translatedActionArgs,
			});
		}

		// Fire the event for systems to listen to
		if (actionSignal !== undefined) {
			actionSignal.Fire(actionExecutionCtx.args as never, actionRuntime.fanon_runtime._author_name as never);
		}

		// warn(actionRuntime.action_header_log);
	} catch (e) {
		errmsg = `Error executing action ${actionId}: ${e}`;
		warn(`Error executing action ${actionId}: ${e}`);
		const back_diffsteps = actionRuntime.fanon_handle.reject_tracked_action_and_get_correction_diffsteps();
		StatuhFanonDiffstep.applyDiffstepsToWorld(actionRuntime.fanon_runtime, back_diffsteps, undefined, true, true);
	} finally {
		actionRuntime.fanon_handle.clear_new_name_queue();
		actionRuntime.fanon_handle.stop_tracking_action();
	}

	return {
		returned: result,
		errmsg,
	};
};
