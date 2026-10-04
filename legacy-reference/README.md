# Legacy reference: statuh v1 / "fanon" netcode (read-only)

The netcode core from the owner's earlier tower defense game (Castle Towers, written in roblox-ts), copied here so the Statuh 2.0 work has something concrete to compare against. Only the networking core is included; game code is left out. **Read it, don't run or port it wholesale.** `agent-handoff/reference/statuh-2.0-overview.md` lists its known flaws.

| Path | What it is |
|---|---|
| `statuh/statuhTypes.d.ts` | The StatuhWorld interface: an ECS world abstraction with relationship hooks. |
| `statuh/jecsStatuh.ts`, `baseStatuh.ts`, `statuhRuntime.ts` | Backends: jecs, and a slow Map-based checker. |
| `statuh/statuhUtil.ts`, `statuhTests.ts` | Query helpers, snapshot/hash helpers, tests. |
| `fanon/statuhFanon.ts` | The replication runtime state: names, component keys. |
| `fanon/statuhFanonName.ts` | Net names `"{authorId}_{counter}"`. Note: `isLocalName` is buggy and unused, and the server never checks client name prefixes. |
| `fanon/statuhFanonDiffstep.ts` | The 8 diffstep ops; the DiffstepBuilder (last write wins per key, compacted) and the InverseDiffstepBuilder (first value seen per key, used for undo); marks and rebuild. |
| `fanon/statuhFanonHandle.ts` | Recording world proxy: forward plus inverse diffsteps per action. |
| `fanon/statuhFanonAction.ts` | `executeAction` (client predict) and `replayAction` (server replay with the client's created names). |
| `fanon/statuhFanonTests*.ts` | About 25 conformance tests plus a long multi-player case. Useful as a behavior spec. |
| `systems/server/*_fanon_*` | Server canon protocol: catch-up, then warp, then realtime; acks; epochs; batching. |
| `systems/client/*_fanon_*` | Client side: undo pending diffs, apply canon, re-apply unacked diffs (diff rebase). |
| `systems/*/*_stream_*` | Unreliable position/velocity/direction streams. |
| `config.zap` | The remote event definitions (Zap IDL). |

Imports point into the original game (`shared/actionsLookup`, `shared/sharedcomponents`, gameUtil, etc.), which isn't included, so these files won't compile here.
