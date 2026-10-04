import { GamuhServerSystem } from "server/servertypes";
import { GamuhServerRuntimeContext } from "server/serverruntime";
import { LOOPUH_ROBLOX_PRIORITY_INT, LOOPUH_SERVER_OFFSET } from "shared/libs/loopuh/loopuhRobloxUtil";
import {
	ClientStreamUPosition,
	ClientStreamUDirection,
	ClientStreamUVelocity,
	ServerStreamUPosition,
	ServerStreamUVelocity,
	ServerStreamUDirection,
} from "server/zap";
import useRemoteCallback from "shared/libs/vendor/hooks/useRemoteCallback";
import { forCurrentAndFutureEntitiesSetted, getPlayerEntityFromPlayer, valid_vec3 } from "shared/utils/gameUtil";
import { entityExists, queryTuples } from "shared/libs/statuh/statuhUtil";
import { StatuhFanonName } from "shared/libs/fanon/statuh/statuhFanonName";
import { statuh_pair } from "shared/libs/statuh/statuhRuntime";
import { runOnce } from "shared/libs/vendor/hooks/runOnce";

const verify_stuff = (srt: GamuhServerRuntimeContext, player: Player, fanon_name: string) => {
	const playerEntity = getPlayerEntityFromPlayer(srt, player);
	if (!entityExists(srt.world, playerEntity)) return { playerEntity: undefined, id: undefined };
	const id = StatuhFanonName.getStatuhEntityFromLocalName(srt.fanon_runtime, fanon_name);
	if (id === undefined) return { playerEntity: undefined, id: undefined };
	return { playerEntity, id };
};

const sys: GamuhServerSystem = {
	name: "server_stream_receive",
	system: (srt: GamuhServerRuntimeContext) => {
		for (const [_, player, sct] of useRemoteCallback<[player: Player, { fanon_name: string; position: Vector3 }]>(
			ClientStreamUPosition,
		)) {
			const { fanon_name, position } = sct;
			const { playerEntity, id } = verify_stuff(srt, player, sct.fanon_name);
			if (playerEntity === undefined || id === undefined) continue;
			if (!srt.world.has_component(id, statuh_pair(srt.rcps.S_R_U_Position_Source, playerEntity))) continue;
			if (!valid_vec3(position as unknown as Vector3)) continue;
			srt.world.set_component_data(id, srt.scps.U_Position, position as unknown as Vector3);
			srt.world.set_component_data(id, srt.scps.Position, position as unknown as Vector3);
			ServerStreamUPosition.FireExcept(player, {
				fanon_name,
				position,
			});
		}

		for (const [_, player, sct] of useRemoteCallback<[player: Player, { fanon_name: string; velocity: Vector3 }]>(
			ClientStreamUVelocity,
		)) {
			const { fanon_name, velocity } = sct;
			const { playerEntity, id } = verify_stuff(srt, player, sct.fanon_name);
			if (playerEntity === undefined || id === undefined) continue;
			if (!srt.world.has_component(id, statuh_pair(srt.rcps.S_R_U_Velocity_Source, playerEntity))) continue;
			if (!valid_vec3(velocity as unknown as Vector3)) continue;
			srt.world.set_component_data(id, srt.scps.U_Velocity, velocity as unknown as Vector3);
			srt.world.set_component_data(id, srt.scps.Velocity, velocity as unknown as Vector3);
			ServerStreamUVelocity.FireExcept(player, {
				fanon_name,
				velocity,
			});
		}

		for (const [_, player, sct] of useRemoteCallback<[player: Player, { fanon_name: string; direction: Vector3 }]>(
			ClientStreamUDirection,
		)) {
			const { fanon_name, direction } = sct;
			const { playerEntity, id } = verify_stuff(srt, player, sct.fanon_name);
			if (playerEntity === undefined || id === undefined) continue;
			if (!srt.world.has_component(id, statuh_pair(srt.rcps.S_R_U_Direction_Source, playerEntity))) continue;
			if (!valid_vec3(direction as unknown as Vector3)) continue;
			srt.world.set_component_data(id, srt.scps.U_Direction, direction as unknown as Vector3);
			srt.world.set_component_data(id, srt.scps.Direction, direction as unknown as Vector3);
			ServerStreamUDirection.FireExcept(player, {
				fanon_name,
				direction,
			});
		}

		// While the client derives the components from Ustreams or Sdiffs,
		// the server inversely relies on its regular Position, Direction, and Velocity components and derives the others.
		// (The exception is if an entity is owned by a player, in which case the server treats U-components as a source of truth.)
		// Any entity with a position or direction or velocity can be CHOSEN to be replicated by the server

		// Upon templating, actions will usually overwrite important position, direction, and velocity components via
		// S components. Thus, this will read all "set-ings" of the S component and overwrite our canonical regular components.
		// (The U-components should be *derived* from this; it's below this code block.)
		if (runOnce()) {
			forCurrentAndFutureEntitiesSetted(srt, srt.rcps.S_Position, (et, id, sdata) => {
				const spos = sdata as Vector3;
				const upos = srt.world.get_component_data(et, srt.scps.U_Position);
				if (!valid_vec3(upos)) srt.world.set_component_data(et, srt.scps.Position, spos);
			});
			forCurrentAndFutureEntitiesSetted(srt, srt.rcps.S_Direction, (et, id, sdata) => {
				const sdir = sdata as Vector3;
				const udir = srt.world.get_component_data(et, srt.scps.U_Direction);
				if (!valid_vec3(udir)) srt.world.set_component_data(et, srt.scps.Direction, sdir);
			});
			forCurrentAndFutureEntitiesSetted(srt, srt.rcps.S_Velocity, (et, id, sdata) => {
				const svel = sdata as Vector3;
				const uvel = srt.world.get_component_data(et, srt.scps.U_Velocity);
				if (!valid_vec3(uvel)) srt.world.set_component_data(et, srt.scps.Velocity, svel);
			});
		}

		// In order to voluntarily stream something, the server must include a U-Component without pairing with any player.
		// Any entity created via a template will by default be owned by the server (having no initial pairing.)
		// Those U-Components will have to be updated here, though. They will simply mirror the server's regular data.
		for (const [id, upos] of queryTuples(
			srt.world,
			[srt.scps.Position],
			[statuh_pair(srt.rcps.S_R_U_Position_Source, srt.world.get_wildcard())],
		)) {
			srt.world.set_component_data(id, srt.scps.U_Position, upos);
		}
		for (const [id, udir] of queryTuples(
			srt.world,
			[srt.scps.Direction],
			[statuh_pair(srt.rcps.S_R_U_Direction_Source, srt.world.get_wildcard())],
		)) {
			srt.world.set_component_data(id, srt.scps.U_Direction, udir);
		}
		for (const [id, uvel] of queryTuples(
			srt.world,
			[srt.scps.Velocity],
			[statuh_pair(srt.rcps.S_R_U_Velocity_Source, srt.world.get_wildcard())],
		)) {
			srt.world.set_component_data(id, srt.scps.U_Velocity, uvel);
		}
	},
	eventId: LOOPUH_ROBLOX_PRIORITY_INT.SERVER_Heartbeat,
	priorityOrder: LOOPUH_SERVER_OFFSET.A_FanonReceive,
};

export default sys;
