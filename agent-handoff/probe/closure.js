// Package-level dependency closure from package.json "dependencies" (workspace packages).
// Usage (from the repo's src/ directory): node closure.js <outDir>   -> writes <outDir>/closure.json
// Roots: immediateutils, jecs, iris. Feeds scan_rbx.js.
const fs = require("fs");
const path = require("path");
const outDir = process.argv[2] || ".";
const pkgDirByName = {};
for (const d of fs.readdirSync(".")) {
	const p = path.join(d, "package.json");
	if (fs.existsSync(p)) {
		try {
			pkgDirByName[JSON.parse(fs.readFileSync(p)).name] = d;
		} catch (e) {}
	}
}
const roots = ["@quenty/immediateutils", "@quenty/jecs", "@quenty/iris"];
const seen = new Map();
const external = new Set();
function visit(name, depth) {
	if (seen.has(name)) return;
	const dir = pkgDirByName[name];
	if (!dir) {
		external.add(name);
		return;
	}
	const pkg = JSON.parse(fs.readFileSync(path.join(dir, "package.json")));
	const deps = Object.keys(pkg.dependencies || {});
	seen.set(name, { dir, deps, depth });
	for (const dep of deps) visit(dep, depth + 1);
}
roots.forEach((r) => visit(r, 0));
fs.writeFileSync(
	path.join(outDir, "closure.json"),
	JSON.stringify([...seen].map(([name, v]) => ({ name, dir: v.dir, deps: v.deps, depth: v.depth })), null, 1)
);
console.log(`closure: ${seen.size} workspace packages; external: ${[...external].join(", ")}`);
