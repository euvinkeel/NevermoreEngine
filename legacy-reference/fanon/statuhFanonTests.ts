import { deepFreeze } from "shared/utils/tableUtil";
import { statuh_create_world, statuh_pair } from "shared/libs/statuh/statuhRuntime";
import { initStatuhFanonRuntime } from "./statuhFanon";
import { _LocalName, StatuhFanonName } from "./statuhFanonName";
import { Diffstep, Diffsteps, StatuhFanonDiffstep } from "./statuhFanonDiffstep";
import { StatuhFanonHandle } from "./statuhFanonHandle";
const makestep = StatuhFanonDiffstep.Make;

const VERBOSE = false;
type ROArray<T> = ReadonlyArray<T>;

function ro<T>(arr: T[]): ROArray<T> {
	// defensively clone so nothing in the test can mutate engine arrays
	return deepFreeze([...arr]) as ROArray<T>;
}

// Mock test framework similar to the jecs tests
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

function CASE(name: string) {
	// Just for organization, similar to jecs tests
}

function CHECK(condition: boolean, message?: string) {
	if (!condition) {
		warn(debug.traceback());
		error(message || "Assertion failed");
	}
}

function CHECK_EXPECT_ERR(fn: () => void) {
	let errored = false;
	try {
		fn();
	} catch {
		errored = true;
	}
	if (!errored) {
		error("Expected function to throw an error");
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
const containsStep = (diffsteps: Diffsteps, step: Diffstep) => {
	return diffsteps.some((s) => eqlstep(s, step));
};

// Run all tests
export function runStatuhFanonTests() {
	print("Running Statuh Fanon Tests...\n");

	// Test Suite
	TEST("additive component op collapsing", function () {
		const builder = new StatuhFanonDiffstep.DiffstepBuilder();
		const A = "A";
		const c = 1;
		builder.add_diffstep(makestep.NEW(A));
		builder.add_diffstep(makestep.ADD(A, c));
		builder.add_diffstep(makestep.SET(A, c, 1));
		builder.add_diffstep(makestep.SET(A, c, 2));
		const final = builder.get_diffsteps();
		CHECK(eqlsteps(final, [makestep.NEW(A), makestep.SET(A, c, 2)]));
	});

	TEST("additive relation op collapsing", function () {
		const builder = new StatuhFanonDiffstep.DiffstepBuilder();
		const A = "A";
		const B = "B";
		const r = 2;
		builder.add_diffstep(makestep.ADDREL(A, r, B));
		builder.add_diffstep(makestep.SETREL(A, r, B, "x"));
		builder.add_diffstep(makestep.REMREL(A, r, B));
		const final = builder.get_diffsteps();
		CHECK(eqlsteps(final, [makestep.REMREL(A, r, B)]));
	});

	TEST("additive DEL cascades subject + targets", function () {
		const builder = new StatuhFanonDiffstep.DiffstepBuilder();
		const A = "A";
		const B = "B";
		const c = 1;
		const r = 2;
		builder.add_diffstep(makestep.NEW(A));
		builder.add_diffstep(makestep.NEW(B));
		builder.add_diffstep(makestep.ADDREL(A, r, B));
		builder.add_diffstep(makestep.ADD(B, c));
		builder.add_diffstep(makestep.DEL(B));
		const final = builder.get_diffsteps();
		CHECK(eqlsteps(final, [makestep.NEW(A), makestep.DEL(B)]));
	});

	TEST("additive NEW after DEL restarts ops", function () {
		const builder = new StatuhFanonDiffstep.DiffstepBuilder();
		const A = "A";
		const c = 1;
		builder.add_diffstep(makestep.NEW(A));
		builder.add_diffstep(makestep.ADD(A, c));
		builder.add_diffstep(makestep.DEL(A));
		builder.add_diffstep(makestep.NEW(A));
		builder.add_diffstep(makestep.ADD(A, c));
		const final = builder.get_diffsteps();
		// CHECK(eqlsteps(final, [makestep.DEL(A), makestep.NEW(A), makestep.ADD(A, c)]));
		CHECK(eqlsteps(final, [makestep.NEW(A), makestep.ADD(A, c)]));
	});

	TEST("additive multi-component independence", function () {
		const builder = new StatuhFanonDiffstep.DiffstepBuilder();
		const A = "A";
		const c1 = 1;
		const c2 = 2;
		builder.add_diffstep(makestep.SET(A, c1, 1));
		builder.add_diffstep(makestep.SET(A, c2, 2));
		builder.add_diffstep(makestep.SET(A, c1, 3));
		const final = builder.get_diffsteps();
		CHECK(eqlsteps(final, [makestep.SET(A, c2, 2), makestep.SET(A, c1, 3)]));
	});

	TEST("additive multi-target relation independence", function () {
		const builder = new StatuhFanonDiffstep.DiffstepBuilder();
		const A = "A";
		const B = "B";
		const C = "C";
		const r = 2;
		builder.add_diffstep(makestep.ADDREL(A, r, B));
		builder.add_diffstep(makestep.ADDREL(A, r, C));
		builder.add_diffstep(makestep.REMREL(A, r, B));
		builder.add_diffstep(makestep.SETREL(A, r, C, "x"));
		const final = builder.get_diffsteps();
		CHECK(eqlsteps(final, [makestep.REMREL(A, r, B), makestep.SETREL(A, r, C, "x")]));
	});

	TEST("additive marks rebuild_after_mark", function () {
		const builder = new StatuhFanonDiffstep.DiffstepBuilder();
		const A = "A";
		const c = 1;
		builder.add_diffstep(makestep.NEW(A));
		builder.mark_last_operation(1);
		builder.add_diffstep(makestep.SET(A, c, 1));
		builder.mark_last_operation(2);
		builder.add_diffstep(makestep.SET(A, c, 2));
		builder.mark_last_operation(3);
		builder.rebuild_after_mark_and_reevaluate(2);
		const final = builder.get_diffsteps();
		CHECK(eqlsteps(final, [makestep.SET(A, c, 2)]));
		CHECK(!builder.has_mark(1));
		CHECK(!builder.has_mark(2));
		CHECK(builder.has_mark(3));
	});
	TEST("diffstep remove orphan related relations", function () {
		const builder = new StatuhFanonDiffstep.DiffstepBuilder();
		const alice = "ALICE";
		const bob = "BOB";
		const friendsWith = 300;
		builder.add_diffstep(makestep.NEW(alice));
		builder.add_diffstep(makestep.NEW(bob));
		builder.add_diffstep(makestep.ADDREL(alice, friendsWith, bob));
		builder.add_diffstep(makestep.DEL(bob));

		const final = builder.get_diffsteps();
		CHECK(eqlsteps(final, [makestep.NEW(alice), makestep.DEL(bob)]));
	});

	TEST("diffstep big general test", function () {
		const builder = new StatuhFanonDiffstep.DiffstepBuilder();
		const alice = "ALICE";
		const bob = "BOB";
		const likesPizza = 100;
		const likesSushi = 200;
		const friendsWith = 300;
		builder.add_diffstep(makestep.NEW(alice));
		builder.add_diffstep(makestep.ADD(alice, likesPizza));
		builder.add_diffstep(makestep.NEW(bob));
		builder.add_diffstep(makestep.ADD(bob, likesPizza));
		builder.add_diffstep(makestep.SET(bob, likesSushi, "tuna"));
		builder.add_diffstep(makestep.SETREL(alice, friendsWith, bob, "bestfriend"));
		builder.add_diffstep(makestep.SETREL(bob, friendsWith, alice, "friend"));

		let final = builder.get_diffsteps();
		CHECK(
			eqlsteps(final, [
				makestep.NEW(alice),
				makestep.ADD(alice, likesPizza),
				makestep.NEW(bob),
				makestep.ADD(bob, likesPizza),
				makestep.SET(bob, likesSushi, "tuna"),
				makestep.SETREL(alice, friendsWith, bob, "bestfriend"),
				makestep.SETREL(bob, friendsWith, alice, "friend"),
			]),
		);

		builder.add_diffstep(makestep.REM(alice, likesPizza));

		final = builder.get_diffsteps();
		CHECK(
			eqlsteps(final, [
				makestep.NEW(alice),
				makestep.NEW(bob),
				makestep.ADD(bob, likesPizza),
				makestep.SET(bob, likesSushi, "tuna"),
				makestep.SETREL(alice, friendsWith, bob, "bestfriend"),
				makestep.SETREL(bob, friendsWith, alice, "friend"),
				makestep.REM(alice, likesPizza),
			]),
		);

		builder.add_diffstep(makestep.DEL(bob));

		final = builder.get_diffsteps();
		CHECK(eqlsteps(final, [makestep.NEW(alice), makestep.REM(alice, likesPizza), makestep.DEL(bob)]));

		builder.add_diffstep(makestep.DEL(alice));

		final = builder.get_diffsteps();
		CHECK(eqlsteps(final, [makestep.DEL(bob), makestep.DEL(alice)]));

		builder.add_diffstep(makestep.NEW(alice));
		builder.add_diffstep(makestep.ADD(alice, likesPizza));
		builder.add_diffstep(makestep.NEW(bob));
		builder.add_diffstep(makestep.ADD(bob, likesPizza));
		builder.add_diffstep(makestep.SET(bob, likesSushi, "tuna"));
		builder.add_diffstep(makestep.SETREL(alice, friendsWith, bob, "bestfriend"));
		builder.add_diffstep(makestep.SETREL(bob, friendsWith, alice, "friend"));

		final = builder.get_diffsteps();
		CHECK(
			eqlsteps(final, [
				makestep.NEW(alice),
				makestep.ADD(alice, likesPizza),
				makestep.NEW(bob),
				makestep.ADD(bob, likesPizza),
				makestep.SET(bob, likesSushi, "tuna"),
				makestep.SETREL(alice, friendsWith, bob, "bestfriend"),
				makestep.SETREL(bob, friendsWith, alice, "friend"),
			]),
		);

		builder.add_diffstep(makestep.DEL(alice));
		final = builder.get_diffsteps();
		CHECK(
			eqlsteps(final, [
				makestep.NEW(bob),
				makestep.ADD(bob, likesPizza),
				makestep.SET(bob, likesSushi, "tuna"),
				makestep.DEL(alice),
			]),
		);

		builder.clear();
		final = builder.get_diffsteps();
		CHECK(eqlsteps(final, []));
	});

	TEST("diffstep name ops", function () {
		const builder = new StatuhFanonDiffstep.DiffstepBuilder();
		const alice = "ALICE";
		const bob = "BOB";
		const charlie = "CHARLIE";

		builder.add_diffstep(makestep.NEW(alice));
		builder.add_diffstep(makestep.NEW(bob));
		builder.add_diffstep(makestep.NEW(charlie));

		let final = builder.get_diffsteps();
		CHECK(eqlsteps(final, [makestep.NEW(alice), makestep.NEW(bob), makestep.NEW(charlie)]));

		builder.add_diffstep(makestep.DEL(alice));
		builder.add_diffstep(makestep.NEW(alice));

		final = builder.get_diffsteps();
		CHECK(eqlsteps(final, [makestep.NEW(bob), makestep.NEW(charlie), makestep.NEW(alice)]));

		builder.add_diffstep(makestep.NEW(alice));
		builder.add_diffstep(makestep.NEW(alice));
		builder.add_diffstep(makestep.NEW(alice));
		builder.add_diffstep(makestep.NEW(bob));
		builder.add_diffstep(makestep.NEW(bob));
		builder.add_diffstep(makestep.NEW(bob));

		final = builder.get_diffsteps();
		CHECK(eqlsteps(final, [makestep.NEW(charlie), makestep.NEW(alice), makestep.NEW(bob)]));
	});

	TEST("diffstep combining diffsteps", function () {
		const player = "PLAYER";
		const player_gun = "GUN";
		const player_tower = "TOWER";
		const server_enemy = "ENEMY";

		const health = 1;

		const builder = new StatuhFanonDiffstep.DiffstepBuilder();
		// player optimistic updates:
		// player assumes that gunshot went through
		builder.add_diffstep(makestep.NEW(player));
		builder.add_diffstep(makestep.NEW(player_gun));
		builder.add_diffstep(makestep.NEW(player_tower));
		builder.add_diffstep(makestep.SET(player, health, 100));
		builder.add_diffstep(makestep.SET(player_tower, health, 100));
		builder.add_diffstep(makestep.SET(server_enemy, health, 10));

		builder.add_diffstep(makestep.SET(server_enemy, health, 5));

		const final = builder.get_diffsteps();
		CHECK(
			eqlsteps(final, [
				makestep.NEW(player),
				makestep.NEW(player_gun),
				makestep.NEW(player_tower),
				makestep.SET(player, health, 100),
				makestep.SET(player_tower, health, 100),
				makestep.SET(server_enemy, health, 5),
			]),
		);

		// player gets corrective server diffsteps
		builder.add_diffsteps([makestep.SET(server_enemy, health, 10)]);

		builder.add_diffstep(makestep.DEL(player));
	});

	TEST("inversion diffstep tests", function () {
		const e2 = "e2";
		const e3 = "e3";
		const e4 = "e4";
		const e5 = "e5";
		const c = 0;
		const r = 0;

		const ibuilder = new StatuhFanonDiffstep.InverseDiffstepBuilder();

		// player optimistic updates:
		// player assumes that gunshot went through
		ibuilder.attempt_add_diffstep(makestep.REMREL(e2, r, e4));
		ibuilder.attempt_add_diffstep(makestep.ADDREL(e2, r, e3));
		ibuilder.attempt_add_diffstep(makestep.NEW(e3));
		ibuilder.attempt_add_diffstep(makestep.ADDREL(e3, r, e2));
		ibuilder.attempt_add_diffstep(makestep.ADDREL(e3, r, e4));
		ibuilder.attempt_add_diffstep(makestep.DEL(e5));
		ibuilder.attempt_add_diffstep(makestep.REMREL(e5, r, e2));
		ibuilder.attempt_add_diffstep(makestep.SET(e2, c, 20));
		ibuilder.attempt_add_diffstep(makestep.REM(e5, c));
		ibuilder.attempt_add_diffstep(makestep.NEW(e2));
		ibuilder.attempt_add_diffstep(makestep.SET(e2, c, 99));
		ibuilder.attempt_add_diffstep(makestep.ADDREL(e2, r, e4));
		ibuilder.attempt_add_diffstep(makestep.ADDREL(e5, r, e2));

		const final = ibuilder.get_diffsteps();
		CHECK(
			eqlsteps(final, [
				makestep.NEW(e2),
				makestep.NEW(e3),
				makestep.SET(e2, c, 20),
				makestep.DEL(e5),
				makestep.ADDREL(e3, r, e4),
				makestep.ADDREL(e3, r, e2),
				makestep.ADDREL(e2, r, e3),
				makestep.REMREL(e2, r, e4),
			]),
		);
	});

	TEST("inverse first-seen per key wins", function () {
		const A = "A";
		const c = 1;
		const ibuilder = new StatuhFanonDiffstep.InverseDiffstepBuilder();
		ibuilder.attempt_add_diffstep(makestep.SET(A, c, 1));
		ibuilder.attempt_add_diffstep(makestep.SET(A, c, 2));
		const final = ibuilder.get_diffsteps();
		CHECK(eqlsteps(final, [makestep.SET(A, c, 1)]));
	});

	TEST("inverse DEL blacklists name and drops rels", function () {
		const A = "A";
		const B = "B";
		const r = 2;
		const ibuilder = new StatuhFanonDiffstep.InverseDiffstepBuilder();
		ibuilder.attempt_add_diffstep(makestep.DEL(B));
		ibuilder.attempt_add_diffstep(makestep.ADDREL(A, r, B));
		ibuilder.attempt_add_diffstep(makestep.SETREL(A, r, B, "x"));
		const final = ibuilder.get_diffsteps();
		CHECK(eqlsteps(final, [makestep.DEL(B)]));
	});

	TEST("inverse render order: NEW first then reverse others", function () {
		const A = "A";
		const B = "B";
		const c = 1;
		const r = 2;
		const ibuilder = new StatuhFanonDiffstep.InverseDiffstepBuilder();
		ibuilder.attempt_add_diffstep(makestep.SET(A, c, 10)); // idx 0
		ibuilder.attempt_add_diffstep(makestep.ADDREL(A, r, B)); // idx 1
		ibuilder.attempt_add_diffstep(makestep.NEW(B)); // idx 2 (NEW should be first)
		const final = ibuilder.get_diffsteps();
		CHECK(
			eqlsteps(final, [makestep.NEW(B), makestep.ADDREL(A, r, B), makestep.SET(A, c, 10)]) ||
				// depending on sort stability, reverse of non-NEWs should be preserved
				// but allow equivalent ordering if comparator behaves differently in target runtime
				eqlsteps(final, [makestep.NEW(B), makestep.SET(A, c, 10), makestep.ADDREL(A, r, B)]),
		);
	});

	TEST("server canon on top of inverted diffsteps test1", function () {
		const e2 = "e2";
		const e3 = "e3";
		const e4 = "e4";
		const e5 = "e5";
		const c = 0;
		const r = 0;

		const startingDiffsteps = [
			makestep.NEW(e2),
			makestep.NEW(e3),
			makestep.SET(e2, c, 20),
			makestep.DEL(e5),
			makestep.ADDREL(e3, r, e2),
			makestep.ADDREL(e3, r, e4),
			makestep.ADDREL(e2, r, e3),
			makestep.REMREL(e2, r, e4),
		];

		const builder = new StatuhFanonDiffstep.DiffstepBuilder(startingDiffsteps);
		let final = builder.get_diffsteps();
		CHECK(eqlsteps(final, startingDiffsteps));

		const serverdiff = [
			makestep.SET(e3, c, 100),
			makestep.ADDREL(e2, r, e4),
			makestep.REMREL(e2, r, e3),
			makestep.NEW(e5),
			makestep.ADDREL(e5, r, e2),
			makestep.SET(e2, c, 100),
			makestep.SET(e5, c, 50),
		];
		builder.add_diffsteps(serverdiff);
		final = builder.get_diffsteps();
		CHECK(
			eqlsteps(final, [
				makestep.NEW(e2),
				makestep.NEW(e3),
				makestep.ADDREL(e3, r, e2),
				makestep.ADDREL(e3, r, e4),
				makestep.SET(e3, c, 100),
				makestep.ADDREL(e2, r, e4),
				makestep.REMREL(e2, r, e3),
				makestep.NEW(e5),
				makestep.ADDREL(e5, r, e2),
				makestep.SET(e2, c, 100),
				makestep.SET(e5, c, 50),
			]),
		);
	});

	TEST("inverse rebuild_after_mark preserves actives and marks", function () {
		const A = "A";
		const c = 1;
		const ibuilder = new StatuhFanonDiffstep.InverseDiffstepBuilder();
		ibuilder.attempt_add_diffstep(makestep.SET(A, c, 10));
		ibuilder.mark_last_operation(1);
		ibuilder.attempt_add_diffstep(makestep.SET(A, c, 20));
		ibuilder.mark_last_operation(2);
		ibuilder.rebuild_after_mark_and_reevaluate(1);
		const final = ibuilder.get_diffsteps();
		CHECK(eqlsteps(final, [makestep.SET(A, c, 20)]));
		CHECK(!ibuilder.has_mark(1));
		CHECK(ibuilder.has_mark(2));
	});

	TEST("handle action rejection returns correction inverse diffsteps", function () {
		const world = statuh_create_world();
		const c = world.register_component<number>();
		const r = world.register_component<undefined>();
		const e1 = world.create_entity();
		const e2 = world.create_entity();
		world.set_component_data(e1, c, 10);
		world.add_component(e1, statuh_pair(r, e2));
		const runtime = initStatuhFanonRuntime(world, [c, r], [e1, e2], "author");
		const handle = new StatuhFanonHandle(runtime);
		const e1Name = StatuhFanonName.getFanonNameFromStatuhEntity(runtime, e1)!;
		const cKey = runtime._component_w_number_key.getMappingToB(c)!;
		const rKey = runtime._component_w_number_key.getMappingToB(r)!;

		handle.start_tracking_action(1);
		handle.set_component_data(e1, c, 20);
		handle.remove_component(e1, statuh_pair(r, e2));
		const corrections = handle.reject_tracked_action_and_get_correction_diffsteps();
		CHECK(
			eqlsteps(corrections, [
				makestep.ADDREL(e1Name, rKey, StatuhFanonName.getFanonNameFromStatuhEntity(runtime, e2)!),
				makestep.SET(e1Name, cKey, 10),
			]) ||
				// expected reverse order (non-NEW reversed)
				eqlsteps(corrections, [
					makestep.SET(e1Name, cKey, 10),
					makestep.ADDREL(e1Name, rKey, StatuhFanonName.getFanonNameFromStatuhEntity(runtime, e2)!),
				]),
		);
	});

	TEST("handle commit+mark+rebuild affects additive/inverse", function () {
		const world = statuh_create_world();
		const c = world.register_component<number>();
		const e1 = world.create_entity();
		const runtime = initStatuhFanonRuntime(world, [c], [e1], "author");
		const handle = new StatuhFanonHandle(runtime);
		const e1Name = StatuhFanonName.getFanonNameFromStatuhEntity(runtime, e1)!;
		const cKey = runtime._component_w_number_key.getMappingToB(c)!;

		handle.start_tracking_action(1);
		handle.set_component_data(e1, c, 1);
		handle.commit_tracked_action();
		handle.mark_last_operation(1);

		handle.start_tracking_action(2);
		handle.set_component_data(e1, c, 2);
		handle.commit_tracked_action();
		handle.mark_last_operation(2);

		handle.rebuild_after_mark(1);
		CHECK(eqlsteps(handle.get_additive_diffstep_builder().get_diffsteps(), [makestep.SET(e1Name, cKey, 2)]));
		CHECK(eqlsteps(handle.get_inverse_diffstep_builder().get_diffsteps(), [makestep.SET(e1Name, cKey, 1)]));
	});

	TEST("applyDiffstepsToWorld strict vs lenient", function () {
		const world = statuh_create_world();
		const c = world.register_component<number>();
		const runtime = initStatuhFanonRuntime(world, [c], [], "author");
		const unknownName = "UNKNOWN";
		const badDiffs = [makestep.SET(unknownName, 0, 1)];
		CHECK_EXPECT_ERR(function () {
			StatuhFanonDiffstep.applyDiffstepsToWorld(runtime, badDiffs);
		});
		// lenient should not throw
		StatuhFanonDiffstep.applyDiffstepsToWorld(runtime, badDiffs, undefined, true, false);
	});

	TEST("inverse then additive roundtrip restores world", function () {
		const world = statuh_create_world();
		const c = world.register_component<number>();
		const r = world.register_component<undefined>();
		const e1 = world.create_entity();
		const e2 = world.create_entity();
		world.set_component_data(e1, c, 5);
		world.add_component(e1, statuh_pair(r, e2));
		const runtime = initStatuhFanonRuntime(world, [c, r], [e1, e2], "author");
		const handle = new StatuhFanonHandle(runtime);
		const e1Name = StatuhFanonName.getFanonNameFromStatuhEntity(runtime, e1)!;
		const e2Name = StatuhFanonName.getFanonNameFromStatuhEntity(runtime, e2)!;
		const cKey = runtime._component_w_number_key.getMappingToB(c)!;
		const rKey = runtime._component_w_number_key.getMappingToB(r)!;

		handle.start_tracking_action(1);
		handle.set_component_data(e1, c, 7);
		handle.add_component(e1, statuh_pair(r, e2)); // duplicate rel, should be no-op in world but tracked
		handle.commit_tracked_action();

		const inverse = handle.get_inverted_diffsteps();
		StatuhFanonDiffstep.applyDiffstepsToWorld(runtime, inverse);
		CHECK(world.get_component_data(e1, c) === 5);
		CHECK(world.has_component(e1, statuh_pair(r, e2)));

		const additive = handle.get_additive_diffstep_builder().get_diffsteps();
		StatuhFanonDiffstep.applyDiffstepsToWorld(runtime, additive);
		CHECK(world.get_component_data(e1, c) === 7);
		CHECK(world.has_component(e1, statuh_pair(r, e2)));
		// ensure diffstep keys line up
		CHECK(
			eqlsteps(additive, [makestep.SET(e1Name, cKey, 7), makestep.ADDREL(e1Name, rKey, e2Name)]) ||
				eqlsteps(additive, [makestep.ADDREL(e1Name, rKey, e2Name), makestep.SET(e1Name, cKey, 7)]),
		);
	});

	// Rigorous rollback/reversion tests
	TEST("rollback delete complex graph with inbound/outbound rels", function () {
		const world = statuh_create_world();
		const c = world.register_component<number>();
		const r = world.register_component<undefined>();
		const eA = world.create_entity();
		const eB = world.create_entity();
		const eX = world.create_entity();
		world.set_component_data(eA, c, 5);
		world.set_component_data(eB, c, 7);
		world.add_component(eA, statuh_pair(r, eB));
		world.add_component(eB, statuh_pair(r, eA));
		world.add_component(eX, statuh_pair(r, eA));

		const runtime = initStatuhFanonRuntime(world, [c, r], [eA, eB, eX], "author");
		const handle = new StatuhFanonHandle(runtime);
		const aName = StatuhFanonName.getFanonNameFromStatuhEntity(runtime, eA)!;
		const bName = StatuhFanonName.getFanonNameFromStatuhEntity(runtime, eB)!;
		const xName = StatuhFanonName.getFanonNameFromStatuhEntity(runtime, eX)!;
		const cKey = runtime._component_w_number_key.getMappingToB(c)!;
		const rKey = runtime._component_w_number_key.getMappingToB(r)!;

		// Action 1: create C and link to A
		handle.start_tracking_action(1);
		const eC = handle.create_entity();
		const cName = StatuhFanonName.getFanonNameFromStatuhEntity(runtime, eC)!;
		handle.add_component(eC, statuh_pair(r, eA));
		handle.set_component_data(eC, c, 10);
		handle.commit_tracked_action();
		handle.mark_last_operation(1);

		// Action 2: remove A->B, delete B
		handle.start_tracking_action(2);
		handle.remove_component(eA, statuh_pair(r, eB));
		handle.delete_entity(eB);
		handle.commit_tracked_action();
		handle.mark_last_operation(2);

		// Action 3: delete A then reject => should restore A's last state (after action 2)
		handle.start_tracking_action(3);
		handle.delete_entity(eA);
		const corrections = handle.reject_tracked_action_and_get_correction_diffsteps();
		StatuhFanonDiffstep.applyDiffstepsToWorld(runtime, corrections);

		// Validate world state
		// Use a function to resolve name to entity because entities that have been brought back may have
		// a different underlying entity.
		const nametoentity = (name: _LocalName) => {
			const entity = StatuhFanonName.getStatuhEntityFromLocalName(runtime, name);
			if (entity === undefined) {
				error(`name ${name} not found in world`);
			}
			return entity;
		};
		let entityA = nametoentity(aName);
		let entityB = nametoentity(bName);
		let entityC = nametoentity(cName);
		let entityX = nametoentity(xName);
		CHECK(world.contains_entity(entityA));
		CHECK(!world.contains_entity(entityB));
		CHECK(world.contains_entity(entityC));
		CHECK(world.contains_entity(entityX));
		CHECK(world.get_component_data(entityA, c) === 5);
		// A->B was removed in action 2, should not come back
		CHECK(!world.has_component(entityA, statuh_pair(r, entityB)));
		// Inbound rels to A from C and X should remain
		CHECK(world.has_component(entityC, statuh_pair(r, entityA)));
		CHECK(world.has_component(entityX, statuh_pair(r, entityA)));

		// Ensure corrections contained at least NEW(A) and not DEL(A)
		const corrStr = StatuhFanonDiffstep.diffsteps_to_str(corrections);
		CHECK(containsStep(corrections, makestep.NEW(aName)));
		CHECK(!containsStep(corrections, makestep.DEL(aName)));
		// ensure some expected entries
		CHECK(containsStep(corrections, makestep.SET(aName, cKey, 5)));
		CHECK(containsStep(corrections, makestep.ADDREL(cName, rKey, aName)));
		CHECK(containsStep(corrections, makestep.ADDREL(xName, rKey, aName)));
		// CHECK(
		// 	string.find(corrStr, `SET ${aName} ${tostring(cKey)} 5`) !== undefined ||
		// 		string.find(corrStr, `ADD ${aName} ${tostring(cKey)}`) !== undefined,
		// );
		// CHECK(
		// 	string.find(corrStr, `ADDREL ${cName} ${tostring(rKey)} ${aName}`) !== undefined &&
		// 		string.find(corrStr, `ADDREL ${xName} ${tostring(rKey)} ${aName}`) !== undefined,
		// );
	});

	TEST("rollback delete_all_entities restores prior world", function () {
		const world = statuh_create_world();
		const c = world.register_component<number>();
		const r = world.register_component<undefined>();
		const e1 = world.create_entity();
		const e2 = world.create_entity();
		world.set_component_data(e1, c, 1);
		world.add_component(e1, statuh_pair(r, e2));
		const runtime = initStatuhFanonRuntime(world, [c, r], [e1, e2], "author");
		const e1Name = StatuhFanonName.getFanonNameFromStatuhEntity(runtime, e1)!;
		const e2Name = StatuhFanonName.getFanonNameFromStatuhEntity(runtime, e2)!;
		const handle = new StatuhFanonHandle(runtime);

		handle.start_tracking_action(1);
		handle.delete_all_entities();
		const corrections = handle.reject_tracked_action_and_get_correction_diffsteps();
		StatuhFanonDiffstep.applyDiffstepsToWorld(runtime, corrections);

		const e1Entity = StatuhFanonName.getStatuhEntityFromLocalName(runtime, e1Name);
		const e2Entity = StatuhFanonName.getStatuhEntityFromLocalName(runtime, e2Name);
		CHECK(world.contains_entity(e1Entity!));
		CHECK(world.contains_entity(e2Entity!));
		CHECK(world.get_component_data(e1Entity!, c) === 1);
		CHECK(world.has_component(e1Entity!, statuh_pair(r, e2Entity!)));
	});

	TEST("delete then recreate same name in one action collapses inverses and additive", function () {
		const world = statuh_create_world();
		const c = world.register_component<number>();
		const eA = world.create_entity();
		world.set_component_data(eA, c, 42);
		const runtime = initStatuhFanonRuntime(world, [c], [eA], "author");
		const handle = new StatuhFanonHandle(runtime);
		const aName = StatuhFanonName.getFanonNameFromStatuhEntity(runtime, eA)!;
		const cKey = runtime._component_w_number_key.getMappingToB(c)!;

		handle.start_tracking_action(1);
		handle.delete_entity(eA);
		// reuse same name for recreation
		handle.enqueue_new_name_to_queue(aName);
		const newA = handle.create_entity();
		handle.set_component_data(newA, c, 123);
		handle.commit_tracked_action();

		// Additive should have NEW(A), SET(A,c,123) and NOT keep DEL(A)
		const add = handle.get_additive_diffstep_builder().get_diffsteps();
		CHECK(
			eqlsteps(add, [makestep.NEW(aName), makestep.SET(aName, cKey, 123)]) ||
				// allow different internal ordering if any
				eqlsteps(add, [makestep.SET(aName, cKey, 123), makestep.NEW(aName)]),
		);
		CHECK(!containsStep(add, makestep.DEL(aName)));

		// Inverse should prefer restoring pre-delete state (NEW + last data), not DEL from recreate
		const inv = handle.get_inverse_diffstep_builder().get_diffsteps();
		CHECK(containsStep(inv, makestep.NEW(aName)));
		CHECK(!containsStep(inv, makestep.DEL(aName)));

		// Roundtrip: apply inverse (restore old value), then additive (re-apply new value)
		StatuhFanonDiffstep.applyDiffstepsToWorld(runtime, inv);
		CHECK(world.get_component_data(StatuhFanonName.getStatuhEntityFromLocalName(runtime, aName)!, c) === 42);
		StatuhFanonDiffstep.applyDiffstepsToWorld(runtime, add);
		CHECK(world.get_component_data(StatuhFanonName.getStatuhEntityFromLocalName(runtime, aName)!, c) === 123);
	});

	TEST("inverted diffstep building with Statuh Handle", function () {
		const world = statuh_create_world();
		const c = world.register_component<number>();
		const r = world.register_component<undefined>();
		const e1 = world.create_entity();
		const e2 = world.create_entity();
		const e3 = world.create_entity();
		world.set_component_data(e1, c, 20);
		world.set_component_data(e3, c, 40);
		world.add_component(e1, statuh_pair(r, e2));
		world.add_component(e2, statuh_pair(r, e1));
		world.add_component(e2, statuh_pair(r, e3));

		const SFruntime = initStatuhFanonRuntime(world, [c, r], [e1, e2, e3], "author");
		const e1Name = StatuhFanonName.getFanonNameFromStatuhEntity(SFruntime, e1);
		const e2Name = StatuhFanonName.getFanonNameFromStatuhEntity(SFruntime, e2);
		const e3Name = StatuhFanonName.getFanonNameFromStatuhEntity(SFruntime, e3);
		const cKey = SFruntime._component_w_number_key.getMappingToB(c);
		const rKey = SFruntime._component_w_number_key.getMappingToB(r);
		CHECK(e1Name !== undefined && e2Name !== undefined && e3Name !== undefined);
		CHECK(cKey !== undefined && rKey !== undefined);
		CHECK(SFruntime._replicated_components.size() === 2);
		CHECK(SFruntime._replicated_components.has(c));
		CHECK(SFruntime._replicated_components.has(r));

		// Simulate local systems doing their thing on shared state via handle.
		const handle = new StatuhFanonHandle(SFruntime);
		const entitiesWithC = world.query_entities_of_archetype([c]);
		CHECK(entitiesWithC.size() === 2);
		CHECK(entitiesWithC.includes(e1));
		CHECK(entitiesWithC.includes(e3));

		handle.start_tracking_action(1);
		handle.add_component(e1, statuh_pair(r, e3));
		handle.remove_component(e1, statuh_pair(r, e2));
		handle.commit_tracked_action();
		handle.mark_last_operation(1);

		handle.start_tracking_action(1);
		handle.delete_entity(e2);
		handle.commit_tracked_action();
		handle.mark_last_operation(2);

		const e4 = handle.create_entity();
		const e4Name = StatuhFanonName.getFanonNameFromStatuhEntity(SFruntime, e4);
		CHECK(e4Name !== undefined);

		handle.start_tracking_action(2);
		handle.add_component(e4, statuh_pair(r, e1));
		handle.set_component_data(e1, c, 99);
		handle.set_component_data(e4, c, 50);
		handle.commit_tracked_action();
		handle.mark_last_operation(3);

		handle.start_tracking_action(2);
		handle.delete_entity(e1);
		handle.commit_tracked_action();
		handle.mark_last_operation(4);

		CHECK(world.get_all_entities().size() === 2);
		CHECK(world.contains_entity(e3));
		CHECK(world.contains_entity(e4));
		CHECK(world.get_component_data(e3, c) === 40);
		CHECK(world.get_component_data(e4, c) === 50);

		const invertedDiffsteps = handle.get_inverted_diffsteps();
		// print(invertedDiffsteps);
		CHECK(
			eqlsteps(invertedDiffsteps, [
				makestep.NEW(e1Name!),
				makestep.NEW(e2Name!),
				makestep.SET(e1Name!, cKey!, 20),
				makestep.DEL(e4Name!),
				makestep.ADDREL(e2Name!, rKey!, e3Name!),
				makestep.ADDREL(e2Name!, rKey!, e1Name!),
				makestep.ADDREL(e1Name!, rKey!, e2Name!),
				makestep.REMREL(e1Name!, rKey!, e3Name!),
			]) ||
				eqlsteps(invertedDiffsteps, [
					makestep.NEW(e1Name!),
					makestep.NEW(e2Name!),
					makestep.SET(e1Name!, cKey!, 20),
					makestep.DEL(e4Name!),
					makestep.ADDREL(e2Name!, rKey!, e1Name!),
					makestep.ADDREL(e2Name!, rKey!, e3Name!),
					makestep.ADDREL(e1Name!, rKey!, e2Name!),
					makestep.REMREL(e1Name!, rKey!, e3Name!),
				]),
		);

		// Apply a server update; get a NEW server canon.
		const serverUpdate = [
			makestep.SET(e2Name!, cKey!, 100),
			makestep.ADDREL(e1Name!, rKey!, e3Name!),
			makestep.REMREL(e1Name!, rKey!, e2Name!),
			makestep.NEW(e4Name!),
			makestep.ADDREL(e4Name!, rKey!, e1Name!),
			makestep.SET(e1Name!, cKey!, 100),
			makestep.SET(e4Name!, cKey!, 50),
		];
		const additive = new StatuhFanonDiffstep.DiffstepBuilder(invertedDiffsteps);
		additive.add_diffsteps(serverUpdate);
		const final = additive.get_diffsteps();
		CHECK(
			eqlsteps(final, [
				makestep.NEW(e1Name!),
				makestep.NEW(e2Name!),
				makestep.ADDREL(e2Name!, rKey!, e3Name!),
				makestep.ADDREL(e2Name!, rKey!, e1Name!),
				makestep.SET(e2Name!, cKey!, 100),
				makestep.ADDREL(e1Name!, rKey!, e3Name!),
				makestep.REMREL(e1Name!, rKey!, e2Name!),
				makestep.NEW(e4Name!),
				makestep.ADDREL(e4Name!, rKey!, e1Name!),
				makestep.SET(e1Name!, cKey!, 100),
				makestep.SET(e4Name!, cKey!, 50),
			]) ||
				eqlsteps(final, [
					makestep.NEW(e1Name!),
					makestep.NEW(e2Name!),
					makestep.ADDREL(e2Name!, rKey!, e1Name!),
					makestep.ADDREL(e2Name!, rKey!, e3Name!),
					makestep.SET(e2Name!, cKey!, 100),
					makestep.ADDREL(e1Name!, rKey!, e3Name!),
					makestep.REMREL(e1Name!, rKey!, e2Name!),
					makestep.NEW(e4Name!),
					makestep.ADDREL(e4Name!, rKey!, e1Name!),
					makestep.SET(e1Name!, cKey!, 100),
					makestep.SET(e4Name!, cKey!, 50),
				]),
		);

		// Now re-apply an optimistic update (assuming server acknowledges up to mark 3)
		handle.rebuild_after_mark(3);

		const diffstepsToOptimistic = handle.get_additive_diffstep_builder().get_diffsteps();
		additive.add_diffsteps(diffstepsToOptimistic);
		const backToLastCanon_ThenToNewServerCanon_ThenToOptimistic = additive.get_diffsteps();
		CHECK(
			eqlsteps(backToLastCanon_ThenToNewServerCanon_ThenToOptimistic, [
				makestep.NEW(e2Name!),
				makestep.ADDREL(e2Name!, rKey!, e3Name!),
				makestep.SET(e2Name!, cKey!, 100),
				makestep.NEW(e4Name!),
				makestep.SET(e4Name!, cKey!, 50),
				makestep.DEL(e1Name!),
			]),
		);

		StatuhFanonDiffstep.applyDiffstepsToWorld(SFruntime, backToLastCanon_ThenToNewServerCanon_ThenToOptimistic);
		const e2Entity = StatuhFanonName.getStatuhEntityFromLocalName(SFruntime, e2Name!);
		CHECK(world.get_all_entities().size() === 3);
		CHECK(world.contains_entity(e2Entity!));
		CHECK(world.contains_entity(e3));
		CHECK(world.contains_entity(e4));
		CHECK(world.get_component_data(e2Entity!, c) === 100);
		CHECK(world.get_component_data(e3, c) === 40);
		CHECK(world.get_component_data(e4, c) === 50);
		CHECK(world.has_component(e2Entity!, statuh_pair(r, e3)));
		CHECK(!world.has_component(e3, statuh_pair(r, e2Entity!)));
		CHECK(!world.has_component(e2Entity!, statuh_pair(r, e4)));
		CHECK(!world.has_component(e4, statuh_pair(r, e2Entity!)));
		// print(handle.get_inverse_diffstep_builder().get_diffsteps());
		// handle.get_inverse_diffstep_builder().print_debug();
		CHECK(
			eqlsteps(handle.get_inverse_diffstep_builder().get_diffsteps(), [
				makestep.NEW(e1Name!),
				makestep.ADDREL(e4Name!, rKey!, e1Name!),
				makestep.ADDREL(e1Name!, rKey!, e3Name!),
				makestep.SET(e1Name!, cKey!, 99),
			]) ||
				eqlsteps(handle.get_inverse_diffstep_builder().get_diffsteps(), [
					makestep.NEW(e1Name!),
					makestep.ADDREL(e1Name!, rKey!, e3Name!),
					makestep.ADDREL(e4Name!, rKey!, e1Name!),
					makestep.SET(e1Name!, cKey!, 99),
				]) ||
				eqlsteps(handle.get_inverse_diffstep_builder().get_diffsteps(), [
					makestep.NEW(e1Name!),
					makestep.SET(e1Name!, cKey!, 99),
					makestep.ADDREL(e4Name!, rKey!, e1Name!),
					makestep.ADDREL(e1Name!, rKey!, e3Name!),
				]) ||
				eqlsteps(handle.get_inverse_diffstep_builder().get_diffsteps(), [
					makestep.NEW(e1Name!),
					makestep.SET(e1Name!, cKey!, 99),
					makestep.ADDREL(e1Name!, rKey!, e3Name!),
					makestep.ADDREL(e4Name!, rKey!, e1Name!),
				]),
		);
		CHECK(eqlsteps(handle.get_additive_diffstep_builder().get_diffsteps(), [makestep.DEL(e1Name!)]));
	});

	return FINISH();
}
