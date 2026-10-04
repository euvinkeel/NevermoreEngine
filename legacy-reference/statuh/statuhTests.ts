import { Wildcard } from "../vendor/jecs";
import { printCodeHistory } from "./jecsStatuh";
import { statuh_create_world, statuh_pair } from "./statuhRuntime";
import { StatuhWorld, StatuhEntity, StatuhPair } from "./statuhTypes";
import { snapshotWorldPrintableString } from "./statuhUtil";
import { deepFreeze } from "shared/utils/tableUtil";

const VERBOSE = false;
type ROArray<T> = ReadonlyArray<T>;

function ro<T>(arr: T[]): ROArray<T> {
	// defensively clone so nothing in the test can mutate engine arrays
	return deepFreeze([...arr]) as ROArray<T>;
}

// Mock test framework similar to the jecs tests
const TestResults = { passed: 0, failed: 0, tests: [] as string[] };

function TEST(name: string, testFn: () => void) {
	try {
		testFn();
		TestResults.passed++;
		if (VERBOSE) {
			print(`✅ ${name}`);
		}
	} catch (error) {
		TestResults.failed++;
		print(`\n\n🟥 ${name}: ${error}`);
		TestResults.tests.push(`FAILED: ${name} - ${error}`);
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

// Test Suite
TEST("world creation and basic entity management", function () {
	const world = statuh_create_world();
	CHECK(world !== undefined);

	const entity = world.create_entity();
	CHECK(world.contains_entity(entity));
	CHECK(world.get_all_entities().includes(entity));

	world.delete_entity(entity);
	CHECK(!world.contains_entity(entity));
	CHECK(!world.get_all_entities().includes(entity));
});

TEST("component registration and basic operations", function () {
	const world = statuh_create_world();

	const NameComponent = world.register_component<string>();
	const HealthComponent = world.register_component<number>();
	const TagComponent = world.register_component<undefined>();

	CHECK(world.get_all_components().includes(NameComponent));
	CHECK(world.get_all_components().includes(HealthComponent));
	CHECK(world.get_all_components().includes(TagComponent));

	const entity = world.create_entity();

	// Test setting component data
	world.set_component_data(entity, NameComponent, "TestEntity");
	world.set_component_data(entity, HealthComponent, 100);
	world.add_component(entity, TagComponent);

	// Test has_component
	CHECK(world.has_component(entity, NameComponent));
	CHECK(world.has_component(entity, HealthComponent));
	CHECK(world.has_component(entity, TagComponent));

	// Test get_component_data
	CHECK(world.get_component_data(entity, NameComponent) === "TestEntity");
	CHECK(world.get_component_data(entity, HealthComponent) === 100);

	// Test get_component_datas (multiple)
	const [name, health] = world.get_component_datas(entity, NameComponent, HealthComponent);
	CHECK(name === "TestEntity");
	CHECK(health === 100);
});

// TEST("entity range creation", function () {
// 	const world = statuh_create_world();

// 	printCodeHistory(world);
// 	const entity1 = world.create_entity_in_range(100, 200);
// 	printCodeHistory(world);
// 	const entity2 = world.create_entity_in_range(100, 200);
// 	printCodeHistory(world);

// 	CHECK(world.contains_entity(entity1));
// 	CHECK(world.contains_entity(entity2));
// 	CHECK(entity1 !== entity2);
// });

TEST("component data type safety", function () {
	const world = statuh_create_world();

	const StringComponent = world.register_component<string>();
	const NumberComponent = world.register_component<number>();
	const ObjectComponent = world.register_component<{ x: number; y: number }>();

	const entity = world.create_entity();

	world.set_component_data(entity, StringComponent, "hello");
	world.set_component_data(entity, NumberComponent, 42);
	world.set_component_data(entity, ObjectComponent, { x: 10, y: 20 });

	CHECK(world.get_component_data(entity, StringComponent) === "hello");
	CHECK(world.get_component_data(entity, NumberComponent) === 42);

	const obj = world.get_component_data(entity, ObjectComponent);
	CHECK(obj.x === 10 && obj.y === 20);
});

TEST("relationships and pairs", function () {
	const world = statuh_create_world();

	const LikesRelation = world.register_component<string>();
	const FriendsWithRelation = world.register_component<undefined>();

	const alice = world.create_entity();
	const bob = world.create_entity();
	const charlie = world.create_entity();

	// Create relationships using pairs
	const aliceLikesBob = statuh_pair(LikesRelation, bob);
	const aliceFriendsCharlie = statuh_pair(FriendsWithRelation, charlie);
	const bobLikesCharlie = statuh_pair(LikesRelation, charlie);

	world.set_component_data(alice, aliceLikesBob, "best friend");
	world.add_component(alice, aliceFriendsCharlie);
	world.set_component_data(bob, bobLikesCharlie, "good friend");

	// Test relationship queries
	CHECK(world.has_component(alice, aliceLikesBob));
	CHECK(world.has_component(alice, aliceFriendsCharlie));
	CHECK(world.has_component(bob, bobLikesCharlie));

	// Test getting relationship data
	CHECK(world.get_component_data(alice, aliceLikesBob) === "best friend");
	CHECK(world.get_component_data(bob, bobLikesCharlie) === "good friend");
});

TEST("relationship target queries", function () {
	const world = statuh_create_world();

	const LikesRelation = world.register_component<undefined>();
	const EnemyRelation = world.register_component<undefined>();

	const alice = world.create_entity();
	const bob = world.create_entity();
	const charlie = world.create_entity();
	const david = world.create_entity();

	// Alice likes Bob and Charlie
	world.add_component(alice, statuh_pair(LikesRelation, bob));
	world.add_component(alice, statuh_pair(LikesRelation, charlie));

	// Bob is enemy with David
	world.add_component(bob, statuh_pair(EnemyRelation, david));

	// Charlie likes Alice (reverse relationship)
	world.add_component(charlie, statuh_pair(LikesRelation, alice));

	// Test getting targets
	const aliceLikesTargets = world.get_relationship_targets(alice, LikesRelation);
	CHECK(aliceLikesTargets.size() === 2);
	CHECK(aliceLikesTargets.includes(bob));
	CHECK(aliceLikesTargets.includes(charlie));

	const bobEnemyTargets = world.get_relationship_targets(bob, EnemyRelation);
	CHECK(bobEnemyTargets.size() === 1);
	CHECK(bobEnemyTargets.includes(david));

	// Test getting single target
	const aliceFirstLike = world.get_relationship_target(alice, LikesRelation);
	CHECK(aliceFirstLike === bob || aliceFirstLike === charlie);

	// Test getting sources (who likes alice)
	const whoLikesAlice = world.get_relationship_sources(alice, LikesRelation);
	CHECK(whoLikesAlice.size() === 1);
	CHECK(whoLikesAlice.includes(charlie));
});

TEST("archetype queries", function () {
	const world = statuh_create_world();

	const NameComponent = world.register_component<string>();
	const HealthComponent = world.register_component<number>();
	const WeaponComponent = world.register_component<string>();
	const DeadTag = world.register_component<undefined>();

	// Create entities with different component combinations
	const player = world.create_entity();
	world.set_component_data(player, NameComponent, "Player");
	world.set_component_data(player, HealthComponent, 100);
	world.set_component_data(player, WeaponComponent, "Sword");

	const enemy = world.create_entity();
	world.set_component_data(enemy, NameComponent, "Enemy");
	world.set_component_data(enemy, HealthComponent, 50);

	const deadEnemy = world.create_entity();
	world.set_component_data(deadEnemy, NameComponent, "Dead Enemy");
	world.add_component(deadEnemy, DeadTag);

	const item = world.create_entity();
	world.set_component_data(item, WeaponComponent, "Bow");

	// Query for entities with Name and Health
	const livingEntities = world.query_entities_of_archetype([NameComponent, HealthComponent]);
	CHECK(livingEntities.size() === 2);
	CHECK(livingEntities.includes(player));
	CHECK(livingEntities.includes(enemy));
	CHECK(!livingEntities.includes(deadEnemy));
	CHECK(!livingEntities.includes(item));

	// Query for entities with Weapon but without Dead tag
	const aliveWithWeapons = world.query_entities_of_archetype([WeaponComponent], [DeadTag]);
	CHECK(aliveWithWeapons.size() === 2);
	CHECK(aliveWithWeapons.includes(player));
	CHECK(aliveWithWeapons.includes(item));
	CHECK(!aliveWithWeapons.includes(deadEnemy));

	// Query for just Name component
	const namedEntities = world.query_entities_of_archetype([NameComponent]);
	CHECK(namedEntities.size() === 3);
	CHECK(namedEntities.includes(player));
	CHECK(namedEntities.includes(enemy));
	CHECK(namedEntities.includes(deadEnemy));
});

TEST("multiple component queries", function () {
	const world = statuh_create_world();

	const A = world.register_component<boolean>();
	const B = world.register_component<boolean>();
	const C = world.register_component<boolean>();

	const e1 = world.create_entity();
	world.set_component_data(e1, A, true);

	const e2 = world.create_entity();
	world.set_component_data(e2, A, true);
	world.set_component_data(e2, B, true);

	const e3 = world.create_entity();
	world.set_component_data(e3, A, true);
	world.set_component_data(e3, B, true);
	world.set_component_data(e3, C, true);

	// Query for A only
	const withA = world.query_entities_of_archetype([A]);
	CHECK(withA.size() === 3);

	// Query for A and B
	const withAB = world.query_entities_of_archetype([A, B]);
	CHECK(withAB.size() === 2);
	CHECK(withAB.includes(e2));
	CHECK(withAB.includes(e3));

	// Query for A and B but not C
	const withABnotC = world.query_entities_of_archetype([A, B], [C]);
	CHECK(withABnotC.size() === 1);
	CHECK(withABnotC.includes(e2));

	// Query for all three
	const withABC = world.query_entities_of_archetype([A, B, C]);
	CHECK(withABC.size() === 1);
	CHECK(withABC.includes(e3));
});

TEST("entity ordering and utilities", function () {
	const world = statuh_create_world();

	const entity1 = world.create_entity();
	const entity2 = world.create_entity();

	// Test ordering (should be deterministic based on creation order)
	const ordered = world.order_entities(entity1, entity2);
	CHECK(typeOf(ordered) === "boolean");

	// Test entity to string conversion
	const entityStr1 = world.entity_to_string(entity1);
	const entityStr2 = world.entity_to_string(entity2);
	CHECK(typeOf(entityStr1) === "string");
	CHECK(typeOf(entityStr2) === "string");
	CHECK(entityStr1 !== entityStr2);
});

TEST("complex relationship scenarios", function () {
	const world = statuh_create_world();

	const ParentOfRelation = world.register_component<undefined>();
	const WorksForRelation = world.register_component<string>();

	// Create family hierarchy
	const grandpa = world.create_entity();
	const father = world.create_entity();
	const mother = world.create_entity();
	const child1 = world.create_entity();
	const child2 = world.create_entity();

	// Create company
	const company = world.create_entity();

	// Set up relationships
	world.add_component(father, statuh_pair(ParentOfRelation, grandpa));
	world.add_component(child1, statuh_pair(ParentOfRelation, father));
	world.add_component(child1, statuh_pair(ParentOfRelation, mother));
	world.add_component(child2, statuh_pair(ParentOfRelation, father));
	world.add_component(child2, statuh_pair(ParentOfRelation, mother));

	world.set_component_data(father, statuh_pair(WorksForRelation, company), "manager");
	world.set_component_data(mother, statuh_pair(WorksForRelation, company), "developer");

	// Test family relationships
	const fatherChildren = world.get_relationship_sources(father, ParentOfRelation);
	CHECK(fatherChildren.size() === 2);
	CHECK(fatherChildren.includes(child1));
	CHECK(fatherChildren.includes(child2));

	const motherChildren = world.get_relationship_sources(mother, ParentOfRelation);
	CHECK(motherChildren.size() === 2);
	CHECK(motherChildren.includes(child1));
	CHECK(motherChildren.includes(child2));

	const grandpaChildren = world.get_relationship_sources(grandpa, ParentOfRelation);
	CHECK(grandpaChildren.size() === 1);
	CHECK(grandpaChildren.includes(father));

	// Test work relationships
	const companyEmployees = world.get_relationship_sources(company, WorksForRelation);
	CHECK(companyEmployees.size() === 2);
	CHECK(companyEmployees.includes(father));
	CHECK(companyEmployees.includes(mother));
});

TEST("delete all entities", function () {
	const world = statuh_create_world();

	const TestComponent = world.register_component<string>();

	// Create several entities
	for (let i = 0; i < 5; i++) {
		const entity = world.create_entity();
		world.set_component_data(entity, TestComponent, `Entity ${i}`);
	}

	CHECK(world.get_all_entities().size() === 5);

	world.delete_all_entities();

	CHECK(world.get_all_entities().size() === 0);

	// Components should still exist
	CHECK(world.get_all_components().includes(TestComponent));
});

// Hook System Tests
TEST("hook added - basic functionality", function () {
	const world = statuh_create_world();

	const TagA = world.register_component<undefined>();
	const DataB = world.register_component<number>();

	let addedACount = 0;
	let addedBCount = 0;

	world.add_component_hook_added(TagA, (entity, id, data) => {
		addedACount++;
	});

	world.add_component_hook_added(DataB, (entity, id, data) => {
		addedBCount++;
	});

	const entity = world.create_entity();

	// Add tag component
	world.add_component(entity, TagA);
	CHECK(addedACount === 1);
	CHECK(addedBCount === 0);

	// First time setting data component - should fire added hook
	world.set_component_data(entity, DataB, 123);
	CHECK(addedBCount === 1);

	// Second time setting data - should NOT fire added hook again
	world.set_component_data(entity, DataB, 456);
	CHECK(addedBCount === 1); // Still 1, not 2
});

TEST("hook setted - fires on every set_component_data", function () {
	const world = statuh_create_world();

	const TagA = world.register_component<undefined>();
	const DataB = world.register_component<number>();

	let setBCount = 0;
	let lastSetData: unknown;

	world.add_component_hook_setted(DataB, (entity, id, data) => {
		setBCount++;
		lastSetData = data;
	});

	const entity = world.create_entity();

	// add_component should NOT trigger set hook
	world.add_component(entity, TagA);
	CHECK(setBCount === 0);

	// First set_component_data should fire set hook
	world.set_component_data(entity, DataB, 123);
	CHECK(setBCount === 1);
	CHECK(lastSetData === 123);

	// Second set_component_data should fire set hook again
	world.set_component_data(entity, DataB, 456);
	CHECK(setBCount === 2);
	CHECK(lastSetData === 456);
});

TEST("hook removed - fires on component removal", function () {
	const world = statuh_create_world();

	const TagA = world.register_component<undefined>();
	const DataB = world.register_component<number>();

	let removedACount = 0;
	let removedBCount = 0;
	let lastRemovedEntityTag: StatuhEntity | undefined;
	let lastRemovedEntityData: StatuhEntity | undefined;
	let lastRemovedDataA: unknown;
	let lastRemovedDataB: unknown;

	world.add_component_hook_removed(TagA, (entity, id, data) => {
		removedACount++;
		lastRemovedEntityTag = entity;
		lastRemovedDataA = data;
	});

	world.add_component_hook_removed(DataB, (entity, id, data) => {
		removedBCount++;
		lastRemovedEntityData = entity;
		lastRemovedDataB = data;
	});

	const entity1 = world.create_entity();
	const entity2 = world.create_entity();

	// Add components to both entities
	world.add_component(entity1, TagA);
	world.set_component_data(entity1, DataB, 100);
	world.add_component(entity2, TagA);
	world.set_component_data(entity2, DataB, 200);

	// Remove component from entity1
	// Only TagA should fire removed hook
	world.remove_component(entity1, TagA);
	CHECK(removedACount === 1);
	CHECK(removedBCount === 0);
	CHECK(lastRemovedEntityTag === entity1);
	CHECK(lastRemovedEntityData === undefined);
	CHECK(lastRemovedDataA === undefined); // Tag components have undefined data

	// Create new entities and delete all
	const entity3 = world.create_entity();
	const entity4 = world.create_entity();
	world.add_component(entity3, TagA);
	world.set_component_data(entity4, DataB, 300);

	// Entity1 is deleted, having only DataB. DataB should fire removed hook
	// A: 1, B: 1
	// Entity2 is deleted, having TagA and DataB. TagA and DataB should fire removed hook
	// A: 2, B: 2
	// Entity3 is deleted, having TagA. TagA should fire removed hook
	// A: 3, B: 2
	// Entity4 is deleted, having DataB. DataB should fire removed hook
	// A: 3, B: 3
	world.delete_all_entities();
	CHECK(removedACount === 3); // entity3 TagA
	CHECK(removedBCount === 3); // entity4 DataB
});

TEST("hook pairs and relationships", function () {
	const world = statuh_create_world();

	const Parent = world.register_component<undefined>();
	const Child = world.register_component<undefined>();

	let addedCount = 0;
	let removedCount = 0;

	const OwnsRelation = statuh_pair(Parent, Child);

	world.add_component_hook_added(OwnsRelation, () => {
		addedCount++;
	});

	world.add_component_hook_removed(OwnsRelation, () => {
		removedCount++;
	});

	const parentEntity = world.create_entity();

	// Add pair relationship
	world.add_component(parentEntity, OwnsRelation);
	CHECK(addedCount === 1);
	CHECK(world.get_relationship_targets(parentEntity, Parent).includes(Child));

	// Remove pair relationship
	world.remove_component(parentEntity, OwnsRelation);
	CHECK(removedCount === 1);
	CHECK(world.get_relationship_targets(parentEntity, Parent).size() === 0);
});

TEST("hook order and data correctness", function () {
	const world = statuh_create_world();

	const TestComp = world.register_component<string>();

	let hookSequence: string[] = [];
	let hookStates: boolean[] = [];

	world.add_component_hook_added(TestComp, (entity, id, data) => {
		hookSequence.push(`added:${data}`);
		hookStates.push(world.has_component(entity, TestComp));
	});

	world.add_component_hook_setted(TestComp, (entity, id, data) => {
		hookSequence.push(`set:${data}`);
		hookStates.push(world.has_component(entity, TestComp));
	});

	world.add_component_hook_removed(TestComp, (entity, id, data) => {
		hookSequence.push(`removed:${data}`);
		hookStates.push(world.has_component(entity, TestComp));
	});

	const entity = world.create_entity();

	// First set should fire both added and set
	world.set_component_data(entity, TestComp, "hello");
	CHECK(hookSequence.size() === 2);
	CHECK(
		(hookSequence[0] === "added:hello" && hookSequence[1] === "set:hello") ||
			(hookSequence[0] === "set:hello" && hookSequence[1] === "added:hello"),
	);
	CHECK(hookStates[0] === true); // Component should exist during added hook
	CHECK(hookStates[1] === true); // Component should exist during set hook

	// Second set should only fire set
	world.set_component_data(entity, TestComp, "world");
	CHECK(hookSequence.size() === 3);
	CHECK(hookSequence[2] === "set:world");

	// Remove should fire removed hook
	world.remove_component(entity, TestComp);
	CHECK(hookSequence.size() === 4);
	CHECK(hookSequence[3] === "removed:world");
	CHECK(hookStates[3] === true); // Component should still exist during "before-remove" hook
});

TEST("hook non-interference between entities", function () {
	const world = statuh_create_world();

	const TestComp = world.register_component<string>();

	let entity1Count = 0;
	let entity2Count = 0;

	const entity1 = world.create_entity();
	const entity2 = world.create_entity();
	world.add_component_hook_added(TestComp, (entity, id, data) => {
		if (entity === entity1) entity1Count++;
		if (entity === entity2) entity2Count++;
	});

	// Add to entity1 only
	world.set_component_data(entity1, TestComp, "test1");
	CHECK(entity1Count === 1);
	CHECK(entity2Count === 0);

	// Add to entity2 only
	world.set_component_data(entity2, TestComp, "test2");
	CHECK(entity1Count === 1);
	CHECK(entity2Count === 1);

	// Remove from entity1
	world.remove_component(entity1, TestComp);
	CHECK(entity1Count === 1); // Should not change for removal
	CHECK(entity2Count === 1);
});

TEST("hook exception isolation", function () {
	const world = statuh_create_world();

	const TestComp = world.register_component<string>();

	let goodHook1Called = false;
	let goodHook2Called = false;

	// Register hooks in order: good, bad, good
	world.add_component_hook_added(TestComp, () => {
		goodHook1Called = true;
	});

	world.add_component_hook_added(TestComp, () => {
		error("This hook intentionally throws! <SILENT>");
	});

	world.add_component_hook_added(TestComp, () => {
		goodHook2Called = true;
	});

	const entity = world.create_entity();

	// Operation should succeed despite hook error
	world.set_component_data(entity, TestComp, "test");
	CHECK(world.has_component(entity, TestComp));
	CHECK(world.get_component_data(entity, TestComp) === "test");
	CHECK(goodHook1Called);
	CHECK(goodHook2Called);
});

TEST("hook duplicate registration", function () {
	const world = statuh_create_world();

	const TestComp = world.register_component<string>();

	let callCount = 0;
	const hookFn = () => {
		callCount++;
	};

	// Register the same function twice
	world.add_component_hook_added(TestComp, hookFn);
	world.add_component_hook_added(TestComp, hookFn);

	const entity = world.create_entity();
	world.set_component_data(entity, TestComp, "test");

	// Should fire twice
	CHECK(callCount === 2);
});

// TEST("entity range exhaustion throws", function () {
// 	const world = statuh_create_world();
// 	// Fill IDs 1 through 5
// 	for (let i = 0; i < 5; i++) {
// 		world.create_entity_in_range(1, 5);
// 	}
// 	// Sixth creation in the same range should error
// 	CHECK_EXPECT_ERR(() => world.create_entity_in_range(1, 5));
// });

// TEST("entity range collision with component id throws", function () {
// 	const world = statuh_create_world();
// 	// First ID (1) consumed by this component
// 	world.register_component<undefined>();
// 	// Trying to create an entity with that same ID should fail
// 	CHECK_EXPECT_ERR(() => world.create_entity_in_range(1, 1));
// });

TEST("pair canonicalisation returns same object", function () {
	const world = statuh_create_world();
	const A = world.register_component<undefined>();
	const B = world.register_component<undefined>();

	const p1 = statuh_pair(A, B);
	const p2 = statuh_pair(A, B);
	CHECK(p1 === p2);
});

TEST("relationship cleanup on source deletion", function () {
	const world = statuh_create_world();
	const Rel = world.register_component<undefined>();

	const source = world.create_entity();
	const target = world.create_entity();

	world.add_component(source, statuh_pair(Rel, target));
	CHECK(world.get_relationship_targets(source, Rel).includes(target));

	world.delete_entity(source);
	const sources = world.get_relationship_sources(target, Rel);
	CHECK(sources.size() === 0);
});

TEST("relationship cleanup on target deletion", function () {
	const world = statuh_create_world();
	const Rel = world.register_component<undefined>();

	const source = world.create_entity();
	const target = world.create_entity();

	world.add_component(source, statuh_pair(Rel, target));
	CHECK(world.get_relationship_targets(source, Rel).includes(target));

	world.delete_entity(target);
	const targets = world.get_relationship_targets(source, Rel);
	CHECK(targets.size() === 0);
});

TEST("can add components to a component", function () {
	const world = statuh_create_world();
	const Component = world.register_component<undefined>();
	const Component2 = world.register_component<undefined>();
	world.add_component(Component, Component2);
	CHECK(world.has_component(Component, Component2));
});

TEST("exclusion-only archetype query", function () {
	const world = statuh_create_world();
	const AliveTag = world.register_component<undefined>();
	const DeadTag = world.register_component<undefined>();

	const alive = world.create_entity();
	world.add_component(alive, AliveTag);

	const dead = world.create_entity();
	world.add_component(dead, DeadTag);

	// Query all entities without DeadTag
	const result_emptywith = world.query_entities_of_archetype(undefined as unknown as undefined, [DeadTag]);
	CHECK(result_emptywith.size() === 0);

	const result_with = world.query_entities_of_archetype([AliveTag], [DeadTag]);
	CHECK(result_with.includes(alive));
	CHECK(!result_with.includes(dead));

	const result_emptywithout = world.query_entities_of_archetype([AliveTag], undefined as unknown as undefined);
	CHECK(result_emptywithout.includes(alive));
	CHECK(!result_emptywithout.includes(dead));

	const result_withwithout = world.query_entities_of_archetype();
	CHECK(result_withwithout.size() === 0);
});

TEST("wildcard relationship query", function () {
	const world = statuh_create_world();
	const Likes = world.register_component<undefined>();
	const Food = world.register_component<undefined>();

	const alice = world.create_entity();
	const apple = world.create_entity();
	world.add_component(apple, Food);

	const banana = world.create_entity();
	world.add_component(banana, Food);

	world.add_component(alice, statuh_pair(Likes, apple));
	world.add_component(alice, statuh_pair(Likes, banana));

	const wildcard = world.get_wildcard();
	const likesAnything = statuh_pair(Likes, wildcard);
	const results = world.query_entities_of_archetype([likesAnything]);

	CHECK(results.includes(alice));
	CHECK(results.size() === 1);
});

TEST("wildcard query matches multiple entities", function () {
	const world = statuh_create_world();
	const Likes = world.register_component<undefined>();

	const alice = world.create_entity();
	const bob = world.create_entity();
	const charlie = world.create_entity(); // charlie doesn't like anything

	const apple = world.create_entity();
	const banana = world.create_entity();

	// Alice likes apple
	world.add_component(alice, statuh_pair(Likes, apple));

	// Bob likes banana
	world.add_component(bob, statuh_pair(Likes, banana));

	const wildcard = world.get_wildcard();
	const likesAnything = statuh_pair(Likes, wildcard);
	const results = world.query_entities_of_archetype([likesAnything]);

	CHECK(results.size() === 2);
	CHECK(results.includes(alice));
	CHECK(results.includes(bob));
	CHECK(!results.includes(charlie));
});

TEST("wildcard query with additional required component", function () {
	const world = statuh_create_world();
	const Likes = world.register_component<undefined>();
	const IsPlayer = world.register_component<undefined>();

	const player1 = world.create_entity();
	world.add_component(player1, IsPlayer);

	const player2 = world.create_entity();
	world.add_component(player2, IsPlayer);

	const npc = world.create_entity(); // NPC also likes things, but is not a player

	const apple = world.create_entity();

	// player1 likes apple
	world.add_component(player1, statuh_pair(Likes, apple));
	// npc likes apple
	world.add_component(npc, statuh_pair(Likes, apple));

	const wildcard = world.get_wildcard();
	const likesAnything = statuh_pair(Likes, wildcard);

	// Query for players that like anything
	const results = world.query_entities_of_archetype([IsPlayer, likesAnything]);

	CHECK(results.size() === 1);
	CHECK(results.includes(player1));
	CHECK(!results.includes(player2));
	CHECK(!results.includes(npc));
});

TEST("wildcard exclusion query", function () {
	const world = statuh_create_world();
	const Likes = world.register_component<undefined>();
	const IsPerson = world.register_component<undefined>();

	const alice = world.create_entity();
	world.add_component(alice, IsPerson);

	const bob = world.create_entity();
	world.add_component(bob, IsPerson);

	const apple = world.create_entity();

	// Alice likes apple
	world.add_component(alice, statuh_pair(Likes, apple));

	const wildcard = world.get_wildcard();
	const likesAnything = statuh_pair(Likes, wildcard);

	// Query for people who do NOT like anything
	const results = world.query_entities_of_archetype([IsPerson], [likesAnything]);

	CHECK(results.size() === 1);
	CHECK(results.includes(bob));
	CHECK(!results.includes(alice));
});

TEST("wildcard query with relationship data", function () {
	const world = statuh_create_world();
	const FriendshipLevel = world.register_component<number>();

	const alice = world.create_entity();
	const bob = world.create_entity();
	const charlie = world.create_entity();

	// Alice and Bob are friends
	world.set_component_data(alice, statuh_pair(FriendshipLevel, bob), 10);

	// Charlie has no friends
	const wildcard = world.get_wildcard();
	const hasAnyFriend = statuh_pair(FriendshipLevel, wildcard);
	const results = world.query_entities_of_archetype([hasAnyFriend]);

	CHECK(results.size() === 1);
	CHECK(results.includes(alice));
	CHECK(!results.includes(bob));
	CHECK(!results.includes(charlie));
});

TEST("wildcard works with has_component", function () {
	const world = statuh_create_world();
	const Likes = world.register_component<undefined>();

	const alice = world.create_entity();
	const bob = world.create_entity();
	const charlie = world.create_entity();

	// Alice and Bob are friends
	world.add_component(alice, statuh_pair(Likes, bob));
	const doesAliceLikeAnyone = world.has_component(alice, statuh_pair(Likes, world.get_wildcard()));
	const doesAliceLikeBob = world.has_component(alice, statuh_pair(Likes, bob));
	const doesAliceLikeCharlie = world.has_component(alice, statuh_pair(Likes, charlie));

	CHECK(doesAliceLikeAnyone === true);
	CHECK(doesAliceLikeBob === true);
	CHECK(doesAliceLikeCharlie === false);
});

TEST("conflicting include and exclude results in empty set", function () {
	const world = statuh_create_world();
	const TagA = world.register_component<undefined>();

	const entity = world.create_entity();
	world.add_component(entity, TagA);

	const result = world.query_entities_of_archetype([TagA], [TagA]);
	CHECK(result.size() === 0);
});

TEST("safe access to missing component", function () {
	const world = statuh_create_world();
	const CompA = world.register_component<number>();
	const CompB = world.register_component<number>();

	const e = world.create_entity();
	world.set_component_data(e, CompA, 123);

	CHECK(world.get_component_data(e, CompB) === undefined);
	// Should not throw when component not present
	world.remove_component(e, CompB);
});

TEST("get_component_datas returns undefined for missing entries", function () {
	const world = statuh_create_world();
	const CompA = world.register_component<number>();
	const CompB = world.register_component<number>();

	const e = world.create_entity();
	world.set_component_data(e, CompA, 42);

	const [a, b] = world.get_component_datas(e, CompA, CompB);
	CHECK(a === 42);
	CHECK(b === undefined);
});

TEST("removed hook fires for pair component", function () {
	const world = statuh_create_world();
	const Pred = world.register_component<undefined>();
	const Obj = world.register_component<undefined>();

	const PairComp = statuh_pair(Pred, Obj);

	let removedCount = 0;
	world.add_component_hook_removed(PairComp, () => {
		removedCount++;
	});

	const entity = world.create_entity();
	world.add_component(entity, PairComp);
	world.remove_component(entity, PairComp);
	CHECK(removedCount === 1);
});

TEST("hook re-entrancy tolerated", function () {
	const world = statuh_create_world();
	const CompA = world.register_component<undefined>();
	const CompB = world.register_component<undefined>();

	let addedACount = 0;
	let addedBCount = 0;

	world.add_component_hook_added(CompA, (entity) => {
		addedACount++;
		world.add_component(entity, CompB);
	});

	world.add_component_hook_added(CompB, () => {
		addedBCount++;
	});

	const entity = world.create_entity();
	world.add_component(entity, CompA);

	CHECK(addedACount === 1);
	CHECK(addedBCount === 1);
	CHECK(world.has_component(entity, CompB));
});

TEST("order_entities deterministic", function () {
	const world = statuh_create_world();
	const e1 = world.create_entity();
	const e2 = world.create_entity();

	CHECK(world.order_entities(e1, e2) === true);
	CHECK(world.order_entities(e2, e1) === false);
});

TEST("entity_to_string produces unique strings", function () {
	const world = statuh_create_world();
	const e1 = world.create_entity();
	const e2 = world.create_entity();
	const e3 = world.create_entity();

	const strs = [world.entity_to_string(e1), world.entity_to_string(e2), world.entity_to_string(e3)];
	const unique = new Set(strs);
	CHECK(unique.size() === 3);
});

TEST("get_relationship_target returns placeholder when missing", function () {
	const world = statuh_create_world();
	const Rel = world.register_component<undefined>();
	const e = world.create_entity();

	const target = world.get_relationship_target(e, Rel);
	CHECK(target === undefined);
});

TEST("term type checking (is_term_pair, is_term_component)", function () {
	const world = statuh_create_world();

	const ComponentA = world.register_component<undefined>();
	const ComponentB = world.register_component<undefined>();
	const PairAB = statuh_pair(ComponentA, ComponentB);

	// Test is_term_pair
	CHECK(world.is_term_pair(PairAB) === true, "PairAB should be identified as a pair");
	CHECK(world.is_term_pair(ComponentA) === false, "ComponentA should not be identified as a pair");
	CHECK(world.is_term_pair(ComponentB) === false, "ComponentB should not be identified as a pair");

	// Test is_term_component
	CHECK(world.is_term_component(PairAB) === false, "PairAB should not be identified as a component");
	CHECK(world.is_term_component(ComponentA) === true, "ComponentA should be identified as a component");
	CHECK(world.is_term_component(ComponentB) === true, "ComponentB should be identified as a component");
});

TEST("get_pair_predicate and get_pair_object", function () {
	const world = statuh_create_world();

	const Predicate = world.register_component<undefined>();
	const Obj = world.register_component<undefined>();
	const PairPO = statuh_pair(Predicate, Obj);

	const retrievedPredicate = world.get_pair_predicate(PairPO);
	const retrievedObject = world.get_pair_object(PairPO);

	CHECK(retrievedPredicate === Predicate, "get_pair_predicate should return the correct predicate entity");
	CHECK(retrievedObject === Obj, "get_pair_object should return the correct object entity");
});

TEST("get_entity_count basics (empty, create, delete)", function () {
	const world = statuh_create_world();
	CHECK(world.get_entity_count() === 0);

	const e1 = world.create_entity();
	CHECK(world.get_entity_count() === 1);

	const e2 = world.create_entity();
	CHECK(world.get_entity_count() === 2);

	world.delete_entity(e1);
	CHECK(world.get_entity_count() === 1);

	world.delete_entity(e2);
	CHECK(world.get_entity_count() === 0);
});

TEST("get_entity_count unaffected by components", function () {
	const world = statuh_create_world();

	const CompA = world.register_component<undefined>();
	const CompB = world.register_component<number>();
	const CompC = world.register_component<string>();

	// Registering components should not count as entities
	CHECK(world.get_entity_count() === 0);

	const e = world.create_entity();
	CHECK(world.get_entity_count() === 1);

	// Adding/removing components does not change entity count
	world.add_component(e, CompA);
	CHECK(world.get_entity_count() === 1);
	world.set_component_data(e, CompB, 42);
	CHECK(world.get_entity_count() === 1);
	world.set_component_data(e, CompC, "x");
	CHECK(world.get_entity_count() === 1);
	world.remove_component(e, CompA);
	CHECK(world.get_entity_count() === 1);
});

TEST("get_entity_count and relationships/wildcards", function () {
	const world = statuh_create_world();
	const Likes = world.register_component<undefined>();

	const a = world.create_entity();
	const b = world.create_entity();
	CHECK(world.get_entity_count() === 2);

	// Add relationship
	world.add_component(a, statuh_pair(Likes, b));
	CHECK(world.get_entity_count() === 2);

	// Wildcard relationship should not affect count
	const wildcard = world.get_wildcard();
	world.add_component(a, statuh_pair(Likes, wildcard));
	CHECK(world.get_entity_count() === 2);
});

TEST("get_entity_count: delete_all_entities and idempotent deletions", function () {
	const world = statuh_create_world();
	CHECK(world.get_entity_count() === 0);

	// delete_all on empty world is fine
	world.delete_all_entities();
	CHECK(world.get_entity_count() === 0);

	// Create several
	const ids: StatuhEntity[] = [];
	for (let i = 0; i < 4; i++) ids.push(world.create_entity());
	CHECK(world.get_entity_count() === 4);

	// Double delete tolerance: only first delete changes the count
	world.delete_entity(ids[0]);
	CHECK(world.get_entity_count() === 3);
	world.delete_entity(ids[0]);
	CHECK(world.get_entity_count() === 3);

	// Bulk delete resets to 0
	world.delete_all_entities();
	CHECK(world.get_entity_count() === 0);
});

TEST("get_entity_count parity with get_all_entities size", function () {
	const world = statuh_create_world();
	const A = world.register_component<undefined>();

	const e1 = world.create_entity();
	const e2 = world.create_entity();
	world.add_component(e1, A);
	const before = world.get_all_entities().size();
	CHECK(world.get_entity_count() === before);

	world.delete_entity(e2);
	const after = world.get_all_entities().size();
	CHECK(world.get_entity_count() === after);
});

TEST("get_entity_count excludes component-entities used as entities", function () {
	const world = statuh_create_world();
	const ComponentEntity = world.register_component<undefined>();
	const AnotherComponent = world.register_component<undefined>();

	// Using component as an entity (allowed by our API) should not increase count
	world.add_component(ComponentEntity, AnotherComponent);
	CHECK(world.get_entity_count() === 0);

	// Creating a normal entity is counted
	const e = world.create_entity();
	CHECK(world.get_entity_count() === 1);
});

TEST("get_relationship_source returns single source", function () {
	const world = statuh_create_world();
	const Likes = world.register_component<undefined>();

	const alice = world.create_entity();
	const bob = world.create_entity();

	// Alice likes Bob
	world.add_component(alice, statuh_pair(Likes, bob));

	const source = world.get_relationship_source(bob, Likes);
	CHECK(source === alice);
});

TEST("get_relationship_source returns one of multiple sources", function () {
	const world = statuh_create_world();
	const Likes = world.register_component<undefined>();

	const alice = world.create_entity();
	const charlie = world.create_entity();
	const bob = world.create_entity();

	// Alice and Charlie like Bob
	world.add_component(alice, statuh_pair(Likes, bob));
	world.add_component(charlie, statuh_pair(Likes, bob));

	const source = world.get_relationship_source(bob, Likes);
	CHECK(source === alice || source === charlie);
});

TEST("get_relationship_source returns undefined when no sources", function () {
	const world = statuh_create_world();
	const Likes = world.register_component<undefined>();

	const bob = world.create_entity();

	const source = world.get_relationship_source(bob, Likes);
	CHECK(source === undefined);
});

TEST("relationship predicate hooks - added fires on add and first set", function () {
	const world = statuh_create_world();
	const Rel = world.register_component<undefined>();
	const source = world.create_entity();
	const target = world.create_entity();

	let addedCount = 0;
	let lastSource: StatuhEntity | undefined;
	let lastPred: StatuhEntity | undefined;
	let lastTarget: StatuhEntity | undefined;
	let lastData: unknown;

	world.add_relationship_hook_added(Rel, (s, pred, t, data) => {
		addedCount++;
		lastSource = s;
		lastPred = pred;
		lastTarget = t;
		lastData = data;
	});

	// Add pair without data -> added fires once, data undefined
	world.add_component(source, statuh_pair(Rel, target));
	CHECK(addedCount === 1);
	CHECK(lastSource === source);
	CHECK(lastPred === Rel);
	CHECK(lastTarget === target);
	CHECK(lastData === undefined);
});

TEST("relationship predicate hooks - setted fires on every set", function () {
	const world = statuh_create_world();
	const RelData = world.register_component<number>();
	const source = world.create_entity();
	const target = world.create_entity();

	let setCount = 0;
	let lastData: unknown = undefined;

	world.add_relationship_hook_setted(RelData, (s, pred, t, data) => {
		setCount++;
		lastData = data;
	});

	// No sets yet
	CHECK(setCount === 0);

	// First set triggers setted
	world.set_component_data(source, statuh_pair(RelData, target), 10);
	CHECK(setCount === 1);
	CHECK(lastData === 10);

	// Second set triggers setted again
	world.set_component_data(source, statuh_pair(RelData, target), 20);
	CHECK(setCount === 2);
	CHECK(lastData === 20);
});

TEST("relationship predicate hooks - removed fires on remove and entity deletion", function () {
	const world = statuh_create_world();
	const RelTag = world.register_component<undefined>();
	const RelData = world.register_component<number>();
	const source = world.create_entity();
	const target = world.create_entity();

	let removedCount = 0;
	let lastSource: StatuhEntity | undefined;
	let lastPred: StatuhEntity | undefined;
	let lastTarget: StatuhEntity | undefined;
	let lastData: unknown;

	world.add_relationship_hook_removed(RelTag, (s, pred, t, data) => {
		removedCount++;
		lastSource = s;
		lastPred = pred;
		lastTarget = t;
		lastData = data;
	});

	world.add_relationship_hook_removed(RelData, (s, pred, t, data) => {
		removedCount++;
		lastSource = s;
		lastPred = pred;
		lastTarget = t;
		lastData = data;
	});

	// Remove via remove_component (with undefined data)
	world.add_component(source, statuh_pair(RelTag, target));
	world.remove_component(source, statuh_pair(RelTag, target));
	CHECK(removedCount === 1);
	CHECK(lastSource === source && lastPred === RelTag && lastTarget === target);
	CHECK(lastData === undefined);

	// Remove via deleting the source (with data present)
	world.set_component_data(source, statuh_pair(RelData, target), 7);
	world.delete_entity(source);
	CHECK(removedCount === 2);
	CHECK(lastSource !== undefined && lastSource !== target); // should be source side
	CHECK(lastPred === RelData && lastTarget === target);
	CHECK(lastData === 7);

	// Recreate and remove via deleting the target
	const src2 = world.create_entity();
	const tgt2 = world.create_entity();
	world.set_component_data(src2, statuh_pair(RelData, tgt2), 9);
	world.delete_entity(tgt2);
	CHECK(removedCount === 3);
	CHECK(lastSource === src2 && lastPred === RelData);
	CHECK(lastTarget === tgt2);
	CHECK(lastData === 9);
});

// Run all tests
export function runStatuhTests() {
	print("Running Statuh Framework Tests...\n");
	return FINISH();
}
