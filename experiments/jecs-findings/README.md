# jecs findings

Six bugs in the vendored `@quentystudios/jecs` 0.11.0-quenty.3, each with a minimal repro, and workarounds that keep a world consistent on that version. The Statuh scope fuzz tests (`experiments/statuh-scope`) and the random search in this folder found them.

**These stay here.** By the owner's rule, nobody contacts the jecs project about them: no issues, pull requests, discussions or comments on its repository. We work around them.

| Script | Bug |
|---|---|
| `delete_corrupts_survivor.luau` | Deleting an entity can corrupt another entity that survives the delete and holds an ordinary relation pair to it. Afterwards the survivor still has the pair to the dead entity, `has` returns true for its data and `get` returns nil, and no OnRemove hook fired. No cascade is needed: it's enough that some entity once held a `ChildOf` pair and another pair to the deleted entity at the same time, as a weapon that's `ChildOf` and `VisibleThrough` its unit does. |
| `cascade_delete_skips_moved_child.luau` | Deleting a parent can leave a `ChildOf` child alive with a dangling pair to the dead parent. It happens when a sibling's deletion moves the child to another archetype mid-cascade, for example because the child held an ordinary relation pair to that sibling. Once the parent's id is reused, the dangling pair resolves to an unrelated new entity. |
| `cascade_delete_crashes.luau` | Deleting a parent errors inside jecs ("attempt to perform arithmetic (mod) on nil and number") when two of its children hold relation pairs to a grandchild. |
| `delete_bare_entity_corrupts_another.luau` | Deleting an entity that has no components can corrupt another entity's data: an entity that once lost all its components and later gained new ones. |
| `exclusive_retarget_loses_entity.luau` | Retargeting an exclusive relation (reparenting with `ChildOf`, which is exclusive, or moving `VisibleThrough`) can make an entity vanish from every query, even one for a plain component. `has` still says it has the pair, and `target` returns nil. It takes the new target being deleted and its id reused. |
| `wildcard_remove_corrupts_entity.luau` | `world:remove(e, pair(R, jecs.Wildcard))` fires OnRemove hooks, leaves the pair in place, and corrupts the entity's other data: `has` returns true while `get` returns nil. |

Run them with `lune run experiments/jecs-findings/<script>`.

## Workarounds

`JecsWorkarounds.luau` keeps jecs off the broken code paths:

- **`JecsWorkarounds.delete(world, entity)`** instead of `world:delete(entity)`. It first removes every ordinary pair that points into what the delete will take with it (the entity and its `ChildOf` descendants), from survivors and doomed entities alike. Then jecs's own cleanup never has to move a surviving entity. An entity with no components gets a tag first, so it isn't deleted through the root archetype. This covers the first four bugs.
- **`JecsWorkarounds.setTarget(world, entity, relation, target)`** to reparent, or to point any exclusive relation somewhere else. It removes the old pair before adding the new one, so jecs never replaces a target in place.
- **`JecsWorkarounds.removeAll(world, entity, relation)`** instead of removing `pair(relation, jecs.Wildcard)`. It removes one target at a time.
- **`JecsWorkarounds.checkIntegrity(world)`** reads jecs's bookkeeping and reports the damage these bugs leave. Tests should run it after every step. Comparing two readers of the same world, like the Statuh engine and its oracle, can't see this damage, because both read it.

The evidence that this is enough:

- **`JecsWorkarounds.spec.luau`** (14 tests): each workaround against its bug, and a randomized check. A second block asserts that each bug is still present, so a jecs upgrade that fixes one fails there; then its workaround can go. Run it with `lune run tools/lune-headless/run.luau experiments/jecs-findings`.
- **`search.luau`** runs `RandomWorld.luau`: random operation sequences, checked after every operation against a plain model of the world and against `checkIntegrity`. The operations are deletes with cascades, ordinary and exclusive relations, reparenting and retargeting, remove-alls, and id reuse. With plain jecs calls, 2,975 of 10,000 seeds (60 operations each) go wrong. With the workarounds, none do.
- **The Statuh fuzz** deletes and retargets through the workarounds and checks `checkIntegrity` every frame: 0 of 6,000 seeds fail. With plain jecs calls (`JECS_WORKAROUNDS=0`), 87 of 1,000 seeds fail, all at the integrity check.

Limits:

- `delete` handles pairs. It doesn't handle deleting an entity that is itself used as a component or as a relation.
- It treats a relation as cascading when it has `pair(jecs.OnDeleteTarget, jecs.Delete)`, like `ChildOf`.
- The workarounds only help code that calls them; a direct `world:delete` or `world:add` takes the broken path.

## Causes

- **Survivor corruption.** `world_delete` walks every archetype that holds a pair to the deleted entity and collects the pairs to remove in a table, `to_remove`, that is shared across the walk and cleared at the end of each step. When an archetype also holds a `ChildOf` pair, the walk deletes its entities and `continue`s past the clear, so that archetype's other pairs leak into the next step. With one real pair and a leaked one, `next(to_remove)` can return the leaked pair, which the next archetype doesn't have. Removing it resolves to the same archetype, so each entity there is appended to its own archetype a second time and loses its row's data. The wildcard remove bug ends the same way: a remove that resolves to the entity's own archetype. Adding `table.clear(to_remove)` before that `continue` fixes this bug and the fuzz seed that found it. I tested that on a scratch copy; the vendored jecs is unchanged.
- **Skipped child.** That same walk fixes its range when it starts. A nested delete (of a sibling) can move a child into an archetype that didn't exist yet, which is appended past the end of the range, so the walk never reaches it.
- **Deleting an entity with no components.** An entity that loses its last component moves into the root archetype and is listed there. When it gains a component again it moves out but stays listed. Deleting an entity that sits in the root archetype rewrites the record of the list's last entry, which may be an entity that has since moved on. A fresh entity that never had a component sits in the root archetype at row 0.
- **Exclusive retarget.** Replacing an exclusive target in place caches the move as a one-way link between the two archetypes. Deleting the new target destroys the archetype that held pairs to it, but the link stays. Pairs don't carry generations, so once the target's id is reused, the next retarget from the same archetype follows the stale link into the destroyed archetype.
- **Cascade crash.** Not tracked down. The `delete` workaround avoids it.

## Impact

- **Who is exposed.** Any game on this jecs version that deletes entities other entities point at, reparents with `ChildOf`, retargets exclusive relations, or deletes entities with no components.
- **Nevermore's own jecs code.** The immediate-mode hooks in `src/jecs` build `ChildOf` trees of hook state and delete them. They re-add the same `ChildOf` pair each frame, which jecs skips, so they only reach the reparent path if a hook state's parent changes. I haven't checked whether that can happen. No Nevermore source uses wildcard removal (checked with grep). Nothing in `src/` was changed.
