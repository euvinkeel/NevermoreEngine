// Run every closure spec under Lune, one process each, and aggregate results.
// node run_specs.js <probeDir> <nevermoreSrc> <lune.exe> [shimLevel]
const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

const [probeDir, nvSrc, lune, shim = "basic"] = process.argv.slice(2);
const specs = JSON.parse(fs.readFileSync(path.join(probeDir, "specs.json")));
const results = [];
for (const s of specs) {
	const t0 = process.hrtime.bigint();
	const r = spawnSync(lune, ["run", path.join(probeDir, "nvlune.luau"), nvSrc, s.file, `--shim=${shim}`], {
		encoding: "utf8",
		timeout: 60000,
	});
	const ms = Number(process.hrtime.bigint() - t0) / 1e6;
	const line = (r.stdout || "").split("\n").find((l) => l.startsWith("RESULT "));
	let parsed = null;
	if (line) {
		try {
			parsed = JSON.parse(line.slice(7));
		} catch (e) {}
	}
	results.push({
		pkg: s.pkg,
		spec: path.basename(s.file),
		file: s.file,
		ms: Math.round(ms),
		timedOut: r.error && r.error.code === "ETIMEDOUT",
		...(parsed || { passed: 0, failed: 0, loadError: ((r.stderr || "") + (r.stdout || "")).slice(0, 400) || "no output" }),
	});
}
fs.writeFileSync(path.join(probeDir, `spec_results_${shim}.json`), JSON.stringify(results, null, 1));

let P = 0,
	F = 0,
	clean = 0,
	loadFail = 0;
for (const r of results) {
	P += r.passed;
	F += r.failed;
	const status = r.loadError ? "LOAD-FAIL" : r.failed ? "SOME-FAIL" : "ALL-PASS";
	if (status === "ALL-PASS") clean++;
	if (status === "LOAD-FAIL") loadFail++;
	console.log(
		status.padEnd(10),
		r.pkg.padEnd(22),
		r.spec.padEnd(40),
		`${r.passed}/${r.passed + r.failed}`.padStart(7),
		r.loadError ? "  " + r.loadError.split("\n")[0].replace(/^.*?:\d+: /, "").slice(0, 110) : ""
	);
}
console.log(`\nspecs: ${results.length}  all-pass: ${clean}  load-fail: ${loadFail}  tests passed: ${P}  failed: ${F}`);
