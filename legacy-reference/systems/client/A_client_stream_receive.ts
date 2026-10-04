import { GamuhClientSystem } from "client/clienttypes";
import { GamuhClientRuntimeContext } from "client/clientruntime";
import { LOOPUH_CLIENT_OFFSET, LOOPUH_ROBLOX_PRIORITY_INT } from "shared/libs/loopuh/loopuhRobloxUtil";
import useRemoteCallback from "shared/libs/vendor/hooks/useRemoteCallback";
import { ServerStreamUDirection, ServerStreamUPosition, ServerStreamUVelocity } from "client/zap";
import { StatuhFanonName } from "shared/libs/fanon/statuh/statuhFanonName";
import { entityExists, queryTuples } from "shared/libs/statuh/statuhUtil";
import { runOnce } from "shared/libs/vendor/hooks/runOnce";
import { forCurrentAndFutureEntitiesSetted, valid_vec3 } from "shared/utils/gameUtil";
import { statuh_pair } from "shared/libs/statuh/statuhRuntime";
import { StatuhEntity } from "shared/libs/statuh/statuhTypes";

const sys: GamuhClientSystem = {
	name: "client_stream_receive",
	system: (crt: GamuhClientRuntimeContext) => {
		if (!crt.local_state.player_entity) return;

		for (const [_, sct] of useRemoteCallback<[{ fanon_name: string; position: vector }]>(ServerStreamUPosition)) {
			const { fanon_name, position } = sct;
			const id = StatuhFanonName.getStatuhEntityFromLocalName(crt.fanon_runtime, fanon_name);
			if (!entityExists(crt.world, id)) continue;
			if (
				crt.world.has_component(id, statuh_pair(crt.rcps.S_R_U_Position_Source, crt.local_state.player_entity))
			) {
				continue;
			}
			if (crt.world.has_component(id, crt.scps.U_IgnoreAllStreams)) continue;
			if (!valid_vec3(position as unknown as Vector3)) continue;
			crt.world.set_component_data(id, crt.scps.U_Position, position as unknown as Vector3);
			crt.world.set_component_data(id, crt.scps.Position, position as unknown as Vector3);
		}

		for (const [_, sct] of useRemoteCallback<[{ fanon_name: string; velocity: vector }]>(ServerStreamUVelocity)) {
			const { fanon_name, velocity } = sct;
			const id = StatuhFanonName.getStatuhEntityFromLocalName(crt.fanon_runtime, fanon_name);
			if (!entityExists(crt.world, id)) continue;
			if (
				crt.world.has_component(id, statuh_pair(crt.rcps.S_R_U_Velocity_Source, crt.local_state.player_entity))
			) {
				continue;
			}
			if (crt.world.has_component(id, crt.scps.U_IgnoreAllStreams)) continue;
			if (!valid_vec3(velocity as unknown as Vector3)) continue;
			crt.world.set_component_data(id, crt.scps.U_Velocity, velocity as unknown as Vector3);
			crt.world.set_component_data(id, crt.scps.Velocity, velocity as unknown as Vector3);
		}

		for (const [_, sct] of useRemoteCallback<[{ fanon_name: string; direction: vector }]>(ServerStreamUDirection)) {
			const { fanon_name, direction } = sct;
			const id = StatuhFanonName.getStatuhEntityFromLocalName(crt.fanon_runtime, fanon_name);
			if (!entityExists(crt.world, id)) continue;
			if (
				crt.world.has_component(id, statuh_pair(crt.rcps.S_R_U_Direction_Source, crt.local_state.player_entity))
			) {
				continue;
			}
			if (crt.world.has_component(id, crt.scps.U_IgnoreAllStreams)) continue;
			if (!valid_vec3(direction as unknown as Vector3)) continue;
			crt.world.set_component_data(id, crt.scps.U_Direction, direction as unknown as Vector3);
			crt.world.set_component_data(id, crt.scps.Direction, direction as unknown as Vector3);
		}

		// reconcile regular pos vel dir stuff here
		// The client will *derive* its position, direction, and velocity from either U-Components or S-Components.
		if (runOnce()) {
			forCurrentAndFutureEntitiesSetted(crt, crt.rcps.S_Position, (et, id, sdata) => {
				const spos = sdata as Vector3;
				const upos = crt.world.get_component_data(et, crt.scps.U_Position);
				if (!valid_vec3(upos)) {
					if (!valid_vec3(spos)) return;
					if (crt.world.has_component(et, crt.scps.U_IgnoreAllStreams)) return;
					crt.world.set_component_data(et, crt.scps.Position, spos);
					crt.world.set_component_data(et, crt.scps.U_Position, spos);
				}
			});
			forCurrentAndFutureEntitiesSetted(crt, crt.rcps.S_Direction, (et, id, sdata) => {
				const sdir = sdata as Vector3;
				const udir = crt.world.get_component_data(et, crt.scps.U_Direction);
				if (!valid_vec3(udir)) {
					if (!valid_vec3(sdir)) return;
					if (crt.world.has_component(et, crt.scps.U_IgnoreAllStreams)) return;
					crt.world.set_component_data(et, crt.scps.Direction, sdir);
					crt.world.set_component_data(et, crt.scps.U_Direction, sdir);
				}
			});
			forCurrentAndFutureEntitiesSetted(crt, crt.rcps.S_Velocity, (et, id, sdata) => {
				const svel = sdata as Vector3;
				const uvel = crt.world.get_component_data(et, crt.scps.U_Velocity);
				if (!valid_vec3(uvel)) {
					if (!valid_vec3(svel)) return;
					if (crt.world.has_component(et, crt.scps.U_IgnoreAllStreams)) return;
					crt.world.set_component_data(et, crt.scps.Velocity, svel);
					crt.world.set_component_data(et, crt.scps.U_Velocity, svel);
				}
			});
		}

		// Client blind derives the Position from its own owned U-Components.
		for (const [id, upos] of queryTuples(crt.world, [
			crt.scps.U_Position,
			statuh_pair(crt.rcps.S_R_U_Position_Source, crt.local_state.player_entity),
		])) {
			crt.world.set_component_data(id, crt.scps.Position, upos);
		}
		for (const [id, udir] of queryTuples(crt.world, [
			crt.scps.U_Direction,
			statuh_pair(crt.rcps.S_R_U_Direction_Source, crt.local_state.player_entity),
		])) {
			crt.world.set_component_data(id, crt.scps.Direction, udir);
		}
		for (const [id, uvel] of queryTuples(crt.world, [
			crt.scps.U_Velocity,
			statuh_pair(crt.rcps.S_R_U_Velocity_Source, crt.local_state.player_entity),
		])) {
			crt.world.set_component_data(id, crt.scps.Velocity, uvel);
		}
	},
	eventId: LOOPUH_ROBLOX_PRIORITY_INT.CLIENT_PreRender,
	priorityOrder: LOOPUH_CLIENT_OFFSET.A_FanonReceive,
};

export default sys;
