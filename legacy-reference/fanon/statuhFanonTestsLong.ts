import { statuh_create_world, statuh_pair } from "shared/libs/statuh/statuhRuntime";
import { initStatuhFanonRuntime } from "./statuhFanon";
import { StatuhFanonHandle } from "./statuhFanonHandle";
import { StatuhEntity, StatuhWorld } from "shared/libs/statuh/statuhTypes";
import Object from "shared/libs/vendor/objectutils";
import { Diffstep, Diffsteps, StatuhFanonDiffstep } from "./statuhFanonDiffstep";
import { ActionExecutionCtx, ActionRuntime, executeAction, makeActionHeader, replayAction } from "./statuhFanonAction";
import { StatuhFanonName } from "./statuhFanonName";
import { SharedComponents } from "shared/sharedcomponents";
const makestep = StatuhFanonDiffstep.Make;

const VERBOSE = false;
type ROArray<T> = ReadonlyArray<T>;

const TestResults = { passed: 0, failed: 0, tests: [] as string[] };

function FORMAT_SMALL_TIME(time: number) {
	if (time < 1 && time > 0.001) {
		return `${math.floor(time * 1000)}ms`;
	} else if (time < 0.001 && time > 0.000001) {
		return `${math.floor(time * 1000000)}μs`;
	} else if (time < 0.000001) {
		return `${math.floor(time * 1000000000)}ns`;
	} else {
		return `${time}s`;
	}
}

function TEST(name: string, testFn: () => void) {
	const start = os.clock();
	try {
		testFn();
		TestResults.passed++;
		// if (VERBOSE) {
		// 	print(`✅ ${name}`);
		// }
	} catch (error) {
		TestResults.failed++;
		print(`\n\n🟥 ${name}: ${error}`);
		TestResults.tests.push(`FAILED: ${name} - ${error}`);
	} finally {
		if (VERBOSE) {
			print(`${FORMAT_SMALL_TIME(os.clock() - start)} : ${name}`);
		}
	}
}

function CHECK(condition: boolean, message?: string) {
	if (!condition) {
		warn(debug.traceback());
		error(message || "Assertion failed");
	}
}

function FINISH() {
	print(`\nTest Results: ${TestResults.passed} passed, ${TestResults.failed} failed`);
	if (TestResults.failed > 0) {
		print("Failed tests:");
		TestResults.tests.forEach((test) => print(`  ${test}`));
	}
	return TestResults;
}

const eqlstep = (a: Diffstep, b: Diffstep) => {
	const length = a.size();
	if (length !== b.size()) {
		return false;
	}
	for (let i = 0; i < length; i++) {
		if (a[i] !== b[i]) {
			return false;
		}
	}
	return true;
};
const eqlsteps = (a: Diffsteps, b: Diffsteps) => {
	if (a.size() !== b.size()) {
		return false;
	}
	for (let i = 0; i < a.size(); i++) {
		if (!eqlstep(a[i], b[i])) {
			return false;
		}
	}
	return true;
};

const _test_replicated_components = (statuh_world: StatuhWorld) => {
	return {
		name: statuh_world.register_component<string>(),
		score: statuh_world.register_component<number>(),
		health: statuh_world.register_component<{ health: number; maxHealth: number }>(),
		refersto: statuh_world.register_component<string>(),
		hates: statuh_world.register_component<undefined>(),
	};
};

type TestReplicatedComponents = ReturnType<typeof _test_replicated_components>;

const _makeclient = () => {
	const statuh_world = statuh_create_world();
	const replicated_components = _test_replicated_components(statuh_world);
	const client_components = {
		mine: statuh_world.register_component<undefined>(),
	};
	const fanon_runtime = initStatuhFanonRuntime(statuh_world, Object.values(replicated_components), [], "plr1");
	const fanon_handle = new StatuhFanonHandle(fanon_runtime);
	const actionRuntime: ActionRuntime<TestReplicatedComponents> = {
		fanon_runtime,
		fanon_handle,
		action_header_log: [],
		last_acknumber: 0,
		rcps: replicated_components,
		scps: {} as SharedComponents,
	};
	return {
		statuh_world,
		replicated_components,
		client_components,
		fanon_runtime,
		fanon_handle,
		actionRuntime,
	};
};

const _makeserver = () => {
	const statuh_world = statuh_create_world();
	const replicated_components = _test_replicated_components(statuh_world);
	const fanon_runtime = initStatuhFanonRuntime(statuh_world, Object.values(replicated_components), [], "server");
	const fanon_handle = new StatuhFanonHandle(fanon_runtime);
	const actionRuntime: ActionRuntime<TestReplicatedComponents> = {
		fanon_runtime,
		fanon_handle,
		action_header_log: [],
		last_acknumber: 0,
		rcps: replicated_components,
		scps: {} as SharedComponents,
	};
	const all_diffstep_builder = new StatuhFanonDiffstep.DiffstepBuilder();
	return {
		statuh_world,
		replicated_components,
		fanon_runtime,
		fanon_handle,
		actionRuntime,
		all_diffstep_builder,
	};
};

enum TestActionId {
	MakeThing = 0,
	SetScore = 1,
	LinkRefersTo = 2,
}

namespace testactions {
	export const makeThing = (name: string, actionRuntime: ActionRuntime<TestReplicatedComponents>) => {
		const actionExecutionCtx: ActionExecutionCtx<{ name: string }> = { args: { name: name } };
		return executeAction(
			TestActionId.MakeThing,
			actionRuntime,
			actionExecutionCtx,
			(actionRuntime, actionExecutionCtx) => {
				const entity = actionRuntime.fanon_handle.create_entity();
				actionRuntime.fanon_handle.set_component_data(entity, actionRuntime.rcps.name, name);
				return entity;
			},
		);
	};
	export const setScore = (
		entity: StatuhEntity,
		score: number,
		actionRuntime: ActionRuntime<TestReplicatedComponents>,
	) => {
		const actionExecutionCtx: ActionExecutionCtx<{ score: number }> = { args: { score: score } };
		return executeAction(
			TestActionId.SetScore,
			actionRuntime,
			actionExecutionCtx,
			(actionRuntime, actionExecutionCtx) => {
				actionRuntime.fanon_handle.set_component_data(entity, actionRuntime.rcps.score, score);
			},
		);
	};
	export const linkRefersTo = (
		from: StatuhEntity,
		to: StatuhEntity,
		as: string,
		actionRuntime: ActionRuntime<TestReplicatedComponents>,
	) => {
		const actionExecutionCtx: ActionExecutionCtx<{ from: StatuhEntity; to: StatuhEntity; as: string }> = {
			args: { from: from, to: to, as: as },
		};
		return executeAction(
			TestActionId.LinkRefersTo,
			actionRuntime,
			actionExecutionCtx,
			(actionRuntime, actionExecutionCtx) => {
				actionRuntime.fanon_handle.set_component_data(from, statuh_pair(actionRuntime.rcps.refersto, to), as);
			},
		);
	};
}

// Run all tests
export function runStatuhFanonTestsLong() {
	print("Running Statuh Fanon Long Tests...\n");

	// Test Suite
	TEST("case 1", () => {
		const server = _makeserver();
		const plrA = _makeclient();
		const plrB = _makeclient();
		const plrC = _makeclient();

		// tick 1
		const { returned: plrAentity } = testactions.makeThing("1", server.actionRuntime);
		testactions.setScore(plrAentity!, 10, server.actionRuntime);
		const { returned: plrBentity } = testactions.makeThing("2", server.actionRuntime);
		testactions.setScore(plrBentity!, 20, server.actionRuntime);
		const { returned: plrCentity } = testactions.makeThing("3", server.actionRuntime);
		testactions.setScore(plrCentity!, 30, server.actionRuntime);
		const { returned: s1 } = testactions.makeThing("1", server.actionRuntime);
		testactions.setScore(s1!, 10, server.actionRuntime);
		const { returned: s2 } = testactions.makeThing("2", server.actionRuntime);
		testactions.setScore(s2!, 20, server.actionRuntime);
		const { returned: s3 } = testactions.makeThing("3", server.actionRuntime);
		testactions.setScore(s3!, 30, server.actionRuntime);

		// in this tick, the server sends out its canon: 1 2 3 have been made.
		// the server will catch them up
		let server_since = server.fanon_handle.get_additive_diffstep_builder().get_diffsteps();
		server.all_diffstep_builder.add_diffsteps(server_since);

		StatuhFanonDiffstep.applyDiffstepsToWorld(plrA.fanon_runtime, server_since);
		StatuhFanonDiffstep.applyDiffstepsToWorld(plrB.fanon_runtime, server_since);
		StatuhFanonDiffstep.applyDiffstepsToWorld(plrC.fanon_runtime, server_since);

		// all clients are now caught up
		// time for clients to do their own stuff

		const { returned: plrA_1 } = testactions.makeThing("plrA_1", plrA.actionRuntime);
		testactions.setScore(plrA_1!, 101, plrA.actionRuntime);
		testactions.linkRefersTo(plrA_1!, s1!, "A1 to 1", plrA.actionRuntime);
		plrA.fanon_handle.mark_last_operation(0);
		testactions.linkRefersTo(plrA_1!, s2!, "A1 to 2", plrA.actionRuntime);
		plrA.fanon_handle.mark_last_operation(1);
		// client shoulda sent it here
		const plrA_outgoing_1 = {
			actionHeaders: [
				makeActionHeader(
					TestActionId.MakeThing,
					{ name: "plrA_1" },
					[StatuhFanonName.getFanonNameFromStatuhEntity(plrA.fanon_runtime, plrA_1!)!],
					"plrA",
				),
				makeActionHeader(TestActionId.SetScore, { score: 101 }, [], "plrA"),
				makeActionHeader(TestActionId.LinkRefersTo, { from: plrA_1!, to: s1!, as: "A1 to 1" }, [], "plrA"),
				makeActionHeader(TestActionId.LinkRefersTo, { from: plrA_1!, to: s2!, as: "A1 to 2" }, [], "plrA"),
			],
			acknumber: 1,
		};
		testactions.linkRefersTo(plrA_1!, s3!, "A1 to 3", plrA.actionRuntime);
		plrA.fanon_handle.mark_last_operation(2);

		// tick 2
		const plrB_1 = testactions.makeThing("plrB_1", plrB.actionRuntime);
		plrB.fanon_handle.mark_last_operation(0);
		testactions.setScore(plrB_1.returned!, 102, plrB.actionRuntime);
		plrB.fanon_handle.mark_last_operation(1);
		testactions.linkRefersTo(plrB_1.returned!, s1!, "B1 to 1", plrB.actionRuntime);
		plrB.fanon_handle.mark_last_operation(2);
		// client shoulda sent it here
		const plrB_outgoing_1 = {
			actionHeaders: [
				makeActionHeader(
					TestActionId.MakeThing,
					{ name: "plrB_1" },
					[StatuhFanonName.getFanonNameFromStatuhEntity(plrB.fanon_runtime, plrB_1.returned!)!],
					"plrB",
				),
				makeActionHeader(TestActionId.SetScore, { score: 102 }, [], "plrB"),
				makeActionHeader(
					TestActionId.LinkRefersTo,
					{ from: plrB_1.returned!, to: s1!, as: "B1 to 1" },
					[],
					"plrB",
				),
			],
			acknumber: 2,
		};

		// tick 3
		const plrC_1 = testactions.makeThing("plrC_1", plrC.actionRuntime);
		testactions.setScore(plrC_1.returned!, 103, plrC.actionRuntime);
		plrC.fanon_handle.mark_last_operation(0);
		// client shoulda sent it here
		const plrC_outgoing_1 = {
			actionHeaders: [
				makeActionHeader(
					TestActionId.MakeThing,
					{ name: "plrC_1" },
					[StatuhFanonName.getFanonNameFromStatuhEntity(plrC.fanon_runtime, plrC_1.returned!)!],
					"plrC",
				),
				makeActionHeader(TestActionId.SetScore, { score: 103 }, [], "plrC"),
			],
			acknumber: 0,
		};

		// clients send their stuff
		// simulate replaying the actions
		// TODO: server should actually replay actions here

		// client all get back from the server:
		// const server_update1 = [];
		// replayAction(
		// 	TestActionId.MakeThing,
		// 	server.actionRuntime,
		// 	{
		// 		args: {
		// 			name: "plrA_1",
		// 		},
		// 		authorEntity: plrA,
		// 	},
		// 	{
		// 		args: {
		// 			name: "plrB_1",
		// 		},
		// 	},
		// 	plrA_outgoing_1.acth,
	});

	return FINISH();
}
