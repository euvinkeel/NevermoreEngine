// Module-level require graph from immediateutils entry points (what actually loads, not package.json).
// node module_graph.js <probeDir> <nevermoreSrc>
const fs = require("fs");
const path = require("path");
const [probeDir, src] = process.argv.slice(2);

const index = {};
function walk(dir) {
	for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
		if (e.name === "node_modules" || e.name === ".git" || e.name === "test") continue;
		const p = path.join(dir, e.name);
		if (e.isDirectory()) walk(p);
		else {
			const m = e.name.match(/^([^.]+)\.luau?$/);
			if (m && !index[m[1]]) index[m[1]] = p;
		}
	}
}
walk(src);

const touch = JSON.parse(fs.readFileSync(path.join(probeDir, "rbx_touch.json")));
const hitsByFile = {};
for (const pkg of Object.values(touch)) for (const fh of pkg.fileHits) hitsByFile[path.resolve(src, fh.file)] = fh.hits;

const ROOTS = {
	core: ["ImmediateCoreUtils", "ImmediateInstall", "ImmediateScheduler", "ImmediateDeferInstall"],
	jecs: ["JecsImmediateInstall", "JecsImmediateUtils", "JecsImmediateHooksInstall", "JecsImmediateHookUtils"],
	commonHooks: ["JecsImmediateHooksCommonHooks"],
	hotReload: ["ImmediateHotReloadInstall"],
	iris: ["IrisImmediateInstall"],
};
const external = new Set(["Jecs", "Jecst", "t", "Iris", "Jest"]);
function closure(roots) {
	const seen = new Map();
	const stack = [...roots];
	while (stack.length) {
		const n = stack.pop();
		if (seen.has(n)) continue;
		const file = index[n];
		if (!file || external.has(n)) {
			seen.set(n, { file: null, external: true, requires: [] });
			continue;
		}
		const text = fs.readFileSync(file, "utf8");
		const reqs = [...new Set([...text.matchAll(/require\("([A-Za-z0-9_]+)"\)/g)].map((m) => m[1]))];
		seen.set(n, { file, requires: reqs });
		for (const r of reqs) stack.push(r);
	}
	return seen;
}
const report = {};
for (const [group, roots] of Object.entries(ROOTS)) {
	const c = closure(roots);
	const modules = [...c.entries()].map(([name, v]) => ({
		name,
		file: v.file && path.relative(src, v.file).split(path.sep).join("/"),
		external: !!v.external,
		requires: v.requires,
		roblox: v.file ? hitsByFile[path.resolve(v.file)] || null : null,
	}));
	report[group] = modules;
	const rbx = modules.filter((m) => m.roblox);
	console.log(`\n[${group}] ${modules.length} modules, ${rbx.length} touch Roblox APIs:`);
	for (const m of rbx) console.log("   ", m.name.padEnd(30), Object.entries(m.roblox).map(([k, v]) => `${k}=${v.join("|")}`).join("  ").slice(0, 150));
	const ext = modules.filter((m) => m.external).map((m) => m.name);
	if (ext.length) console.log("    external:", ext.join(", "));
}
fs.writeFileSync(path.join(probeDir, "module_graph.json"), JSON.stringify(report, null, 1));
