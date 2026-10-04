# Questions and deferred decisions

Each entry names the conservative choice I made so work could continue.

## M0
- **Global nevermore-cli.** CI runs `npm install --ignore-scripts -g .` in `tools/nevermore-cli`. Repeating it over an existing global link fails inside npm (`Cannot read properties of null (reading 'package')`), so `cloud-setup.sh` skips it when `nevermore` is already on PATH. *Choice:* skip; nothing in the milestones needs the global CLI.

## M1
- **Where the runner lives.** `tools/CLAUDE.md` describes `tools/` as TypeScript; the handoff asked for `tools/lune-headless/`. *Choice:* put it there with no `package.json`, so it isn't a pnpm workspace project and `pnpm-lock.yaml` doesn't change. Run it through root scripts (`npm run test:lune`).
- **Root `package.json` scripts.** I added `test:lune`, `test:lune:all` and `test:lune:selftest`; there are no other root changes. *Choice:* kept, since the handoff asked for `npm run test:lune`.
- **What `npm run test:lune` gates on.** 20 of the 37 closure specs can't pass without M5's fake DataModel, so a plain "all green" exit code would always be red. *Choice:* `expectations.json` lists must-pass specs (exit 1 on regression) and known-failing specs with reasons. Should CI run it? I didn't touch `.github/workflows` (ground rule 4).
- **Fake timer callbacks run in their own thread** (jest-lua calls them inline). Roblox runs `task.delay` callbacks in new threads, so a callback that yields shouldn't suspend the test. Errors are still rethrown from `advanceTimersByTime` like jest-lua. Say if you'd rather match jest-lua exactly.
- **Flaky spec outside the closure:** `src/scoredactionservice/.../ScoredActionPicker.spec.lua` "breaks score ties in favor of the older action" compares `os.clock()` reads and fails about 1 in 3 runs under parallel load headlessly. Not touched (out of scope).

## M2
- **Where the full-stack spec lives.** The handoff said "next to immediateutils' other specs", but the full stack needs `JecsImmediateInstall`, `JecsImmediateHooksInstall` and the common hooks, which live in `src/jecs`. jecs depends on immediateutils, not the other way round, so a spec inside immediateutils couldn't resolve them on Roblox. *Choice:* `ImmediateStack.spec.lua` in immediateutils covers the immediateutils-only stack (installers, scheduler, defer), and `JecsImmediateStack.spec.lua` plus `JecsImmediateHooksCommonHooks.spec.lua` live in `src/jecs/src/Shared/Immediate/`. Move them if you prefer another layout.
