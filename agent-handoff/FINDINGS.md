# Findings so far (evidence for HANDOFF.md)

Gathered 2026-10-03/04 on Windows with Lune 0.10.5 and luau-lsp 1.58.0-quenty.1, against Nevermore `main` (`de6ba8b`). Every number here came from running something; treat anything marked "inferred" as unverified.

## 1. What actually loads (module graph, not package.json)
Package-level closure of immediateutils + jecs + iris: 38 workspace packages, 152 source files, 69 with no Roblox API use at all.

The module-level require graph from the entry points is much smaller (`probe/module_graph.js`):

| Entry group | Modules | Touch Roblox APIs |
|---|---|---|
| core (ImmediateCoreUtils, ImmediateInstall, ImmediateScheduler, ImmediateDeferInstall) | 11 | 6 |
| jecs addon (JecsImmediateInstall/Utils, JecsImmediateHooksInstall, JecsImmediateHookUtils) | 21 | 9 |
| JecsImmediateHooksCommonHooks | 39 | 22 |
| ImmediateHotReloadInstall | 25 | 16 |
| IrisImmediateInstall | 11 | 7 |

Union: 41 modules, 24 touch Roblox APIs.

## 2. Per-module verdicts (audited by hand, line-level)
| Module | Verdict | What it needs |
|---|---|---|
| ImmediateScheduler | polyfill-only | `task.spawn/cancel`, `debug.profilebegin/profileend`. `RegisterDescendantModuleScripts` walks Instances but is opt-in and call-time only. |
| ImmediateCoreUtils | pure | `plugin: Plugin?` is type-only. |
| ServiceBag | polyfill-only | `task.spawn`, `debug.setmemorycategory`. `typeof(x) == "Instance"` is simply false outside Roblox. |
| Signal, EventHandlerUtils | polyfill-only | `task.spawn`, `debug.getmemorycategory` (Signal.lua:81, called on every Connect), `debug.setmemorycategory`. |
| Maid (loader/src/Maid.lua), MaidTaskUtils | polyfill-only | `task.cancel/defer/delay`. Instance/RBXScriptConnection checks are harmless. |
| Observable | pure | `workspace` only in a doc comment. |
| Rx, Brio, CancelToken, cancellableDelay, ThrottledFunction | polyfill-only | `task.*` at call time. |
| Promise | small seam | Line 10 calls `game:GetService("HttpService")` **at import**, and kills Rx/CancelToken imports without a `game` polyfill. It is used only for JSONEncode in `_toHumanReadable` (line ~414, inside a pcall). Fix: fetch HttpService lazily there. Patched copy: `probe/a1/Promise.patched.lua`. |
| JecsImmediateHookUtils | pure on the number path | Vector3/Vector2/Color3 branches are behind `typeof` guards. |
| JecsImmediateHooksCommonHooks | split needed | Import-time `game:GetService("HttpService")` at line 2. 30 of 37 hooks are pure or need small polyfills. Roblox-only: `filterDescendants`, `findChild`, `useBinder`, `useTieInterface`. Mixed: `spring`, `linearWalk` (CFrame/Color3 branches). Needs polyfills: `guid`, `async`, `noise`, `random`, `sin`, `distributeIteration` (15 profilebegin calls), `subscribe`, `value`. |
| ValueObject | small seam | `require("Rx")` is used only as a type (`Rx.Predicate`). The ValueBase branch pulls in ValueBaseUtils/RxValueBaseUtils/RxInstanceUtils; a duck-typed inline branch would cut them from the closure. |
| RandomUtils | small seam | `Random` is type-only except `Vector3.new` in `randomUnitVector3`. Suggested: a `RandomLike` type plus `createRandom(seed)` falling back to a pure PCG. |
| Spring | pure | Roblox only appears in comments. |
| ValueBaseUtils, RxValueBaseUtils, RxInstanceUtils | Roblox-only (adapters) | Instance API and events throughout. |
| ImmediateHotReloadInstall, IrisImmediateInstall | Roblox-only (adapters) | ModuleScripts, services, GUI. Leave as they are. |

**Common-hooks split proposal:**
- A pure pack, `JecsImmediateHooksCoreHooks`, with no HttpService, tie, instanceutils, valuebaseutils or binder in its require closure.
- A Roblox pack: `filterDescendants`, `findChild`, `useBinder`, `useTieInterface`, a `guid` override using HttpService, and the CFrame/Color3 datatype paths.
- A facade, `JecsImmediateHooksCommonHooks`, that builds the pure table and copies the Roblox pack's keys over it. A flat merge, so call cost on Roblox is unchanged.

**Critical:** hook state is keyed by `debug.info(3, "s")`/`("l")`, the call site of the hook. A wrapper hook, even a tail call, moves level 3 to the wrapper. Roblox-pack hooks must *replace* pure hooks; they must never wrap or delegate to another hook.

## 3. Lune facts (verified on 0.10.5)
- **Run fine:** jecs (`@quentystudios/jecs` 0.11.0-quenty.3) runs unmodified. `buffer` (including `readbits`/`writebits`), the `vector` library, and native codegen (`luau.load(src, {codegenEnabled = true})`, about 17x faster on a buffer loop) all work.
- **Missing:** the `task` global (only `require("@lune/task")`), `Random`, `DateTime`, `TweenInfo`, `debug.profilebegin/profileend/setmemorycategory/getmemorycategory`, `game`, `script`, `Instance`. HttpService JSONEncode/GenerateGUID are missing too.
- **`debug` is a read-only table.** `debug.profilebegin = f` errors. You can, however, rebind the *global* `debug` to a proxy table with `__index = debug`.
- **Injecting globals for modules loaded by Lune's `require`:** write to `getfenv(0)` in the entry script before requiring (`getfenv(0).task = require("@lune/task")`). Assigning `_G.task` does **not** propagate. Note that `getfenv` disables Luau's safe-env optimizations, so don't benchmark with an injected environment.
- **`luau.load(source, { environment = env })`** gives per-module environments. This is what the harness uses. Chunks loaded this way have no native `require`, so the environment must provide one.
- **`@lune/roblox`:** Instance trees, properties, attributes, tags, Value objects, Clone/IsA/Destroy, DataModel + GetService, and Vector3/CFrame/Color3/UDim2/Enum datatypes all work. There are **no events of any kind**: no Changed, ChildAdded, GetPropertyChangedSignal, AttributeChanged, BindableEvent.Event or RunService.Heartbeat. `implementProperty`/`implementMethod` can add members, but writes to built-in members (Parent, Name, SetAttribute) can't be intercepted. So events can't be bolted onto Lune instances; every working mock replaces the Instance layer.
- **Bare-name requires:** Lune's native require cannot resolve `require("Maid")`; paths need a `./`, `../` or `@alias` prefix.

## 4. Spec runs (37 specs in the package closure)
Harness: `probe/nvlune.luau` (loader emulation + mini jest), driven by `probe/run_specs.js`.

| Level | What's injected | Tests passing | Specs fully green |
|---|---|---|---|
| `basic` | Lune task, fake `game` services, debug stubs | 248 / 476 | 12 |
| `roblox` | basic + `@lune/roblox` Instances/datatypes + pure Random/DateTime/TweenInfo | 306 / 477 | 14 |
| a1 harness (`probe/a1/nvlune_a1.luau`) | + `expect.any`, `debug.getmemorycategory`, HttpService stub | Rx 3/3, BrioUtils 10/10, RxBrioUtils 25/25, Promise 63/63, PromiseUtils 27/27, PromiseRetryUtils 5/5, PromiseTestUtils 9/9, ThrottledFunction 5/5, MaidTaskUtils 5/5 | |

Remaining failures at `roblox` level, by cause:
- **Instance events** (about 100 tests): ChildAdded, GetAttributeChangedSignal/AttributeChanged, AncestryChanged, GetPropertyChangedSignal, BindableEvent.Event, BindableFunction.OnInvoke.
- **HttpService** GenerateGUID/JSONEncode (about 25).
- **RunService** IsClient/Stepped/IsRunning (about 17).
- **Harness gaps:** `expect.any`, getmemorycategory, and "Instance has been destroyed", which is a quirk of Lune instances.

**Known harness bug:** `it` only catches errors from the first resume of a test. A test that yields and *then* fails is counted as passed, so the numbers above may be slightly inflated. Fix: wrap the test body in pcall inside the coroutine and record the result there.

**Full stack under Lune:** `probe/stack.spec.luau` ran `ImmediateInstall.stack3` with JecsImmediateInstall, JecsImmediateHooksInstall, ImmediateDeferInstall, JecsImmediateHooksCommonHooks and real jecs, ticking a system 5 times with `hooks.cache`. It passed at `basic` level.

## 5. Typing and loading
- **Nevermore's lint runs headless:** `npm run lint:luau` (luau-lsp, Quenty fork, `--flag:LuauSolverV2=false`, sourcemap) gives 0 errors on all of `src` in about 35 s. Bare-name requires resolve to full types through the sourcemap. CI runs this on ubuntu (`.github/workflows/linting.yml`).
- **The Quenty luau-lsp fork** (`users/quenty/support-nevermore-string-requires`) indexes sourcemap ModuleScripts by bare name and synthesizes `loader` modules. It's frozen at 1.58.0-quenty.1 and undocumented.
- **Roblox require-by-string is GA** (`./`, `../`, `@self`, `@game`), but custom aliases don't exist yet, so Nevermore keeps its loader on Roblox.
- **Two ways to run Nevermore modules in Lune:**
  - (a) Loader emulation via `luau.load` with per-module environments. This is `probe/nvlune.luau`: original files, original line numbers, per-module control.
  - (b) A generated "stage" copy with the loader line stripped and bare requires rewritten to `./Name`, run by Lune's native require plus a `getfenv(0)` shim. See `probe/a3/stage.luau` and `shim.luau`. It loaded 1035 modules in 1.3 s.

  (a) is proven on the specs; (b) is useful for typed Lune-side scripts.
- **Lune-side typing:** `lune setup` writes typedefs to `~/.lune/.typedefs/<version>/`. Add a `.luaurc` alias `"lune": "~/.lune/.typedefs/0.10.5/"` and luau-lsp then resolves `@lune/*`.
- **Optional portability lint:** `luau-lsp analyze --platform=standard --defs=probe/a3/lune_shim.d.luau <files>` flags uses of Roblox-only globals.
- **darklua can't convert loader-style requires;** it only bundles once the loader line is stripped.

## 6. Prior art for an event-capable fake Roblox
| Project | License | Notes |
|---|---|---|
| [pigxity-games/lune-test](https://github.com/pigxity-games/lune-test) | Apache-2.0 | **Best base.** Pure-Luau fake DataModel with events (Changed, ChildAdded/Removed, Destroying, AncestryChanged, AttributeChanged, GetPropertyChangedSignal, GetAttributeChangedSignal), a steppable scheduler, RunService, CollectionService, Players, and Instance-style `require`. Its 163 tests pass on Lune 0.10.5. Gaps: `typeof(inst)` is "table", about 25 classes, no BindableEvent, its own datatypes, signals fire synchronously. |
| ssimilize/new `RobloxMock.luau` | **no license** | Good design to learn from (reflection-validated fake instances on top of `@lune/roblox` datatypes, handlers in new threads, virtual task clock). **Do not copy code.** |
| centau/vide `test/mock.luau` | MIT | `newproxy` instance + `typeof` override trick. Small. |
| LPGhatguy/lemur | MIT, archived | Lua 5.1. Reference only. |
| jsdotlua/jest-lua | MIT | **Can't run under Lune today:** it needs Instance-based requires, ModuleScript.Source + loadstring/getfenv, and FileSystemService/ProcessService. Keep a small jest adapter for headless runs. |
