#!/usr/bin/env node
// packages/env-guard/bin/env-guard.js
//
// ホスト側 (開発コンテナの外) から commit する経路にも検査を効かせるための
// 導入コマンド。
//
// コンテナの中では、イメージが git の system 設定に書く core.hooksPath に
// よって全リポジトリ・全 clone で hook が効く。ホストの git はコンテナの
// 設定ファイルを読まないので、ホストの GUI クライアントから commit すると
// その hook は走らない。そこで、ホスト側で既に動いている simple-git-hooks に
// 相乗りする形で、このパッケージの hooks/pre-commit を
// .git/hooks/pre-commit から呼ばせる。
//
// .git/hooks/pre-commit を自分で書きに行かないのは、git hook を書き込む
// 仕組みがプロジェクト内に 2 つできるのを避けるため。simple-git-hooks が
// 無いプロジェクトでは、何も書かずに落ちて何を入れればよいかだけを言う。
//
// 実行時依存を持たない (Node の標準モジュールだけで書く)。npx で取ったときに
// 引かれる依存の木が実行のたびに変わりうる状態を作らないため。

const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

// hook を呼ぶコマンド。simple-git-hooks はこの文字列をそのまま
// .git/hooks/pre-commit に書き、git はリポジトリルートで実行する。
const HOOK_PATH = "node_modules/@himorogy/env-guard/hooks/pre-commit";
const HOOK_COMMAND = `sh ${HOOK_PATH}`;

// 「既に env-guard を指しているか」の判定に使う目印。前後に別のコマンドを
// 連結してある場合も導入済みと見なしたいので、完全一致ではなく部分一致。
const HOOK_MARKER = "@himorogy/env-guard/hooks/pre-commit";

const OK = 0;
const FAILED = 1;

function out(line) {
	process.stdout.write(`${line}\n`);
}

function err(line) {
	process.stderr.write(`${line}\n`);
}

function usage(write) {
	write("Usage: env-guard install [--check]");
	write("");
	write("  install          Make this project run the env-guard pre-commit");
	write("                   hook through simple-git-hooks, then verify that");
	write("                   the hook file is actually in place.");
	write("  install --check  Report the current state without writing");
	write("                   anything. Exits 0 only when the hook is in");
	write("                   place, so it can be used from CI or a checklist.");
	write("");
	write("Run it from the root of the repository you want to protect.");
}

// --- package.json の読み取り ---------------------------------------------------

function readPackageJson(pkgPath) {
	let text;
	try {
		text = fs.readFileSync(pkgPath, "utf8");
	} catch (e) {
		return {
			error: [
				`❌ env-guard: could not read ${pkgPath}`,
				`   ${e.message}`,
				"   Run this from the root of the repository you want to protect.",
			],
		};
	}

	let data;
	try {
		data = JSON.parse(text);
	} catch (e) {
		return {
			error: [
				`❌ env-guard: ${pkgPath} is not valid JSON.`,
				`   ${e.message}`,
				"   Nothing was written.",
			],
		};
	}

	if (data === null || typeof data !== "object" || Array.isArray(data)) {
		return {
			error: [
				`❌ env-guard: ${pkgPath} does not contain a JSON object.`,
				"   Nothing was written.",
			],
		};
	}

	return { text, data };
}

function hasDependency(pkg, name) {
	for (const field of ["devDependencies", "dependencies"]) {
		const deps = pkg[field];
		if (deps && typeof deps === "object" && Object.hasOwn(deps, name)) {
			return true;
		}
	}
	return false;
}

// describeConfig -> package.json の simple-git-hooks.pre-commit がどうなっているか。
//
//   installed  … 既に env-guard の hook を指している
//   absent     … 未設定。書き込んでよい
//   conflict   … 別のコマンドが設定済み。上書きしない
//   invalid    … 設定の形が想定と違う。触らない
function describeConfig(pkg) {
	const section = pkg["simple-git-hooks"];

	if (section === undefined) {
		return { kind: "absent" };
	}

	if (
		section === null ||
		typeof section !== "object" ||
		Array.isArray(section)
	) {
		return {
			kind: "invalid",
			reason: 'the "simple-git-hooks" key is not an object',
		};
	}

	const current = section["pre-commit"];

	if (current === undefined) {
		return { kind: "absent" };
	}

	if (typeof current !== "string") {
		return {
			kind: "invalid",
			reason: 'the "pre-commit" entry is not a string',
		};
	}

	if (current.includes(HOOK_MARKER)) {
		return { kind: "installed", current };
	}

	return { kind: "conflict", current };
}

// --- package.json への書き込み --------------------------------------------------
//
// JSON.parse して JSON.stringify で書き戻すと、元のファイルの書式 (インデント
// 幅、空行、末尾改行) が丸ごと現在の整形規則へ寄せられる。他人のリポジトリの
// package.json を、頼まれてもいない範囲まで書き換えることになる。
// そこで、追加するキーの分だけを文字列として差し込む。

// skipString <text> <i> — text[i] が `"` のとき、閉じ引用符の次の位置を返す。
function skipString(text, i) {
	let j = i + 1;
	while (j < text.length) {
		if (text[j] === "\\") {
			j += 2;
			continue;
		}
		if (text[j] === '"') {
			return j + 1;
		}
		j += 1;
	}
	return j;
}

// scanObject <text> <start> — text[start] が `{` のとき、対応する `}` の位置と、
// その object の直下にあるキーの位置を返す。壊れていれば null。
//
// 文字列の中身を読み飛ばすので、値に `{` や `}` が入っていても数え違えない。
function scanObject(text, start) {
	if (text[start] !== "{") {
		return null;
	}

	const keys = new Map();
	let i = start + 1;
	let depth = 0;

	while (i < text.length) {
		const c = text[i];

		if (c === '"') {
			const nameStart = i;
			i = skipString(text, i);
			if (depth === 0) {
				let j = i;
				while (j < text.length && /\s/.test(text[j])) {
					j += 1;
				}
				if (text[j] === ":") {
					let v = j + 1;
					while (v < text.length && /\s/.test(text[v])) {
						v += 1;
					}
					keys.set(JSON.parse(text.slice(nameStart, i)), {
						valueStart: v,
					});
				}
			}
			continue;
		}

		if (c === "{" || c === "[") {
			depth += 1;
		} else if (c === "]") {
			depth -= 1;
		} else if (c === "}") {
			if (depth === 0) {
				return { end: i, keys };
			}
			depth -= 1;
		}

		i += 1;
	}

	return null;
}

function detectIndent(text) {
	const m = text.match(/\n([\t ]+)"/);
	return m ? m[1] : "  ";
}

// insertKey — object の最後のキーとして keyText を差し込む。
// 直前のキーの行末にコンマが 1 つ増えるほかは、行が増えるだけになる。
function insertKey(text, closeIndex, keyText, childPad, parentPad, eol) {
	const head = text.slice(0, closeIndex);
	const trimmed = head.replace(/\s+$/, "");
	const empty = trimmed.endsWith("{");
	const tail = empty ? eol + parentPad : head.slice(trimmed.length);
	const comma = empty ? "" : ",";
	return (
		trimmed + comma + eol + childPad + keyText + tail + text.slice(closeIndex)
	);
}

// addPreCommit — 書き込み後のテキストを返す。安全に差し込めなければ null。
function addPreCommit(text) {
	const rootStart = text.indexOf("{");
	if (rootStart < 0) {
		return null;
	}

	const root = scanObject(text, rootStart);
	if (!root) {
		return null;
	}

	const indent = detectIndent(text);
	const eol = text.includes("\r\n") ? "\r\n" : "\n";
	const value = JSON.stringify(HOOK_COMMAND);
	const section = root.keys.get("simple-git-hooks");

	let updated;
	if (section) {
		const inner = scanObject(text, section.valueStart);
		if (!inner) {
			return null;
		}
		updated = insertKey(
			text,
			inner.end,
			`"pre-commit": ${value}`,
			indent + indent,
			indent,
			eol,
		);
	} else {
		const block = [
			'"simple-git-hooks": {',
			`${indent}${indent}"pre-commit": ${value}`,
			`${indent}}`,
		].join(eol);
		updated = insertKey(text, root.end, block, indent, "", eol);
	}

	// 差し込んだ結果が、意図した 1 キーの追加以外の変化を含まないことを確かめる。
	// 追加したキーを取り除いたものが元と一致しなければ、差し込み位置の読み違い
	// なので書かない。
	let before;
	let after;
	try {
		before = JSON.parse(text);
		after = JSON.parse(updated);
	} catch {
		return null;
	}

	if (after["simple-git-hooks"]?.["pre-commit"] !== HOOK_COMMAND) {
		return null;
	}

	if (section) {
		delete after["simple-git-hooks"]["pre-commit"];
	} else {
		delete after["simple-git-hooks"];
	}

	if (JSON.stringify(before) !== JSON.stringify(after)) {
		return null;
	}

	return updated;
}

// --- hook ファイルの確認 --------------------------------------------------------

function gitHooksDir(root) {
	try {
		const p = execFileSync("git", ["rev-parse", "--git-path", "hooks"], {
			cwd: root,
			encoding: "utf8",
			stdio: ["ignore", "pipe", "pipe"],
		}).trim();
		return path.resolve(root, p);
	} catch {
		return null;
	}
}

function gitHooksPathSetting(root) {
	try {
		return execFileSync("git", ["config", "--get", "core.hooksPath"], {
			cwd: root,
			encoding: "utf8",
			stdio: ["ignore", "pipe", "pipe"],
		}).trim();
	} catch {
		return "";
	}
}

function isExecutable(file) {
	try {
		fs.accessSync(file, fs.constants.X_OK);
		return fs.statSync(file).isFile();
	} catch {
		return false;
	}
}

// verifyHook — 「書いたつもりで効いていない」を作らないための最終確認。
// hook ファイルが在ること・実行できること・env-guard の hook を呼んでいること、
// そしてその呼び先が実際に置かれていることを見る。呼び先まで見るのは、
// package.json に書いて hook ファイルも生まれたのに、パッケージ本体が
// node_modules に無くて commit のたびに失敗する、という形を先に潰すため。
function verifyHook(root, hooksDir) {
	const file = path.join(hooksDir, "pre-commit");
	const problems = [];

	let content;
	try {
		content = fs.readFileSync(file, "utf8");
	} catch {
		return { ok: false, file, problems: [`there is no hook file at ${file}`] };
	}

	if (!isExecutable(file)) {
		problems.push(`${file} is not executable, so git will not run it`);
	}

	if (content.includes(HOOK_MARKER)) {
		const target = path.join(root, HOOK_PATH);
		if (!fs.existsSync(target)) {
			problems.push(
				`${file} runs ${HOOK_PATH}, but there is no such file: install the dependencies of this project`,
			);
		}
	} else {
		problems.push(`${file} does not run ${HOOK_PATH}`);
	}

	return { ok: problems.length === 0, file, problems };
}

function runSimpleGitHooks(root) {
	const bin = path.join(root, "node_modules", ".bin", "simple-git-hooks");

	if (!isExecutable(bin)) {
		out("env-guard: simple-git-hooks is listed in package.json but is not");
		out("env-guard: installed under node_modules, so the hook file could not");
		out(
			"env-guard: be written from here. Install the dependencies and run it:",
		);
		out("env-guard:");
		out("env-guard:   npm install && npx simple-git-hooks");
		return;
	}

	out("env-guard: running simple-git-hooks to write the hook file.");
	try {
		execFileSync(bin, [], { cwd: root, stdio: "inherit" });
	} catch (e) {
		err(`env-guard: simple-git-hooks did not finish: ${e.message}`);
	}
}

// --- コマンド本体 ---------------------------------------------------------------

function reportEffectiveHooksPath(root, file) {
	const configured = gitHooksPathSetting(root);
	if (!configured) {
		return;
	}
	out(`env-guard: note — core.hooksPath is set to ${configured} here, so git`);
	out("env-guard: in this environment runs hooks from there and ignores");
	out(`env-guard: ${file}. A git that does not set core.hooksPath (a client`);
	out("env-guard: running outside this environment) runs the file above.");
}

function missingDependency(pkgPath) {
	return [
		"❌ env-guard: simple-git-hooks is not a dependency of this project.",
		"   env-guard installs its pre-commit hook through simple-git-hooks so",
		"   that the project keeps a single mechanism for writing git hooks.",
		"   Add it first:",
		"",
		"     npm install --save-dev simple-git-hooks",
		"     (pnpm add -D simple-git-hooks / yarn add -D simple-git-hooks)",
		"",
		"   Then run 'env-guard install' again.",
		`   ${pkgPath} was not modified.`,
	];
}

function conflictReport(pkgPath, current) {
	return [
		"❌ env-guard: this project already runs a different pre-commit command.",
		`   currently:  ${current}`,
		`   env-guard needs:  ${HOOK_COMMAND}`,
		"   Refusing to replace it: that would drop the check you already have,",
		"   and nothing would say so afterwards. Combine them yourself, for",
		'   example  "pre-commit": ' +
			JSON.stringify(`${HOOK_COMMAND} && ${current}`),
		"   Putting the env-guard hook first keeps the secret check running even",
		"   when the other command fails.",
		`   ${pkgPath} was not modified.`,
	];
}

function install(root, checkOnly) {
	const pkgPath = path.join(root, "package.json");
	const pkg = readPackageJson(pkgPath);
	if (pkg.error) {
		for (const line of pkg.error) {
			err(line);
		}
		return FAILED;
	}

	// hook の置き場が分からないうちは何も書かない。書けたかどうかを確かめ
	// られないまま package.json だけ変えるのが、いちばん困る中途半端になる。
	const hooksDir = gitHooksDir(root);
	if (!hooksDir) {
		err(`❌ env-guard: ${root} is not inside a git repository (or git is`);
		err("   not on the PATH), so the hook file cannot be placed or checked.");
		err("   Nothing was written.");
		return FAILED;
	}

	const declared = hasDependency(pkg.data, "simple-git-hooks");
	const config = describeConfig(pkg.data);

	if (checkOnly) {
		if (!declared) {
			err(
				"❌ env-guard: simple-git-hooks is not a dependency of this project.",
			);
			err("   The env-guard pre-commit hook is not installed.");
			return FAILED;
		}
		if (config.kind === "invalid") {
			err(`❌ env-guard: ${pkgPath}: ${config.reason}.`);
			return FAILED;
		}
		if (config.kind !== "installed") {
			err("❌ env-guard: package.json does not run the env-guard hook.");
			if (config.kind === "conflict") {
				err(`   its pre-commit command is:  ${config.current}`);
			}
			err("   Run 'env-guard install' to set it up.");
			return FAILED;
		}

		const verified = verifyHook(root, hooksDir);
		if (!verified.ok) {
			err("❌ env-guard: package.json asks for the env-guard hook, but the");
			err("   hook file is not in place, so commits are not being checked.");
			for (const problem of verified.problems) {
				err(`   ${problem}`);
			}
			err("   Run 'npx simple-git-hooks' to write it.");
			return FAILED;
		}

		out(`env-guard: installed — ${verified.file} runs the env-guard hook.`);
		reportEffectiveHooksPath(root, verified.file);
		return OK;
	}

	if (!declared) {
		for (const line of missingDependency(pkgPath)) {
			err(line);
		}
		return FAILED;
	}

	if (config.kind === "invalid") {
		err(`❌ env-guard: ${pkgPath}: ${config.reason}.`);
		err("   Refusing to guess what was meant. Nothing was written.");
		return FAILED;
	}

	if (config.kind === "conflict") {
		for (const line of conflictReport(pkgPath, config.current)) {
			err(line);
		}
		return FAILED;
	}

	if (config.kind === "installed") {
		out("env-guard: package.json already runs the env-guard hook:");
		out(`env-guard:   ${config.current}`);
	} else {
		const updated = addPreCommit(pkg.text);
		if (updated === null) {
			err("❌ env-guard: could not add the entry to package.json without");
			err("   risking changes elsewhere in the file, so nothing was written.");
			err("   Add this by hand:");
			err("");
			err('     "simple-git-hooks": {');
			err(`       "pre-commit": ${JSON.stringify(HOOK_COMMAND)}`);
			err("     }");
			return FAILED;
		}

		try {
			fs.writeFileSync(pkgPath, updated);
		} catch (e) {
			err(`❌ env-guard: could not write ${pkgPath}`);
			err(`   ${e.message}`);
			return FAILED;
		}

		out(`env-guard: added the pre-commit entry to ${pkgPath}:`);
		out(`env-guard:   "pre-commit": ${JSON.stringify(HOOK_COMMAND)}`);
	}

	// package.json に書いただけでは .git/hooks/pre-commit は生まれない。
	// 書けたと報告して実際には何も検査されていない状態を作らないよう、
	// ここで実体化まで進めてから確かめる。
	let verified = verifyHook(root, hooksDir);
	if (!verified.ok) {
		runSimpleGitHooks(root);
		verified = verifyHook(root, hooksDir);
	}

	if (!verified.ok) {
		err("❌ env-guard: the hook is not in place, so nothing is checking your");
		err("   commits yet.");
		for (const problem of verified.problems) {
			err(`   ${problem}`);
		}
		err("   Install the dependencies and run 'npx simple-git-hooks', then");
		err("   run 'env-guard install --check' to confirm.");
		return FAILED;
	}

	out(`env-guard: verified — ${verified.file} exists, is executable, and runs`);
	out(`env-guard: ${HOOK_PATH}`);
	reportEffectiveHooksPath(root, verified.file);
	out("env-guard: add 'simple-git-hooks' to the 'prepare' script if you want");
	out("env-guard: fresh clones of this project to get the hook automatically.");
	return OK;
}

function main(argv) {
	const args = argv.slice(2);

	if (args.includes("--help") || args.includes("-h")) {
		usage(out);
		return OK;
	}

	if (args[0] !== "install") {
		err(`❌ env-guard: unknown command '${args[0] ?? ""}'.`);
		usage(err);
		return FAILED;
	}

	let checkOnly = false;
	for (const arg of args.slice(1)) {
		if (arg === "--check") {
			checkOnly = true;
			continue;
		}
		err(`❌ env-guard: unknown option '${arg}'.`);
		usage(err);
		return FAILED;
	}

	return install(process.cwd(), checkOnly);
}

// process.exit() ではなく exitCode を立てる。stdout がパイプやファイルへ
// 向いていると書き込みは非同期になり、process.exit() は書き終わる前に
// プロセスを終わらせて出力を落とすことがある。このコマンドは、断るときに
// 何を直せばよいかを出力で伝えるものなので、終了コードだけ残って理由が
// 消える形は避ける。ここは全て同期処理なので、main が返ればイベント
// ループは空になり、Node が出力を書き終えてから終了する。
process.exitCode = main(process.argv);
