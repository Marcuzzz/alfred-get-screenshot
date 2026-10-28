#!/usr/bin/env osascript -l JavaScript
ObjC.import("stdlib");
const app = Application.currentApplication();
app.includeStandardAdditions = true;
//──────────────────────────────────────────────────────────────────────────────

/** @type {AlfredRun} */
// biome-ignore lint/correctness/noUnusedVariables: Alfred run
function run() {
	const dir = app.pathTo("home folder").toString() + "/Documents/screenshots";
	const limit = 15;
	const items = [];

	const ls = app.doShellScript(
		`ls -t ${JSON.stringify(dir)}/*.png 2>/dev/null | head -${limit} || true`,
	);
	const paths = ls.split(/[\r\n]+/).filter((p) => p.length > 0);

	for (const fullPath of paths) {
		const name = fullPath.replace(/^.*\//, "");
		items.push({
			title: name,
			subtitle: fullPath,
			arg: fullPath,
			icon: { path: fullPath },
		});
	}

	if (items.length === 0) {
		items.push({
			title: "No screenshots found",
			subtitle: dir,
			valid: false,
		});
	}

	return JSON.stringify({ items });
}
