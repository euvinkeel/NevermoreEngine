# Statuh 2.0: where the design stands

Statuh 2.0 is a proposed **server-authoritative netcode addon for immediateutils**: one jecs world per peer, the server in charge, and clients predicting their own actions. It doesn't exist yet. This file summarizes the decisions so far, so the scope work in HANDOFF M4 has something to build on.

## Lineage
- **v0 (`defender` project, 2025):** snapshot diffing.
- **v1 ("fanon", shipped in the Castle Towers tower defense game, roblox-ts):**
  - Actions are `{validate, effect}` pairs with codegen-typed wrappers.
  - Every mutation is recorded as an op log of 8 "diffsteps" (NEW, DEL, ADD, SET, REM, ADDREL, SETREL, REMREL), plus an inverse log for undo.
  - Net names are `"{authorId}_{counter}"`.
  - Each client frame undoes the predicted diffsteps, applies the canon frame, and re-applies the still-unacked diffsteps.
  - Unreliable streams carry position, velocity and direction.

  Known flaws:
  - Stale values until the ack, and whole-table overwrites, both caused by re-applying diffs instead of re-running actions.
  - Clients can claim any name prefix.
  - Module globals, string keys and hardcoded streams.
- **v2 (this design):** Luau, inside Nevermore, built on immediateutils.

## Core decisions so far
- **Components are module-level jecs ids** created with `jecs.component()` and `jecs.meta()` before any world exists. That gives identical ids on every peer and makes them `require`-able with exact types. jecs caps these at 256 per process.
- **One schema language** gives the static type, the runtime validation and the wire encoding. Schema values are typed as the value they validate (phantom typing), e.g. `S.integer(0, 1000)` is typed `number`, so the types come out of the schema itself.
- **Actions use a two-step builder:**
  ```lua
  return Statuh.action("CollectCoin", { coin = S.entity() }):run(function(ctx)
      local drop = ctx.check(ctx.world:get(ctx.args.coin, C.CoinDrop), "Coin is gone")
      ctx.check(ctx.world:target(ctx.args.coin, C.CollectedBy) == nil, "Already collected")
      ctx.world:set(ctx.caller, C.Gold, (ctx.world:get(ctx.caller, C.Gold) or 0) + drop.gold)
      ctx.world:add(ctx.args.coin, ctx.pair(C.CollectedBy, ctx.caller))
  end)
  ```
  Verified with luau-lsp under both the old and the new solver: this shape types `ctx` inside the body. The single-table `Statuh.action({ ..., run = function(ctx) })` shape does **not** type the body under the new solver. Call sites `rt.net.call(CollectCoin, { coin = coin })` are fully checked with zero annotations, including wrong types, typo'd fields and the return type.
- **The action context (`ctx`):**

  | Field | What it is |
  |---|---|
  | `args` | The validated arguments. |
  | `world` | A recording view of the world. |
  | `pair` | jecs pair helper. |
  | `check(value, reason)` | Returns `value`, or rejects the action and undoes its writes. |
  | `caller` | The calling player's entity. |
  | `player` | The calling player. |
  | `now` | The client's timestamp for the action, clamped by the server. |
  | `rng` | A random generator seeded from the caller and sequence number. |
  | `reason` | `"predict"`, `"rebase"` or `"server"`. |
  | `isServer` | True on the server. |

- **Prediction model:**
  - The first time a prediction writes a key, the server's value of that key is saved.
  - On each server frame: restore the saved values, apply the frame, drop actions the server has acknowledged, and **re-run** the remaining pending actions (Replicache-style).
  - Effects use cues, which are confirmed or canceled once the server answers.
- **Server code writes jecs directly.** Statuh tracks which keys changed and builds frames from them. Net IDs are numeric, an author range plus a counter. Clients mint IDs for their predicted spawns, and the server reuses the same IDs and enforces each client's range.
- **Shared time:**
  - The server timestamp is `rt.net.now()`. Actions carry their issue time (`ctx.now`), which the server clamps.
  - Timers are stored as end times ("ready at 812.4") rather than countdowns.
- **Core vs. addon vs. game code:**
  - **Core** owns the trust boundary: argument checks, IDs, timestamp clamping, permissions. It also owns anything that must match exactly on every peer, and the extension points.
  - **Addons:** cues, streams with interpolation, interest management, the Iris debug panel, recording.
  - **Game code:** smoothing, lag compensation, validation policy, and "send intents, not outcomes" discipline.
- **Planned `rt.net` API:**
  - Both sides: `call`, `now`, `idOf`, `entityOf`, `stats`.
  - Client: `results`, `corrections`, `messages`, `localPlayerEntity`.
  - Server: `joined`, `left`, `applied`, `message`, `addFilter` (now superseded by scope rules).

  Results, messages and corrections are per-tick lists that suit immediate mode.
- **Testing:** a headless rig with a server runtime and N client runtimes over a fake wire with latency, jitter and loss, ticked deterministically. Your M1–M3 work builds its foundation.

## Selective replication
See `statuh-selective-replication.md` (v2, after an adversarial review). Its guardrails are binding for any scope design you produce.
