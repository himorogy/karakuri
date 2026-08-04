import { execSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";

export function check(): void {
	let stagedOutput: string;
	try {
		stagedOutput = execSync("git diff --cached --name-only", {
			encoding: "utf-8",
		});
	} catch {
		return;
	}

	const staged = stagedOutput
		.split("\n")
		.filter((f) => f && /(^|\/)\.env/.test(f));

	if (staged.length === 0) {
		process.exit(0);
	}

	let failed = false;

	for (const file of staged) {
		if (file.includes(".env.keys")) {
			console.error(
				`❌ pre-commit: ERROR: ${file} contains private keys and must not be committed`,
			);
			failed = true;
			continue;
		}

		if (
			existsSync(file) &&
			!readFileSync(file, "utf-8").includes("DOTENV_PUBLIC_KEY")
		) {
			console.error(`❌ pre-commit: ERROR: ${file} is not encrypted`);
			console.error(
				"   Run 'enclave-env encrypt --env <environment>' before committing",
			);
			failed = true;
		}
	}

	if (failed) {
		process.exit(1);
	}

	console.log("✅ pre-commit: all staged .env* files are encrypted");
}
