import { GamuhClientSystem } from "client/clienttypes";
import { GamuhClientRuntimeContext } from "client/clientruntime";
import { LOOPUH_CLIENT_OFFSET, LOOPUH_ROBLOX_PRIORITY_INT } from "shared/libs/loopuh/loopuhRobloxUtil";
import useThrottle from "shared/libs/vendor/hooks/useThrottle";
import {
	ClientSendActionHeaders,
	RequestEmergencyClear,
	ForceEmergencyClearOntoPlayer,
	SentActionHeaders,
	TEST_HALTSERVER,
} from "client/zap";
import { ActionType, ActionTypeToGeneralInfo, setDebugLogTable } from "shared/actionsLookup";
import { ActionArgs, prepareArgsFromEntityToName } from "shared/libs/fanon/statuh/statuhFanonAction";
import { StatuhFanonName } from "shared/libs/fanon/statuh/statuhFanonName";
import { resetStatuhFanonRuntime } from "shared/libs/fanon/statuh/statuhFanon";
import useRemoteCallback from "shared/libs/vendor/hooks/useRemoteCallback";
import { HttpService, ScriptContext, Workspace } from "@rbxts/services";
import { getAllReplicatedEntities, snapshotWorldPrintableString } from "shared/libs/statuh/statuhUtil";
import useEvent from "shared/libs/vendor/hooks/useEvent";
import { DevFlags } from "shared/gamevars";
import { IS_STUDIO } from "shared/constants";
import { BLACKBOX_RECORDING_ENABLED } from "shared/blackbox";

const SEND_RATE = 1 / 20;
// const DEBUG_SEND_SYSTEM = true;
const DEBUG_SEND_SYSTEM = false;

const logdebug = (...args: unknown[]) => {
	if (DEBUG_SEND_SYSTEM) {
		warn("[SEND]", ...args);
	}
};

export const OnFatalError = (crt: GamuhClientRuntimeContext) => {
	print("🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥 ");
	print("LEFTOVER FRAMETICK JUST PUSHED:", crt.debug_state.curr_blackbox_frametick);

	crt.debug_state.blackbox.push(crt.debug_state.curr_blackbox_frametick);
	crt.debug_state.curr_blackbox_frametick = [];
	setDebugLogTable(crt.debug_state.curr_blackbox_frametick);

	// if (IS_STUDIO) {
	// 	// Catch the error and halt everything.
	// 	crt.HALT = true;
	// 	TEST_HALTSERVER.Fire({
	// 		servercanonnumber: crt.replication_state.curr_canonnumber,
	// 	});
	// } else {
	// 	// In production, just try to clear and move on.
	// 	EmergencyClearOurself(crt);
	// }
	EmergencyClearOurself(crt);

	print("\n\n\n");
	print("SNAPSHOT AT FATAL ERROR:");
	print(snapshotWorldPrintableString(crt.fanon_runtime));
	print("\n\n\n");
	print("BLACKBOX:");
	print(crt.debug_state.blackbox);
	const ser = HttpService.JSONEncode(crt.debug_state.blackbox);
	print(`\n\n\n${ser}\n\n\n`);
	print("🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥 ");
};

export const EmergencyClearOurself = (crt: GamuhClientRuntimeContext) => {
	// First, update epoch to ignore any incoming packages
	// until the server has cleared our replication state on its end
	// and has incremented its epoch number as well.
	print("🛑 EMERGENCY CLEAR CALLED 🛑");
	crt.replication_state.expected_epoch++;

	// Robust clear: delete only replicated entities; leave any local-only state intact
	const replicatedEntities = getAllReplicatedEntities(crt.fanon_runtime);
	for (const e of replicatedEntities) {
		if (crt.world.contains_entity(e)) {
			crt.world.delete_entity(e);
		}
	}

	crt.fanon_handle.reset_all_handle_tracking_state();
	crt.action_runtime.action_header_log.clear();
	// never reset our acknumber... i think we require it to be unique counter
	// crt.action_runtime.last_acknumber = 0;
	StatuhFanonName.cleanupNonexistentEntitiesFromNameMap(crt.fanon_runtime);
	crt.replication_state.catching_up = true;
	crt.replication_state.all_canonical_diffsteps.clear();
	crt.replication_state.package_diffsteps.clear();
	crt.replication_state.accum_new_server_canon.clear();
	crt.replication_state.curr_canonnumber = 0;
	resetStatuhFanonRuntime(crt.fanon_runtime);
	RequestEmergencyClear.Fire({ newEpoch: crt.replication_state.expected_epoch });
	crt.replication_state.emergency_clear_signal.Fire();
	return crt.replication_state.expected_epoch;
};

const sys: GamuhClientSystem = {
	name: "client_fanon_send",
	system: (crt: GamuhClientRuntimeContext) => {
		for (const [_, GOT] of useRemoteCallback<[SentActionHeaders]>(ForceEmergencyClearOntoPlayer)) {
			print("🛑 SERVER FORCING EMERGENCY CLEAR ON US 🛑");
			EmergencyClearOurself(crt);
		}

		const sendTick = useThrottle(SEND_RATE);
		const haveNewActions = crt.action_runtime.action_header_log.size() > 0;
		const has_a_canonnumber =
			crt.replication_state.curr_canonnumber !== undefined && crt.replication_state.curr_canonnumber !== 0;
		const isCatchingUp = crt.replication_state.catching_up;

		if (sendTick && haveNewActions && !isCatchingUp && has_a_canonnumber) {
			const newAcknumber = crt.action_runtime.last_acknumber + 1;
			crt.action_runtime.last_acknumber = newAcknumber;
			crt.fanon_handle.mark_last_operation(newAcknumber);
			const outgoingPackage: SentActionHeaders = {
				actionHeaders: crt.action_runtime.action_header_log,
				acknumber: newAcknumber,
			};
			ClientSendActionHeaders.Fire(outgoingPackage);

			table.clear(crt.action_runtime.action_header_log);
			logdebug(`📤 Final outgoing ACK ${newAcknumber} :`, outgoingPackage);
		}

		// In case any error occurs and we need the blackbox.
		for (const [i, err] of useEvent(ScriptContext, "Error")) {
			warn(`Error ${i}:`, err);
			print(crt.debug_state);
		}

		// For debugging, save and push the current frame tick to the history.
		if (BLACKBOX_RECORDING_ENABLED) {
			crt.debug_state.blackbox.push(crt.debug_state.curr_blackbox_frametick);
			crt.debug_state.curr_blackbox_frametick = [];
			setDebugLogTable(crt.debug_state.curr_blackbox_frametick);
			crt.frametick++;
		}
	},
	eventId: LOOPUH_ROBLOX_PRIORITY_INT.CLIENT_PreRender,
	priorityOrder: LOOPUH_CLIENT_OFFSET.E_FanonSend,
};

export default sys;
