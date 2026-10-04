# jecs findings

Four bugs in the vendored `@quentystudios/jecs` 0.11.0-quenty.3, found by the Statuh scope fuzz tests (`experiments/statuh-scope`) and a jecs-only random search (`experiments/statuh-scope/tools/jecs_delete_search.luau`). Each script is a minimal repro:

| Script | Bug |
|---|---|
| `delete_corrupts_survivor.luau` | Deleting an entity can corrupt another entity that survives the delete and holds an ordinary relation pair to it. Afterwards the survivor still has the pair to the dead entity, `has` returns true for its data and `get` returns nil, and no OnRemove hook fired. No cascade is needed. The condition is that some entity once held a `ChildOf` pair and another pair to the deleted entity at the same time, as a weapon that's `ChildOf` and `VisibleThrough` its unit does. Cause and a one-line fix are below. |
| `cascade_delete_skips_moved_child.luau` | Deleting a parent can leave a `ChildOf` child alive with a dangling pair to the dead parent. It happens when a sibling's deletion moves the child to another archetype mid-cascade, for example because the child held an ordinary relation pair to that sibling. Once the parent's id is recycled, the dangling pair resolves to an unrelated new entity. |
| `cascade_delete_crashes.luau` | Deleting a parent errors inside jecs ("attempt to perform arithmetic (mod) on nil and number") when two of its children hold relation pairs to a grandchild. Five operations; same family as the one above. |
| `wildcard_remove_corrupts_entity.luau` | `world:remove(e, pair(R, jecs.Wildcard))` fires OnRemove hooks, leaves the pair in place, and corrupts the entity's other columns: `has` returns true while `get` returns nil. |

Run them with `lune run experiments/jecs-findings/<script>`.

## Cause of the survivor corruption

`world_delete` walks every archetype that holds a pair to the deleted entity and collects the pairs to remove in a table, `to_remove`, that is shared across the loop and cleared at the end of each pass. When an archetype also holds a `ChildOf` pair (a delete policy), the loop deletes that archetype's entities and `continue`s, skipping the clear. That archetype's other pairs then leak into the next pass. With one real pair and a leaked one, `next(to_remove)` can return the leaked pair, which the next archetype doesn't have. Removing it resolves to the same archetype, so each entity is appended to its own archetype a second time and loses its row's data. The wildcard remove bug ends the same way, through a remove that resolves to the entity's own archetype.

Adding `table.clear(to_remove)` before that `continue` fixes `delete_corrupts_survivor.luau` and the fuzz seed that found it. I tested that on a scratch copy of jecs and haven't changed the vendored one. The patch doesn't fix the two cascade bugs, which have a different cause I haven't tracked down.

## Impact and workaround

No Nevermore source uses wildcard removal (checked with grep). The delete bugs can affect any game that keeps relation pairs pointing at entities it deletes. The survivor corruption needs only an entity that was once both `ChildOf` and otherwise related to the deleted one, which is the normal shape of attached items. The fuzz tests work around all three delete bugs: before every delete, they remove every pair pointing into the deleted set (see `safeDelete` in `experiments/statuh-scope/src/FuzzWorld.luau`). I haven't checked whether upstream jecs has the same bugs.
