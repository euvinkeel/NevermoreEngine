// Scan the dependency closure for Roblox API touchpoints. Run from Nevermore/src.
const fs = require("fs");
const path = require("path");

const OUT = process.argv[2];
const closure = JSON.parse(fs.readFileSync(path.join(OUT, "closure.json")));
const P = {
	service: /game:GetService\(\s*"(\w+)"/g,
	instance: /Instance\.new\(|:IsA\(|:GetChildren\(|:GetDescendants\(|:FindFirstChild\w*\(|:WaitForChild\(|:GetAttribute\w*\(|:SetAttribute\(|:GetPropertyChangedSignal\(|\.(ChildAdded|ChildRemoved|DescendantAdded|DescendantRemoving|AncestryChanged|Destroying|AttributeChanged)\b|:IsDescendantOf\(|:Clone\(\)/g,
	typeofRbx: /typeof\([^)]*\)\s*[=~]=\s*"(Instance|RBXScriptConnection|RBXScriptSignal|Vector3|Vector2|CFrame|Color3|UDim2?|EnumItem|Enum|BrickColor|NumberRange|NumberSequence|ColorSequence|Rect|Ray|Region3|TweenInfo|Font|DateTime|Random)"/g,
	task: /\btask\.(spawn|defer|delay|wait|cancel|desynchronize|synchronize)\b/g,
	debugRbx: /debug\.(profilebegin|profileend|setmemorycategory|resetmemorycategory|dumpcodesize)\b/g,
	datatype: /\b(Vector3|Vector2|CFrame|Color3|UDim2|UDim|BrickColor|NumberSequence|ColorSequence|NumberRange|TweenInfo|Ray|Region3|Rect|PhysicalProperties|Random|DateTime|Font)\.(new|fromRGB|fromHSV|fromHex|zero|one|xAxis|yAxis|zAxis|identity|lookAt|fromMatrix|fromOrientation|Angles|fromAxisAngle|now|fromUnixTimestamp|fromScale|fromOffset)\b/g,
	enum: /\bEnum\.\w+/g,
	robloxGlobal: /(?<![.:\w])(workspace|settings\(\)|UserSettings\(\)|plugin|tick\(\)|elapsedTime\(\)|wait\(|delay\(|spawn\()/g,
	scriptUse: /\bscript\.(?!Parent\.loader)\w+/g,
	rawRequire: /rawrequire\(|require\(script\.(?!Parent\.loader\))|require\(\w+:/g,
};

function walk(dir, acc) {
	if (!fs.existsSync(dir)) return acc;
	for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
		if (e.name === "node_modules" || e.name === ".git") continue;
		const p = path.join(dir, e.name);
		if (e.isDirectory()) walk(p, acc);
		else if (/\.luau?$/.test(e.name)) acc.push(p);
	}
	return acc;
}

const norm = (f) => f.split(path.sep).join("/");
const out = {};
const specs = [];
for (const pkg of closure) {
	const files = walk(path.join(pkg.dir, "src"), []);
	const pk = { files: 0, pureFiles: 0, touch: {}, fileHits: [], pure: [] };
	for (const f of files) {
		const base = path.basename(f);
		if (/\.spec\.luau?$/.test(base)) {
			specs.push({ pkg: pkg.dir, file: norm(path.resolve(f)) });
			continue;
		}
		if (/\.(story|client|server)\.luau?$/.test(base) || /[\\/]test[\\/]/.test(f)) continue;
		pk.files++;
		const src = fs
			.readFileSync(f, "utf8")
			.split("\n")
			.filter((l) => !/^\s*--/.test(l))
			.join("\n");
		const hits = {};
		for (const [k, re] of Object.entries(P)) {
			const m = [...src.matchAll(re)].map((x) => x[1] || x[0]);
			if (m.length) hits[k] = [...new Set(m)].slice(0, 8);
		}
		if (Object.keys(hits).length) {
			pk.fileHits.push({ file: norm(f), hits });
			for (const k in hits) pk.touch[k] = (pk.touch[k] || 0) + 1;
		} else {
			pk.pureFiles++;
			pk.pure.push(norm(f));
		}
	}
	out[pkg.dir] = pk;
}
fs.writeFileSync(path.join(OUT, "rbx_touch.json"), JSON.stringify(out, null, 1));
fs.writeFileSync(path.join(OUT, "specs.json"), JSON.stringify(specs, null, 1));

let tf = 0;
let tp = 0;
console.log("package".padEnd(24), "files  pure  touchpoints");
for (const [d, v] of Object.entries(out).sort((a, b) => b[1].files - b[1].pureFiles - (a[1].files - a[1].pureFiles))) {
	tf += v.files;
	tp += v.pureFiles;
	console.log(
		d.padEnd(24),
		String(v.files).padStart(5),
		String(v.pureFiles).padStart(5),
		" ",
		Object.entries(v.touch)
			.map(([k, n]) => k + ":" + n)
			.join(" ")
	);
}
console.log("TOTAL files", tf, "pure", tp, "| spec files", specs.length);
