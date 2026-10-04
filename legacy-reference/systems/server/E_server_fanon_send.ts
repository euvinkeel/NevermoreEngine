import { GamuhServerSystem } from "server/servertypes";
import { GamuhServerRuntimeContext } from "server/serverruntime";
import { LOOPUH_ROBLOX_PRIORITY_INT, LOOPUH_SERVER_OFFSET } from "shared/libs/loopuh/loopuhRobloxUtil";
import {
	getNormalizedAdditiveDiffstepsString,
	hashDiffsteps,
	queryTuples,
	snapshotSharedWorldAsHash,
	snapshotWorldPrintableString,
} from "shared/libs/statuh/statuhUtil";
import useThrottle from "shared/libs/vendor/hooks/useThrottle";
import { ServerSendActionHeaders, ServerSendDiffsteps } from "server/zap";
import { Diffstep } from "shared/libs/fanon/statuh/statuhFanonDiffstep";
import { StatuhFanonDiffstep } from "shared/libs/fanon/statuh/statuhFanonDiffstep";
import deque from "shared/utils/primitives/deque";
import { hasKey } from "shared/utils/shims";
import { setDebugLogTable } from "shared/actionsLookup";
import { test_info } from "./D_server_fanon_hashes";
import { BLACKBOX_RECORDING_ENABLED } from "shared/blackbox";
import { ActionHeader } from "shared/libs/fanon/statuh/statuhFanonAction";

const max_batch_size = 100;
const SEND_RATE = 1 / 20;
// const DEBUG_SEND_SYSTEM = true;
const DEBUG_SEND_SYSTEM = false;
const DEBUG_SAVE_SNAPSHOTS = false;
// const DEBUG_SAVE_SNAPSHOTS = false;
export const DEBUG_ENABLE_HASHING = false;

// Newline encoding (no regex): use split/join to replace real newlines with a sentinel
const NL_SENTINEL = "<<<NL>>>";
const encodeNewlines = (s: string): string => {
	// normalize CRLF/CR to LF then replace LF with sentinel
	const lf = s.split("\r\n").join("\n").split("\r").join("\n");
	return lf.split("\n").join(NL_SENTINEL);
};

export const server_canon_to_snapshotstring = new Map<number, string>();

// TODO: neurotic invariant: ensure the diffsteps, if run in order, can bring a blank world state to
// exactly the same as it is. ensure all_diffstep_builder diffsteps are actually sufficient and correct
const logdebug = (...args: unknown[]) => {
	if (DEBUG_SEND_SYSTEM) {
		warn("[SERVER_SEND]", ...args);
	}
};

let currWorldHash: number | undefined = undefined;

const sys: GamuhServerSystem = {
	name: "server_fanon_send",
	system: (srt: GamuhServerRuntimeContext) => {
		if (useThrottle(SEND_RATE)) {
			const realtime_diffsteps = srt.fanon_handle.get_additive_diffstep_builder().get_diffsteps();
			const shouldUpdateCanonNumber = realtime_diffsteps.size() > 0 || srt.replication_state.actions_received;
			srt.replication_state.actions_received = false;

			if (shouldUpdateCanonNumber) {
				debug.profilebegin("server_fanon_send_shouldSendCanonNumber");
				srt.replication_state.canon_number++;
				logdebug(
					`🔘 New Canon State Number: ${srt.replication_state.canon_number} (${realtime_diffsteps.size()} diffsteps)`,
				);

				// our entire snapshot state is updated here
				// (server needs all diffsteps in order to catch up players)
				const allds = srt.replication_state.all_diffstep_builder;
				allds.add_diffsteps(realtime_diffsteps);
				currWorldHash = DEBUG_ENABLE_HASHING ? snapshotSharedWorldAsHash(srt.fanon_runtime) : undefined;
				srt.fanon_handle.reset_all_handle_tracking_state();

				// also save the snapshot (IF DEBUGGING LOL)
				if (DEBUG_SAVE_SNAPSHOTS) {
					const snapshotstr = snapshotWorldPrintableString(srt.fanon_runtime);
					const snapshotstr_replaced = encodeNewlines(snapshotstr);
					const additivediffstepstr = getNormalizedAdditiveDiffstepsString(
						srt.replication_state.all_diffstep_builder.get_diffsteps(),
					);
					const additivediffstepstr_replaced = encodeNewlines(additivediffstepstr);
					if (BLACKBOX_RECORDING_ENABLED) {
						srt.debug_state.curr_blackbox_frametick.push({
							canonnumber: srt.replication_state.canon_number,
							snapshotstr: snapshotstr_replaced,
							additivediffstepstr: additivediffstepstr_replaced,
						});
					}
				}

				// try to optimize every so often
				// if (srt.replication_state.canon_number % 10 === 0) {
				if (srt.replication_state.canon_number % 5 === 0) {
					srt.replication_state.all_diffstep_builder.cleanup_inactive(true);
				}

				debug.profileend();
			}

			// To send CATCHUP diffsteps or WARP diffsteps.
			debug.profilebegin("server_fanon_send_catchup");
			for (const [_, plrI, stateC] of queryTuples(srt.world, [
				srt.scps.Instance,
				srt.vcps.PlayerReplicationState,
			])) {
				const SHOULD_CATCH_UP =
					stateC.lastQueuedCanonNumber === undefined && stateC.catchingUpToStateNumber === undefined;
				const SHOULD_ADD_TO_WARP =
					stateC.catchingUpToStateNumber !== undefined && stateC.outgoingDiffsteps.size > 0;
				const SHOULD_SEND_WARP =
					stateC.catchingUpToStateNumber !== undefined && stateC.outgoingDiffsteps.size === 0;

				if (SHOULD_CATCH_UP) {
					// We haven't sent anything to this player.
					// They're not caught up to any previous state.
					// Usually when they join -- catch them up to the current state.
					logdebug(
						`Player ${plrI} has no last kept state number, catching up to state ${srt.replication_state.canon_number}`,
					);
					if (DEBUG_SEND_SYSTEM) {
						for (const diffstep of srt.replication_state.all_diffstep_builder.get_diffsteps()) {
							logdebug(" CATCHUP > ", StatuhFanonDiffstep.diffstep_to_str(diffstep as Diffstep));
						}
					}
					enqueueCatchupDiffsteps(srt, stateC, srt.replication_state.all_diffstep_builder.get_diffsteps());
					stateC.warpBuilder.clear();
				} else if (SHOULD_ADD_TO_WARP) {
					// They have a catch-up target.
					// They are still catching up.
					// Meanwhile, prepare the warp diffsteps.
					if (realtime_diffsteps.size() > 0) {
						logdebug(`Adding realtime diffsteps to accumulating warp ${plrI}:`);
						stateC.warpBuilder.add_diffsteps(realtime_diffsteps);
						if (DEBUG_SEND_SYSTEM) {
							for (const diffstep of realtime_diffsteps) {
								logdebug(" ACCUMWARP + ", StatuhFanonDiffstep.diffstep_to_str(diffstep as Diffstep));
							}
						}
					}
				} else if (SHOULD_SEND_WARP) {
					// They have a catch-up target.
					// They have no more diffsteps to send.
					// They're ready to go warp to our current state, which may be vastly different from
					// the static snapshot they caught up to.

					// Don't forget to close the gap! Top it off with any realtime diffsteps we have left.
					stateC.warpBuilder.add_diffsteps(realtime_diffsteps);
					const warp_diffsteps = stateC.warpBuilder.get_diffsteps();
					if (DEBUG_SEND_SYSTEM) {
						if (warp_diffsteps.size() > 0) {
							logdebug(
								`All catch-up diffsteps to ${plrI} gone, finally warping them to state ${srt.replication_state.canon_number}.`,
							);
							for (const diffstep of warp_diffsteps) {
								logdebug(" WARP > ", StatuhFanonDiffstep.diffstep_to_str(diffstep as Diffstep));
							}
						} else {
							logdebug(`No warp necessary, just send state number ${srt.replication_state.canon_number}`);
						}
					}
					enqueueDiffstepsAndStateNumber(srt, stateC, warp_diffsteps, currWorldHash);
					stateC.catchingUpToStateNumber = undefined;
					stateC.lastReadAcknumber = undefined;
					stateC.warpBuilder.clear();
					stateC.actionsEnabled = true;
				}
			}
			debug.profileend();

			// To send REALTIME diffsteps
			// Here we gather everything accumulated by our handle and clear it.
			// We also send the canon number here and mark boundaries
			debug.profilebegin("server_fanon_send_realtime");
			for (const [_, stateC] of queryTuples(srt.world, [srt.vcps.PlayerReplicationState])) {
				if (stateC.catchingUpToStateNumber !== undefined) continue;
				if (stateC.lastQueuedCanonNumber === undefined) continue;

				// There used to be a check here that checked if there were no diffsteps to send.
				// But even if there were no diffsteps to send, we still need to send the state number.
				// In case we rejected all their actions. We still need to send some acknowledgement so they
				// can revert it.
				// On the other hand, we should only send each canon number once.
				if (stateC.lastQueuedCanonNumber === srt.replication_state.canon_number) continue;

				// A player is considered realtime when the server knows they've already sent a client up
				// to some existent state number, known by lastQueuedCanonNumber.
				// if (DEBUG_SEND_SYSTEM) {
				// 	for (const diffstep of realtime_diffsteps) {
				// 		logdebug(" REALTIME > ", StatuhFanonDiffstep.diffstep_to_str(diffstep as Diffstep));
				// 	}
				// }
				enqueueDiffstepsAndStateNumber(srt, stateC, realtime_diffsteps, currWorldHash);
			}
			debug.profileend();

			// To send packages across network barrier
			// Batching happens here.
			for (const [id, plrInstance, stateC] of queryTuples(srt.world, [
				srt.scps.Instance,
				srt.vcps.PlayerReplicationState,
			])) {
				// OutgoingDiffsteps also contain state numbers, so this empty check is fine.
				// If it's empty, then there's no new state to send.
				if (stateC.outgoingDiffsteps.size === 0) continue;

				let encountered_canon_number: number | undefined = undefined;
				let encountered_canon_hash: number | undefined = undefined;
				let encountered_ack_number: number | undefined = undefined;
				let encountered_world_hash: number | undefined = undefined;

				const diffstep_batch: Diffstep[] = [];
				for (let _ = 0; _ < max_batch_size; _++) {
					const got = stateC.outgoingDiffsteps.popLeft();
					if (got === undefined) break;
					if (hasKey(got, "canonnumber")) {
						const info = got as {
							canonnumber: number;
							canondiffstephash: number;
							canonworldhash: number | undefined;
							acknumber: number | undefined;
						};
						encountered_canon_number = info.canonnumber;
						encountered_canon_hash = info.canondiffstephash;
						encountered_world_hash = info.canonworldhash;
						encountered_ack_number = info.acknumber;
						// Canon numbers always come last, no diffsteps after them.
						break;
					} else {
						diffstep_batch.push(got as Diffstep);
					}
				}

				if (DEBUG_SEND_SYSTEM) {
					logdebug(`\nFinal outgoing diffsteps to ${plrInstance}:`);
					for (const diffstep of diffstep_batch) {
						logdebug(`\t${plrInstance} > `, StatuhFanonDiffstep.diffstep_to_str(diffstep as Diffstep));
					}
					if (encountered_canon_number !== undefined) {
						logdebug(
							`${plrInstance} - CANON#${encountered_canon_number}, ${encountered_ack_number ? `ACK#${encountered_ack_number}` : "_"}\n`,
						);
					} else {
						logdebug(`${plrInstance} - (no canon/ack)\n`);
					}
				}

				if (!srt.debug_state.replaying_blackbox) {
					ServerSendDiffsteps.Fire(plrInstance as Player, {
						diffsteps: diffstep_batch,
						epoch: stateC.epochNumber,
						canonnumber: encountered_canon_number,
						acknumber: encountered_ack_number,
						canondiffstephash: encountered_canon_hash,
						canonworldhash: encountered_world_hash,
					});
				}

				// Canon_number could be undefined if we're in the middle of realtime packet sending.
				// After all, only the final batch should have a canon number.
				// NEVER set it to undefined. That's only for when we're catching up players.
				if (encountered_canon_number !== undefined) {
					stateC.lastSentCanonNumber = encountered_canon_number;
				}
			}

			// Send action headers through a different channel.
			for (const [_, playerInstance, stateC] of queryTuples(srt.world, [
				srt.scps.Instance,
				srt.vcps.PlayerReplicationState,
			])) {
				const actionHeadersToSend: ActionHeader[] = [];
				for (const actionHeader of srt.action_runtime.action_header_log) {
					if (actionHeader.authorId === stateC.authorId) {
						continue;
					} else {
						actionHeadersToSend.push(actionHeader);
					}
				}
				if (actionHeadersToSend.size() > 0) {
					ServerSendActionHeaders.Fire(playerInstance as Player, {
						actionHeaders: actionHeadersToSend,
					});
				}
			}
			srt.action_runtime.action_header_log.clear();
		}

		srt.debug_state.blackbox.push(srt.debug_state.curr_blackbox_frametick);
		srt.debug_state.curr_blackbox_frametick = [] as never;
		setDebugLogTable(srt.debug_state.curr_blackbox_frametick);

		srt.frametick++;
	},
	eventId: LOOPUH_ROBLOX_PRIORITY_INT.SERVER_Heartbeat,
	priorityOrder: LOOPUH_SERVER_OFFSET.E_FanonSend,
};

const enqueueCatchupDiffsteps = (
	srt: GamuhServerRuntimeContext,
	stateC: {
		warpBuilder: StatuhFanonDiffstep.DiffstepBuilder;
		catchingUpToStateNumber: number | undefined;
		lastReadAcknumber: number | undefined;
		outgoingDiffsteps: deque<
			| Diffstep
			| {
					canonnumber: number;
					canondiffstephash: number;
					canonworldhash: number | undefined;
					acknumber: number | undefined;
			  }
		>;
	},
	all_diffsteps: Diffstep[],
) => {
	for (const diffstep of all_diffsteps) {
		stateC.outgoingDiffsteps.appendRight(diffstep);
	}
	// To make someone CATCH-UP, must reset whatever warp builder they had.
	stateC.warpBuilder.clear();
	stateC.catchingUpToStateNumber = srt.replication_state.canon_number;
	stateC.lastReadAcknumber = undefined;
};

const enqueueDiffstepsAndStateNumber = (
	srt: GamuhServerRuntimeContext,
	stateC: {
		catchingUpToStateNumber: number | undefined;
		lastReadAcknumber: number | undefined;
		lastQueuedCanonNumber: number | undefined;
		outgoingDiffsteps: deque<
			| Diffstep
			| {
					canonnumber: number;
					canondiffstephash: number;
					canonworldhash: number | undefined;
					acknumber: number | undefined;
			  }
		>;
	},
	warp_diffsteps: Diffstep[],
	world_hash: number | undefined,
) => {
	debug.profilebegin("server_fanon_send_enqueueDiffstepsAndStateNumber");
	for (const diffstep of warp_diffsteps) {
		stateC.outgoingDiffsteps.appendRight(diffstep);
	}
	const ack_number = stateC.lastReadAcknumber;
	if (world_hash !== undefined) {
		test_info.server_hash = world_hash;
	}
	stateC.outgoingDiffsteps.appendRight({
		canonnumber: srt.replication_state.canon_number,
		canondiffstephash: 0, // for now we're not using this
		canonworldhash: world_hash,
		acknumber: ack_number,
	});
	stateC.lastQueuedCanonNumber = srt.replication_state.canon_number;
	stateC.lastReadAcknumber = undefined;
	debug.profileend();
};

export default sys;
