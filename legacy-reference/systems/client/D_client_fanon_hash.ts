import { GamuhClientSystem } from "client/clienttypes";
import { GamuhClientRuntimeContext } from "client/clientruntime";
import { LOOPUH_CLIENT_OFFSET, LOOPUH_ROBLOX_PRIORITY_INT } from "shared/libs/loopuh/loopuhRobloxUtil";
import useThrottle from "shared/libs/vendor/hooks/useThrottle";
import { UpdateClientHash } from "client/zap";
import { snapshotSharedWorldAsHash } from "shared/libs/statuh/statuhUtil";
import { DEBUG_ENABLE_HASHING } from "./A_client_fanon_receive";

const sys: GamuhClientSystem = {
	name: "client_fanon_hash",
	system: (crt: GamuhClientRuntimeContext) => {
		if (!DEBUG_ENABLE_HASHING) {
			return;
		}
		if (useThrottle(0.3, "update client hash", true)) {
			const hash = snapshotSharedWorldAsHash(crt.fanon_runtime);
			UpdateClientHash.Fire(hash);
		}
	},
	eventId: LOOPUH_ROBLOX_PRIORITY_INT.CLIENT_PreRender,
	priorityOrder: LOOPUH_CLIENT_OFFSET.D_Fourth,
};

export default sys;
