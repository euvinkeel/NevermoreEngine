# Probe tooling (throwaway prototypes, written on Windows)

All paths are passed as arguments. Run from anywhere with Lune 0.10.5 and Node.

| File | What it does |
|---|---|
| `nvlune.luau` | Runs one Nevermore spec under Lune: `lune run nvlune.luau <repo>/src <spec.lua> --shim=none\|basic\|roblox`, printing a final `RESULT {json}` line. It emulates Nevermore's loader (modules indexed by name; npm packages via default.project.json) and includes a mini jest with fake timers. `--shim` picks how much Roblox to fake. |
| `a1/nvlune_a1.luau` | Improved copy: callable `expect` with `expect.any/anything`, `debug.getmemorycategory`, an HttpService stub. **Start from this one.** |
| `a1/sched.spec.lua` | 13 checks of Nevermore's async helpers against Lune's real scheduler. |
| `a1/Promise.patched.lua` | Promise.lua with HttpService fetched lazily (the proposed upstream seam). |
| `run_specs.js` | Runs every spec in `specs.json` through `<dir>/nvlune.luau`: `node run_specs.js <dir> <repo>/src <lune> <shim>`. Writes `spec_results_<shim>.json`. |
| `closure.js` | Run from `<repo>/src`: `node closure.js <outDir>`. Writes `closure.json` (package closure of immediateutils/jecs/iris). |
| `scan_rbx.js` | Run from `<repo>/src`: `node scan_rbx.js <outDir>`. Reads `closure.json` and writes `rbx_touch.json` (regex scan for Roblox APIs per file) and `specs.json` (absolute spec paths for this machine). |
| `module_graph.js` | `node module_graph.js <outDir> <repo>/src` gives the module-level require graph from the immediateutils entry points, with Roblox hits per module. |
| `causes.js` | Groups failures in a `spec_results_*.json` by root cause. |
| `stack.spec.luau` | Probe spec: builds the full immediate stack with real jecs and ticks a system 5 times. |
| `lune_roblox_probe.luau` | Lists what `@lune/roblox` supports (no events). |
| `a3/stage.luau`, `a3/shim.luau`, `a3/lune_shim.d.luau` | Alternative loading approach: a generated copy with bare requires rewritten to `./Name`, a `getfenv(0)` globals shim, and a defs file for a portability lint. |
| `baseline/spec_results_*.json` | Windows results at the basic and roblox levels (paths replaced with `<repo>`). |
