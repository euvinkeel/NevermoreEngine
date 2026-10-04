# lune-headless

Runs Nevermore's `*.spec.lua` files under [Lune](https://github.com/lune-org/lune), with no Roblox Studio and no Open Cloud. Each spec runs unmodified: the runner emulates Nevermore's loader and the parts of jest-lua the specs use, and fakes as much of Roblox as you ask for.

This is the one Luau tool under `tools/` (the rest are TypeScript). It has no dependencies beyond `lune` 0.10.5 from `aftman.toml`.

## Usage

```bash
npm run test:lune            # the immediateutils closure, gated by expectations.json
npm run test:lune:all        # every spec under src/
npm run test:lune:selftest   # checks the runner's own semantics

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
| `basic` (default) | `task`, `os` (faked by fake timers), `tick/time/wait/delay/spawn`, a `debug` proxy with the profiling and memory-category functions, captured `warn`/`print`, pure `Random`/`DateTime`/`TweenInfo`, `shared`, and a `game` whose only working service is a pure `HttpService`. |
| `roblox` | `basic` plus `@lune/roblox` Instances and datatypes. Lune's Instances have **no events**. |

## How it works

- `run.luau` builds a package index once, picks specs, and starts one `worker.luau` process per spec (`--jobs`, default 4). A worker that runs past `--timeout` (60 s) is killed and reported as `timeout`.
- `worker.luau` loads the spec through `lib/ModuleLoader.luau`, collects its tests, runs them, and writes JSON.
- **Module resolution** (`lib/PackageIndex.luau`) follows Nevermore's loader (`src/loader/src/Dependencies/PackageTracker.lua`): the requiring package's own modules, then its direct dependencies, then a breadth-first walk of transitive dependencies (standing in for the loader's implicit-parent lookup). A name found only through a last-resort global search is listed in the spec's `notes`.
- **`script`** is a filesystem-backed stand-in for the module's Instance (`Name`, `Parent`, children, `FindFirstChild`, `WaitForChild`, `GetChildren`, `IsA`, `GetFullName`), so Instance-style requires like `require(script.Parent.Util)` work.
- **Lune's `fs` yields and Luau can't yield inside a metamethod,** and `script.Parent.X` is a metamethod. `lib/FileSnapshot.luau` lists the spec's package closure (and reads workspace sources) up front so those lookups never touch `fs`.
- **Errors in spawned threads** (`task.spawn/defer/delay`) are captured per test as `strayErrors` and don't fail the test, as on Roblox.

## Mini-jest (`lib/MiniJest.luau`, `lib/Expect.luau`)

Same API as the jest-lua that Nevermore specs use: `Jest.Globals.describe/it/test/expect/jest/beforeAll/afterAll/beforeEach/afterEach`, plus `.skip`, `.only` and `it.todo`.

- **Collect, then run.** Like Jest, describe bodies run while the file loads and tests run afterwards. Hooks are scoped to the describe block that declares them.
- **Async tests.** Each test runs in its own thread, and it passes only if that thread *finishes* without error. A test that yields and then fails is a failure. A test that doesn't finish within `--test-timeout` (5 s) fails. Tests that take a `done` argument finish when `done()` is called.
- **Matchers:** `toBe` (identity, NaN equals NaN), `toEqual`, `toStrictEqual`, `toBeNil`, `toBeDefined`, `toBeTruthy`, `toBeFalsy`, `toBeNaN`, `toBeCloseTo`, `toBeGreaterThan[OrEqual]`, `toBeLessThan[OrEqual]`, `toContain`, `toContainEqual`, `toHaveLength`, `toMatch`, `toBeInstanceOf`, `toHaveProperty`, `toThrow`, and the mock matchers `toHaveBeenCalled[Times|With]`, `toHaveBeenLastCalledWith`, `toHaveBeenNthCalledWith`. Each works with `.never`, and with `.` or `:`. `toThrow("text")` matches a substring of the message.
- **Asymmetric matchers:** `expect.any(typeName | class)`, `expect.anything()`, `expect.stringContaining`, `expect.stringMatching`, `expect.objectContaining`, `expect.arrayContaining`.
- **Mocks:** `jest.fn(impl?)` returns `(mock, forwardingFunction)` like jest-lua. `jest.spyOn` keeps one spy per object and key, even across `restoreAllMocks`, which is a jest-lua quirk that some specs rely on.
- **Fake timers** follow jest-lua's modern fake timers. `useFakeTimers` fakes `task.delay`, `task.wait`, `task.cancel`, `delay`, `os.clock`, `os.time`, `tick`, `time` and `DateTime.now`; `task.spawn` and `task.defer` stay real. Also provided: `advanceTimersByTime(ms)`, `runAllTimers`, `runOnlyPendingTimers`, `advanceTimersToNextTimer`, `clearAllTimers`, `getTimerCount`, `setSystemTime`. Two differences from jest-lua:
  - A fake `task.delay` returns a thread, as on Roblox.
  - A timer callback runs in its own thread, so one that yields doesn't suspend the test.

  An error in a timer callback is still rethrown from `advanceTimersByTime`.

## Expectations

`expectations.json` lists the specs that must pass (`mustPass`) and the ones known to fail, each with a reason (`knownFailing`). With `--expect`, the exit code is 1 only if a must-pass spec doesn't pass. A known-failing spec that starts passing is reported so it can be promoted.

## Working on the runner

- Type-check it: `luau-lsp analyze --platform=standard tools/lune-headless/run.luau tools/lune-headless/worker.luau tools/lune-headless/lib`. The local `.luaurc` aliases `@lune` to `~/.lune/.typedefs/0.10.5/`; run `lune setup` once (outside the repo, since it edits the current directory's `.luaurc`).
- `selftest/Runner.spec.lua` pins down the runner's own semantics. Tests named `[fails] ...` must fail; `selftest/check.luau` enforces it.
- Don't benchmark through this runner. Per-module environments turn off Luau's fast paths for builtins (a `math`-heavy loop measured about 5× slower than under `luau.load` with the default environment).
