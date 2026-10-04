import { GamuhServerSystem } from "server/servertypes";
import { GamuhServerRuntimeContext } from "server/serverruntime";
import { LOOPUH_ROBLOX_PRIORITY_INT, LOOPUH_SERVER_OFFSET } from "shared/libs/loopuh/loopuhRobloxUtil";
import useThrottle from "shared/libs/vendor/hooks/useThrottle";
import { FanonName, ServerStreamUPosition, ServerStreamUDirection, ServerStreamUVelocity } from "server/zap";
import { useComponentTracker } from "shared/libs/vendor/hooks/useComponentTracker";
import { StatuhFanonName } from "shared/libs/fanon/statuh/statuhFanonName";
import { useQueryTracker } from "shared/libs/vendor/hooks/useQueryTracker";
import { statuh_pair } from "shared/libs/statuh/statuhRuntime";
import { useChanged } from "shared/libs/vendor/hooks/useChanged";
import { valid_vec3 } from "shared/utils/gameUtil";
import { VEC_ZERO } from "shared/constants";

const STREAM_THROTTLE = 1 / 30;
const FULL_THROTTLE = 1;

const sys: GamuhServerSystem = {
	name: "server_stream_send",
	system: (srt: GamuhServerRuntimeContext) => {
		if (!useThrottle(STREAM_THROTTLE)) return;
		const full_replication = useThrottle(FULL_THROTTLE);

		const { currset: server_uposition_set } = useQueryTracker(
			srt.world.query_entities_of_archetype(
				[srt.scps.U_Position],
				[statuh_pair(srt.rcps.S_R_U_Position_Source, srt.world.get_wildcard())],
			),
		);
		const { currset: server_uvelocity_set } = useQueryTracker(
			srt.world.query_entities_of_archetype(
				[srt.scps.U_Velocity],
				[statuh_pair(srt.rcps.S_R_U_Velocity_Source, srt.world.get_wildcard())],
			),
		);
		const { currset: server_udirection_set } = useQueryTracker(
			srt.world.query_entities_of_archetype(
				[srt.scps.U_Direction],
				[statuh_pair(srt.rcps.S_R_U_Direction_Source, srt.world.get_wildcard())],
			),
		);

		for (const changed_entity_upos of server_uposition_set.getList()) {
			const upos = srt.world.get_component_data(changed_entity_upos, srt.scps.U_Position);
			if (!valid_vec3(upos)) continue;
			const fanon_name = StatuhFanonName.getFanonNameFromStatuhEntity(
				srt.fanon_runtime,
				changed_entity_upos,
			) as FanonName;
			if (useChanged(upos, changed_entity_upos, true) || full_replication) {
				// warn(`Server streaming ${fanon_name} position ${upos}`);
				ServerStreamUPosition.FireAll({
					fanon_name,
					position: upos as Vector3,
				});
			}
		}

		for (const changed_entity_uvel of server_uvelocity_set.getList()) {
			const uvel = srt.world.get_component_data(changed_entity_uvel, srt.scps.U_Velocity);
			if (!valid_vec3(uvel)) continue;
			const fanon_name = StatuhFanonName.getFanonNameFromStatuhEntity(
				srt.fanon_runtime,
				changed_entity_uvel,
			) as FanonName;
			if (useChanged(uvel, changed_entity_uvel, true) || full_replication) {
				ServerStreamUVelocity.FireAll({
					fanon_name,
					velocity: uvel as Vector3,
				});
			}
		}

		for (const changed_entity_udir of server_udirection_set.getList()) {
			const udir = srt.world.get_component_data(changed_entity_udir, srt.scps.U_Direction);
			if (!valid_vec3(udir)) continue;
			if (udir === VEC_ZERO) continue;
			const fanon_name = StatuhFanonName.getFanonNameFromStatuhEntity(
				srt.fanon_runtime,
				changed_entity_udir,
			) as FanonName;
			if (useChanged(udir, changed_entity_udir, true) || full_replication) {
				ServerStreamUDirection.FireAll({
					fanon_name,
					direction: udir as Vector3,
				});
			}
		}
	},
	eventId: LOOPUH_ROBLOX_PRIORITY_INT.SERVER_Heartbeat,
	priorityOrder: LOOPUH_SERVER_OFFSET.E_FanonSend,
};

export default sys;
