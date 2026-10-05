# Statuh scope: who sees what

Design and prototype for per-client selective replication in Statuh 2.0 (HANDOFF milestone M4). This document compares three ways to express visibility, picks one, and reports on a prototype of its core: semantics, typing, tests and cost. Nothing here is in `src/`.

The owner's decisions (`agent-handoff/QUESTIONS.md`, "Owner's answers") are folded in:

- scope is permission only, and interest management is game code;
- `VisibleThrough` names an entity, and game relations carry no visibility meaning;
- components can be narrower than their entity;
- a loop of `VisibleThrough` links is walked without revisiting an entity.

| Path | What |
|---|---|
| `src/StatuhScope.luau` | The prototype core: a jecs world in, per-client frames out. No networking. |
| `src/ScopeOracle.luau` | The same semantics computed from scratch, the reference in tests. |
| `src/ClientReplica.luau` | A client rebuilt only from frames; checks the protocol as it applies them. |
| `src/ScopeHarness.luau`, `src/FuzzWorld.luau` | The per-frame invariant checks, and the seeded random worlds. |
| `test/*.spec.luau` | Scenario specs (the four games) and the randomized invariant specs. |
| `types/` | Typed stubs of the chosen API, example games that must type-check, misuse that must not. |
| `bench/bench.luau` | Per-frame cost at 50 players × 2,000 entities. |
| `tools/` | `replay`, `trace` and `soak` for fuzz seeds. |

```bash
lune run tools/lune-headless/run.luau experiments/statuh-scope          # specs (22 tests, ~12 s)
lune run experiments/statuh-scope/tools/soak.luau 1 3000 60             # 3,000 seeds x 60 frames
lune run experiments/statuh-scope/tools/soak.luau 5001 8000 60 3        # same, ENTER budget 3
lune run experiments/statuh-scope/tools/replay.luau <seed> [frames] [budget]
lune run experiments/statuh-scope/types/check.luau                      # typing (luau-lsp, old solver)
lune run experiments/statuh-scope/bench/bench.luau                      # benchmarks
```

## What the API has to express

From `agent-handoff/reference/statuh-selective-replication.md`: teams and rooms, with membership (who is in red) separate from audience (what red may see); owner-only components; children that follow a parent; per-entity overrides (a boss hidden until a reveal); and custom and spatial rules as key functions with declared dependencies. The owner added components narrower than their entity: a far-away player arrives as a player on a team, while their position and animation only go to players near them.

All of it under the notes' 11 core and 6 game-code guardrails. The ones that shape the API: fail closed (2, 5); never put an out-of-scope net id on the wire (4); revoke immediately (6; the notes also put relevance with hysteresis in core, and the owner moved interest to game code); a fixed frame order with groups entering atomically (7); incremental evaluation (11); and never one relation for both membership and audience (game 6).

The four test games:

1. **Tower defense, two teams.** Public towers and enemy waves, team-only plans, owner-only gold, players switching teams.
2. **RTS with fog of war.** Your team always sees its units; enemies see a unit only in a cell their team has vision of. Weapons follow their unit. Neutral resources are only sent near your camera.
3. **Instanced dungeons.** Monsters shown to the party and the spectators, loot only to the party, loot rolls only to the looter, a boss hidden until the reveal. Quitting revokes everything in the instance.
4. **Arena** (the owner's example). Every player is public, but position and animation only go to players near them. A sword near you, owned by a far-away player, arrives whole, with its owner as data. Holding an item grants nothing; the game makes a held item visible through its holder.

## Three designs

### A. Grants and needs, stored in the world (chosen)

Visibility is data on entities, as jecs relations and tags that core owns. **Grants** say who may see an entity, and they add up: `Net.Public`, `pair(Net.Audience, room)`, `pair(Net.Owner, player)`, grant rules, and `pair(Net.VisibleThrough, target)` for whoever sees the target. **Needs** narrow that: the `Net.VisibleTo` override and restrict rules. A component can have a need of its own. Typed helpers wrap the raw pairs so rooms and players can't be swapped.

```lua
-- Tower defense
local Gold = Statuh.replicated(S.integer(0, 1000000), { visibleTo = "owner" })
Net.join(world, alice, red)              -- membership
Net.showTo(world, redPlan, red)          -- audience
Net.setOwner(world, alice, alice)        -- alice's Gold goes to alice only
Net.leave(world, alice, red); Net.join(world, alice, blue) -- a swap: never both teams' plans

-- RTS
rt.net.addScopeRule("fog", {
	mode = "grant", appliesTo = C.Unit, dependsOn = { C.Cell },
	key = function(unit): number? return cellOf(unit) end,
	viewerKeys = function(viewer): { [number]: true } return visionOf(teamOf(viewer)) end,
})
Net.visibleThrough(world, weapon, unit)  -- seen whenever its unit is
rt.net.addScopeRule("camera", { mode = "restrict", appliesTo = C.Resource, ... }) -- interest is game code

-- Dungeons
Net.override(world, boss, "server")      -- hidden; Net.override(world, boss, nil) reveals it

-- Arena
local Position = Statuh.replicated(S.struct({ x = S.number(), z = S.number() }), { visibleTo = Statuh.rule("near") })
world:add(sword, Statuh.pair(C.OwnedBy, owner)) -- game data: no say in visibility
```

The full versions are `types/examples/*.luau` (type-checked) and `test/Scenarios.spec.luau` (run against the prototype).

### B. Visibility predicates

Each archetype registers `canSee(viewer, entity) -> boolean`, and core asks it for every pair it needs:

```lua
Statuh.visibility(C.Unit, function(viewer, unit)
	return world:get(unit, C.Team) == teamOf(viewer) or teamVision(teamOf(viewer))[cellOf(unit)] ~= nil
end)
```

It reads naturally at first, but it can't be evaluated incrementally: a predicate can read anything, so core can't know what to re-evaluate, and it ends up at O(viewers × entities) per frame. It has no fail-closed default, since a forgotten `if` is a leak, and it invites what the game-code guardrails forbid, such as branching on secrets.

### C. Interest channels (publish/subscribe keys)

Every entity publishes to channel keys and every client subscribes to some; a client sees an entity when the two sets meet:

```lua
Statuh.publish(redPlan, "team:red")
Statuh.subscribe(alice, { "public", "team:red", "player:" .. alice })
```

Channels are fast and easy to make incremental, and they split membership from audience by construction. But they're untyped strings outside the world (not queryable, typos are silent), AND across kinds (team *and* in view) needs a second mechanism, and children following a parent means copying channels by hand.

### Scoring

✔ by construction, ◐ needs discipline or extra machinery, ✘ works against it.

| | A. Grants and needs | B. Predicates | C. Channels |
|---|---|---|---|
| 1 LEAVE/DEL/ROLLBACK distinct | ✔ (core) | ✔ (core) | ✔ (core) |
| 2 unknown reads | ✔ a component is hideable exactly when its visibility isn't "all"; HIDE is distinct from REM | ◐ predicates hide why something is absent | ✔ |
| 4 no out-of-scope id on the wire | ✔ core redacts refs and pairs | ◐ a predicate call per reference per viewer | ✔ |
| 5 fail closed, removing never widens | ✔ grants only add; checked by the fuzz | ✘ a predicate can return true from anything | ◐ ordered unsubscribe/subscribe |
| 6 revoke now (interest is game code) | ✔ every scope change is immediate | ✘ can't tell security from interest | ◐ per-channel flag |
| 7 fixed order, atomic groups | ✔ VisibleThrough defines the groups | ◐ groups invisible to core | ◐ copied channels aren't a group |
| 9 recursive arg checks | ✔ scope is data at the base canon | ✘ re-running predicates at a past canon | ✔ |
| 11 incremental, declared dependencies | ✔ hooks plus `dependsOn` | ✘ | ✔ |
| Game: membership vs audience distinct | ✔ different relations, typed helpers | ◐ ad hoc | ✔ |
| Game: interest from server-validated state | ✔ `dependsOn` lists server components | ✘ | ◐ |
| Typing | ✔ phantom-typed rooms and players; closed unions | ◐ | ✘ strings |
| Cost per frame | O(dirty × viewers changed), bitsets | O(viewers × entities) | O(dirty × keys) |

Guardrails 3, 8 and 10 are core's in all three.

**Choice: A.** Only in A do the guardrails hold by construction rather than by care. Grants only add and needs only narrow, so fail-closed and "removing never widens" are properties of the data model. Visibility is ordinary jecs data, so it's queryable and changes through the same hooks that drive frames. C survives inside A, as the mechanism (below), and B only as a warning of what "natural" looks like before it leaks.

## The chosen design, precisely

The prototype implements this, and `ScopeOracle.luau` is its executable reference.

**Principals.** One idea carries everything: a viewer *holds* principals, and an entity is *granted* to some and may *need* some.

- A viewer holds: everyone (`ALL`), its own player entity, and the rooms it's a member of. Each scope rule is a space of its own principals (cells, chunks), and its `viewerKeys` say which ones the viewer holds.
- An entity is granted to: `ALL` if it has `Net.Public`, its `Audience` rooms, its `Owner`s, and its key under each grant rule.
- An entity needs: per `Net.VisibleTo` its owners (`"owner"`), a room, or nothing anyone holds (`"server"`); and its key under each restrict rule. A viewer must hold one principal of each need.
- A component's visibility is a need of its own: `"all"` (none), `"owner"` (its entity's owners), or a rule (its entity's key under that rule).

So rooms, owners, Public, overrides, rules and component visibility are one mechanism. Because players and rooms are both principals, an `Owner` or a `VisibleTo` that names a room means the room's members.

**Inheritance.** Following `VisibleThrough` up from the entity:

```
final(e) = (holders(grants(e)) ∪ final(target(e))) ∩ holders(needs(e))
```

The walk stops at an entity with no target, at a target that isn't replicated, or at an entity it has already visited, so a loop shares its members' grants. Computed scope is `final`, plus the prediction pin.

**Consequences.**

- **Nothing granted, nobody sees.** An entity with no grants is invisible.
- **Removing a grant, a membership, rule data or a `VisibleThrough` link only shrinks scope,** and so does adding a need. Since scope is permission only, this covers everything a client receives, component visibility included.
- **Removing an override is the one way to widen by removal:** a deliberate reveal, like `Net.override(boss, nil)`.
- **Rules are latched when the entity starts replicating,** so they can't fall off when a component is removed. A rule that only decides a component's visibility needs no `appliesTo`. **A nil key matches nobody.**
- **Archetype defaults are grants applied once:** `setDefaultPublic(C.Enemy)` adds `Net.Public` at spawn, visibly, and never acts as a fallback.
- **`VisibleThrough` names an entity and has one target** (it's exclusive), so removing a pair can't promote another. Game relations (`ChildOf`, Held, OwnedBy) have no say in visibility; a replicated relation's pairs are data, sent while both ends are delivered. **Deleting a target ends inheritance,** and the entity falls back to its own grants, failing closed.

**Frames.** Each client gets, per frame:

1. **ENTER.** An inheritance group (an entity with its entering inheritors) enters whole and is never split by `enterBudget`. Parents and reference targets go before the entities that need them. Components the client may not see are left out.
2. **Ops (SET/HIDE/REM).** References to entities the client lacks are `REDACTED`, and re-sent when the target enters. A component that becomes visible gets SET; one that stops being visible but still exists, HIDE; one that's removed, REM.
3. **Pairs (PAIR_REM/PAIR_ADD),** only between entities the client has.
4. **LEAVE,** at once when scope is lost: there's no lingering in core. A game that wants lingering keeps old cells in its rule's keys (the RTS scenario does).
5. **DEL,** only to clients that had the entity.
6. **ROLLBACK,** for predicted spawns the server didn't make.

When a client loses an entity (LEAVE or DEL) it strips pairs to it and redacts its own references to it, without cleanup traits.

**Unknown reads (guardrail 2).** At ENTER a client can't tell a hidden component from a missing one, since a "hidden" mask would reveal that hidden data exists, so predicted code treats an absent hideable component as unknown. After the client has held it, HIDE and REM say which happened.

**Prediction.** `clientMinted(player, seq, netId)` records a predicted spawn; `bindMinted(entity, player, netId)` gives the server's entity that id and pins the client into its scope until `acknowledge`; an action acknowledged without its spawn gets ROLLBACK.

### Living with jecs 0.11.0-quenty.3

Statuh is built on the vendored jecs, which has six bugs (`experiments/jecs-findings/`). By the owner's rule they stay here: nobody contacts the jecs project. Statuh works around them: destroying an entity goes through a safe delete (`Net.destroy`, `JecsWorkarounds.delete` underneath); `Net.visibleThrough` removes the old pair before adding the new one, since retargeting an exclusive relation in place can later drop the entity from every query; nothing removes `pair(R, jecs.Wildcard)`; and tests check jecs's own bookkeeping every frame (invariant 0), which comparing the engine with the oracle can't, as both read the same world. In the fuzz, plain jecs calls hit a jecs bug in 80 of 1,000 seeds within 60 frames, all caught by invariant 0; with the workarounds, none of 6,000 do.

### Where this departs from the reference notes, and why

| Reference v2 says | Prototype does | Why |
|---|---|---|
| VisibleThrough "inherits the parent's viewer set"; cycles or depth beyond a limit mean invisible. | VisibleThrough is a grant added to the entity's own; the walk stops at an entity already visited, so a loop shares grants. | The fuzz found "deep or cyclic means invisible" isn't monotone: removing a link near the root brings a deep descendant back within the limit, widening visibility (guardrail 5). The owner chose the no-revisit walk over a hop limit. |
| `pair(Net.VisibleThrough, jecs.ChildOf)` follows a relation, exclusive with delete-with-target. | `pair(Net.VisibleThrough, target)` names the entity and is exclusive. No game relation affects visibility. | The owner's call: Attached, Held or OwnedBy are game data. Naming the entity drops the delete-with-target requirement. Exclusivity stays: the fuzz found that with two pairs, removing one promoted the other, which widened. |
| Custom rules are key functions (one kind). | Two modes, `grant` and `restrict`. | Fog of war is a union ("own team, or anyone whose vision covers the cell"); an AND-only rule would hide your own units from you. |
| Revoke immediately; relevance with hysteresis, in core. | Scope is permission only; a camera is a restrict rule and lingering is game code. | The owner's call: nearness is per game. It also makes "removing never widens" hold for all of scope; with relevance in core, removing a link could widen relevance. |
| `visibleTo = "owner"` on a component. | `"all"`, `"owner"` or any rule (`Statuh.rule("near")`); HIDE is distinct from REM. | So a far-away player arrives as a name and a team (the arena). HIDE vs REM is LEAVE vs DEL for components. |
| Per-archetype default, `private` unless set otherwise. | Defaults are grants applied once at spawn. | A default that applies when an entity "has no rule" is a fallback: stripping rules would widen, and a team swap could flash an entity public. |

## Typing

`types/Statuh.luau` gives the API types: phantom-typed `Room` and `PlayerEntity` entities, a schema library whose values are typed as what they validate (so `S.struct({ ... })` infers the component type), closed unions for overrides, rule modes and visibility (a rule is named with `Statuh.rule(name)`), and a generic rule key. `lune run experiments/statuh-scope/types/check.luau` type-checks it and `examples/*.luau` with the old solver, and checks that each of the 15 lines marked `-- expect-error` in `mustfail/` errors, for the intended reason: `types OK: 5 files type-check, 15 must-fail lines all fail`. Caught: a swapped `Net.join(world, room, player)`, a player where an audience room goes, an override of `"everyone"` or a player, a room as a `VisibleThrough` target, a wrong component value or a struct missing a field, `visibleTo = "owners"` or a bare rule name, `S.instance()` (no Instances in replicated data), the mode `"relevance"`, strings in `dependsOn`, rule keys that disagree, and treating `removalKind` as only LEAVE or DEL or `componentRemovalKind` as only REM.

Old-solver limits found along the way: key agreement is only checked when `key` and `viewerKeys` aren't annotated; unannotated rule functions that return `{}` in one branch don't infer, so `viewerKeys` needs `: { [number]: true }` (a mismatched key fails closed at runtime); and a bad mode is reported on the rule's table rather than its `mode` field.

## Prototype

**Data.** Viewer sets are two 32-bit words (up to 64 clients). Each space (the built-in one, and one per rule) keeps who holds each principal and which entities watch it. Each entity caches its grants and needs as principal lists, their viewer bits, its authorized, delivered and pending sets, and per component the clients that hold it. Reverse indexes cover `VisibleThrough` target → inheritors and target → entities referring or paired to it. jecs hooks only mark things dirty; all reading happens in `frame()`.

**Per frame:**

1. Settle new entities (latch rules, apply defaults, index references), refresh the principals of viewers whose memberships or rule inputs changed, and re-read changed entities' grants, needs and pairs.
2. Spread dirtiness to inheritors, recompute viewer bits, fold inheritance, and turn changes into pending ENTERs and immediate LEAVEs.
3. Per client: ENTER, ops, pairs, LEAVE. Then removals (LEAVE if the entity is alive, DEL if not) and ROLLBACKs.

### Tests

**Scenario specs** (`test/Scenarios.spec.luau`, 20 tests) run the four games: team plans and owner-only gold; a team swap revoked at once, never public in between; references redacted, fixed up, and redacted by the client when it loses the target; DEL vs LEAVE; enemies made public as they spawn; a predicted spawn pinned until acknowledged, and a ROLLBACK; fog reveal and revoke with the weapon in the same frame; a camera as a restrict rule, and lingering kept by the game; the boss reveal; loot rolls changing owner (HIDE for the old one); quitting (LEAVE) vs the boss dying (DEL); a late spectator joining through budgeted ENTERs; and the arena (a far-away player as a name and a team, position and animation shown near and hidden away, REM on removal, the viewer walking up, Held vs VisibleThrough, the holder deleted).

**Invariants**, checked by `ScopeHarness` after every frame of every scenario and fuzz run:

0. **jecs integrity** (`JecsWorkarounds.checkIntegrity`), before anything reads the world.
1. **Protocol.** Phase order, and no message mentions an id the client doesn't have (except the subject of ENTER and ROLLBACK).
2. **Oracle agreement** for every entity and client.
3. **No out-of-scope net id** in any message, references included.
4. **Projection.** Every client equals the server world projected onto its delivered scope, with each component's own visibility.
5. **Delivered scope equals authorization** (or pending under a budget).
6. **LEAVE vs DEL and HIDE vs REM** are never confused.
7. **Inheritance groups enter whole.**

Plus, at random points, a narrowing edit, after which the oracle checks that authorization and restricted component data only shrank.

**Fuzz** (`test/Invariants.spec.luau`, `src/FuzzWorld.luau`): 3 rooms and 6 players who connect and disconnect; grants, needs, and `VisibleThrough` chains retargeted, dropped and closed into loops; grant and restrict rules and a component visible only through a rule; references, owner-only data, unreplicate/re-replicate, deletes with cascades (through the jecs workarounds; `JECS_WORKAROUNDS=0` runs plain calls); 0–6 random edits per frame. Failures print the seed and frame for `tools/replay.luau` and `tools/trace.luau`. The spec runs 150 seeds × 40 frames plus 100 × 40 with an ENTER budget of 2. **Soak:** 3,000 seeds × 60 frames plus 3,000 × 60 with budget 3, 360,000 checked frames, **0 failures** (about 105 s each).

The tests catch a broken core. Making it send REM instead of HIDE, skip re-evaluating entities when a viewer gains a principal, skip the reference fix-up, or cut inheritance at the parent each fails the fuzz (and all but the last, the scenarios).

The fuzz found these in the prototype, all fixed: non-monotone depth limits; a second VisibleThrough pair promoting a different parent; references from an entity entering before its target in the same frame never fixed up; a DEL sent to a new player that reused a disconnected player's index; owner-only data leaking when ownership and the value changed in the same frame; and a stale parent after a reparent. It and the jecs-only search also found the six jecs bugs above.

### Cost

`bench/bench.luau` loads jecs and the core with codegen. 50 players and 2,000 entities (40% public, 40% team-only, 10% owner-owned with owner-only data, 10% visible through a parent); each frame 100 entities change a value, 100 move cells, and 5 cameras move.

| Scenario | Per frame avg | p50 | p95 | Messages/frame | Join frame (all 50 players) |
|---|---|---|---|---|---|
| Teams, public, owner, inheritance | 4.7 ms | 4.0 | 9.8 | 4,206 | 365 ms, 61,993 ENTERs |
| + camera rule, cameras pan one chunk | 3.7 ms | 3.2 | 5.7 | 1,131 | 137 ms, 20,949 ENTERs |
| + camera rule, cameras teleport (18 chunk keys change per move) | 13.3 ms | 12.5 | 19.4 | 3,200 | 130 ms |
| teleport + ENTER budget 64 per client per frame | 17.3 ms | 16.3 | 26.5 | 2,846 | 71 ms, 3,143 ENTERs |
| No camera rule; cell position only to cameras near it, pan | 5.4 ms | 4.9 | 8.1 | 2,918 | 450 ms, 61,993 ENTERs |

Lune on a Linux x86 container, single-threaded; numbers vary about 10–15% between runs. They compare designs; they don't predict a Roblox server. Steady state is O(dirty × clients that have them); the join frame is O(entities × clients), so joins should be budgeted. Teleporting cameras are the worst case, re-keying 18 chunks and dirtying about 560 entities per move. The principal rewrite is 5–35% slower per frame than the first version of the core, which kept more special cases; with this much run-to-run noise, part of that is noise.

Not done yet: a per-viewer path for viewer-key changes instead of recomputing whole entities, and the notes' encoded-chunk cache per (entity, mask class).

## Compared with fanon (statuh v1, `legacy-reference/`)

- **Removal kinds.** v1 had one removal (DEL), so "left your view" and "destroyed" were the same. Here LEAVE, DEL and ROLLBACK reach the client distinct, and so do HIDE and REM.
- **Diffstep compaction.** v1's `DiffstepBuilder` keeps the last write per key and lets a DEL deactivate everything naming it. Scope frames read ops from the world at frame time, so a key written many times is sent once, and HIDE/REM go only to clients holding the component (v1's "drop ops on a key that never reached the client"). v1's NEW → DEL → NEW collapse was only safe because names were never reused; Statuh 2 net ids aren't reused either.
- **Inverse log.** v1's `InverseDiffstepBuilder` is the client-side undo for prediction. Statuh 2 saves the server value on first predicted write, restores and re-runs; the scope core's side is ROLLBACK and the pin.
- **Canon/ack.** v1 catches a joining player up with all compacted diffsteps in batches of 100 and a per-player warp, then switches to realtime frames with a canon number and ack. Here catch-up is budgeted ENTERs of the player's own scope, and the warp is unnecessary because ENTER reads current state. Frames still need the canon number, ack, and per-client hash over delivered scope (guardrail 10); the prototype has no transport, so these aren't modeled.
- **Trust.** v1 never checked client name prefixes. `bindMinted` asserts the id is unused, and the notes' per-author range check goes in the same place.
- **v1 tests as a spec.** Their scope-relevant parts (a DEL hides everything about the name; relations to a deleted target vanish) map to invariants 4 and 6 and the pairs rule. The rest is prediction.

## Open questions

1. **A component visible to "owners, or whoever is near".** A component has one visibility. Should `visibleTo` take a list, as a union?
2. **Hidden or absent at ENTER.** Is the leak of a "hidden" mask worth taking for some components, so predicted code knows more?
3. **Overrides that widen.** Is there a case for an override that grants (show this one entity to spectators)? Today that's an Audience grant.
4. **Key agreement under the old solver** is only enforced for unannotated rules; worth revisiting on the new solver.
5. **Rule latching** means adding `appliesTo` after spawn doesn't subject an entity to a rule. An error in debug builds?
6. **Join cost** (~130–450 ms here) says joins must be budgeted. What budget, and should globals go first (`rt.net.ready()`)?
7. **Game guardrail 5** ("never delete a VisibleThrough target without a cascade") no longer protects anything. Drop it from the notes?
8. **A direct `world:delete` or retarget in game code** takes jecs's broken path. Should debug builds check jecs's integrity every frame, as the tests do?
