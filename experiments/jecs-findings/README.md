# jecs findings

Six bugs in the vendored `@quentystudios/jecs` 0.11.0-quenty.3, and workarounds that keep a world consistent on that version. The Statuh scope fuzz tests (`experiments/statuh-scope`) and the random search here found them.

**These stay here.** By the owner's rule, nobody contacts the jecs project about them: no issues, pull requests, discussions or comments on its repository. We work around them.

| File | What |
|---|---|
| `JecsBugs.luau` | The six bugs, each a minimal scenario that runs with plain jecs calls (showing the bug) or through the workarounds (avoiding it). |
| `JecsWorkarounds.luau` | The workarounds: a safe delete, a safe retarget, a remove-all, and an integrity check. |
| `RandomWorld.luau` | Random operation sequences checked after every operation against a plain model and the integrity check. |
| `JecsBugs.spec.luau` | Every bug both ways, plus 1,000 random worlds through the workarounds. |
| `check.luau` | Prints how each bug shows on the installed jecs, and the random search both ways. After a jecs upgrade, it says which workarounds can go. |

```bash
lune run tools/lune-headless/run.luau experiments/jecs-findings   # the spec (14 tests)
lune run experiments/jecs-findings/check.luau [seeds] [steps]
```

## The bugs

1. **A delete can corrupt an entity that survives it,** when the survivor holds an ordinary relation pair to the deleted entity. Afterwards the survivor still has the pair to the dead entity, `has` returns true for its data and `get` returns nil, and no OnRemove hook fired. No cascade is needed. It's enough that some entity once held a `ChildOf` pair and another pair to the deleted entity at the same time, as a weapon that's `ChildOf` and `VisibleThrough` its unit does.
2. **A cascade can leave a `ChildOf` child alive** with a dangling pair to the dead parent, when a sibling's deletion moves the child to another archetype mid-cascade. Once the parent's id is reused, the dangling pair resolves to an unrelated new entity.
3. **A cascade can crash** ("attempt to perform arithmetic (mod) on nil and number") when two children hold relation pairs to a grandchild.
4. **Deleting an entity with no components can corrupt another entity's data:** one that once lost all its components and later gained new ones.
5. **Retargeting an exclusive relation can drop an entity from every query,** even one for a plain component, once the new target is deleted and its id reused. `has` still says it has the pair, and `target` returns nil. Reparenting with `ChildOf` (which is exclusive) and moving `VisibleThrough` are both retargets.
6. **`world:remove(e, pair(R, jecs.Wildcard))`** fires OnRemove hooks, leaves the pair in place, and corrupts the entity's other data.

## Workarounds

- **`JecsWorkarounds.delete(world, entity)`** instead of `world:delete(entity)`. It first removes every ordinary pair that points into what the delete takes with it (the entity and its `ChildOf` descendants), from survivors and doomed entities alike, so jecs's own cleanup never has to move an entity. An entity with no components gets a tag first, so it isn't deleted through the root archetype. This covers bugs 1 to 4.
- **`JecsWorkarounds.setTarget(world, entity, relation, target)`** to reparent, or to point any exclusive relation somewhere else. It removes the old pair before adding the new one, so jecs never replaces a target in place (bug 5).
- **`JecsWorkarounds.removeAll(world, entity, relation)`** instead of removing `pair(relation, jecs.Wildcard)` (bug 6).
- **`JecsWorkarounds.checkIntegrity(world)`** reports the damage these bugs leave in jecs's bookkeeping. Tests should run it after every step. Comparing two readers of the same world, like the Statuh engine and its oracle, can't see this damage, because both read it.

The evidence that this is enough:

- **The random search:** with plain jecs calls, 349 of 2,000 seeds (40 operations each) go wrong; with the workarounds, none do. At 10,000 seeds × 60 operations it's 2,975 and none.
- **The Statuh fuzz** deletes and retargets through the workarounds and checks `checkIntegrity` every frame: 0 of 6,000 seeds fail. With plain jecs calls (`JECS_WORKAROUNDS=0`), about 8% of seeds fail, all at the integrity check.

Limits:

- `delete` handles pairs. It doesn't handle deleting an entity that is itself used as a component or as a relation.
- It treats a relation as cascading when it has `pair(jecs.OnDeleteTarget, jecs.Delete)`, like `ChildOf`.
- The workarounds only help code that calls them; a direct `world:delete` or `world:add` takes the broken path.

## Causes

- **Bug 1.** `world_delete` walks every archetype that holds a pair to the deleted entity and collects the pairs to remove in a table, `to_remove`, shared across the walk and cleared at the end of each step. When an archetype also holds a `ChildOf` pair, the walk deletes its entities and `continue`s past the clear, so that archetype's other pairs leak into the next step. `next(to_remove)` can then return a leaked pair the next archetype doesn't have. Removing it resolves to the same archetype, so each entity there is appended to its own archetype a second time and loses its row's data. Bug 6 ends the same way, through a remove that resolves to the entity's own archetype. Adding `table.clear(to_remove)` before that `continue` fixes bug 1; I tested that on a scratch copy and left the vendored jecs unchanged.
- **Bug 2.** That walk fixes its range when it starts. A nested delete (of a sibling) can move a child into an archetype that didn't exist yet. The new archetype is appended past the end of the range, so the walk never reaches it.
- **Bug 3.** Not tracked down.
- **Bug 4.** An entity that loses its last component moves into the root archetype and is listed there. When it gains a component again it moves out but stays listed. Deleting an entity that sits in the root archetype rewrites the record of the list's last entry, which may be an entity that has moved on. A fresh entity that never had a component sits in the root archetype at row 0.
- **Bug 5.** Replacing an exclusive target in place caches the move as a one-way link between the two archetypes. Deleting the new target destroys the archetype that held pairs to it, but the link stays. Pairs don't carry generations, so once the target's id is reused, the next retarget from the same archetype follows the stale link into the destroyed archetype.

## Impact

- **Who is exposed.** Any game on this jecs version that deletes entities other entities point at, reparents with `ChildOf`, retargets exclusive relations, or deletes entities with no components.
- **Nevermore's own jecs code.** The immediate-mode hooks in `src/jecs` build `ChildOf` trees of hook state and delete them. They re-add the same `ChildOf` pair each frame, which jecs skips, so they only reach the reparent path if a hook state's parent changes. I haven't checked whether that can happen. No Nevermore source uses wildcard removal (checked with grep). Nothing in `src/` was changed.
