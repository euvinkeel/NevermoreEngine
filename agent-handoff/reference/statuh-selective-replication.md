# Statuh 2.0: selective replication (design notes, v2)

**For the owner. Not part of the cloud agent's mission.** Draft v1 was written from research on Replecs, duplecs, replicon, lightyear, naia, Unity, Unreal, SS14, Zero, Replicache, Linear, SpacetimeDB and Colyseus. An adversarial review then attacked it; this version applies its fixes.

## Short answer
Per-client replication doesn't break Statuh's action/prediction model. Replicache and Zero already run optimistic mutators on partial data, and the server's full-state run wins.

What it does break:
1. **Shortcuts that assume everyone sees the same world:** one shared encoded frame, one global desync hash.
2. **Treating "left your view" as "destroyed".** Nearly every surveyed system does this. SS14 (detach) and naia's opt-in Persist are the exceptions.
3. **The idea that a client knows when it is missing data.** Queries and nil reads hide missing data silently.

The fixes below are mostly core rules, so the game-facing API can stay simple.

## Core model
- **Scope** is membership per (client, entity). It is separate from lifecycle. Core tracks *computed* scope (what the rules say) and *delivered* scope (what the client actually has; they differ while enter budgets apply). Checks, hashes, cues and streams use delivered scope.
- **Three removal kinds reach game code:**
  - `LEAVE`: out of scope.
  - `DEL`: destroyed.
  - `ROLLBACK`: a predicted spawn the server didn't make.

  Game code asks `rt.net.removalKind(e)`, or reads the per-tick lists `rt.net.left()`, `deleted()` and `rolledBack()`. No tags are added during removal, because that would mean structural changes inside jecs hooks.
- **On LEAVE the client forgets the entity.** It strips pairs pointing at it **without running cleanup traits**, so a parent leaving can't cascade-delete children that are still in scope. Re-entry sends full state. (`freeze`, which keeps the entity frozen and sends deltas on re-entry, is deferred: it costs clients × entities memory and reveals existence.)
- **Hidden net IDs never go on the wire:**
  - No pairs, fields, messages, results or cue subjects that reference an entity outside the receiver's delivered scope.
  - Entity fields pointing at hidden entities are sent as a `Redacted` sentinel. The server tracks reverse references per client and re-sends the field when the target enters.
  - Messages are delivered redacted, with no fix-up.
  - A DEL for a forgotten entity is never sent.
- **Fixed per-frame order:**
  1. ENTER: targets before referrers, and an inheritance group as one unit that is never split by budgets.
  2. Ops.
  3. Pair adds.
  4. LEAVE.
  5. DEL.

  Unreliable stream samples for IDs outside delivered scope, or older than the ENTER canon, are dropped.
- **Revocation vs relevance:** a LEAVE because visibility was revoked is immediate and never budgeted. A LEAVE because something is far away (relevance) lingers a few frames (hysteresis in core) to avoid flapping.
- **Owner pin:** a client stays in scope of entities it minted until the spawning action is acked, as an entity-level override. This is separate from `Net.Owner` and from who predicts.

## Prediction on partial state
A read is **unknown** if it:
1. Touches an entity outside the client's delivered scope.
2. Returns nil from a component or relation declared *hideable*. Present means known; absent means unknown.
3. Is a query. Queries are complete only inside coverage the client can prove, for example its own entities under the owner pin. Otherwise they are unknown, like Zero's `complete | unknown`.
4. Touches state an earlier, unpredicted pending action could write. The simple version is prefix taint: once one action is unpredicted, the ones after it are too.

**Execution:** the run aborts at the first unknown read and discards *all* of its effects: writes, cues, minted IDs and rng draws.

**Sending:** the action is **always sent**. A local rejection suppresses the send only when the action opts in (`localReject = true`) *and* the run was complete and untainted. This removes the "valid input silently lost" bug.

**Latching:** once an action is unpredicted, it stays unpredicted until its ack. No flip-flopping as scope churns.

**Status:** the action handle reports `predicted | unpredicted | rejectedLocally`, so games can show a pending indicator.

**Server:** entity args are checked recursively (nested fields too) against the caller's scope at the client's base canon, plus about 1 s of leave history. Hidden IDs, nonexistent IDs and out-of-range minted IDs all take one identical reject path: same reason, same frame. Minted IDs are validated by range, never by lookup.

## API: natural to express, closed by default
```lua
-- membership and audience are different relations
world:add(alice, pair(Net.Member, redTeam))         -- alice is in red
world:add(redIntel, pair(Net.Audience, redTeam))    -- only red sees it
world:add(map, Net.Public)                          -- explicitly public

-- per component, declared once; owner = pair(Net.Owner, player)
Inventory = Statuh.replicated(S.struct({...}), { visibleTo = "owner" })

-- children follow a parent (exclusive relation with delete-with-target required)
world:add(sword, pair(Net.VisibleThrough, jecs.ChildOf))

-- per-entity override
world:set(boss, Net.VisibleTo, "server")            -- or "owner" or a room

-- custom rules are key functions with declared dependencies, O(dirty)
rt.net.addScopeRule("chunks", function(entity) return chunkKeyOf(entity) end, { dependsOn = { C.Position } })
```
- **Combination:** OR within one relation (two Audience pairs means shared with both), AND across different kinds of constraint.
- **Fail closed:** entities without a rule follow a declared per-archetype default, `private` unless set otherwise, and removing a constraint never widens visibility. A team swap can't make something public for a frame.
- **`VisibleThrough`:** inherits the parent's viewer set (computed once, like lightyear's ReplicateLike). Cycles, or depth beyond a limit, mean invisible.
- **Scope pairs** (`Net.Member`, `Net.Audience`, ...) are server-only and never replicated, because they would leak team and chunk membership.
- **Interest uses server-validated positions,** never owner-written streams. Otherwise a cheater moves their focus to scout the map.

## Frames, cost, hashing (single-threaded Luau, 30–50 players)
- **Per-entity viewer bitset** (2 × 32 bits) and O(dirty × viewers) appends. Viewer-set grouping rarely helps with spatial interest.
- **Encoded chunk cache keyed by (entity, mask class).** Bytes are shared only when the baseline is the previous frame.
- **Per-client hash:** XOR of chunk hashes that include the net ID and mask class, over the confirmed layer at the same canon. Exclude pending state. Sample it in release builds.
- **Join is a series of budgeted ENTERs:** globals first, then `rt.net.ready()` once the initial set has arrived.

## Guardrails
**Core always:**
1. Keep LEAVE, DEL and ROLLBACK distinct all the way to game code.
2. Treat out-of-scope point reads, nil reads of hideable data, uncovered queries and tainted keys as unknown.
3. Abort unknown runs, discard all their effects, and send them anyway.
4. Never put an out-of-scope net ID on the wire.
5. Fail closed: removing a constraint never widens visibility.
6. Apply revocation immediately; apply relevance changes with hysteresis.
7. Use a fixed frame-atomic order (ENTER, ops, pairs, LEAVE, DEL), with groups entering atomically.
8. Strip pairs on LEAVE without running cleanup traits.
9. Check args recursively against scope at the base canon, with one identical reject path.
10. Use delivered scope for checks, hashes, cues and streams.
11. Evaluate scope incrementally, through key functions with declared dependencies.

**Game code never:**
1. Infers events (death, pickup) from disappearance. Use replicated state or cues.
2. Puts Roblox Instances in replicated data.
3. Branches on secrets in predicted code, or returns hidden data in rejection reasons or results.
4. Lets client-written state, including owner streams, drive that client's interest.
5. Deletes a VisibleThrough target without a cascade.
6. Reuses one relation for both membership and audience.

## Open questions
- Is `freeze` worth adding later, for cheap re-entry of big public objects?
- How much of spatial interest (chunk rooms, hysteresis) is core vs. a StatuhInterest addon?
- Randomized server net IDs, to hide spawn counts? Rekey on re-entry for secret identities?
- Prefix taint is conservative; is per-key taint worth the complexity?
