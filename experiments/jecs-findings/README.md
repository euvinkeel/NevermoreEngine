# jecs findings

Two bugs in the vendored `@quentystudios/jecs` 0.11.0-quenty.3, found by the Statuh scope fuzz tests (`experiments/statuh-scope`). Each script is a minimal repro:

| Script | Bug |
|---|---|
| `cascade_delete_skips_moved_child.luau` | Deleting a parent can leave a `ChildOf` child alive with a dangling pair to the dead parent. It happens when a sibling's deletion moves the child to another archetype mid-cascade, for example because the child held an ordinary relation pair to that sibling. Once the parent's id is recycled, the dangling pair resolves to an unrelated new entity. |
| `wildcard_remove_corrupts_entity.luau` | `world:remove(e, pair(R, jecs.Wildcard))` fires OnRemove hooks, leaves the pair in place, and corrupts the entity's other columns: `has` returns true while `get` returns nil. |

Run them with `lune run experiments/jecs-findings/<script>`.

No Nevermore source uses wildcard removal (checked with grep). The cascade bug can affect any game whose `ChildOf` children hold relation pairs to their siblings. The fuzz tests work around both bugs (see `experiments/statuh-scope/src/FuzzWorld.luau`). I haven't checked whether upstream jecs has the same bugs.
