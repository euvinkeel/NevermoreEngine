# lune-headless

Runs Nevermore's `*.spec.lua` files under [Lune](https://github.com/lune-org/lune), with no Roblox Studio and no Open Cloud. Each spec runs unmodified: the runner emulates Nevermore's loader and the parts of jest-lua the specs use, and fakes as much of Roblox as you ask for.

This is the one Luau tool under `tools/` (the rest are TypeScript). It has no dependencies beyond `lune` 0.10.5 from `aftman.toml`.

## Usage

```bash
npm run test:lune            # the immediateutils closure, gated by expectations.json
npm run test:lune:all        # every spec under src/
npm run test:lune:datamodel  # every spec on the fake DataModel, gated by expectations.datamodel.json
npm run test:lune:selftest   # checks the runner's own semantics
npm run lint:portability     # Roblox-only API use in the engine-free closure (see below)

lune run tools/lune-headless/run.luau src/maid src/rx            # some packages
lune run tools/lune-headless/run.luau src/rx/src/Shared/Rx.spec.lua
lune run tools/lune-headless/run.luau --level=roblox --filter="Rx.of"
```

Run from the repo root (or pass `--root`). `run.luau --help` isn't implemented; the options are at the top of `run.luau`.

Each run writes `tools/lune-headless/out/results.json` (gitignored): totals, then per spec its status, counts, durations and every failure with a trimmed traceback. `--detail` adds every test.

## Host levels

`--level` picks how much Roblox the specs see. Levels make it easy to tell which code needs which part of the engine.

| Level | Adds |
|---|---|
| `none` | Only `script`, `require` and `Jest`. |
| `basic` (default) | `task`, `os` (faked by fake timers), `tick/time/wait/delay/spawn`, a `debug` proxy with the profiling and memory-category functions, captured `warn`/`print`, pure `Random`/`DateTime`/`TweenInfo`, `shared`, a `typeof` that knows `DateTime`, and a `game` whose only working service is a pure `HttpService`. |
| `roblox` | `basic` plus `@lune/roblox` Instances and datatypes. Lune's Instances have **no events**. |
| `datamodel` | `basic` plus `@lune/roblox` datatypes and a fake Instance layer with events (`lib/FakeDataModel.luau`). See below. |

## How it works

- `run.luau` builds a package index once, picks specs, and starts one `worker.luau` process per spec (`--jobs`, default 4). A worker that runs past `--timeout` (60 s) is killed and reported as `timeout`.
- `worker.luau` loads the spec through `lib/ModuleLoader.luau`, collects its tests, runs them, and writes JSON.
- **Module resolution** (`lib/PackageIndex.luau`) follows Nevermore's loader (`src/loader/src/Dependencies/PackageTracker.lua`): the requiring package's own modules, then its direct dependencies, then a breadth-first walk of transitive dependencies (standing in for the loader's implicit-parent lookup). A name found only through a last-resort global search is listed in the spec's `notes`.
- **`script`** is a filesystem-backed stand-in for the module's Instance (`Name`, `Parent`, children, `FindFirstChild`, `WaitForChild`, `GetChildren`, `IsA`, `GetFullName`), so Instance-style requires like `require(script.Parent.Util)` work.
- **Lune's `fs` yields and Luau can't yield inside a metamethod,** and `script.Parent.X` is a metamethod. `lib/FileSnapshot.luau` lists the spec's package closure and reads its sources up front, plus every package that a `require("Name")` literal in them resolves to, so neither those lookups nor `require` ever yield (Roblox's `require` doesn't, and ServiceBag rejects an `Init` that yields).
- **Concurrent requires wait.** If a module yields while loading and another thread requires it, the second thread waits for the first, as on Roblox. Only a require cycle in one chain is "required recursively".
- **Errors in spawned threads** (`task.spawn/defer/delay`) are captured per test as `strayErrors` and don't fail the test, as on Roblox.

## Mini-jest (`lib/MiniJest.luau`, `lib/Expect.luau`)

Same API as the jest-lua that Nevermore specs use: `Jest.Globals.describe/it/test/expect/jest/beforeAll/afterAll/beforeEach/afterEach`, plus `.skip`, `.only` and `it.todo`.

- **Collect, then run.** Like Jest, describe bodies run while the file loads and tests run afterwards. Hooks are scoped to the describe block that declares them.
- **Async tests.** Each test runs in its own thread, and it passes only if that thread *finishes* without error. A test that yields and then fails is a failure. A test that doesn't finish within `--test-timeout` (5 s) fails. Tests that take a `done` argument finish when `done()` is called.
- **Matchers:** `toBe` (jest-lua's `Object.is`: `==`, so `__eq` applies; NaN equals NaN; 0 isn't -0), `toEqual`, `toStrictEqual`, `toBeNil`, `toBeDefined`, `toBeTruthy`, `toBeFalsy`, `toBeNaN`, `toBeCloseTo`, `toBeGreaterThan[OrEqual]`, `toBeLessThan[OrEqual]`, `toContain`, `toContainEqual`, `toHaveLength`, `toMatch`, `toBeInstanceOf`, `toHaveProperty`, `toThrow`, and the mock matchers `toHaveBeenCalled[Times|With]`, `toHaveBeenLastCalledWith`, `toHaveBeenNthCalledWith`. Each works with `.never`, and with `.` or `:`. `toThrow("text")` matches a substring of the message.
- **Asymmetric matchers:** `expect.any(typeName | class)`, `expect.anything()`, `expect.stringContaining`, `expect.stringMatching`, `expect.objectContaining`, `expect.arrayContaining`.
- **Mocks:** `jest.fn(impl?)` returns `(mock, forwardingFunction)` like jest-lua. `jest.spyOn` keeps one spy per object and key, even across `restoreAllMocks`, which is a jest-lua quirk that some specs rely on.
- **Fake timers** follow jest-lua's modern fake timers. `useFakeTimers` fakes `task.delay`, `task.wait`, `task.cancel`, `delay`, `os.clock`, `os.time`, `tick`, `time` and `DateTime.now`; `task.spawn` and `task.defer` stay real. Also provided: `advanceTimersByTime(ms)`, `runAllTimers`, `runOnlyPendingTimers`, `advanceTimersToNextTimer`, `clearAllTimers`, `getTimerCount`, `setSystemTime`. Two differences from jest-lua:
  - A fake `task.delay` returns a thread, as on Roblox.
  - A timer callback runs in its own thread, so one that yields doesn't suspend the test.

  An error in a timer callback is still rethrown from `advanceTimersByTime`.

## The datamodel level

`--level=datamodel` replaces Lune's event-less Instances with `lib/FakeDataModel.luau`, an Instance layer written for this runner. ([lune-test](https://github.com/pigxity-games/lune-test), Apache-2.0, was read for ideas; nothing was copied. See `agent-handoff/QUESTIONS.md` for why it wasn't vendored.)

By default it looks like a Nevermore test place, as described in `docs/testing/testing.md` ("What a test place can drive"): a server (`IsServer`), not running (`IsRunning` false), not Studio, with immediate signals. Heartbeat fires about 60 times a second in real time; Stepped and PreSimulation don't. Connecting to RenderStepped throws "can only be used from local scripts". BindToRenderStep binds and never runs. Change the context with `--realm=client`, `--running`, `--studio` and `--signals=deferred`.

**What's emulated:**
- **Classes and properties come from data.** Class names, superclasses, NotCreatable and Service tags, and scriptable properties with their types and defaults are read from the reflection database bundled with `@lune/roblox` (rbx-dom). So `Instance.new`, `GetService`, `IsA`, defaults, read-only properties and typed writes behave like Roblox for all ~900 classes. That includes `Unable to assign property X. bool expected, got string`, Float32 rounding, and Enum coercion from names and numbers.
- **Event and method names come from luau-lsp's definitions.** `globalTypes.d.lua`, which `npm run lint:luau` downloads, is read by `lib/RobloxApi.luau`. Every real event resolves to a signal; most stay silent unless something below fires them. A real method that isn't emulated fails with `[lune-headless] Class:Method() is not emulated`, so emulation gaps can't be mistaken for "not a valid member". Without the file, only a hand-written list of common events exists.
- **Instances and events:**
  - Instances, signals and connections are userdata; `typeof` reports `Instance`, `RBXScriptSignal`, `RBXScriptConnection`, `EnumItem` and `DateTime`.
  - `Changed` passes the new value on ValueBase and the property name elsewhere.
  - Also: `GetPropertyChangedSignal`, `AttributeChanged`/`GetAttributeChangedSignal` (with attribute name and type checks), `ChildAdded/Removed`, `DescendantAdded/Removing`, `AncestryChanged`, and `Destroying`. Destroy also locks `Parent` and disconnects everything.
  - `Clone` remaps references within the cloned tree and respects `Archivable`.
- **Services and helpers:**
  - Bindables: `BindableEvent` copies tables like Roblox does, and `BindableFunction:Invoke` waits for `OnInvoke`.
  - CollectionService: tags, tagged-instance signals, and only DataModel members counted.
  - `Debris:AddItem`, `Teams:GetTeams`, `Players:GetPlayers`.
  - Humanoid: state enablement with `StateEnabledChanged`, and a derived `Humanoid.RootPart`.
  - A UserInputService/GuiService with no input devices.
  - ReflectionService, answered from the two data sources above.
- **Frames and time.** Real `task.wait`/`task.delay` (and `wait`/`delay`) resume after a frame's Heartbeat, so `task.wait()` waits a frame. Jest fake timers still take over when enabled; frames keep stepping regardless.
- **Unique EnumItems** (`lib/EnumShim.luau`). Lune creates a new EnumItem on every access, so tables keyed by EnumItem miss. The shim hands out one userdata per item, adds `Enum.X:FromName/FromValue`, and converts to Lune's EnumItems when one is passed to a Lune datatype constructor.

**Fidelity compromises** (each one deliberate; most are visible in `expectations.datamodel.json`):
- Signals run handlers in `task.spawn` (immediate) or `task.defer` (deferred) threads. Deferred mode doesn't reproduce Roblox's re-entrancy limits or its exact resumption points.
- Engine-computed state isn't simulated: no physics, assemblies, joints, rendering, Humanoid state machine (`GetState` is always `None`, `ChangeState` does nothing), replication, or input. `Humanoid.RootPart` is derived from the parent model's `HumanoidRootPart`; like on Roblox, its changed signal never fires.
- Property aliases are separate properties (`Humanoid.maxHealth` doesn't change `MaxHealth`). Defaults rbx-dom doesn't list fall back to the serialized name (`Health_XML`), then to a type default (0, "", false, the enum's first item).
- `IntValue`-style integer properties aren't truncated; Float32 properties are rounded.
- `Players` never has real players (`Player` isn't creatable); use `player-mock`.
- The package's source tree is still FS-backed `script` nodes, not Instances in the fake DataModel. Code that clones or reparents its own ModuleScripts (TemplateProvider folders, hot reload) can't work yet.
- Enum data is Lune's (rbx-dom), which can lag Roblox: for example `Enum.KeyCode.None` is missing. Enum fields read off a Lune datatype (`font.Weight`) are Lune EnumItems, not the shim's.
- Pure `DateTime` formats English only; other locales fail with a clear `[lune-headless]` error. `ToIsoDate` matches Roblox (`...Z`, no fraction). `fromUniversalTime` rolls clock fields over (hour 25 is 01:00 the next day) and rejects out-of-range months and days.
- `tick()` is wall-clock time with `os.clock()` resolution, since DateTime.now() only has milliseconds.
- ReflectionService answers names only: `Permits` values are `true` placeholders, and security filters are ignored.
- The definitions file reflects the live API; rbx-dom's database may be older. A property only the definitions know about reports "not emulated".

## Expectations

`expectations.json` lists the specs that must pass (`mustPass`) and the ones known to fail, each with a reason (`knownFailing`). With `--expect`, the exit code is 1 only if a must-pass spec doesn't pass. A known-failing spec that starts passing is reported so it can be promoted. `expectations.datamodel.json` does the same for every spec at the datamodel level. Each of its `knownFailing` reasons starts with a class: `emulation gap`, `harness gap`, `needs the real engine`, `slow`, `spec bug`, or `out of scope`.

## Portability lint (`portability.luau`)

`npm run lint:portability` finds Roblox-only API use in the modules meant to run without the engine, so a new engine dependency there gets noticed. It only reports. It never edits code, and Roblox-only modules outside the closure aren't its concern.

- **The pure closure** is every module reachable at require time from the roots at the top of `portability.luau`: the immediate-mode core, `JecsImmediateHooksCoreHooks`, ServiceBag, Rx/Promise/Signal/Maid, Spring and RandomUtils. Requires are followed statically (`require("Name")` through Nevermore's resolution, plus `require(script.Parent.X)`), with comments stripped.
- **The check** runs `luau-lsp --platform=standard` with `portability/portable.d.luau`, which declares only what the `basic` host polyfills.
- **Findings:**
  - Runtime: an unknown global (`game`, `Vector3`, `workspace`...), marked "import" when it sits on an unindented line and so runs at require time.
  - Type-only: a Roblox type in an annotation. Harmless at runtime.
- **The baseline.** `--check` compares against `portability/baseline.json` and exits 1 when a file gains a finding. `--update-baseline` accepts the current state. Full details go to `out/portability.json`.

## Working on the runner

- Type-check it: `luau-lsp analyze --platform=standard tools/lune-headless/run.luau tools/lune-headless/worker.luau tools/lune-headless/lib`. The local `.luaurc` aliases `@lune` to `~/.lune/.typedefs/0.10.5/`; run `lune setup` once (outside the repo, since it edits the current directory's `.luaurc`).
- `selftest/Runner.spec.lua` pins down the runner's own semantics. Tests named `[fails] ...` must fail; `selftest/check.luau` enforces it.
- Don't benchmark through this runner. Per-module environments turn off Luau's fast paths for builtins (a `math`-heavy loop measured about 5× slower than under `luau.load` with the default environment).
