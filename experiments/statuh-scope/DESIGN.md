# Statuh scope: who sees what

Design and prototype for per-client selective replication in Statuh 2.0 (HANDOFF milestone M4). This document compares three ways to express visibility, picks one, and reports on a prototype of the chosen design's core: its semantics, typing, tests and cost. Nothing here is in `src/`.

| Path | What |
|---|---|
| `src/StatuhScope.luau` | The prototype core: a jecs world in, per-client frames out. No networking. |
| `src/ScopeOracle.luau` | The same semantics computed from scratch, used as the reference in tests. |
| `src/ClientReplica.luau` | A client rebuilt only from frames; checks the protocol as it applies them. |
| `src/ScopeHarness.luau`, `src/FuzzWorld.luau` | The per-frame invariant checks, and the seeded random worlds. |
| `test/*.spec.luau` | Scenario specs (the three games) and the randomized invariant specs. |
| `types/` | Typed stubs of the chosen API, example games that must type-check, misuse that must not. |
| `bench/bench.luau` | Per-frame cost at 50 players x 2,000 entities. |
| `tools/` | `replay`, `trace` and `soak` for fuzz seeds. |

```bash
lune run tools/lune-headless/run.luau experiments/statuh-scope          # specs (14 tests, ~11 s)
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

It has to do this under the 11 core guardrails and 6 game-code guardrails listed in that doc. The ones that shape the API are:

- fail closed (2, 5);
- never put an out-of-scope net id on the wire (4);
- revoke immediately but apply relevance changes with hysteresis (6);
- keep a fixed frame order with groups entering atomically (7);
- evaluate incrementally (11);
- never reuse one relation for both membership and audience (game 6).

The three test games:

1. **Tower defense, two teams.** Public towers and enemy waves, team-only plans, owner-only gold and inventories, players switching teams.
2. **RTS with fog of war.** Your team always sees its own units. Enemies see a unit only while it's in a cell their team has vision of. Weapons follow their unit. Neutral resources are only relevant near your camera.
3. **Instanced dungeons with parties and spectators.** Monsters are shown to the party and the spectators, loot only to the party, loot rolls only to the looter. The boss is hidden until the reveal. Quitting revokes everything in the instance.

## Three designs

### A. Grants and rules, stored in the world (chosen)

Visibility is data on entities, as jecs relations and tags owned by core:

- **Grants** say who may see an entity, and they add up: `Net.Public`, `pair(Net.Audience, room)`, `pair(Net.Owner, player)`, and `pair(Net.VisibleThrough, relation)`, which also grants whoever sees the relation's target.
- **Restrictions** narrow that: the `Net.VisibleTo` override (`"server"`, `"owner"` or a room) and scope rules.
- **Rules** are key functions in three modes. `grant` adds the viewers interested in the entity's key. `restrict` keeps only them, as authorization. `relevance` keeps only them as interest management, with hysteresis on exit.

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
Net.follow(world, weapon, Net.ChildOf)                -- weapon follows its unit
rt.net.addScopeRule("camera", {
	mode = "relevance", appliesTo = C.Resource, dependsOn = { C.Cell }, viewerDependsOn = { C.Camera },
	key = function(ore): number? return chunkOf(ore) end,
	viewerKeys = function(viewer): { [number]: true } return chunksAround(cameraOf(viewer)) end,
})

-- Dungeons
Net.showTo(world, goblin, instance.party); Net.showTo(world, goblin, instance.spectators)
Net.showTo(world, loot, instance.party); Net.setOwner(world, loot, looter) -- Rolls are visibleTo = "owner"
Net.override(world, boss, "server")     -- hidden; later Net.override(world, boss, nil) reveals it
Net.leave(world, healer, instance.party) -- revoked at once: LEAVE for everything in the instance
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
| 2 unknown reads | ✔ "hideable" per component | ◐ predicates hide why something is absent | ✔ |
| 3 abort and resend unknown runs | ✔ (core) | ✔ (core) | ✔ (core) |
| 4 no out-of-scope id on the wire | ✔ core redacts refs and pairs | ◐ needs a predicate call per reference per viewer | ✔ |
| 5 fail closed, removing never widens | ✔ grants only add; proven by fuzz (monotonicity) | ✘ a predicate can return true from anything | ◐ needs ordered unsubscribe/subscribe |
| 6 revoke now, relevance with hysteresis | ✔ rule modes say which is which | ✘ can't tell security from interest | ◐ per-channel flag |
| 7 fixed order, atomic groups | ✔ VisibleThrough defines the groups | ◐ groups invisible to core | ◐ copied channels aren't a group |
| 8 strip pairs on LEAVE | ✔ (core) | ✔ (core) | ✔ (core) |
| 9 recursive arg checks | ✔ scope is data at the base canon | ✘ needs re-running predicates at a past canon | ✔ |
| 10 delivered scope for checks/hashes | ✔ (core) | ✔ (core) | ✔ (core) |
| 11 incremental, declared dependencies | ✔ hooks on relations plus `dependsOn` | ✘ | ✔ |
| Game: membership vs audience distinct | ✔ different relations, typed helpers | ◐ ad hoc | ✔ subscribe vs publish |
| Game: interest from server-validated state | ✔ `dependsOn` lists server components | ✘ | ◐ |
| Natural to write | ✔ reads as "show this to red" | ✔ at first, then subtle | ◐ string plumbing |
| Typing | ✔ phantom-typed rooms, players, relations | ◐ | ✘ strings |
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

**Inheritance.** Following VisibleThrough at most `L` hops from the entity:

```
final(e, n) = (grants(e) ∪ final(parent(e), n - 1)) ∩ restrictions(e)
```

- `restrictions(e)` is the `VisibleTo` override intersected with every `restrict` rule.
- Relevance follows the same chain: `relevance(e, n) = relevanceRules(e) ∩ relevance(parent, n - 1)`.
- Computed scope is `final ∩ relevance`, plus the owner pin.

**Consequences.**

- **Nothing grants, nobody sees.** An entity with no grants is invisible.
- **Removing a grant, a membership, rule data or an inheritance link can only shrink authorization.** Adding a restriction can only shrink it.
- **Removing an override is the one way to widen by removal.** It's a deliberate reveal, like `Net.override(boss, nil)`.
- **Rules are latched when the entity starts replicating.** `appliesTo` is checked once, so a rule can't fall off when a component is removed.
- **A nil key matches nobody.** A unit with no `Cell` is seen by no one through fog.
- **Archetype defaults are grants applied once.** `setDefaultPublic(C.Enemy)` adds `Net.Public` at spawn. It never acts as a fallback, so stripping an entity's grants can't make it public.
- **VisibleThrough is exclusive, and only follows exclusive relations** (one target, like `jecs.ChildOf`). Removing one pair can never promote a different parent.

**Frames.** Each client gets, per frame:

1. **ENTER.** Targets go before referrers. An inheritance group (an entity with its in-scope inheritors) enters as one unit and is never split by `enterBudget`.
2. **Ops (SET/REM).** Entity references to entities the client lacks are sent as `REDACTED`. They are re-sent when the target enters, and redacted again before the target leaves. Owner-only components come and go with ownership.
3. **Pairs (PAIR_REM/PAIR_ADD).** Only between entities the client has.
4. **LEAVE.** The client forgets the entity and strips pairs to it, without cleanup traits.
5. **DEL.** Only to clients that had the entity.
6. **ROLLBACK.** For predicted spawns the server didn't make.

**Revocation is immediate.** Losing authorization means LEAVE that frame. Failing only relevance means the entity lingers `hysteresisFrames` first, and coming back within that window costs nothing.

**Prediction hooks:**

- `clientMinted(player, seq, netId)` records a client's predicted spawn.
- `bindMinted(entity, player, netId)` gives the server-made entity the client's id, and pins the client into its scope until `acknowledge`.
- If the action is acknowledged without the spawn, the client gets ROLLBACK.

### Where this departs from the reference notes, and why

| Reference v2 says | Prototype does | Why |
|---|---|---|
| VisibleThrough "inherits the parent's viewer set"; cycles or depth beyond a limit mean invisible. | VisibleThrough is a grant added to the entity's own. Inheritance stops after L hops from the entity, and cycles just share grants. | The fuzz found that "deep or cyclic means invisible" isn't monotone. Removing a link near the root brings a deep descendant back within the limit, widening visibility (guardrail 5). Bounding hops from the entity itself keeps removal monotone. |
| "Exclusive relation with delete-with-target required." | Enforced: `Net.VisibleThrough` is exclusive, and a non-exclusive relation contributes nobody. | The fuzz found that with two VisibleThrough pairs, removing one promoted the other parent, which widened. |
| Custom rules are key functions (one kind). | Three modes: `grant`, `restrict`, `relevance`. | Fog of war is "own team, or anyone whose vision covers the cell": a union. An AND-only rule can't express it without hiding your own units from you. Relevance is separate because only it gets hysteresis. |
| Per-archetype default, `private` unless set otherwise. | Defaults are grants applied once at spawn (`Net.Public` is added). | A default that applies when an entity "has no rule" is a fallback, and stripping the rules then widens. A team swap could flash an entity public, which is exactly the case the notes warn about. |
| "Removing a constraint never widens visibility." | Holds for authorization. Relevance (interest) can widen when an inheritance link is removed. | Relevance isn't a security boundary. Hysteresis and interest changes widen it by design. |

## Typing

`types/Statuh.luau` gives the API types: phantom-typed `Room`, `PlayerEntity` and `ExclusiveRelation` entities, a schema library whose values are typed as what they validate, literal unions for overrides and rule modes, and a generic rule key.

```bash
lune run experiments/statuh-scope/types/check.luau
# = luau-lsp analyze --platform=standard --flag:LuauSolverV2=false Statuh.luau examples/*.luau   (0 errors)
#   and the same over mustfail/*.luau, which must error on exactly the 13 lines marked `-- expect-error`
```

Result: `types OK: 4 files type-check, 13 must-fail lines all fail`. Every line below is caught by the old solver:

- A swapped `Net.join(world, room, player)`.
- A player passed where an audience room goes (membership vs audience).
- An override of `"everyone"`, or a player as an override.
- Inheriting through a non-exclusive relation.
- A component value of the wrong type, or a struct missing a field.
- `visibleTo = "owners"`.
- `S.instance()`: there's no Instance schema, so no Instances in replicated data.
- A rule mode `"spatial"`.
- Strings in `dependsOn`.
- A rule whose `key` and `viewerKeys` disagree on the key type.
- Treating `removalKind` as only LEAVE or DEL.

Limits of the old solver, found while doing this:

- **Key agreement is only checked when `key` and `viewerKeys` aren't annotated.** With return annotations, or through a builder, the generic key is unified silently.
- **Unannotated rule functions that return `{}` in one branch don't infer at all**, so real code needs `: { [number]: true }` on `viewerKeys`. The examples do this. A mismatched key fails closed at runtime (nothing ever matches), so the gap is safe, but it isn't caught at compile time.
- `Statuh.replicated(S.struct({ ... }))` infers the component type with no annotations, because schemas are phantom-typed values.

## Prototype

**Data.**

- Viewer sets are two 32-bit words (up to 64 clients). Each replicated entity caches its own grants, restrictions, relevance, delivered and pending sets, and owner sets.
- Reverse indexes cover room → entities, parent → inheritors, target → referrers (references and pairs), and rule key → entities and → viewers.
- jecs hooks (`world:added/changed/removed`) only mark things dirty. All reading happens in `frame()`.

**Per frame:**

1. Settle new entities: latch rules and apply defaults.
2. Settle membership, references and pair diffs.
3. Re-key rules.
4. Spread dirtiness to inheritors.
5. Recompute dirty entities: own data only when its world data changed, then rules, then the inheritance fold.
6. Turn bit changes into ENTER candidates, revocations and lingering.
7. Emit per client in the fixed order, fanning out entity-major to the clients that have each entity.

### Tests

**Scenario specs** (`test/Scenarios.spec.luau`, 12 tests) run the three games and assert the visible behavior:

- team plans and owner-only gold;
- a team swap revoked at once and never public in between;
- references redacted and fixed up;
- DEL vs LEAVE vs unreplicate;
- fog reveal and revoke with the weapon entering in the same frame;
- camera hysteresis without flapping;
- the boss reveal;
- loot rolls changing owner;
- quitting a dungeon (LEAVE) vs the boss dying (DEL);
- a late spectator joining through budgeted ENTERs.

**Invariants**, checked by `ScopeHarness` after every frame of every scenario and fuzz run:

1. **Protocol.** The phase order holds, and no message mentions an id the client doesn't have, except the subject of ENTER and ROLLBACK.
2. **Oracle agreement.** Engine scope equals the oracle's from-scratch answer for every entity and client.
3. **No out-of-scope net id** in any message, references included.
4. **Projection.** Every client equals the projection of the server world onto its delivered scope: components, owner-only data, redactions and pairs.
5. **Delivered scope stays in bounds.** It stays within authorization; in-scope entities are delivered (or pending under a budget); out-of-relevance entities linger at most `hysteresisFrames`.
6. **LEAVE and DEL are never confused.**
7. **Inheritance groups enter whole.**

Plus, at random points, a narrowing edit is applied and the oracle checks that authorization only shrank.

**Fuzz** (`test/Invariants.spec.luau`, `src/FuzzWorld.luau`) uses seeded random worlds:

- 3 rooms, 6 players who connect and disconnect;
- grants, overrides, and inheritance through `ChildOf` and a cycle-capable exclusive relation;
- all three rule modes;
- references, owner-only data, unreplicate/re-replicate, deletes with cascades;
- 0–6 random edits per frame.

Every failure prints its seed and frame, and `tools/replay.luau` and `tools/trace.luau` replay it.

- **In the spec suite:** 150 seeds × 40 frames unbudgeted plus 100 × 40 with an ENTER budget of 2.
- **Soak:** 3,000 seeds × 60 frames unbudgeted plus 3,000 × 60 with budget 3, i.e. 360,000 checked frames, **0 failures** (about 100 s each).

The fuzz found these in the prototype, all fixed:

1. Non-monotone depth limits.
2. A second VisibleThrough pair promoting a different parent.
3. References from an entity entering before its target in the same frame never being fixed up.
4. A DEL sent to a new player that reused a disconnected player's index.
5. Owner-only data leaking when ownership and the value changed in the same frame.
6. A stale parent after a reparent, during the optimization work.

It also found two bugs in the vendored jecs (`experiments/jecs-findings/`, each with a minimal repro):

- **A cascade delete can skip a child** that a sibling's deletion moved mid-cascade, leaving a dangling `ChildOf` that later resolves to a recycled id.
- **`world:remove(e, pair(R, jecs.Wildcard))`** leaves the pair, fires OnRemove, and corrupts the entity's other data.

The fuzz works around both.

### Cost

`bench/bench.luau` loads jecs and the core with codegen and their default environments. Setup: 50 players, 2,000 entities (40% public, 40% team-only, 10% owner-owned with owner-only data, 10% inheriting). Each frame, 100 entities change a value and 100 move cells, and 5 cameras move.

| Scenario | Per frame avg | p50 | p95 | Messages/frame | Join frame (all 50 players, every entity) |
|---|---|---|---|---|---|
| Teams, public, owner, inheritance | 3.7 ms | 3.5 | 5.8 | 4,206 | 325 ms, 61,993 ENTERs |
| + relevance rule, cameras pan one chunk | 3.5 ms | 3.0 | 6.0 | 1,979 | 129 ms, 20,949 ENTERs |
| + relevance rule, cameras teleport (18 chunk keys change per move) | 14.1 ms | 13.4 | 19.9 | 4,118 | 126 ms |
| teleport + ENTER budget 64 per client per frame | 15.8 ms | 14.6 | 24.4 | 3,893 | 73 ms, 3,143 ENTERs |

These are Lune on a Linux x86 container, single-threaded. They are for comparing designs, not for predicting a Roblox server.

- **Steady state is O(dirty × clients that have them).** The join frame is O(entities × clients), which is why joins should be budgeted (the notes' "join is a series of budgeted ENTERs").
- **Teleporting cameras are the worst case,** because each move re-keys 18 chunks and dirties about 560 entities.

Optimizations not done yet:

- inline the bit loops (closures per entity);
- give viewer-key changes a per-viewer path, instead of recomputing whole entities;
- cache encoded chunks per (entity, mask class), as the notes suggest.

## Compared with fanon (statuh v1, `legacy-reference/`)

- **Removal kinds.** v1 had one removal (DEL), so "left your view" and "destroyed" were the same. Here LEAVE, DEL and ROLLBACK are distinct all the way to the client, and the harness checks that they're never confused.
- **Diffstep compaction.** v1's `DiffstepBuilder` keeps the last write per key and lets a DEL deactivate everything that mentions the name (including relations where it's the target). Scope frames don't need a builder: ops are read from the world at frame time, so a key written many times in a frame is sent once with its final value. REM is sent only if the client had the component (`sent` tracking), which is v1's "drop ops on a key that never reached the client". v1 dropped the DEL in NEW → DEL → NEW of one name ("additive NEW after DEL restarts ops"). That is only safe because names were never reused. Statuh 2 net ids aren't reused either, and re-replicating an entity gets a new id.
- **Inverse log.** v1's `InverseDiffstepBuilder` (first value per key, NEWs first, the rest reversed) is the client-side undo for prediction. Statuh 2 replaces it with "save the server value on first predicted write, restore, re-run". The scope core's side of that is ROLLBACK and the owner pin.
- **Canon/ack protocol.** v1 catches a joining player up with all compacted diffsteps in batches of 100, accumulates realtime diffsteps into a per-player warp meanwhile, then switches to realtime frames tagged with the canon number and an ack. In Statuh 2 terms:
  - catch-up becomes budgeted ENTERs of the player's computed scope, so it no longer sends the whole world to everyone;
  - the warp is unnecessary, because ENTER always reads current state;
  - each per-client frame still needs the canon number and ack, plus the per-client hash over delivered scope (guardrail 10).

  The prototype has no transport, so canon numbers aren't modeled.
- **Trust.** v1 never checked client name prefixes. The prototype's `bindMinted` asserts the id is unused, and the notes' range check per author goes in the same place.
- **v1 tests as a spec.** v1's tests cover compaction (`additive component op collapsing`, `DEL cascades subject + targets`) and inverse/rebuild rules. Their scope-relevant parts (a DEL hides everything about the name, relations to a deleted target vanish) map to invariants 4 and 6 and the pairs rule. The rest is prediction, outside this milestone.

## Open questions

1. **Cycles in VisibleThrough.** The notes say cycles should be invisible, but that contradicts guardrail 5. The prototype lets a cycle share its members' grants, bounded by L hops. Cycles need a custom exclusive relation, since ChildOf deletes can't make them. Is sharing acceptable, or should core reject such relations?
2. **Overrides that widen.** `VisibleTo` only narrows. Is there a case for an override that grants (show this one entity to spectators)? Today that's just an Audience grant.
3. **Relevance and monotonicity.** Should relevance also be monotone under link removal (don't inherit relevance), at the cost of children lingering apart from their parent?
4. **Key agreement under the old solver** is only enforced for unannotated rules. Worth revisiting on the new solver.
5. **Rule latching** means adding `appliesTo` after spawn doesn't subject an entity to a rule. Should that be an error in debug builds?
6. **The two jecs bugs:** report upstream, or patch the vendored fork?
7. **Per-client cost at the join frame** (~130–325 ms here) says joins must be budgeted. What budget, and should globals go first (the notes' `rt.net.ready()`)?
