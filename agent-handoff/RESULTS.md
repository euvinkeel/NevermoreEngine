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
