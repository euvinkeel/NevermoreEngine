# Questions and deferred decisions

Each entry names the conservative choice I made so work could continue.

## Owner's answers

The five questions I asked in plain English after the night, and what was decided:

1. **Loops in VisibleThrough.** Loops are fine. Instead of a hop limit, the walk up the chain stops at an entity it has already visited. *Done:* the core and the oracle walk without revisits, and there's no hop limit anymore.
2. **Nearness (relevance).** Nearness doesn't belong in the engine; it's per game, and the server implements it. Core is permission only. Game relations (Attached, Held, OwnedBy, Near, ...) carry no replication meaning; only replication data like VisibleThrough does, and component replication should be granular too. *Done:*
   - The `relevance` rule mode and hysteresis are gone. A camera is an ordinary `restrict` rule, and any lingering is the game's to build into its keys.
   - `pair(Net.VisibleThrough, target)` names an entity directly. A replicated relation is data only.
   - Each replicated component has its own visibility (`"all"`, `"owner"`, or a restrict rule), so a far-away player arrives as a name and a team without Position and Animation. Hiding a component that still exists sends HIDE, not REM.
3. **Hooks split by their assumptions** (pure, Roblox, facade). Kept as built: `hooks.value` stays in the Roblox pack.
4. **`spring` and `linearWalk`** stay in the pure pack unchanged.
5. **The GameVersionUtils spec bug.** Left alone: no changes to code outside what the work needs.
6. **The jecs bugs.** Don't interact with the jecs repository in any way (its maintainers are tired of AI contributions); make the best of the jecs we have. *Done:*
   - `experiments/jecs-findings/JecsWorkarounds.luau` keeps jecs off its broken paths: a safe delete, a remove-then-add retarget for exclusive relations, an explicit remove-all, and an integrity check.
   - The Statuh fuzz uses the workarounds and checks jecs's integrity every frame. Two more bugs turned up along the way, six in all, each with a repro.
   - The rule is in `CLAUDE.md` under "Common Pitfalls", so every session sees it. Remove it there if you'd rather keep it out of that file.

## M0
- **Global nevermore-cli.** CI runs `npm install --ignore-scripts -g .` in `tools/nevermore-cli`. Repeating it over an existing global link fails inside npm (`Cannot read properties of null (reading 'package')`), so `cloud-setup.sh` skips it when `nevermore` is already on PATH. *Choice:* skip; nothing in the milestones needs the global CLI.

## M1
- **Where the runner lives.** `tools/CLAUDE.md` describes `tools/` as TypeScript; the handoff asked for `tools/lune-headless/`. *Choice:* put it there with no `package.json`, so it isn't a pnpm workspace project and `pnpm-lock.yaml` doesn't change. Run it through root scripts (`npm run test:lune`).
- **Root `package.json` scripts.** I added `test:lune`, `test:lune:all` and `test:lune:selftest`; there are no other root changes. *Choice:* kept, since the handoff asked for `npm run test:lune`.
- **What `npm run test:lune` gates on.** 20 of the 37 closure specs can't pass without M5's fake DataModel, so a plain "all green" exit code would always be red. *Choice:* `expectations.json` lists must-pass specs (exit 1 on regression) and known-failing specs with reasons. Should CI run it? I didn't touch `.github/workflows` (ground rule 4).
- **Fake timer callbacks run in their own thread** (jest-lua calls them inline). Roblox runs `task.delay` callbacks in new threads, so a callback that yields shouldn't suspend the test. Errors are still rethrown from `advanceTimersByTime` like jest-lua. Say if you'd rather match jest-lua exactly.
- **Flaky spec outside the closure:** `src/scoredactionservice/.../ScoredActionPicker.spec.lua` "breaks score ties in favor of the older action" failed about 1 in 3 runs headlessly. *Resolved in M5:* the runner's `tick()` had millisecond resolution, and the spec orders actions by creation `tick()`. Fixed in the runner; the spec was fine.

## M2
- **Where the full-stack spec lives.** The handoff said "next to immediateutils' other specs", but the full stack needs `JecsImmediateInstall`, `JecsImmediateHooksInstall` and the common hooks, which live in `src/jecs`. jecs depends on immediateutils, not the other way round, so a spec inside immediateutils couldn't resolve them on Roblox. *Choice:* `ImmediateStack.spec.lua` in immediateutils covers the immediateutils-only stack (installers, scheduler, defer), and `JecsImmediateStack.spec.lua` plus `JecsImmediateHooksCommonHooks.spec.lua` live in `src/jecs/src/Shared/Immediate/`. Move them if you prefer another layout.

## M3
- **canceltoken and cancellabledelay have no specs.** *Choice:* I didn't add any, since they would be new source that's unverified on Roblox. Both are small and sit under the netcode path (cancellation, timers), so they're good candidates for specs later.

## M4 (details and more in experiments/statuh-scope/DESIGN.md, "Open questions")
- **Cycles in VisibleThrough.** The notes say cycles mean invisible, but that breaks guardrail 5. *Choice:* a cycle shares its members' grants, bounded by hops. *Resolved (answer 1):* sharing stays, and the walk stops at an entity it already visited instead of at a hop limit.
- **Monotonicity covers authorization, not relevance.** Removing an inheritance link can widen relevance (interest). *Choice:* treat relevance as non-security. *Resolved (answer 2):* relevance left core, so scope is permission only and monotone throughout.
- **The jecs bugs** (`experiments/jecs-findings/`). *Choice:* reported here and worked around in the fuzz only. Not patched (third-party, out of scope). *Resolved (answer 6):* no contact with the jecs project; the workarounds are now a tested module, and there are six bugs.
- **The typed API is a proposal.** The prototype's runtime surface (`scope.Net`, raw pairs) is untyped; the typed helpers (`Net.join`, `Net.showTo`, ...) exist only as stubs.

## M5
- **lune-test wasn't vendored.** The handoff preferred vendoring pigxity-games/lune-test (Apache-2.0). Having read it, I wrote `FakeDataModel.luau` instead (no code copied; credited in the file header and README). Reasons:
  - It's built around its own runner.
  - Its signals fire synchronously, with no immediate/deferred thread semantics.
  - It hand-declares roughly 25 classes and carries its own datatypes.

  What was needed instead: Lune's datatypes, all ~900 classes from Lune's reflection database, and threads that match this runner's scheduler and fake timers. *Choice:* own implementation. Revisit if you'd rather share code with lune-test upstream.
- **Default signal behavior is immediate.** No test place sets `Workspace.SignalBehavior`, and `docs/testing/testing.md` records that handlers "run before the next line" in a test place. Deferred mode fails 30 of the 325 target tests. *Choice:* immediate by default, `--signals=deferred` available. If the test places move to Deferred, flip the default.
- **Run context defaults** (server, not running, not Studio) follow testing.md's "What a test place can drive". *Choice:* those defaults, with `--realm=client`, `--running` and `--studio` as overrides. Client-folder specs run as server, like they do in the cloud test place.
- **`globalTypes.d.lua` is required at the datamodel level.** It's gitignored and downloaded by `npm run lint:luau`'s prelint. At first it was optional, with a hand-written list of common events as the fallback. The simplification pass measured that fallback: without the file, 19 must-pass specs fail, so it couldn't pass the gate anyway. *Choice:* the datamodel level needs the file, and `run.luau` stops with a message to run `npm run lint:luau` once. The other levels don't need it, and the portability lint needs it only for `--check`, as before. `cloud-setup.sh` runs the lint once, so it's present here.
- **Spec bug, not fixed:** `src/gameversionutils/src/Shared/GameVersionUtils.spec.lua`, tests "says unknown when a deploy did not record its target" and the "?" variant, pass `{ target = nil }` to `deployedMetadata`. A table constructor with a nil value has no key, so the override does nothing, and the output says "integration" on any platform. *Choice:* left alone (source outside this milestone's scope). A fix would be a sentinel or an explicit `metadata.target = nil` after the merge. *Owner (answer 5):* leave it.
- **Not emulated, on purpose:** physics and geometry (`GetBoundingBox`, `GetMass`), avatar loading, DataStores, LocalizationTable/Translator, non-English DateTime locales, and the package tree as real Instances. Each is listed with its specs in `expectations.datamodel.json`. *Choice:* stop at clear, labelled failures rather than approximate engine math or localization tables that could pass for the wrong reasons. `GetBoundingBox` is the cheapest next step (pure geometry, unblocks 4 specs). The package tree as Instances is the most valuable (TemplateProvider, hot reload).

## M6
- **`value` lives in the Roblox pack.** `ValueObject` requires ValueBaseUtils and RxValueBaseUtils at import, which pull in instanceutils. *Choice:* Roblox pack, so the pure pack's closure stays engine-free. To move it back, make ValueObject's ValueBase branch lazy, or use a duck-typed inline branch as FINDINGS suggests. That's a ValueObject change I didn't make. *Owner (answer 3):* keep it in the Roblox pack.
- **`spring` and `linearWalk` keep their CFrame/Color3 branches in the pure pack.** FINDINGS proposed moving "the CFrame/Color3 datatype paths" to the Roblox pack. Since a hook can't wrap another, that would mean two full copies of each hook. The branches only run for CFrame/Color3 values (behind `typeof` guards) and require nothing. *Choice:* unchanged in the pure pack. Off Roblox, they just never take those branches. *Owner (answer 4):* fine.
- **The pure `guid` isn't HttpService's.** It's a v4 GUID in the same braced, uppercase format, from `math.random`. On Roblox the facade always uses HttpService's.
- **The hook table is untyped for strict consumers** (before and after the split). `hooks.gate()` is `any` there. Not changed; noting it in case Raven expected types.

## M7
- **The roots of the pure closure are a hand-written list** in `portability.luau` (FINDINGS §2 plus CoreHooks). *Choice:* explicit roots rather than inferring them. Add a root when a new module joins the engine-free path.
- **Not wired into CI.** `lint:portability` is a root script only. `.github/workflows` is off limits (ground rule 4), and the check needs `globalTypes.d.lua`, which the existing lint job already downloads.
- **Call-time findings are accepted into the baseline as they are** (datatype branches, Promise's guarded `game`). The import-time count is 0, and that's the number worth keeping at 0.
