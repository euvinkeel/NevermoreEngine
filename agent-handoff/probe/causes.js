const fs = require("fs");
const R = JSON.parse(fs.readFileSync(process.argv[2]));
const causes = {}, per = {}, examples = {};
function classify(m) {
	let x;
	if ((x = m.match(/GetService\("(\w+)"\)\.(\w+)/))) return "service member " + x[1] + "." + x[2];
	if (/yielded and never resumed/.test(m)) return "test yields (real scheduler / frame events needed)";
	if ((x = m.match(/global '(\w+)'/))) return "missing global " + x[1];
	if ((x = m.match(/attempt to (index|call) nil( value)?( with '(\w+)')?/))) return "nil " + x[1] + (x[4] ? " ." + x[4] : "");
	if (/expected/.test(m)) return "assertion mismatch";
	return "other";
}
for (const r of R) {
	const fl = Array.isArray(r.failures) ? r.failures : Object.values(r.failures || {});
	for (const f of fl) {
		const m = f.includes(" :: ") ? f.split(" :: ").slice(1).join(" :: ") : f;
		const c = classify(m);
		causes[c] = (causes[c] || 0) + 1;
		(per[c] = per[c] || new Set()).add(r.pkg);
		(examples[c] = examples[c] || []).length < 2 && examples[c].push(m.replace(/^.*?:\d+: /, "").slice(0, 140));
	}
}
for (const [c, n] of Object.entries(causes).sort((a, b) => b[1] - a[1])) {
	console.log(String(n).padStart(4), " ", c.padEnd(55), " ", [...per[c]].join(","));
	for (const e of examples[c]) console.log("        e.g.", e);
}
