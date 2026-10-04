import { GamuhClientSystem } from "client/clienttypes";
import { GamuhClientRuntimeContext } from "client/clientruntime";
import { LOOPUH_CLIENT_OFFSET, LOOPUH_ROBLOX_PRIORITY_INT } from "shared/libs/loopuh/loopuhRobloxUtil";
import useRemoteCallback from "shared/libs/vendor/hooks/useRemoteCallback";
import {
	SentActionHeaders,
	SentDiffstepsZap,
	ServerSendActionHeaders,
	ServerSendDiffsteps,
	UpdateClientHash,
} from "client/zap";
import { Diffstep, Diffsteps, StatuhFanonDiffstep } from "shared/libs/fanon/statuh/statuhFanonDiffstep";
import {
	getNormalizedAdditiveDiffstepsString,
	hashDiffsteps,
	snapshotSharedWorldAsHash,
	snapshotWorldPrintableString,
} from "shared/libs/statuh/statuhUtil";
import { OnFatalError } from "./E_client_fanon_send";
import { BLACKBOX_RECORDING_ENABLED } from "shared/blackbox";
import { Workspace } from "@rbxts/services";
import { ActionSignals, ActionType, ActionTypeToGeneralInfo } from "shared/actionsLookup";
import {
	ActionHeader,
	neuterEntityArgs,
	translateArgsFromNameToEntity,
} from "shared/libs/fanon/statuh/statuhFanonAction";

const DEBUG_INCOMING_SYSTEM = false;
// const DEBUG_INCOMING_SYSTEM = true;
export const DEBUG_ENABLE_HASHING = false;

const logdebug = (...args: unknown[]) => {
	if (DEBUG_INCOMING_SYSTEM) warn("[INCOMING]", ...args);
};

// CATCH-UP
// When catching up, we blindly apply all diffsteps we receive.
const process_catchup_package = (crt: GamuhClientRuntimeContext, GOT: SentDiffstepsZap) => {
	const { diffsteps, canonnumber, acknumber, epoch, canondiffstephash, canonworldhash } = GOT;

	// every time we get a catchup/warp package, revert any optimistic diffsteps we applied.
	const goback = crt.fanon_handle.get_inverted_diffsteps();
	StatuhFanonDiffstep.applyDiffstepsToWorld(crt.fanon_runtime, goback);
	crt.fanon_handle.get_additive_diffstep_builder().clear();
	crt.fanon_handle.get_inverse_diffstep_builder().clear();
	previous_correct_hash = 0;
	previous_correct_canonnumber = 0;
	if (DEBUG_INCOMING_SYSTEM) {
		for (const diffstep of diffsteps) {
			logdebug("APPLIED + ", StatuhFanonDiffstep.diffstep_to_str(diffstep as Diffstep));
		}
	}
	StatuhFanonDiffstep.applyDiffstepsToWorld(crt.fanon_runtime, diffsteps as Diffstep[]);

	if (canonnumber !== undefined) {
		// The moment we get a canonnumber, we're done catching up.
		crt.replication_state.catching_up = false;
		crt.replication_state.curr_canonnumber = canonnumber;

		// also, ensure we have nothing going out. starting completely fresh
		crt.action_runtime.action_header_log.clear();
		crt.fanon_handle.reset_all_handle_tracking_state();

		logdebug(`CAUGHTUP TO CANON#${canonnumber}`);

		if (DEBUG_ENABLE_HASHING) {
			if (!compare_shared_world_hashes(crt, canonnumber, canonworldhash!)) {
				warn(`Fatal error: mismatched canonworldhash on CATCHUP canon#${canonnumber}`);
				OnFatalError(crt);
				return;
			}
		}

		// The diffstep hashes are not reliable... :/
		// idk why, but the real world hash can be relied on more.
	}
};

let previous_correct_hash = 0;
let previous_correct_canonnumber = 0;

const compare_shared_world_hashes = (crt: GamuhClientRuntimeContext, canonnumber: number, server_hash: number) => {
	if (!DEBUG_ENABLE_HASHING) {
		return true;
	}
	const our_hash = snapshotSharedWorldAsHash(crt.fanon_runtime);
	UpdateClientHash.Fire(our_hash);
	logdebug(`Checking SHARED WORLD HASH for canon#${canonnumber}: server:${server_hash}, ours: ${our_hash}`);
	if (server_hash !== our_hash) {
		warn(`🟥🟥🟥🟥🟥🟥🟥🟥🟥🟥🟥🟥🟥🟥🟥🟥🟥🟥🟥🟥🟥`);
		warn(`SHARED WORLD HASH MISMATCH ${server_hash} !== ${our_hash}`);
		warn(`Our (wrong) shared world:`);
		warn(snapshotWorldPrintableString(crt.fanon_runtime));
		warn(`\n\n\n\n\n`);
		return false;
	}
	return true;
};

const print_diffstep_and_world_state = (crt: GamuhClientRuntimeContext, GOT: SentDiffstepsZap) => {
	logdebug(`DS&WORLD FROM ${debug.traceback()}`);
	logdebug("Here is what our current diffsteps looks like.");
	if (DEBUG_INCOMING_SYSTEM) {
		crt.fanon_handle.get_additive_diffstep_builder().print_debug();
		crt.fanon_handle.get_inverse_diffstep_builder().print_debug();
	}
	logdebug("Here is what our world looks like.");
	logdebug(snapshotWorldPrintableString(crt.fanon_runtime));
};

// Whenever we get a completed block of diffsteps representing the difference
// between the last server canon and the new server canon, we process it depending
// on if we have acknumbers/local optimistic diffsteps, pending acknowledgements.
const process_realtime_server_canon_state = (
	crt: GamuhClientRuntimeContext,
	GOT: SentDiffstepsZap,
	complete_diffsteps: Diffstep[],
) => {
	let { canonnumber, acknumber, canonworldhash } = GOT;
	assert(canonnumber !== undefined, "canonnumber is undefined");
	if (DEBUG_ENABLE_HASHING) {
		assert(canonworldhash !== undefined, "canonworldhash is undefined");
	}
	const expected_canonnumber = crt.replication_state.curr_canonnumber + 1;
	crt.replication_state.curr_canonnumber = canonnumber;
	const acknowledged_us = acknumber !== undefined;
	const we_have_pending_diffsteps = crt.fanon_handle.get_additive_diffstep_builder().get_diffsteps().size() > 0;

	if (canonnumber !== expected_canonnumber) {
		warn(`Fatal error: got canonnumber ${canonnumber} but expected ${expected_canonnumber}`);
		warn(`We must have skipped a server canon state`);
		OnFatalError(crt);
		return;
	}

	// Always build server-only history.
	// This is required to update our server canon when we finally get acknowledged.
	// (in case we don't really need it, we just clear it in the one tiny case where
	// acknumber is missing AND we have no pending diffsteps. a bit down there.)
	crt.replication_state.accum_new_server_canon.add_diffsteps(complete_diffsteps);

	// const OPTIMISTIC_DIFFSTEPS_ENABLED = false;
	const OPTIMISTIC_DIFFSTEPS_ENABLED = true;
	const goback = crt.fanon_handle.get_inverted_diffsteps();

	if (OPTIMISTIC_DIFFSTEPS_ENABLED) {
		debug.profilebegin("optimistic branch");
		const pathbuilder = new StatuhFanonDiffstep.DiffstepBuilder(goback);
		pathbuilder.add_diffsteps(crt.replication_state.accum_new_server_canon.get_diffsteps());
		// at this point we have a path to new server canon

		if (we_have_pending_diffsteps) {
			if (acknowledged_us) {
				debug.profilebegin("ack_rebuild_after_mark");
				// This *has* to happen at some point.
				logdebug(`[PENDING] [ACKED ] : ACK ${acknumber}, rebuilding history`);
				try {
					crt.fanon_handle.rebuild_after_mark(acknumber);
				} catch (e) {
					warn(`FATAL ERROR when rebuilding after mark ${acknumber}`, e);
					OnFatalError(crt);
					return;
				}
				debug.profileend();
			} else {
				logdebug(`[PENDING] [NO ACK] : should be temporary`);
			}

			// Everything *remaining* inside the builders can be applied; they are unacknowledged.
			debug.profilebegin("unacknowledged_diffsteps");
			const unacknowledged = crt.fanon_handle.get_additive_diffstep_builder().get_diffsteps();
			pathbuilder.add_diffsteps(unacknowledged);
			logdebug(`[PENDING] [      ] : adding remaining ${unacknowledged.size()} unacknowledged diffsteps`);
			try {
				StatuhFanonDiffstep.applyDiffstepsToWorld(
					crt.fanon_runtime,
					pathbuilder.get_diffsteps(),
					undefined,
					true,
					// true,
				);
			} catch (e) {
				warn(`FATAL ERROR when applying diffsteps to world`);
				OnFatalError(crt);
				return;
			}
			debug.profileend();
		} else {
			// we have nothing to contribute. just apply. (should be perfect)
			// this should be the final response from a server in a test run
			debug.profilebegin("simple_apply");
			debug.profilebegin("simple_apply_diffsteps");
			StatuhFanonDiffstep.applyDiffstepsToWorld(crt.fanon_runtime, pathbuilder.get_diffsteps());
			debug.profileend();
			logdebug(`[NO PEND] [      ] : simple apply (should be perfect)`);
			debug.profilebegin("simple_apply_compare_hashes");
			if (DEBUG_ENABLE_HASHING) {
				if (!compare_shared_world_hashes(crt, canonnumber, canonworldhash!)) {
					warn(`Fatal error: mismatched canonworldhash on canon#${canonnumber}`);
					OnFatalError(crt);
					return;
				} else {
					previous_correct_hash = canonworldhash!;
					previous_correct_canonnumber = canonnumber;
				}
			}
			debug.profileend();
			debug.profileend();
		}

		// When it comes to optimistic updates, we have to maintain some of our history
		// We shouldn't clear our builders; any redundant diffsteps should be cleared automatically
		// via the rebuild_after_mark method.
		// Clearing out builders should be done if OPTIMISTIC_DIFFSTEPS_ENABLED is false.

		// crt.fanon_handle.get_additive_diffstep_builder().clear();
		// crt.fanon_handle.get_inverse_diffstep_builder().clear();
		// logdebug(`Cleaned out diffstep builders`);
		debug.profileend();
	} else {
		const APPLY_DIRECTLY = false;
		if (APPLY_DIRECTLY) {
			StatuhFanonDiffstep.applyDiffstepsToWorld(crt.fanon_runtime, goback);
			// we should check that this matches the last hash of the previous canon.
			if (previous_correct_hash !== 0) {
				const gobackHash = snapshotSharedWorldAsHash(crt.fanon_runtime);
				if (gobackHash !== previous_correct_hash) {
					warn(
						`Fatal error: we reverted, but mismatched PREVIOUS canonworldhash (our recieved canonnumber was canon#${canonnumber}, so previous must have been canon#${previous_correct_canonnumber}).`,
					);
					warn(
						`The previous canonworldhash was ${previous_correct_hash}, but the current one is ${gobackHash}`,
					);
					OnFatalError(crt);
					return;
				}
			}
			const tonew = crt.replication_state.accum_new_server_canon.get_diffsteps();
			StatuhFanonDiffstep.applyDiffstepsToWorld(crt.fanon_runtime, tonew);
		} else {
			// Here, we'll attempt to do diffstep arithmetic instead of applying changes directly.
			const pathbuilder = new StatuhFanonDiffstep.DiffstepBuilder(goback);
			pathbuilder.add_diffsteps(crt.replication_state.accum_new_server_canon.get_diffsteps());
			StatuhFanonDiffstep.applyDiffstepsToWorld(crt.fanon_runtime, pathbuilder.get_diffsteps());
		}
		// When optimistic diffsteps are disabled, we expect a perfect match.
		if (DEBUG_ENABLE_HASHING && !compare_shared_world_hashes(crt, canonnumber, canonworldhash!)) {
			warn(`Fatal error: mismatched canonworldhash on canon#${canonnumber}`);
			OnFatalError(crt);
			return;
		} else {
			previous_correct_hash = (canonworldhash as number | undefined) ?? previous_correct_hash;
			previous_correct_canonnumber = canonnumber;
		}
		crt.fanon_handle.get_additive_diffstep_builder().clear();
		crt.fanon_handle.get_inverse_diffstep_builder().clear();
		logdebug(`Cleaned out diffstep builders`);
	}
};

const process_realtime_package = (crt: GamuhClientRuntimeContext, GOT: SentDiffstepsZap) => {
	// REALTIME
	// When we're in realtime mode, we wait for canonnumbers to show up.
	// We collect diffsteps until we get a canonnumber.
	// The moment we get a canonnumber, we treat that as one new server state.
	// New server canon states have their own logic upon being completed.
	// This is more of a packet builder.

	// ... however, there are two paths:
	// 1) We have no optimistic pending diffsteps, no marks.
	//    In this case we just apply to world blindly, like catchup.
	// 2) We have optimistic pending diffsteps, and marks. (e.g. our handle was used AT ALL.)
	//    In this case we must track a bunch of histories. Use the handle for all reversion.
	debug.profilebegin("process_realtime_package");
	const { diffsteps, canonnumber, acknumber } = GOT;
	for (const diffstep of diffsteps) {
		if (DEBUG_INCOMING_SYSTEM) {
			logdebug("accRT + ", StatuhFanonDiffstep.diffstep_to_str(diffstep as Diffstep));
		}
		crt.replication_state.package_diffsteps.push(diffstep as Diffstep);
	}
	if (crt.replication_state.package_diffsteps.size() > 200) {
		warn(
			`[INCOMING] Accumulating Package diffsteps size is dangerously high: ${crt.replication_state.package_diffsteps.size()}`,
		);
	}

	if (canonnumber !== undefined) {
		if (DEBUG_INCOMING_SYSTEM) {
			logdebug(`Received canonnumber ${canonnumber}, ${acknumber ? `!ACK ${acknumber}` : "no ack"}`);
		}
		process_realtime_server_canon_state(crt, GOT, crt.replication_state.package_diffsteps);
		table.clear(crt.replication_state.package_diffsteps);
	}
	debug.profileend();
};

export const onServerSendDiffsteps = (crt: GamuhClientRuntimeContext, GOT: SentDiffstepsZap) => {
	const { diffsteps, canonnumber, acknumber, epoch, canondiffstephash } = GOT;
	if (BLACKBOX_RECORDING_ENABLED) {
		crt.debug_state.curr_blackbox_frametick.push({
			serverPackage: GOT,
		} as never);
	}

	// This is to ignore packages after an emergency clear.
	if (epoch !== crt.replication_state.expected_epoch) {
		logdebug(`[INCOMING] outdated epoch ${epoch}, need ${crt.replication_state.expected_epoch}`);
		return;
	}
	logdebug(`📨 Got ${diffsteps.size()} ds, ${canonnumber ? `canon#: ${canonnumber}` : "none"}, ack: ${acknumber}`);

	if (crt.replication_state.catching_up) {
		process_catchup_package(crt, GOT);
	} else {
		process_realtime_package(crt, GOT);
	}
};

export const onServerSendActionHeaders = (crt: GamuhClientRuntimeContext, GOT: SentActionHeaders) => {
	const { actionHeaders, acknumber } = GOT as {
		actionHeaders: ActionHeader[];
		acknumber: number;
	};
	logdebug(`📨 Got ${actionHeaders.size()} action headers, ${acknumber ? `!ACK ${acknumber}` : "no ack"}`);
	for (const actionHeader of actionHeaders) {
		if (actionHeader.authorId === crt.fanon_runtime._author_name) {
			continue;
		}
		try {
			const translatedArgs = translateArgsFromNameToEntity(
				crt.fanon_runtime,
				actionHeader.actionArgs,
				ActionTypeToGeneralInfo[actionHeader.actionId as ActionType].argNameFields,
			);
			ActionSignals[actionHeader.actionId as ActionType]!.Fire(
				translatedArgs as never,
				actionHeader.authorId as never,
			);
		} catch (e) {
			// Failed to translate args, which usually means an entity argument is invalid.
			// that's fine, replace all args with undefined.
			const neuterArgs = neuterEntityArgs(
				actionHeader.actionArgs,
				ActionTypeToGeneralInfo[actionHeader.actionId as ActionType].argNameFields,
			);
			ActionSignals[actionHeader.actionId as ActionType]!.Fire(
				neuterArgs as never,
				actionHeader.authorId as never,
			);
		}
	}
};

const sys: GamuhClientSystem = {
	name: "client_fanon_receive",
	system: (crt: GamuhClientRuntimeContext) => {
		if (crt.debug_state.replaying_blackbox) return;

		if (Workspace.GetAttribute("Unhalt") === true) {
			crt.HALT = false;
		}

		for (const [_, GOT] of useRemoteCallback<[SentDiffstepsZap]>(ServerSendDiffsteps)) {
			onServerSendDiffsteps(crt, GOT);
		}

		for (const [_, GOT] of useRemoteCallback<[SentActionHeaders]>(ServerSendActionHeaders)) {
			onServerSendActionHeaders(crt, GOT);
		}
	},
	eventId: LOOPUH_ROBLOX_PRIORITY_INT.CLIENT_PreRender,
	priorityOrder: LOOPUH_CLIENT_OFFSET.A_FanonReceive,
};

export default sys;
