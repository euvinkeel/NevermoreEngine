import { GamuhClientSystem } from "client/clienttypes";
import { GamuhClientRuntimeContext } from "client/clientruntime";
import { LOOPUH_CLIENT_OFFSET, LOOPUH_ROBLOX_PRIORITY_INT } from "shared/libs/loopuh/loopuhRobloxUtil";
import { FanonName, ClientStreamUPosition, ClientStreamUVelocity, ClientStreamUDirection } from "client/zap";
import { StatuhFanonName } from "shared/libs/fanon/statuh/statuhFanonName";
import { statuh_pair } from "shared/libs/statuh/statuhRuntime";
import { useQueryTracker } from "shared/libs/vendor/hooks/useQueryTracker";
import useThrottle from "shared/libs/vendor/hooks/useThrottle";
import { useChanged } from "shared/libs/vendor/hooks/useChanged";

const STREAM_THROTTLE = 1 / 30;
const FULL_THROTTLE = 2;

const sys: GamuhClientSystem = {
	name: "client_stream_send",
	system: (crt: GamuhClientRuntimeContext) => {
		if (!useThrottle(STREAM_THROTTLE)) return;
		const full_replication = useThrottle(FULL_THROTTLE);

		if (crt.local_state.player_entity === undefined) return;

		const { currset: server_uposition_set } = useQueryTracker(
			crt.world.query_entities_of_archetype([
				crt.scps.U_Position,
				statuh_pair(crt.rcps.S_R_U_Position_Source, crt.local_state.player_entity),
			]),
		);
		const { currset: server_uvelocity_set } = useQueryTracker(
			crt.world.query_entities_of_archetype([
				crt.scps.U_Velocity,
				statuh_pair(crt.rcps.S_R_U_Velocity_Source, crt.local_state.player_entity),
			]),
		);
		const { currset: server_udirection_set } = useQueryTracker(
			crt.world.query_entities_of_archetype([
				crt.scps.U_Direction,
				statuh_pair(crt.rcps.S_R_U_Direction_Source, crt.local_state.player_entity),
			]),
		);

		for (const changed_entity_upos of server_uposition_set.getList()) {
			const upos = crt.world.get_component_data(changed_entity_upos, crt.scps.U_Position);
			const fanon_name = StatuhFanonName.getFanonNameFromStatuhEntity(
				crt.fanon_runtime,
				changed_entity_upos,
			) as FanonName;
			if (useChanged(upos, changed_entity_upos, true) || full_replication) {
				ClientStreamUPosition.Fire({
					fanon_name,
					position: upos as Vector3,
				});
			}
		}

		for (const changed_entity_uvel of server_uvelocity_set.getList()) {
			const uvel = crt.world.get_component_data(changed_entity_uvel, crt.scps.U_Velocity);
			const fanon_name = StatuhFanonName.getFanonNameFromStatuhEntity(
				crt.fanon_runtime,
				changed_entity_uvel,
			) as FanonName;
			if (useChanged(uvel, changed_entity_uvel, true) || full_replication) {
				ClientStreamUVelocity.Fire({
					fanon_name,
					velocity: uvel as Vector3,
				});
			}
		}

		for (const changed_entity_udir of server_udirection_set.getList()) {
			const udir = crt.world.get_component_data(changed_entity_udir, crt.scps.U_Direction);
			const fanon_name = StatuhFanonName.getFanonNameFromStatuhEntity(
				crt.fanon_runtime,
				changed_entity_udir,
			) as FanonName;
			if (useChanged(udir, changed_entity_udir, true) || full_replication) {
				ClientStreamUDirection.Fire({
					fanon_name,
					direction: udir as Vector3,
				});
			}
		}
	},
	eventId: LOOPUH_ROBLOX_PRIORITY_INT.CLIENT_PreRender,
	priorityOrder: LOOPUH_CLIENT_OFFSET.E_FanonSend - 10,
};

export default sys;
