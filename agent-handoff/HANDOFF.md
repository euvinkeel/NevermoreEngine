# Handoff: headless Luau tests for immediateutils

You're picking up overnight work on euvinkeel's fork of NevermoreEngine. The owner (euvinkeel, who wrote most of immediateutils) is asleep and will review your branch in the morning. Read this file, then `FINDINGS.md` (the evidence so far), then start.

## Ground rules
1. **Branch.** Work only on `users/euvinkeel/headless-luau` in `euvinkeel/NevermoreEngine`. Don't create, push to, or delete any other branch. Don't open pull requests, and never target `Quenty/NevermoreEngine`.
2. **Push often.** Commit and push after every milestone and at least every hour of work. Cloud machines are reclaimed when idle, and uncommitted work is lost.
3. **No agents.** Don't spawn subagents or workflows. Do everything in this one session.
4. **No publishing or releasing.** No `npm publish`, `auto`, `nevermore deploy`, version bumps or changeset/CHANGELOG edits. Don't touch `.github/workflows`.
5. **Roblox behavior must not change.** Any change to Nevermore source must be small, follow Nevermore conventions, cost nothing on Roblox, and keep `npm run lint:luau` at 0 errors. Put each source change in its own commit, with the reason in the message.
6. **Stay in scope.** No Roblox Open Cloud, no secrets, no new network services. Statuh (the planned netcode) work happens only as the design and prototype in milestone M4, under `experiments/statuh-scope/`. Nothing Statuh-related goes into `src/`.
7. **When unsure,** pick the conservative option, write the question in `agent-handoff/QUESTIONS.md`, and keep going.

## Goal
Make `src/immediateutils`, the jecs Immediate addon (`src/jecs/src/Shared/Immediate`) and their dependency closure testable headlessly with **Lune**, with no Roblox Studio and no Open Cloud. Roblox behavior and IDE typing must stay unchanged.

Why: a netcode layer for immediateutils is planned next. It needs fast, deterministic tests (simulated latency and packet loss, fuzzing) that run in CI and in cloud sessions like this one.

## Where things stand
Everything in `FINDINGS.md` was verified on Windows. In short:
- **The immediateutils core path needs no source changes to run in Lune,** only a host providing `task`, a `debug` proxy and a loader stand-in. The full stack (`ImmediateInstall.stack3` + jecs + hooks + defer + common hooks) ticks under Lune.
- **Rx/Promise/Signal family:** all of their specs pass with the `probe/a1` harness. The only source fix worth making is Promise.lua's import-time HttpService.
- **Instance-heavy packages** (attributeutils, instanceutils, tie, valuebaseutils, steputils) need a fake DataModel with events.
- **Prototype tooling is in `agent-handoff/probe/`.** It was written on Windows; all paths come in as arguments.

## Milestones
Do them in order. After each, update `agent-handoff/RESULTS.md` (numbers + exact commands to reproduce), then commit and push.

### M0. Toolchain and baseline
- Install the tools from `aftman.toml`: lune 0.10.5, luau-lsp `Quenty/luau-lsp@1.58.0-quenty.1`, rojo (Quenty fork), stylua, selene.
  - If GitHub release downloads fail (the cloud GitHub proxy may block release assets from repos not attached to the session), use `cargo install` for lune/stylua/selene/rojo (crates.io is reachable).
  - For luau-lsp, try other ways; if impossible, note it in QUESTIONS.md and skip the typing checks.
- Build: `pnpm install --frozen-lockfile`, then `pnpm -r --filter './tools/**' --filter '!./tools/nevermore-vscode' run build`, then `npm run build:sourcemap`. Mirror `.github/workflows/linting.yml`.
- Baseline: `npm run lint:luau` should give 0 errors. Record the time and result.

### M1. Turn the probe into a real test runner
- Move the harness into `tools/lune-headless/` (keep it small and dependency-free) and add an `npm run test:lune` script that runs every spec in the immediateutils closure and writes a JSON summary. Optionally add a flag for all of `src`.
  - Start from `probe/a1/nvlune_a1.luau`, which has `expect.any`, `debug.getmemorycategory` and the HttpService stub.
  - Regenerate the closure with `probe/closure.js` then `probe/scan_rbx.js`.
- **Fix the known bug:** a test that yields and then fails is counted as passed. Also add a per-test timeout.
- Keep the mini-jest API identical to what Nevermore specs use: `Jest.Globals.describe/it/expect/jest/beforeEach/afterEach`, the `toBe/toEqual/toThrow/toBeNil/toHaveLength/never` matchers, `expect.any`, and the fake timers `useFakeTimers/advanceTimersByTime/useRealTimers`.
- Acceptance: on Linux, reproduce or beat the Windows numbers in FINDINGS §4.

### M2. Core path green with no source changes
- These must pass through host polyfills only: `ImmediateScheduler.spec`, `ServiceBag.spec`, `MaidTaskUtils.spec`, plus a new spec for the full immediate stack (adapt `probe/stack.spec.luau`) placed next to immediateutils' other specs.
- Also add a spec that ticks the jecs hooks pack: `hooks.cache`, `throttle`, `changed`, `state` and `gate` with fake timers.

### M3. The Rx/Promise family
- All specs for rx, brio, promise, canceltoken, cancellabledelay, throttle and maid pass.
- Land the Promise.lua lazy-HttpService change as its own commit, keeping `_toHumanReadable` output identical on Roblox. `lint:luau` must stay at 0.

### M4. Selective replication for Statuh: design and code-UX prototype
Read `reference/statuh-2.0-overview.md` and `reference/statuh-selective-replication.md` first. The owner wants per-client replication to feel **natural to express** for game developers, and the guardrails in that doc are binding.
- **Designs.** Write 2–3 competing API designs for expressing "who sees what":
  - teams and rooms (membership vs audience)
  - owner-only components
  - children inheriting a parent's visibility
  - per-entity overrides
  - custom/spatial rules as key functions

  Show each as realistic game code for at least:
  - a tower defense game with two teams and private inventories
  - an RTS with fog of war
  - instanced dungeons with parties and spectators

  Score each design against the guardrails and pick one, with reasons. Record this in `experiments/statuh-scope/DESIGN.md`.
- **Typing.** Write typed stubs for the chosen API plus example files that **must type-check**, and "must-fail" files (lines that must produce errors). Check both with the luau-lsp from M0, using `--flag:LuauSolverV2=false` like Nevermore does. Put the exact commands in the doc.
- **Prototype.** Build a small **pure-Luau prototype of the scope core** under `experiments/statuh-scope/` with no networking. Input: a jecs world, plus scope rules, plus a set of players. Output: per-client ENTER/LEAVE/DEL/ROLLBACK diffs in the fixed order, with redaction of out-of-scope references, fail-closed defaults, revocation that's immediate, and relevance changes with hysteresis.
- **Tests.** Test it under Lune with the M1 runner, including **randomized invariant tests**: random worlds, rules and edits each frame, with a seeded RNG. Each failure must print its seed. Assert that:
  - no out-of-scope net ID ever appears in any client's output
  - removing a constraint never widens visibility
  - LEAVE and DEL are never confused
  - groups enter atomically
- **Report.** Add a results section with design decisions, open questions and rough per-frame cost numbers from benchmarks (e.g. 50 players × 2,000 entities, 10% dirty per frame).

### M5. A fake DataModel with events
- Build an event-capable Instance layer for the host. Preferred: vendor pigxity-games/lune-test (Apache-2.0; keep its LICENSE and notice) and extend it. Do **not** copy code from unlicensed projects (RobloxMock); learning from their design is fine.
- It needs:
  - `typeof()` returning `"Instance"`/`"RBXScriptSignal"`/`"RBXScriptConnection"` (override `typeof` in the host environment).
  - Changed/GetPropertyChangedSignal, ChildAdded/Removed, DescendantAdded/Removing, AncestryChanged, AttributeChanged/GetAttributeChangedSignal, Destroying.
  - BindableEvent and BindableFunction.
  - RunService with manual stepping (Heartbeat/Stepped/RenderStepped/PreRender) and configurable IsClient/IsServer/IsStudio/IsRunning.
  - HttpService GenerateGUID/JSONEncode/JSONDecode, where `{}` encodes as `[]` like Roblox.
- Target the specs in attributeutils, instanceutils, valuebaseutils, tie and steputils.
- Report per-spec before/after numbers, and classify every remaining failure as harness gap, emulation gap, or needs the real engine.
- Write down each fidelity compromise, for example signal ordering and deferred vs immediate events.

### M6. Split the common hooks (only after M1–M5)
- Implement the split in FINDINGS §2: a pure pack, a Roblox pack and a facade.
- Behavior on Roblox must be identical, and the `debug.info(3, ...)` call-site keying must survive. **Never wrap a hook in another hook.**
- Add Lune specs for the pure hooks. `lint:luau` stays at 0.

### M7. Portability lint (stretch)
- A script that runs `luau-lsp analyze --platform=standard` with a small defs file over the pure closure, to catch new Roblox-only API use. Report findings only; don't "fix" Roblox-only modules.

### Out of scope
Hot reload, Iris, changing the Nevermore loader, Statuh networking/transport code, anything Statuh inside `src/`, any upstream PR.

## What to leave for the owner
- **Commits:** small and focused, with messages explaining why.
- **`agent-handoff/RESULTS.md`:**
  - Per milestone: what was done, spec pass rates (before/after), and commands to reproduce.
  - A list of every Nevermore source change with its risk on Roblox.
  - Anything you couldn't verify.
- **`agent-handoff/QUESTIONS.md`:** decisions you deferred.
- **Last thing before you stop,** for the owner to pick up in the morning:
  1. Make sure everything is committed and pushed.
  2. Put a short summary at the top of RESULTS.md.

## Practical notes
- **Injecting globals in Lune:** do `getfenv(0).task = require("@lune/task")` in the entry script before any require. `_G` doesn't propagate. `debug` is read-only, so rebind the global: `getfenv(0).debug = setmetatable({ profilebegin = ..., profileend = ..., setmemorycategory = ..., getmemorycategory = ..., resetmemorycategory = ... }, { __index = debug })`. Inside `luau.load`, use the `environment` table instead.
- **Third-party dependencies** (jecs, `t`) resolve via `node_modules/.pnpm/*/node_modules/<scope>/<pkg>/default.project.json` (`tree.$path`); see `nvlune.luau`. `require("Jecs")` maps to the `jecs` package (case-insensitive).
- **Benchmarks:** `getfenv`/injected environments disable Luau's safe-env fast paths. Don't benchmark through them; use `luau.load(..., { codegenEnabled = true })` without `getfenv` when measuring.
- **Specs live next to their modules as `*.spec.lua`.** They start with `local require = require(script.Parent.loader).load(script)` and get Jest via `require("Jest")`.
- **Pull request conventions** are in `.github/` if you need them (you shouldn't).
