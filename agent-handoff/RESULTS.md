# Results: headless Luau tests

<!-- SUMMARY: filled in at the end of the night -->

Branch `users/euvinkeel/headless-luau`, based on Nevermore `main` `de6ba8b`. Machine: Linux x86_64 cloud container (4 cores), Node 22.22, pnpm 10.27.

## M0. Toolchain and baseline

**Done.** All tools from `aftman.toml` that the milestones need are installed at the pinned versions, and `npm run lint:luau` gives 0 errors on Linux.

| Tool | Version | Source |
|---|---|---|
| lune | 0.10.5 | GitHub release asset |
| luau-lsp | 1.58.0 (`Quenty/luau-lsp@1.58.0-quenty.1`) | GitHub release asset `luau-lsp-linux-x86_64.zip` |
| rojo | 7.7.0-rc.3-quenty | GitHub release asset |
| stylua | 2.3.1 | GitHub release asset |
| selene | 0.29.0 | GitHub release asset |

Not installed: mantle, moonwave-extractor, run-in-roblox (not needed for any milestone).

**Reproduce:** `bash agent-handoff/cloud-setup.sh`, then `export PATH="$HOME/.nevermore-headless/bin:$PATH"`. The script is idempotent; a warm re-run takes about 12 s.

Two cloud-proxy obstacles, and how the script gets around them without changing repo files:
- **aftman can't resolve versions:** `api.github.com` returns 403 here, but release downloads from `github.com/.../releases/download/...` work. The script downloads the five zips directly, so no `cargo install` was needed.
- **`pnpm install --frozen-lockfile` fails on 5 dependencies:** the lockfile pins jecs, Iris, Fusion, Highlighter and BufferEncoder as `codeload.github.com` tarballs, and codeload returns 403. `git fetch` of the same public repos works. The script rebuilds each tarball with `git archive` at the pinned SHA, points only those 5 `resolution: {tarball: ...}` lines at the local files for the install, then restores `pnpm-lock.yaml` byte for byte. Those entries have no integrity hash, and `--frozen-lockfile` checks specifiers, not resolutions, so the install is still frozen.

### Baseline
| Step | Command | Result | Time |
|---|---|---|---|
| Install | `pnpm install --frozen-lockfile` (with the tarball workaround) | OK, 1068 packages | 9 s cold |
| Build tools | `pnpm -r --filter './tools/**' --filter '!./tools/nevermore-vscode' run build` | OK, 7 projects | 16 s |
| Sourcemap | `npm run build:sourcemap` | OK, stripped 160 Jest shadow nodes | 7.6 s |
| Type check | `npm run lint:luau` (includes prelint: sourcemap + `download-roblox-types`) | **0 errors**, exit 0 | 57.6 s |
| Type check only | `luau-lsp analyze ...` (the `lint:luau` command without prelint) | **0 errors** | 46.5 s |
| Format | `npm run lint:stylua` | clean, exit 0 | 6.7 s |

`lune setup` has also been run, so `~/.lune/.typedefs/0.10.5/` exists for Lune-side typing.

Gotchas found while setting up:
- **`lune setup` edits `.luaurc` in the current directory,** adding a `"lune"` alias. Run it outside the repo (the script does), or the repo's `.luaurc` shows up as modified.
- **The repo's Claude hooks need the tools on the default PATH.** `.claude/hooks/luau-lint-before-push.mjs` runs `npm run lint:luau` before every `git push` from Claude, and the stylua hook formats every edited file. A shell-local `export PATH` doesn't reach them, so the script symlinks the tools into `/usr/local/bin`.

## M1. The test runner: `tools/lune-headless`

**Done.** The probe harness is now a small, dependency-free Lune tool. See `tools/lune-headless/README.md` for how it works.

| Command | What it does |
|---|---|
| `npm run test:lune` | The 37 specs in the immediateutils/jecs/iris package closure (same closure as `probe/closure.js`). Writes `tools/lune-headless/out/results.json` and exits 1 only if a spec in `expectations.json` `mustPass` regresses. |
| `npm run test:lune:all` | Every spec under `src/` (312). |
| `npm run test:lune:selftest` | Runs `selftest/Runner.spec.lua` and checks 19 outcomes of the runner's own semantics. |
| `lune run tools/lune-headless/run.luau [--level=none\|basic\|roblox] [paths or --package=a,b] [--filter=text]` | Ad hoc runs. |

What changed from the probe:
- **Yield-then-fail is fixed.** Each test body runs in its own thread inside `xpcall`, and the runner waits for that thread to *finish* (polling Lune's scheduler), so an error after a yield fails the test. `selftest` pins this down: `[fails] a test that yields and then fails is a failure`.
- **Per-test timeout,** 5 s by default (`--test-timeout`, or jest's third `it` argument). A test that never finishes fails with "Exceeded timeout". Each spec runs in its own process, which is killed after `--timeout` (60 s) in case a test loops without yielding.
- **Real Jest structure:** collect then run, hooks scoped to their describe block, `beforeAll`/`afterAll`, `.skip`/`.only`/`todo`, `done` callbacks, describe-body errors reported as failures.
- **jest-lua parity** checked against the vendored jest-lua 3.10.0-quenty.2 source, especially the fake timers (`jest-fake-timers/src/init.lua`): what gets faked, how time advances, errors rethrown from `advanceTimersByTime`. Matchers and mocks cover everything used in `src/**/*.spec.lua` (counted: 4907 `toEqual`, 2997 `toBe`, 648 `toThrow`, ...).
- **Loader parity:** names resolve per package through the dependency graph, following `PackageTracker.ResolveDependency`. The probe used a global first-found index, which could pick the wrong copy of a duplicated name; `Maid` exists in both `src/maid` and `src/loader`.
- **Linux fixes:**
  - `fs.isFile`/`fs.isDir` throw "Not a directory" when a path component is a file, so on Linux every probe spec failed to load (37/37 `LOAD-FAIL`).
  - Lune's `fs` yields, which breaks `script.Parent.X` inside metamethods. The runner now takes a file snapshot before running.
- **Stray errors** in spawned or deferred threads are recorded per test and don't fail it, as on Roblox. Lune would otherwise set exit code 1 for the whole process.
- Error locations read `src/pkg/src/Shared/File.lua:12:` (the chunk name gets an `@` prefix).

### Spec results, closure of immediateutils + jecs + iris (37 specs)

| Level | Tests passing | Specs fully green | Wall time (4 jobs) |
|---|---|---|---|
| Windows probe `basic` (FINDINGS §4) | 248 / 476 | 12 | n/a |
| Windows probe `roblox` (FINDINGS §4) | 306 / 477 | 14 | n/a |
| **Linux `none`** | 100 / 117 (26 specs fail to load) | 5 | 1.8 s |
| **Linux `basic`** | **276 / 486** | **17** | **1.7 s** |
| **Linux `roblox`** | **339 / 487** | **19** | 11.5 s (two `promiseChild` tests sit out the 5 s timeout) |

Totals differ slightly from the probe because describe-body errors now count as failures, and the probe stopped counting a spec at its first harness crash.

The specs green at `basic` are the 9 the a1 harness passed (Rx, BrioUtils, RxBrioUtils, Promise, PromiseUtils, PromiseRetryUtils, PromiseTestUtils, ThrottledFunction, MaidTaskUtils) plus ImmediateScheduler, ServiceBag, PendingPromiseTracker, promiseWait, TieUtils, NevermoreTestResults, BindableEncodingUtils and String. No source changes were needed.

**Whole repo** (`--all`, 312 specs):

| Level | Tests passing | Specs green | Load errors | Time |
|---|---|---|---|---|
| `basic` | 1508 / 2238 | 82 | 161 | 23 s |
| `roblox` | 2260 / 4061 | 109 | 43 | 42 s |

One spec is timing-flaky under parallel load: `ScoredActionPicker.spec` "breaks score ties in favor of the older action" relies on two `os.clock()` reads differing, and failed in 1 of 3 runs.

Most remaining `roblox` load errors are emulation gaps for M5: RunService members (`IsRunning`, `IsStudio`), `@lune/roblox` constructors with no arguments (`Vector3`-typed defaults in `DefaultValueUtils`), and a missing `Enum.X:FromValue`.

### Remaining failures at `basic` in the closure, by cause
| Cause | Specs | Milestone |
|---|---|---|
| Instance trees with events (ChildAdded, AttributeChanged, GetPropertyChangedSignal, AncestryChanged) | attributeutils ×5, instanceutils, promise ×3 (InstanceUtils/child/propertyValue), tie ×4 | M5 |
| BindableEvent/BindableFunction | steputils, tie | M5 |
| RunService (IsClient/IsServer/IsRunning, Stepped, BindToRenderStep) | steputils ×3, TieRealmService | M5 |
| `Instance.new`/`Vector3` only | JestUtils, RandomUtils (both pass at `roblox`) | - |
| Roblox-only by design | ImmediateHotReloadInstall (Studio hot reload) | none |

### Typing
`luau-lsp analyze --platform=standard tools/lune-headless/run.luau tools/lune-headless/worker.luau tools/lune-headless/lib tools/lune-headless/selftest/check.luau` reports 0 errors (strict mode, `@lune` resolved through `tools/lune-headless/.luaurc`).

## M2. Core path green with no source changes

**Done.** Everything below passes at `--level=basic` (host polyfills only), with no changes to Nevermore source.

| Spec | Tests | Notes |
|---|---|---|
| `src/immediateutils/.../scheduler/ImmediateScheduler.spec.lua` (existing) | 3/3 | |
| `src/servicebag/.../ServiceBag.spec.lua` (existing) | 13/13 | |
| `src/maid/.../MaidTaskUtils.spec.lua` (existing) | 5/5 | |
| **new** `src/immediateutils/src/Shared/core/ImmediateStack.spec.lua` | 10/10 | `ImmediateInstall.stack3` ordering; Tick slot topology (preTick → (preSystem → system → postSystem)* → postTick, priority then name); extra Tick args; `previousSystem`/`previousRawSystem`; protected errors logged in `rt.errorlog`; DEBUG yield detection; `ImmediateDeferInstall` (flush after each system, nested defers, no double fire); `rt.Destroy`. |
| **new** `src/jecs/src/Shared/Immediate/core/JecsImmediateStack.spec.lua` | 6/6 | The probe's full stack (`stack3` + `JecsImmediateInstall` + `JecsImmediateHooksInstall` + `ImmediateDeferInstall` + common hooks + real jecs), plus: pre-world `Jecs.component()` ids passed through `comps`, per-iteration hook state, hook GC running the hook maid, `rt.defer` for structural changes during a query, `rt.Destroy` cleaning the world and hook maids. |
| **new** `src/jecs/src/Shared/Immediate/hooks/JecsImmediateHooksCommonHooks.spec.lua` | 12/12 | `hooks.cache` (once per call site, multiple returns, discriminators, cleanup with the cached values), `throttle` (window by `os.clock()` under fake timers, `delayOnFirstCall`, keeps its window through unused ticks, then is cleaned up), `changed` (`runFirst`, `onlyOnEqualTo`), `state`, `gate` (once per call site, reopens after cleanup). All under `jest.useFakeTimers()`. |

Reproduce: `npm run test:lune` (the closure now has 40 specs, 20 green, 304 tests passing in 2.3 s) or `lune run tools/lune-headless/run.luau src/jecs src/immediateutils`.

`npm run lint:luau` is still 0 errors with the new specs. `npm run lint:stylua` is clean, and selene is clean on both packages (`cd src/<pkg> && selene --no-summary --num-threads=1 --config=../../selene.toml src`). Generating selene's `roblox.yml` needed a selene built with system certificates (`cloud-setup.sh --selene-std`), because the stock binary rejects the cloud proxy's certificate.

Behaviors the new specs pin down (worth knowing):
- **The scheduler's error-log key includes the full traceback,** so the same error reached from two different `Tick` call sites is counted under two keys. A game ticks from one place, so this doesn't matter in practice, but the spec ticks from a loop for that reason.
- **Hook GC timing:** a hook that isn't called during a tick is deleted at the end of that tick, because the previous tick's GC already flagged it. `throttle` keeps its state through unused ticks until its window has passed.
- **`hooks.maid`'s callback runs during cleanup evaluation,** not at creation. Add tasks to the maid it returns.

**Not verified on Roblox:** the three new specs ran only under Lune. I wrote them against APIs that behave the same in jest-lua, and fake timers reach hook modules on Roblox the same way: Nevermore's loader requires through the `require` in its own environment, which is jest-runtime's when a spec loads it, and that's how `ThrottledFunction.spec` already works. Running `nevermore test` for `immediateutils` and `jecs` would confirm.

## M3. The Rx/Promise family

**Done, except three promise specs that need Instance events (M5).**

| Package | Specs | `basic` before → after | Notes |
|---|---|---|---|
| rx | Rx | 3/3 → 3/3 | |
| brio | BrioUtils, RxBrioUtils | 35/35 → 35/35 | |
| promise | Promise, PromiseUtils, PromiseRetryUtils, PromiseTestUtils, PendingPromiseTracker, promiseWait | 112/112 → 112/112 | |
| promise | PromiseInstanceUtils, promiseChild, promisePropertyValue | 0/7 | Need `AncestryChanged`, `ChildAdded`, `GetPropertyChangedSignal`: M5. |
| throttle | ThrottledFunction | 5/5 → 5/5 | Uses fake timers. |
| maid | MaidTaskUtils | 5/5 → 5/5 | |
| canceltoken, cancellabledelay | (no specs) | - | |

At `basic` these already passed in M1, because the host's `game` provides a pure HttpService. The source change is about not needing that shim at all.

### Source change: `src/promise/src/Shared/Promise.lua` (commit `fix(promise): fetch HttpService on first use instead of at require`)
- **Before:** `local HttpService = game:GetService("HttpService")` ran at require time, so requiring Promise without a DataModel failed. That broke Rx, CancelToken and every module above them.
- **After:** `HttpService` is fetched and cached inside the existing `pcall` in `_toHumanReadable`, the only place it is used.
- **Risk on Roblox:** none expected.
  - The output of `_toHumanReadable` is unchanged: same service, same `JSONEncode`, same `tostring` fallback.
  - The extra cost is one nil check, only when an uncaught rejection is reported.
  - `Promise.spec`'s `_toHumanReadable` block (4 tests: strings, custom `__tostring`, `{code=500}` → `{"code":500}`, `{}` → `[]`) passes headlessly against the Roblox-compatible JSON stub.
- **Checks:** `npm run lint:luau` 0 errors; selene clean on `src/promise`.
- **Headless effect at `--level=none`** (no `task`, no `game`), closure specs:

  | | Load errors | Passing tests | Green specs |
  |---|---|---|---|
  | Before | 28 | 102 | 5 |
  | After | 16 | 177 | 7 |

  Rx.spec and PendingPromiseTracker.spec go green with no host at all.

Reproduce: `lune run tools/lune-headless/run.luau src/rx src/brio src/promise src/throttle src/maid` (`--level=none` for the before/after; check out `a96fa1e~1 -- src/promise/src/Shared/Promise.lua` for "before").

## M4. Selective replication for Statuh: design and code-UX prototype

**Done.** Everything is in `experiments/statuh-scope/`; nothing Statuh-related is in `src/`. **Read `experiments/statuh-scope/DESIGN.md` first**: the designs, scoring, choice, semantics, typing, tests, costs and open questions are all there. In short:

- **Designs.** Three were written out for all three games (tower defense with teams and private inventories, RTS with fog of war, instanced dungeons with parties and spectators) and scored against all 17 guardrails:
  - A: grants and rules stored in the world as relations;
  - B: visibility predicates;
  - C: pub/sub interest channels.

  **A was chosen.** Grants only add and restrictions only narrow, so fail-closed and "removing never widens" hold by construction, and the fuzz tests check both on every frame. Key functions survive as rules in three modes: `grant` for fog vision, `restrict` for authorization, `relevance` for interest with hysteresis.
- **Departures from the reference notes,** each forced by a fuzz counterexample or by a game:
  - VisibleThrough is a union grant bounded by hops from the entity. "Deep or cyclic means invisible" isn't monotone.
  - VisibleThrough is enforced exclusive.
  - Rules have modes, because fog of war is a union.
  - Archetype defaults are spawn-time grants, not fallbacks.

  All are listed with reasons in DESIGN.md.
- **Typing.** `types/Statuh.luau` stubs, three example games that type-check, and 13 must-fail lines that each error under `--flag:LuauSolverV2=false`. Run `lune run experiments/statuh-scope/types/check.luau`, which prints `types OK: 4 files type-check, 13 must-fail lines all fail`. One limit of the old solver: rule key agreement is only checked when `key`/`viewerKeys` aren't annotated.
- **Prototype.** `src/StatuhScope.luau` is pure Luau with no networking: a jecs world, scope rules and players in; per-client ENTER, ops, pairs, LEAVE, DEL, ROLLBACK frames out in the fixed order. It covers redaction with fix-ups, fail-closed defaults, immediate revocation, relevance hysteresis, budgeted atomic group ENTERs, and an owner pin with ROLLBACK for predicted spawns. It type-checks clean (strict, old solver).
- **Tests** (M1 runner): 12 scenario tests and 2 randomized invariant tests (250 seeds × 40 frames). Every frame of every run checks seven invariants: protocol, oracle agreement, no out-of-scope ids, replica = projection, scope bounds and hysteresis, LEAVE vs DEL, atomic groups. The randomized tests also check monotonicity. Failures print the seed. `tools/soak.luau` ran **3,000 seeds × 60 frames unbudgeted plus 3,000 × 60 with an ENTER budget of 3, with 0 failures**, on the final committed code (about 105 s each).
- **Bugs the fuzz found:**
  - Six in the prototype, all fixed.
  - Two in the vendored jecs 0.11.0-quenty.3, each with a minimal repro in `experiments/jecs-findings/`: a cascade delete can skip a child (dangling `ChildOf` that later resolves to a recycled id), and wildcard pair removal corrupts the entity. No Nevermore source uses wildcard removal.
- **Cost** (`bench/bench.luau`, codegen on, Lune on this Linux container), at 50 players × 2,000 entities with 10% dirty per frame:

  | Scenario | Avg per frame | p95 |
  |---|---|---|
  | Teams, public, owner, inheritance | 3.7 ms | 5.8 ms |
  | + chunk relevance rule, cameras panning | 3.5 ms | 6.0 ms |
  | + chunk relevance rule, cameras teleporting (worst case) | 14.1 ms | 19.9 ms |

  The first frame with every player joining at once is 130–325 ms, so joins need an ENTER budget.
- **Legacy comparison.** DESIGN.md compares this with fanon v1 (`legacy-reference/`): diffstep compaction vs reading ops from the world at frame time, the inverse log vs ROLLBACK/pin, catch-up/warp vs budgeted ENTERs, and the trust gaps v1 had. `legacy-reference/` isn't committed (it's in `.git/info/exclude` locally).

Reproduce:
```bash
lune run tools/lune-headless/run.luau experiments/statuh-scope
lune run experiments/statuh-scope/tools/soak.luau 1 3000 60 && lune run experiments/statuh-scope/tools/soak.luau 5001 8000 60 3
lune run experiments/statuh-scope/types/check.luau
lune run experiments/statuh-scope/bench/bench.luau
```

## M5. Fake DataModel with events: `--level=datamodel`

**What was built.** A fourth host level whose Instances have events. Files, all in `tools/lune-headless/lib/`:
- `FakeDataModel.luau`: Instances, signals, services, frame stepping.
- `RobloxApi.luau`: event and method names from the luau-lsp definitions.
- `EnumShim.luau`: unique EnumItems.

Also changed: `Host.luau`, `Scheduler.luau` (frame-aligned waits), `RobloxPure.luau` (DateTime formatting).

Classes, services, creatability, property types and defaults come from Lune's bundled rbx-dom reflection database rather than a hand-written list. Event and method names come from `globalTypes.d.lua`, the file `npm run lint:luau` downloads. So the fake knows all ~900 classes, and an unemulated engine member fails with an explicit `[lune-headless] ... is not emulated` instead of a misleading "not a valid member".

Defaults follow the "What a test place can drive" table in `docs/testing/testing.md`:
- server, not running, immediate signals;
- Heartbeat at ~60 Hz, Stepped silent;
- RenderStepped throws on a server, and BindToRenderStep is silent.

Flags change the context: `--realm=client`, `--running`, `--studio`, `--signals=deferred`. The full emulated surface and every fidelity compromise are in the README, under "The datamodel level". `npm run test:lune:datamodel` gates the whole repo against `expectations.datamodel.json`.

**Target specs, before and after** (tests passed / total):

| Spec | `basic` | `roblox` | `datamodel` |
|---|---|---|---|
| attributeutils / AttributeUtils.spec.lua | 2/15 | 12/15 | 15/15 |
| attributeutils / AttributeValue.spec.lua | 1/19 | 12/19 | 19/19 |
| attributeutils / EncodedAttributeValue.spec.lua | 0/19 | 12/19 | 19/19 |
| attributeutils / JSONAttributeValue.spec.lua | 0/10 | 8/10 | 10/10 |
| attributeutils / RxAttributeUtils.spec.lua | 1/12 | 1/12 | 12/12 |
| instanceutils / RxInstanceUtils.spec.lua | 0/15 | 0/15 | 15/15 |
| tie / TiePropertyInterface.spec.lua | 0/30 | 5/30 | 30/30 |
| tie / TieRealmService.spec.lua | 4/5 | 4/5 | 5/5 |
| tie / TieDefinition.spec.lua | 0/8 | 0/8 | 8/8 |
| tie / TieImplementation.spec.lua | 0/8 | 1/8 | 8/8 |
| tie / TieInterface.spec.lua | 0/16 | 9/16 | 16/16 |
| tie / TieUtils.spec.lua | 5/5 | 5/5 | 5/5 |
| steputils / StepUtils.spec.lua | 4/35 | 6/35 | 35/35 |
| steputils / onRenderStepFrame.spec.lua | 2/5 | 2/5 | 5/5 |
| steputils / onSteppedFrame.spec.lua | 1/4 | 1/4 | 4/4 |
| promise / Promise.spec.lua | 63/63 | 63/63 | 63/63 |
| promise / PromiseRetryUtils.spec.lua | 5/5 | 5/5 | 5/5 |
| promise / PromiseTestUtils.spec.lua | 9/9 | 9/9 | 9/9 |
| promise / PromiseUtils.spec.lua | 27/27 | 27/27 | 27/27 |
| promise / PendingPromiseTracker.spec.lua | 6/6 | 6/6 | 6/6 |
| promise / PromiseInstanceUtils.spec.lua | 0/2 | 0/2 | 2/2 |
| promise / promiseChild.spec.lua | 0/3 | 1/3 | 3/3 |
| promise / promisePropertyValue.spec.lua | 0/2 | 1/2 | 2/2 |
| promise / promiseWait.spec.lua | 2/2 | 2/2 | 2/2 |
| **Total (24 specs)** | **132/325** | **192/325** | **325/325** |

valuebaseutils has no specs. The promise rows are the instance-based utilities from M3.

**Signal timing matters, and immediate is right.** With `--signals=deferred`, the same 24 specs drop to 295/325 (9 specs fail). They assert right after a write, which matches the "handlers run before the next line" row in testing.md.

**Whole repo** (315 specs):

| Level | Specs passing | Load errors | Tests passing |
|---|---|---|---|
| `basic` | 87 | 161 | 1,634 |
| `roblox` | 125 | 25 | 2,503 |
| `datamodel` | **282** | 1 | **4,440** of 4,750 |

The default closure (`npm run test:lune`) at `datamodel` passes 39 of its 40 specs. The exception is ImmediateHotReloadInstall (harness gap, below). `npm run test:lune` itself stays on `basic`.

**Every remaining failure, classified** (33 specs; the per-spec reason is in `expectations.datamodel.json`):

| Class | Specs | What |
|---|---|---|
| Emulation gap | 20 | `Model:GetBoundingBox` (4); LocalizationTable/Translator (6, clienttranslator); `BasePart:GetMass`/`GetConnectedParts` (2); R6 rig joints/constraints (2, ragdoll); non-English DateTime locales (2); SecurityCapabilities (2, brine); TeleportOptions (1); `Humanoid:UnequipTools` (1) |
| Needs the real engine | 6 | Avatar loading through `Players:CreateHumanoidModelFromDescription` (PlayerMock, characterutils, resetservice ×2, playerutils); DataStoreService (1) |
| Harness gap | 3 | Package source folders are FS nodes rather than Instances in the fake DataModel, so TemplateProvider and hot reload can't clone them (2); Lune's enum data lacks `Enum.KeyCode.None` (1) |
| Slow | 2 | Pass with `--test-timeout=30` (EllipticCurveCryptography, a datastore removal-callback test) |
| Spec bug | 1 | `GameVersionUtils.spec.lua` "says unknown when a deploy did not record its target" passes `{ target = nil }` as overrides. That table has no keys, so the override does nothing and the test fails on Roblox too. Not fixed (out of scope); noted in QUESTIONS. |
| Out of scope | 1 | `HttpService:RequestAsync` (network) |

**Runner bugs found and fixed along the way.** These affect every level:
- `toBe` used `rawequal`; jest-lua's `Object.is` uses `==`. EnumItems and datatypes now compare like they do in jest-lua.
- `tick()` had millisecond resolution because it came from `DateTime.now()`. Roblox's is much finer. This was the cause of the M1 "flaky" ScoredActionPicker tie-break test, which orders actions by creation `tick()`.
- A require could yield: lazy file reads for packages outside the declared closure, and third-party packages. ServiceBag rejects a yielding `Init`. The snapshot now pre-reads every package that a `require("Name")` literal resolves to.
- A second thread requiring a module that was mid-load raised "required recursively". Roblox makes it wait, and now so does the runner.

**Why lune-test wasn't vendored:** see QUESTIONS.md, M5.

Reproduce:
```bash
npm run test:lune:datamodel                      # whole repo vs expectations.datamodel.json (~70 s)
lune run tools/lune-headless/run.luau src/attributeutils src/instanceutils src/tie src/steputils src/promise --level=datamodel
lune run tools/lune-headless/run.luau src/attributeutils src/instanceutils src/tie src/steputils src/promise --level=basic   # "before"
```

## M6. Common hooks split: pure pack, Roblox pack, facade

Implements the FINDINGS §2 proposal in `src/jecs/src/Shared/Immediate/hooks/` (commit `refactor(jecs): split the common hooks ...`):

| Module | Contents |
|---|---|
| `JecsImmediateHooksCoreHooks` | The 31 engine-free hooks plus a `guid` that formats a v4 GUID like `HttpService:GenerateGUID()`. Its require closure has no `game`, Instance, tie, binder or ValueBase code. |
| `JecsImmediateHooksRobloxHooks` | `filterDescendants`, `findChild`, `useBinder`, `useTieInterface`, `value`, and `guid` from HttpService, moved verbatim. |
| `JecsImmediateHooksCommonHooks` | Facade: builds the core table, then copies the Roblox pack's entries over it. |

- **Flat merge, no wrappers.** Every facade entry is the pack's own function, so the `debug.info(3, ...)` call-site keying in `getOrCreateHookState` still sees game code, and a call costs the same. The only new cost is one loop over 6 keys per runtime.
- **`value` went to the Roblox pack.** FINDINGS lists it as "needs polyfills", but `ValueObject` requires ValueBaseUtils and RxValueBaseUtils at import, which would break the pure pack's closure rule. See QUESTIONS.
- **`spring` and `linearWalk` stay in the pure pack unchanged.** Their CFrame/Color3 branches sit behind `typeof` guards and add nothing to the require closure. Splitting them would have meant duplicating each whole hook, because a Roblox override can't wrap the pure one. See QUESTIONS.
- **Roblox behavior.** Unchanged: the same 37 hooks with the same code, and `guid` still comes from HttpService. `lint:luau` is 0. selene and stylua are clean on the package, and `moonwave-extractor` passes. Types are unchanged too. A strict probe showed `hooks.gate()` was already `any` to strict consumers before the split, and still is.
- **Specs** (Lune, also in both gates):
  - `JecsImmediateHooksCoreHooks.spec.lua`: 15 tests that tick the pure pack on its own with fake timers.
  - `JecsImmediateHooksCommonHooks.spec.lua`: +2 tests. One checks the facade exposes exactly the union of the two packs. The other checks a Roblox-pack hook stays keyed by the caller's line. I verified that second test catches a wrapper: temporarily wrapping `guid` in the facade made it fail.
- **Proof the pure pack is engine-free.** The core spec loads at `--level=none`, which has no `game` global. The facade's spec fails to load there, as expected: `JecsImmediateHooksRobloxHooks.lua:15: attempt to index nil with 'GetService'`.

Reproduce:
```bash
lune run tools/lune-headless/run.luau src/jecs/src/Shared/Immediate/hooks                       # 3 specs, 35 tests
lune run tools/lune-headless/run.luau src/jecs/src/Shared/Immediate/hooks/JecsImmediateHooksCoreHooks.spec.lua --level=none  # loads; only the timer-free test passes
npm run lint:luau
```

## M7 (stretch). Portability lint

`npm run lint:portability` runs `tools/lune-headless/portability.luau --check`; the README section "Portability lint" has the details.

- **Closure.** It follows requires statically from 20 roots on the engine-free path (the FINDINGS §2 pure and polyfill-only modules, plus `JecsImmediateHooksCoreHooks`), reaching 31 modules.
- **Check.** It runs `luau-lsp analyze --platform=standard` with `portability/portable.d.luau`, which declares only what the `basic` host polyfills.
- **Classification.** Unknown globals count as runtime use, marked "import" when they run at require time. Roblox types in annotations count as type-only.
- **Baseline.** `--check` fails only when a file gains a finding. I confirmed it catches a new use: an import-time `workspace` added to Spring.lua was flagged and the check exited 1.
- **Speed:** about 1 s.

**Current findings.** These are reported, not fixed; each is a known, guarded use:

| Kind | Count | Where |
|---|---|---|
| Runtime, import time | **0** | Nothing in the closure touches the engine while loading. |
| Runtime, call time | 11 | CFrame ×3 and Vector3 ×2 in the `spring`/`linearWalk` datatype branches (CoreHooks); Vector3/Vector2/Color3 ×4 in JecsImmediateHookUtils' datatype branches; `Vector3.new` in `RandomUtils.randomUnitVector3`; `game` in Promise's lazy HttpService fetch (inside a pcall, M3). All sit behind `typeof` guards, in a pcall, or in a function that's Roblox-specific by name. |
| Type-only | 33 | `Instance` (10), `RBXScriptConnection` (6), `CFrame` (4), `Color3` (3), `Vector3` (3), `HttpService` (2), `Plugin` (2), `RBXScriptSignal` (2), `Vector2` (1) |

Type classification uses `globalTypes.d.lua` to tell Roblox types apart: jecs's own type functions aren't Roblox API. So `--check` refuses to run without that file, which `npm run lint:luau` downloads.
