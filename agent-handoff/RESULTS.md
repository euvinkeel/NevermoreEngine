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
