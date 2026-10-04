# Statuh scope: who sees what

Design and prototype for per-client selective replication in Statuh 2.0 (HANDOFF milestone M4). This document compares three ways to express visibility, picks one, and reports on a prototype of the chosen design's core: its semantics, typing, tests and cost. Nothing here is in `src/`.

The owner's decisions on the first version (`agent-handoff/QUESTIONS.md`, "Owner's answers") are folded in:

- scope is permission only, and interest management is game code;
- `VisibleThrough` names an entity, and game relations carry no visibility meaning;
- components can be narrower than their entity;
- a loop of `VisibleThrough` links is walked without revisiting an entity.

| Path | What |
|---|---|
| `src/StatuhScope.luau` | The prototype core: a jecs world in, per-client frames out. No networking. |
| `src/ScopeOracle.luau` | The same semantics computed from scratch, used as the reference in tests. |
| `src/ClientReplica.luau` | A client rebuilt only from frames; checks the protocol as it applies them. |
| `src/ScopeHarness.luau`, `src/FuzzWorld.luau` | The per-frame invariant checks, and the seeded random worlds. |
| `test/*.spec.luau` | Scenario specs (the four games) and the randomized invariant specs. |
| `types/` | Typed stubs of the chosen API, example games that must type-check, misuse that must not. |
| `bench/bench.luau` | Per-frame cost at 50 players x 2,000 entities. |
| `tools/` | `replay`, `trace` and `soak` for fuzz seeds. |

```bash
lune run tools/lune-headless/run.luau experiments/statuh-scope          # specs (20 tests, ~10 s)
lune run experiments/statuh-scope/tools/soak.luau 1 3000 60             # 3,000 seeds x 60 frames
lune run experiments/statuh-scope/tools/soak.luau 5001 8000 60 3        # same, ENTER budget 3
lune run experiments/statuh-scope/tools/replay.luau <seed> [frames] [budget]
lune run experiments/statuh-scope/types/check.luau                      # typing (luau-lsp, old solver)
lune run experiments/statuh-scope/bench/bench.luau                      # benchmarks
```

## What the API has to express

From `agent-handoff/reference/statuh-selective-replication.md`:

- **Teams and rooms.** Membership (who is in red) is separate from audience (what red may see).
- **Owner-only components.** An inventory replicates only to its owner.
- **Children follow a parent.** A unit's weapon is visible exactly when the unit is.
- **Per-entity overrides.** A boss stays hidden until a reveal.
- **Custom and spatial rules,** as key functions with declared dependencies.

The owner added one more:

- **Components narrower than their entity.** A far-away player still arrives as a player on a team, while their position and animation only go to players near them.

It has to do this under the 11 core guardrails and 6 game-code guardrails listed in that doc. The ones that shape the API are:

- fail closed (2, 5);
- never put an out-of-scope net id on the wire (4);
- revoke immediately (6). The notes also put relevance, with hysteresis, in core; the owner moved interest to game code;
- keep a fixed frame order with groups entering atomically (7);
- evaluate incrementally (11);
- never reuse one relation for both membership and audience (game 6).

The four test games:

1. **Tower defense, two teams.** Public towers and enemy waves, team-only plans, owner-only gold and inventories, players switching teams.
2. **RTS with fog of war.** Your team always sees its own units. Enemies see a unit only while it's in a cell their team has vision of. Weapons follow their unit. Neutral resources are only sent near your camera.
3. **Instanced dungeons with parties and spectators.** Monsters are shown to the party and the spectators, loot only to the party, loot rolls only to the looter. The boss is hidden until the reveal. Quitting revokes everything in the instance.
4. **Arena** (the owner's example). Every player is public, but their position and animation only go to players near them, so a far-away player is just a name and a team. A sword lying near you, owned by a far-away player, arrives whole, with its owner as data. Holding an item grants nothing by itself; the game makes a held item visible through its holder.

## Three designs

### A. Grants and rules, stored in the world (chosen)

Visibility is data on entities, as jecs relations and tags owned by core:

- **Grants** say who may see an entity, and they add up: `Net.Public`, `pair(Net.Audience, room)`, `pair(Net.Owner, player)`, and `pair(Net.VisibleThrough, target)`, which also grants whoever sees the target.
- **Restrictions** narrow that: the `Net.VisibleTo` override (`"server"`, `"owner"` or a room) and restrict rules.
- **Rules** are key functions in two modes. `grant` adds the viewers interested in the entity's key. `restrict` keeps only them.
- **Components** can be narrower than their entity. Each replicated component goes to everyone who has the entity (`"all"`), to its owners (`"owner"`), or to the clients a restrict rule lets through.

Typed helpers (`Net.join`, `Net.showTo`, ...) wrap the raw pairs so rooms and players can't be swapped.

```lua
-- Tower defense
local Gold = Statuh.replicated(S.integer(0, 1000000), { visibleTo = "owner" })
Net.join(world, alice, red)            -- membership
Net.showTo(world, redPlan, red)        -- audience
Net.makePublic(world, tower)
Net.setOwner(world, alice, alice)      -- alice's Gold goes to alice only
rt.net.setDefaultPublic(C.Enemy)       -- applied once at spawn, as a visible Net.Public
-- switching teams: leave then join; in between alice sees neither team's plans, never both
Net.leave(world, alice, red); Net.join(world, alice, blue)

-- RTS
Net.showTo(world, unit, team)                         -- own team always sees its units
rt.net.addScopeRule("fog", {
	mode = "grant", appliesTo = C.Unit, dependsOn = { C.Cell },
	key = function(unit): number? return cellOf(unit) end,
	viewerKeys = function(viewer): { [number]: true } return visionOf(teamOf(viewer)) end,
})
Net.visibleThrough(world, weapon, unit)               -- weapon is seen whenever its unit is
rt.net.addScopeRule("camera", {                       -- interest is game code: a restrict rule
	mode = "restrict", appliesTo = C.Resource, dependsOn = { C.Cell }, viewerDependsOn = { C.Camera },
	key = function(ore): number? return chunkOf(ore) end,
	viewerKeys = function(viewer): { [number]: true } return chunksAround(cameraOf(viewer)) end,
})

-- Dungeons
Net.showTo(world, goblin, instance.party); Net.showTo(world, goblin, instance.spectators)
Net.showTo(world, loot, instance.party); Net.setOwner(world, loot, looter) -- Rolls are visibleTo = "owner"
Net.override(world, boss, "server")     -- hidden; later Net.override(world, boss, nil) reveals it
Net.leave(world, healer, instance.party) -- revoked at once: LEAVE for everything in the instance

-- Arena
local Near = Statuh.rule("near")
local Position = Statuh.replicated(S.struct({ x = S.number(), z = S.number() }), { visibleTo = Near })
rt.net.addScopeRule("near", {                         -- no appliesTo: it only decides components
	mode = "restrict", dependsOn = { C.Position }, viewerDependsOn = { C.Position },
	key = function(e): number? return chunkOf(e) end,
	viewerKeys = function(viewer): { [number]: true } return chunksAround(viewer) end,
})
Net.makePublic(world, player)                         -- a player, on a team, to everyone
world:add(sword, Statuh.pair(C.OwnedBy, owner))       -- game data: no say in visibility
Net.visibleThrough(world, dagger, holder)             -- replication data: seen whenever the holder is
```

The full versions are `types/examples/*.luau` (type-checked) and `test/Scenarios.spec.luau` (run against the prototype).

### B. Visibility predicates

Each archetype registers a function `canSee(viewer, entity) -> boolean`, and core asks it for every (viewer, entity) pair it needs.

```lua
-- Tower defense
Statuh.visibility(C.Plan, function(viewer, plan) return teamOf(viewer) == world:get(plan, C.Team) end)
Statuh.visibility(C.Tower, function() return true end)
Statuh.componentVisibility(C.Gold, function(viewer, player) return viewer == player end)

-- RTS
Statuh.visibility(C.Unit, function(viewer, unit)
	return world:get(unit, C.Team) == teamOf(viewer) or teamVision(teamOf(viewer))[cellOf(unit)] ~= nil
end)
Statuh.visibility(C.Weapon, function(viewer, weapon) return Statuh.canSee(viewer, world:parent(weapon)) end)
Statuh.visibility(C.Resource, function(viewer, ore) return near(cameraOf(viewer), cellOf(ore)) end)

-- Dungeons
Statuh.visibility(C.Monster, function(viewer, m)
	local instance = instanceOf(m)
	return isInParty(viewer, instance) or isSpectating(viewer, instance)
end)
Statuh.visibility(C.Boss, function(viewer, boss) return world:has(boss, C.Revealed) and inInstance(viewer, boss) end)
```

This reads naturally at first: "a viewer can see a thing when ...". But it can't be evaluated incrementally. A predicate can read anything, so core can't know what to re-evaluate when something changes, and it ends up at O(viewers × entities) per frame. It also has no fail-closed default: a forgotten `if` in a predicate is a leak. And it invites exactly what the game-code guardrails forbid, such as reading client-written state or branching on secrets.

### C. Interest channels (publish/subscribe keys)

Every entity publishes to a set of channel keys and every client subscribes to a set. A client sees an entity when the two sets meet. Spatial interest is a rule that produces keys.

```lua
-- Tower defense
Statuh.publish(tower, "public")
Statuh.publish(redPlan, "team:red")
Statuh.subscribe(alice, { "public", "team:red", "player:" .. alice })
Statuh.publishComponent(alice, C.Gold, "player:" .. alice)

-- RTS
Statuh.publish(unit, "team:" .. team)              -- and per frame: "cell:" .. cell
Statuh.publishKeyRule(C.Unit, function(unit) return "cell:" .. cellOf(unit) end)
Statuh.subscribe(viewer, cellsVisibleTo(team))      -- re-subscribed when vision changes
Statuh.publish(weapon, unpackChannelsOf(unit))      -- kept in sync by hand, or a "same as" helper

-- Dungeons
Statuh.publish(goblin, { "dungeon:7:party", "dungeon:7:spectators" })
Statuh.publish(loot, "dungeon:7:party")
Statuh.publish(boss, {})                            -- hidden: no channels; reveal = publish later
```

Channels are fast (key lookups), easy to make incremental, and familiar from Colyseus- and SpatialOS-style systems. They split membership (subscribe) from audience (publish) by construction. The weak points:

- Channels are untyped strings that live outside the world, so they aren't queryable and a typo is silent.
- AND across kinds (team *and* in view) needs a second mechanism.
- Children following a parent means copying channels by hand.
- An entity with no channels being invisible is fail-closed, but a team swap needs care: unsubscribe before subscribe.

### Scoring

✔ the design satisfies it by construction, ◐ it needs discipline or extra machinery, ✘ it works against it.

| | A. Grants and rules | B. Predicates | C. Channels |
|---|---|---|---|
| 1 LEAVE/DEL/ROLLBACK distinct | ✔ (core) | ✔ (core) | ✔ (core) |
| 2 unknown reads | ✔ a component is hideable exactly when its visibility isn't "all"; HIDE is distinct from REM | ◐ predicates hide why something is absent | ✔ |
| 3 abort and resend unknown runs | ✔ (core) | ✔ (core) | ✔ (core) |
| 4 no out-of-scope id on the wire | ✔ core redacts refs and pairs | ◐ needs a predicate call per reference per viewer | ✔ |
| 5 fail closed, removing never widens | ✔ grants only add; proven by fuzz (monotonicity) | ✘ a predicate can return true from anything | ◐ needs ordered unsubscribe/subscribe |
| 6 revoke now (interest is game code) | ✔ every scope change is immediate | ✘ can't tell security from interest | ◐ per-channel flag |
| 7 fixed order, atomic groups | ✔ VisibleThrough defines the groups | ◐ groups invisible to core | ◐ copied channels aren't a group |
| 8 strip pairs on LEAVE | ✔ (core) | ✔ (core) | ✔ (core) |
| 9 recursive arg checks | ✔ scope is data at the base canon | ✘ needs re-running predicates at a past canon | ✔ |
| 10 delivered scope for checks/hashes | ✔ (core) | ✔ (core) | ✔ (core) |
| 11 incremental, declared dependencies | ✔ hooks on relations plus `dependsOn` | ✘ | ✔ |
| Game: membership vs audience distinct | ✔ different relations, typed helpers | ◐ ad hoc | ✔ subscribe vs publish |
| Game: interest from server-validated state | ✔ `dependsOn` lists server components | ✘ | ◐ |
| Natural to write | ✔ reads as "show this to red" | ✔ at first, then subtle | ◐ string plumbing |
| Typing | ✔ phantom-typed rooms and players; closed unions for modes, overrides and visibility | ◐ | ✘ strings |
| Cost per frame | O(dirty × viewers changed), bitsets | O(viewers × entities) | O(dirty × keys) |

**Choice: A.** It is the only design where the guardrails hold by construction rather than by care:

- Grants only add and restrictions only remove, so fail-closed and "removing never widens" are properties of the data model. The prototype's fuzz tests check them on every frame.
- Because visibility is ordinary jecs data, it's queryable, it fits "server code writes jecs directly", and it changes through the same hooks that drive frames.
- C's key functions are kept as rules, which is where they're strongest (spatial interest, fog vision).
- B is only useful as a warning: it's what "natural" looks like before it leaks.

## The chosen design, precisely

The prototype implements this. `ScopeOracle.luau` is the executable version of these rules.

**Grants (union).**

```
grants(e) = Public ? everyone : (∪ members(room) for each Audience room) ∪ owners(e) ∪ (∪ viewers interested in key(e) for each grant rule)
```

**Inheritance.** Following `VisibleThrough` up from the entity:

```
final(e) = (grants(e) ∪ final(target(e))) ∩ restrictions(e)
```

- The walk stops at an entity with no target, at a target that isn't replicated, or at an entity it has already visited.
- `restrictions(e)` is the `VisibleTo` override intersected with every restrict rule latched on `e`.
- Computed scope is `final`, plus the owner pin.

**Component visibility.** A client that has entity `e` holds its component `c` when `e` has `c` and the client passes `c`'s visibility:

```
"all":         every client that has e
"owner":       owners(e)
a rule name:   the clients interested in that restrict rule's key(e)
```

A component is never sent to a client that doesn't have its entity, so its visibility only ever narrows.

**Consequences.**

- **Nothing grants, nobody sees.** An entity with no grants is invisible.
- **Removing a grant, a membership, rule data or a `VisibleThrough` link can only shrink scope.** Adding a restriction can only shrink it. Because scope is permission only, this covers everything a client receives, component visibility included.
- **Removing an override is the one way to widen by removal.** It's a deliberate reveal, like `Net.override(boss, nil)`.
- **Rules are latched when the entity starts replicating.** `appliesTo` is checked once, so a rule can't fall off when a component is removed. A rule that only decides a component's visibility needs no `appliesTo`: core keys every replicated entity under it.
- **A nil key matches nobody.** A unit with no `Cell` is seen by no one through fog.
- **Archetype defaults are grants applied once.** `setDefaultPublic(C.Enemy)` adds `Net.Public` at spawn. It never acts as a fallback, so stripping an entity's grants can't make it public.
- **`VisibleThrough` names an entity and has one target** (it's exclusive), so removing a pair can never promote a different parent. Game relations (`ChildOf`, Held, OwnedBy) have no say in visibility. A replicated relation's pairs are data, sent while both ends are delivered.
- **Deleting a `VisibleThrough` target ends inheritance.** The pair goes with the target, and the entity falls back to its own grants, which fails closed. So "never delete a target without a cascade" (game guardrail 5) isn't needed for safety anymore.
- **A loop shares its members' grants.** Each member's walk goes round the loop once and stops when it comes back to an entity it has seen.

**Frames.** Each client gets, per frame:

1. **ENTER.** Targets go before referrers. An inheritance group (an entity with its in-scope inheritors) enters as one unit and is never split by `enterBudget`. A component the client may not see is left out.
2. **Ops (SET/HIDE/REM).** Entity references to entities the client lacks are sent as `REDACTED`. They are re-sent when the target enters, and redacted again before the target leaves. When a component becomes visible to the client it gets SET. When it stops being visible but still exists, the client gets HIDE; when it's removed, REM. Neither is sent for a component the client doesn't hold.
3. **Pairs (PAIR_REM/PAIR_ADD).** Only between entities the client has.
4. **LEAVE.** The client forgets the entity and strips pairs to it, without cleanup traits.
5. **DEL.** Only to clients that had the entity.
6. **ROLLBACK.** For predicted spawns the server didn't make.

**Revocation is immediate.** Losing scope means LEAVE that frame. There is no lingering in core. A game that wants things to linger at the edge of a camera keeps old cells in its rule's keys for a while; the RTS scenario does this.

**Unknown reads (guardrail 2).** A client can't tell at ENTER whether a component with restricted visibility is hidden from it or doesn't exist; sending a "hidden" mask would reveal that hidden data exists. So predicted code treats an absent hideable component as unknown. After the client has held it, HIDE and REM say which happened.

**Prediction hooks:**

- `clientMinted(player, seq, netId)` records a client's predicted spawn.
- `bindMinted(entity, player, netId)` gives the server-made entity the client's id, and pins the client into its scope until `acknowledge`.
- If the action is acknowledged without the spawn, the client gets ROLLBACK.

### Living with jecs 0.11.0-quenty.3

Statuh is built on the vendored jecs, which has six bugs (`experiments/jecs-findings/`). By the owner's rule they stay here: nobody contacts the jecs project about them. Statuh works around them instead:

- **Destroying an entity goes through a safe delete:** `Net.destroy` in the typed API, `JecsWorkarounds.delete` underneath. It removes the ordinary pairs pointing into what it deletes before deleting. A plain `world:delete` can corrupt entities that survive it, leave a `ChildOf` child alive, or crash.
- **`Net.visibleThrough` removes the old pair before adding the new one.** Retargeting an exclusive relation in place, which a second `world:add(e, pair(Net.VisibleThrough, other))` does, can later drop the entity from every query. Reparenting with `ChildOf` has the same problem.
- **Nothing removes `pair(R, jecs.Wildcard)`.**
- **Tests check jecs's own bookkeeping every frame** (invariant 0 below). Comparing the engine with the oracle can't see damage to the world, because both read it.

In the fuzz, plain jecs calls hit a jecs bug in 87 of 1,000 seeds within 60 frames, every one caught by invariant 0. With the workarounds, none of 6,000 seeds do.

### Where this departs from the reference notes, and why

| Reference v2 says | Prototype does | Why |
|---|---|---|
| VisibleThrough "inherits the parent's viewer set"; cycles or depth beyond a limit mean invisible. | VisibleThrough is a grant added to the entity's own. The chain is followed until it reaches an entity already visited, so a loop shares its members' grants. | The fuzz found that "deep or cyclic means invisible" isn't monotone. Removing a link near the root brings a deep descendant back within the limit, widening visibility (guardrail 5). The first version bounded hops from the entity; the owner chose the no-revisit walk. |
| `pair(Net.VisibleThrough, jecs.ChildOf)` follows a relation, and that relation must be exclusive with delete-with-target. | `pair(Net.VisibleThrough, target)` names the entity, and is exclusive (one target). No game relation, `ChildOf` included, affects visibility. | The owner's call: relations like Attached, Held or OwnedBy are game data and shouldn't imply replication. Naming the entity also drops the delete-with-target requirement, since deleting the target just ends inheritance. Exclusivity stays because the fuzz found that with two VisibleThrough pairs, removing one promoted the other parent, which widened. |
| Custom rules are key functions (one kind). | Two modes, `grant` and `restrict`. | Fog of war is "own team, or anyone whose vision covers the cell": a union. An AND-only rule can't express it without hiding your own units from you. |
| Revoke immediately; relevance changes with hysteresis, in core. | Scope is permission only. A camera is an ordinary restrict rule, and lingering is game code. | The owner's call: nearness is per game, and the server's game code implements it. It also makes "removing a constraint never widens" hold for all of scope. With relevance in core it held only for authorization, since removing a link could widen relevance. |
| `visibleTo = "owner"` on a component. | A component's visibility is `"all"`, `"owner"` or any restrict rule (`Statuh.rule("near")`). A component that stops being visible but still exists gets HIDE, distinct from REM. | So a far-away player can arrive as a name and a team without position or animation (the owner's arena example). HIDE vs REM is LEAVE vs DEL for components: absence because of scope must not read as removal (guardrails 1 and 2). |
| Per-archetype default, `private` unless set otherwise. | Defaults are grants applied once at spawn (`Net.Public` is added). | A default that applies when an entity "has no rule" is a fallback, and stripping the rules then widens. A team swap could flash an entity public, which is exactly the case the notes warn about. |

## Typing

`types/Statuh.luau` gives the API types:

- phantom-typed `Room` and `PlayerEntity` entities;
- a schema library whose values are typed as what they validate;
- closed unions for overrides, rule modes and component visibility, where a rule is named with `Statuh.rule(name)`;
- a generic rule key.

```bash
lune run experiments/statuh-scope/types/check.luau
# = luau-lsp analyze --platform=standard --flag:LuauSolverV2=false Statuh.luau examples/*.luau   (0 errors)
#   and the same over mustfail/*.luau, which must error on exactly the 15 lines marked `-- expect-error`
```

Result: `types OK: 5 files type-check, 15 must-fail lines all fail`. Every line below is caught by the old solver, each for the intended reason (checked against the analyzer's messages):

- A swapped `Net.join(world, room, player)`.
- A player passed where an audience room goes (membership vs audience).
- An override of `"everyone"`, or a player as an override.
- A room as the entity something is visible through.
- A component value of the wrong type, or a struct missing a field.
- `visibleTo = "owners"`, and a bare rule name (`visibleTo = "near"`, which must be `Statuh.rule("near")`).
- `S.instance()`: there's no Instance schema, so no Instances in replicated data.
- The rule mode `"relevance"`, which core no longer has.
- Strings in `dependsOn`.
- A rule whose `key` and `viewerKeys` disagree on the key type.
- Treating `removalKind` as only LEAVE or DEL, or `componentRemovalKind` as only REM.

Limits of the old solver, found while doing this:

- **Key agreement is only checked when `key` and `viewerKeys` aren't annotated.** With return annotations, or through a builder, the generic key is unified silently.
- **Unannotated rule functions that return `{}` in one branch don't infer at all**, so real code needs `: { [number]: true }` on `viewerKeys`. The examples do this. A mismatched key fails closed at runtime (nothing ever matches), so the gap is safe, but it isn't caught at compile time.
- **A bad rule mode is reported on the rule's table, not on its `mode` field,** and a mismatched key on the `return` inside `viewerKeys`. Must-fail markers sit on those lines.
- `Statuh.replicated(S.struct({ ... }))` infers the component type with no annotations, because schemas are phantom-typed values.

## Prototype

**Data.**

- Viewer sets are two 32-bit words (up to 64 clients). Each replicated entity caches its own grants and restrictions, its authorized, delivered and pending sets, its owners, and, per component, the clients that hold it.
- Reverse indexes cover room → entities, `VisibleThrough` target → inheritors, target → referrers (references and pairs), and rule key → entities and → viewers.
- jecs hooks (`world:added/changed/removed`) only mark things dirty. All reading happens in `frame()`.

**Per frame:**

1. Settle new entities: latch rules, key the rules components name, and apply defaults.
2. Settle membership, references and pair diffs.
3. Re-key rules.
4. Spread dirtiness to inheritors.
5. Recompute dirty entities: own data only when its world data changed, then rules, then the inheritance fold.
6. Turn bit changes into ENTER candidates and revocations, and component visibility changes into per-client SET or HIDE.
7. Emit per client in the fixed order, fanning out entity-major to the clients that have each entity.

### Tests

**Scenario specs** (`test/Scenarios.spec.luau`, 18 tests) run the four games and assert the visible behavior:

- team plans and owner-only gold;
- a team swap revoked at once and never public in between;
- references redacted and fixed up;
- DEL vs LEAVE vs unreplicate;
- fog reveal and revoke with the weapon entering in the same frame;
- a camera as a restrict rule, and lingering kept by the game in its keys;
- the boss reveal;
- loot rolls changing owner, with HIDE for the old owner;
- quitting a dungeon (LEAVE) vs the boss dying (DEL);
- a late spectator joining through budgeted ENTERs;
- a far-away player as a name and a team, and an owned sword arriving with its owner pair;
- position and animation sent as a player comes near and hidden (HIDE) as they go, and REM when one is removed;
- the viewer walking up to a player;
- Held granting nothing while VisibleThrough does, and the holder being deleted with its pairs left for jecs to remove.

**Invariants**, checked by `ScopeHarness` after every frame of every scenario and fuzz run:

0. **jecs integrity.** jecs's bookkeeping is consistent (`JecsWorkarounds.checkIntegrity`), checked before anything reads the world.
1. **Protocol.** The phase order holds, and no message mentions an id the client doesn't have, except the subject of ENTER and ROLLBACK.
2. **Oracle agreement.** Engine scope equals the oracle's from-scratch answer for every entity and client.
3. **No out-of-scope net id** in any message, references included.
4. **Projection.** Every client equals the projection of the server world onto its delivered scope, with each component's own visibility computed from scratch: components, redactions and pairs.
5. **Delivered scope equals authorization.** Nothing unauthorized is held, and every authorized entity is delivered (or pending under a budget).
6. **LEAVE and DEL are never confused, nor HIDE and REM.**
7. **Inheritance groups enter whole.**

Plus, at random points, a narrowing edit is applied and the oracle checks that authorization, and every restricted component's data, only shrank.

**Fuzz** (`test/Invariants.spec.luau`, `src/FuzzWorld.luau`) uses seeded random worlds:

- 3 rooms, 6 players who connect and disconnect;
- grants, overrides, and `VisibleThrough` chains that get retargeted, dropped and closed into loops;
- grant and restrict rules, and a component visible only through a rule ("near");
- references, owner-only data, unreplicate/re-replicate, deletes with cascades;
- 0–6 random edits per frame.

Deletes and retargets go through `JecsWorkarounds`, as game code on this jecs must; `JECS_WORKAROUNDS=0` runs plain jecs calls instead. The arena scenario covers a `VisibleThrough` target deleted with plain `world:delete`, its pairs left for jecs to remove.

Every failure prints its seed and frame, and `tools/replay.luau` and `tools/trace.luau` replay it.

- **In the spec suite:** 150 seeds × 40 frames unbudgeted plus 100 × 40 with an ENTER budget of 2.
- **Soak:** 3,000 seeds × 60 frames unbudgeted plus 3,000 × 60 with budget 3, i.e. 360,000 checked frames, **0 failures** (about 100 s each).

The tests catch a broken core. Making it send REM instead of HIDE, or not re-key entities when a viewer's keys grow, fails both the scenarios and the fuzz.

The fuzz found these in the prototype, all fixed:

1. Non-monotone depth limits.
2. A second VisibleThrough pair promoting a different parent.
3. References from an entity entering before its target in the same frame never being fixed up.
4. A DEL sent to a new player that reused a disconnected player's index.
5. Owner-only data leaking when ownership and the value changed in the same frame.
6. A stale parent after a reparent, during the optimization work.

It, and the random search in `experiments/jecs-findings/`, also found six bugs in the vendored jecs. That folder has a minimal repro for each, the cause of five, and the workarounds above:

- **A delete can corrupt an entity that survives it,** when that entity holds a relation pair to the deleted one and anything once held both a `ChildOf` pair and another pair to it.
- **A cascade delete can skip a child** that a sibling's deletion moved mid-cascade, leaving a dangling `ChildOf`.
- **A cascade delete can crash** when two children hold pairs to a grandchild.
- **Deleting an entity with no components can corrupt another entity.**
- **Retargeting an exclusive relation can drop an entity from every query,** once the new target is deleted and its id reused.
- **`world:remove(e, pair(R, jecs.Wildcard))`** leaves the pair, fires OnRemove, and corrupts the entity's other data.

### Cost

`bench/bench.luau` loads jecs and the core with codegen and their default environments. Setup: 50 players, 2,000 entities (40% public, 40% team-only, 10% owner-owned with owner-only data, 10% visible through a parent). Each frame, 100 entities change a value and 100 move cells, and 5 cameras move.

| Scenario | Per frame avg | p50 | p95 | Messages/frame | Join frame (all 50 players, every entity) |
|---|---|---|---|---|---|
| Teams, public, owner, inheritance | 3.7 ms | 3.3 | 6.6 | 4,206 | 268 ms, 61,993 ENTERs |
| + camera rule, cameras pan one chunk | 2.8 ms | 2.3 | 5.5 | 1,131 | 101 ms, 20,949 ENTERs |
| + camera rule, cameras teleport (18 chunk keys change per move) | 12.6 ms | 11.9 | 20.4 | 3,200 | 115 ms |
| teleport + ENTER budget 64 per client per frame | 14.7 ms | 13.4 | 22.2 | 2,846 | 64 ms, 3,143 ENTERs |
| No camera rule; cell position only to cameras near it, cameras pan | 4.7 ms | 4.3 | 7.5 | 2,918 | 516 ms, 61,993 ENTERs |

These are Lune on a Linux x86 container, single-threaded. They are for comparing designs, not for predicting a Roblox server.

- **Steady state is O(dirty × clients that have them).** The join frame is O(entities × clients), which is why joins should be budgeted (the notes' "join is a series of budgeted ENTERs").
- **Teleporting cameras are the worst case,** because each move re-keys 18 chunks and dirties about 560 entities.
- **Component visibility** (the last row) costs about 1 ms per frame over the first row, with the same entities delivered. It doubles the join frame, because ENTER checks each component's visibility and records who holds it, per client.

Optimizations not done yet:

- inline the bit loops (closures per entity);
- give viewer-key changes a per-viewer path, instead of recomputing whole entities;
- make ENTER cheaper for components visible to all (it records holders for every component);
- cache encoded chunks per (entity, mask class), as the notes suggest.

## Compared with fanon (statuh v1, `legacy-reference/`)

- **Removal kinds.** v1 had one removal (DEL), so "left your view" and "destroyed" were the same. Here LEAVE, DEL and ROLLBACK are distinct all the way to the client, and so are HIDE and REM for components. The harness checks that they're never confused.
- **Diffstep compaction.** v1's `DiffstepBuilder` keeps the last write per key and lets a DEL deactivate everything that mentions the name (including relations where it's the target). Scope frames don't need a builder: ops are read from the world at frame time, so a key written many times in a frame is sent once with its final value. HIDE and REM are sent only if the client holds the component (tracked per component), which is v1's "drop ops on a key that never reached the client". v1 dropped the DEL in NEW → DEL → NEW of one name ("additive NEW after DEL restarts ops"). That is only safe because names were never reused. Statuh 2 net ids aren't reused either, and re-replicating an entity gets a new id.
- **Inverse log.** v1's `InverseDiffstepBuilder` (first value per key, NEWs first, the rest reversed) is the client-side undo for prediction. Statuh 2 replaces it with "save the server value on first predicted write, restore, re-run". The scope core's side of that is ROLLBACK and the owner pin.
- **Canon/ack protocol.** v1 catches a joining player up with all compacted diffsteps in batches of 100, accumulates realtime diffsteps into a per-player warp meanwhile, then switches to realtime frames tagged with the canon number and an ack. In Statuh 2 terms:
  - catch-up becomes budgeted ENTERs of the player's computed scope, so it no longer sends the whole world to everyone;
  - the warp is unnecessary, because ENTER always reads current state;
  - each per-client frame still needs the canon number and ack, plus the per-client hash over delivered scope (guardrail 10).

  The prototype has no transport, so canon numbers aren't modeled.
- **Trust.** v1 never checked client name prefixes. The prototype's `bindMinted` asserts the id is unused, and the notes' range check per author goes in the same place.
- **v1 tests as a spec.** v1's tests cover compaction (`additive component op collapsing`, `DEL cascades subject + targets`) and inverse/rebuild rules. Their scope-relevant parts (a DEL hides everything about the name, relations to a deleted target vanish) map to invariants 4 and 6 and the pairs rule. The rest is prediction, outside this milestone.

## Open questions

1. **A component visible to "owners, or whoever is near".** A component has one visibility. Your own position under a "near" rule works because you're always near yourself, but "owners plus a rule" can't be said in general. Should `visibleTo` take a list, as a union?
2. **Hidden or absent at ENTER.** A client can't tell a hidden component from a missing one when an entity enters, since a "hidden" mask would reveal that hidden data exists. Is that leak worth taking for some components, so predicted code knows more?
3. **Overrides that widen.** `VisibleTo` only narrows. Is there a case for an override that grants (show this one entity to spectators)? Today that's just an Audience grant.
4. **Key agreement under the old solver** is only enforced for unannotated rules. Worth revisiting on the new solver.
5. **Rule latching** means adding `appliesTo` after spawn doesn't subject an entity to a rule. Should that be an error in debug builds?
6. **Per-client cost at the join frame** (~100–500 ms here) says joins must be budgeted. What budget, and should globals go first (the notes' `rt.net.ready()`)?
7. **Game guardrail 5** ("never delete a VisibleThrough target without a cascade") no longer protects anything: deleting the target fails closed. Drop it from the notes?
8. **A direct `world:delete` or retarget in game code** takes jecs's broken path, and Statuh can't stop it. Should debug builds check jecs's integrity every frame, as the tests do, to catch it?
