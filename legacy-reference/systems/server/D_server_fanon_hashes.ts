import { GamuhServerSystem } from "server/servertypes";
import { GamuhServerRuntimeContext } from "server/serverruntime";
import { LOOPUH_ROBLOX_PRIORITY_INT, LOOPUH_SERVER_OFFSET } from "shared/libs/loopuh/loopuhRobloxUtil";
import { UpdateClientHash } from "server/zap";
import useRemoteCallback from "shared/libs/vendor/hooks/useRemoteCallback";
import { getPlayerEntityFromPlayer } from "shared/utils/gameUtil";
import { numberHashToColor3 } from "shared/utils/shims";
import { assets } from "shared/assetLookup";

// stuff that shouldn't be coupled to fanon, like roblox-runtime specific stuff
export const test_info = {
	server_hash: 0,
};

const hashsign = assets.ui.hashsign()! as BillboardGui;

const sys: GamuhServerSystem = {
	name: "server_fanon_hashes",
	system: (srt: GamuhServerRuntimeContext) => {
		for (const [_, player, hash] of useRemoteCallback<[Player, number]>(UpdateClientHash)) {
			const playerEntity = getPlayerEntityFromPlayer(srt, player);
			const data = srt.world.get_component_data(playerEntity!, srt.vcps.PlayerReplicationState);
			if (data !== undefined) {
				data.lastHash = hash;
				// task.spawn(() => {
				// 	if (player.Character === undefined) return;
				// 	const head = player.Character.WaitForChild("Head", 5)! as BasePart;
				// 	if (head === undefined) return;
				// 	let foundhashsign = head.FindFirstChild("hashsign") as BillboardGui;
				// 	if (foundhashsign === undefined) {
				// 		foundhashsign = hashsign.Clone();
				// 		foundhashsign.Parent = head;
				// 		foundhashsign.Adornee = head;
				// 		foundhashsign.Enabled = true;
				// 	}
				// 	const hashtext = foundhashsign.FindFirstChild("TextLabel", true)! as TextLabel;
				// 	hashtext.Text = tostring(hash);
				// 	hashtext.TextColor3 = numberHashToColor3(hash);
				// 	if (hash === test_info.server_hash) {
				// 		hashtext.BackgroundColor3 = new Color3(0, 1, 0);
				// 	} else {
				// 		hashtext.BackgroundColor3 = new Color3(1, 0, 0);
				// 	}
				// });
				task.spawn(() => {
					if (player.Character === undefined) return;
					const head = player.Character.WaitForChild("Head", 5)! as BasePart;
					if (head === undefined) return;
					if (hash === test_info.server_hash) {
						head.Color = new Color3(0, 1, 0);
					} else {
						head.Color = new Color3(1, 0, 0);
					}
				});
			}
		}
	},
	eventId: LOOPUH_ROBLOX_PRIORITY_INT.SERVER_Heartbeat,
	priorityOrder: LOOPUH_SERVER_OFFSET.D_Fourth,
};

export default sys;
