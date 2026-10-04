import { GamuhServerSystem } from "server/servertypes";
import { GamuhServerRuntimeContext } from "server/serverruntime";
import { LOOPUH_ROBLOX_PRIORITY_INT, LOOPUH_SERVER_OFFSET } from "shared/libs/loopuh/loopuhRobloxUtil";
import { ClientSendActionHeaders, RequestEmergencyClear, SentActionHeaders, TEST_HALTSERVER } from "server/zap";
import useRemoteCallback from "shared/libs/vendor/hooks/useRemoteCallback";
import { ActionSignals, ActionType, ActionTypeToGeneralInfo, setDebugLogTable } from "shared/actionsLookup";
import {
	ActionArgs,
	ActionConfig,
	ActionExecutionCtx,
	ActionHeader,
	ActionReplayCtx,
	replayAction,
	translateArgsFromNameToEntity,
} from "shared/libs/fanon/statuh/statuhFanonAction";
import { getPlayerEntityFromPlayer } from "shared/utils/gameUtil";
import { tableinlinestr } from "shared/utils/miscUtil";
import { StatuhEntity } from "shared/libs/statuh/statuhTypes";
import {
	actionHeaderToPrintableString,
	queryTuples,
	snapshotWorldPrintableString,
} from "shared/libs/statuh/statuhUtil";
import { _LocalName, StatuhFanonName } from "shared/libs/fanon/statuh/statuhFanonName";
import { HttpService, Workspace } from "@rbxts/services";
import { server_canon_to_snapshotstring } from "./E_server_fanon_send";
import { BLACKBOX_RECORDING_ENABLED } from "shared/blackbox";
import { StatuhFanonDiffstep } from "shared/libs/fanon/statuh/statuhFanonDiffstep";
import deque from "shared/utils/primitives/deque";
import { runOnce } from "shared/libs/vendor/hooks/runOnce";
import { DevFlags } from "shared/gamevars";
import { IS_STUDIO } from "shared/constants";
// const DEBUG_SERVER_RECEIVE_SYSTEM = true;
const DEBUG_SERVER_RECEIVE_SYSTEM = false;

const logdebug = (...args: unknown[]) => {
	if (DEBUG_SERVER_RECEIVE_SYSTEM) {
		warn("[SERVER RECEIVE]", ...args);
	}
};

export const EmergencyClearPlayerEntity = (
	srt: GamuhServerRuntimeContext,
	playerEntity: StatuhEntity,
	newEpoch: number,
) => {
	const repstate = srt.world.get_component_data(playerEntity, srt.vcps.PlayerReplicationState);
	repstate.actionsEnabled = false;
	repstate.catchingUpToStateNumber = undefined;
	repstate.lastSentCanonNumber = undefined;
	repstate.lastQueuedCanonNumber = undefined;
	repstate.lastReadAcknumber = undefined;
	repstate.warpBuilder.clear();
	repstate.warpBuilder = new StatuhFanonDiffstep.DiffstepBuilder();
	repstate.outgoingDiffsteps.clear();
	repstate.outgoingDiffsteps = new deque();
	repstate.outgoingPackageQueue.clear();
	repstate.outgoingPackageQueue = new deque();
	repstate.epochNumber = newEpoch;
};

const findPlayerEntityByUserId = (srt: GamuhServerRuntimeContext, userId: number) => {
	for (const [id, playerC] of queryTuples(srt.world, [srt.rcps.S_Player])) {
		if (playerC.userId === userId) return id;
	}
	return undefined;
};

export const onPlayerEntitySendActionHeaders = (
	srt: GamuhServerRuntimeContext,
	playerEntity: StatuhEntity,
	GOT: SentActionHeaders,
) => {
	// const playerEntity = StatuhFanonName.getStatuhEntityFromLocalName(srt.fanon_runtime, playerFanonName);
	// if (playerEntity === undefined) {
	// 	warn(`Player ${playerFanonName} has no entity`);
	// 	return;
	// }
	// Log network boundary input for server blackbox
	const playerFanonName = StatuhFanonName.getFanonNameFromStatuhEntity(srt.fanon_runtime, playerEntity)!;
	if (BLACKBOX_RECORDING_ENABLED) {
		srt.debug_state.curr_blackbox_frametick.push({
			playerFanonName: playerFanonName,
			clientPackage: GOT,
		} as never);
	}

	const { actionHeaders, acknumber } = GOT as {
		actionHeaders: ActionHeader[];
		acknumber: number;
	};

	if (DEBUG_SERVER_RECEIVE_SYSTEM) {
		for (const actionHeader of actionHeaders) {
			logdebug(`\t${actionHeaderToPrintableString(actionHeader)}`);
		}
	}

	for (let actionHeader of actionHeaders) {
		const info = ActionTypeToGeneralInfo[actionHeader.actionId as ActionType];
		const config = info.config as ActionConfig<typeof actionHeader.actionArgs>;
		let translatedArgs: ActionArgs;
		try {
			translatedArgs = translateArgsFromNameToEntity(
				srt.fanon_runtime,
				actionHeader.actionArgs,
				info.argNameFields,
			);
		} catch (e) {
			warn(`Error translating args for action ${actionHeader.actionId}: ${e}`);
			warn(`Treat as failure, skip action.`);
			continue;
		}
		const actionExecutionCtx: ActionExecutionCtx<typeof actionHeader.actionArgs> = {
			args: translatedArgs,
		};
		const actionReplayCtx: ActionReplayCtx<typeof actionHeader.actionArgs> = {
			args: translatedArgs,
			authorEntity: playerEntity,
		};
		const { returned, errmsg } = replayAction(
			actionHeader.actionId,
			srt.action_runtime,
			actionReplayCtx,
			actionExecutionCtx,
			actionHeader.createdNames,
			config.effect,
			config.validate,
		);
		if (errmsg === undefined) {
			if (DEBUG_SERVER_RECEIVE_SYSTEM) {
				logdebug(
					`Replayed action ${actionHeader.actionId} from ${playerEntity} (${tableinlinestr(actionHeader.actionArgs)})`,
				);
			}

			ActionSignals[actionHeader.actionId as ActionType]!.Fire(
				actionExecutionCtx.args as never,
				actionHeader.authorId as never,
			);

			// Remember to re-enqueue to send out a successful action to players.
			srt.action_runtime.action_header_log.push(actionHeader);

			// Blackbox log executed action
			if (BLACKBOX_RECORDING_ENABLED) {
				srt.debug_state.curr_blackbox_frametick.push({
					actionId: actionHeader.actionId,
					actionArgs: actionHeader.actionArgs,
				} as never);
			}
		} else {
			logdebug(`Rejected action ${actionHeader.actionId}: ${errmsg}`);
		}
	}
};

const sys: GamuhServerSystem = {
	name: "server_fanon_receive",
	system: (srt: GamuhServerRuntimeContext) => {
		if (srt.debug_state.replaying_blackbox) return;

		if (runOnce()) {
			Workspace.SetAttribute(DevFlags.Unhalt, false);
			Workspace.SetAttribute(DevFlags.FixFlag, true);
			Workspace.SetAttribute(DevFlags.ClearOnHalt, false);
		}

		if (Workspace.GetAttribute(DevFlags.Unhalt) === true) {
			srt.HALT = false;
			Workspace.SetAttribute(DevFlags.Unhalt, false);
		}

		if (IS_STUDIO) {
			for (const [_, player, got] of useRemoteCallback<[Player, { servercanonnumber: number }]>(
				TEST_HALTSERVER,
			)) {
				srt.HALT = true;
				print("🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥 ");
				warn(`Server halted by player ${player}`);
				warn(`The canon number halted at was ${got.servercanonnumber}`);
				warn(`The server's snapshot world at that canon number:`);
				print(server_canon_to_snapshotstring.get(got.servercanonnumber));
				srt.debug_state.blackbox.push(srt.debug_state.curr_blackbox_frametick);
				srt.debug_state.curr_blackbox_frametick = [];
				setDebugLogTable(srt.debug_state.curr_blackbox_frametick);

				// Now halt everything.
				print("BLACKBOX BLACK BOX BLACKBOX");
				print(srt.debug_state.blackbox);
				const ser = HttpService.JSONEncode(srt.debug_state.blackbox);
				print(`\n\n\n${ser}\n\n\n`);
				print("🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥 ");
				return;
			}
		}

		for (const [_, player, got] of useRemoteCallback<[Player, { newEpoch: number }]>(RequestEmergencyClear)) {
			const { newEpoch } = got;
			// Emergency clear: assume player is clean slate and setup for catchup
			const playerEntity = getPlayerEntityFromPlayer(srt, player);
			if (playerEntity === undefined) continue;
			EmergencyClearPlayerEntity(srt, playerEntity, newEpoch);
		}

		for (const [_, player, GOT] of useRemoteCallback<[Player, SentActionHeaders]>(ClientSendActionHeaders)) {
			let playerEntity = player ? getPlayerEntityFromPlayer(srt, player) : undefined;
			if (playerEntity === undefined) {
				warn(`Player ${player} has no entity`);
				continue;
			}
			const repstate = srt.world.get_component_data(playerEntity, srt.vcps.PlayerReplicationState);
			if (!repstate.actionsEnabled) {
				warn(`Player ${player} is not enabled; should not acknowledge any actions/ack.`);
				continue;
			}

			repstate.lastReadAcknumber = GOT.acknumber;
			logdebug(
				`\n\nGot ${GOT.actionHeaders.size()} action headers from ${playerEntity} (ack: ${GOT.acknumber}):`,
			);
			// Used to always update canon number
			srt.replication_state.actions_received = true;
			onPlayerEntitySendActionHeaders(srt, playerEntity, GOT);
		}
	},
	eventId: LOOPUH_ROBLOX_PRIORITY_INT.SERVER_Heartbeat,
	priorityOrder: LOOPUH_SERVER_OFFSET.A_FanonReceive,
};

export default sys;
