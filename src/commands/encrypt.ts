import { execSync } from "node:child_process";
import { createRequire } from "node:module";
import path from "node:path";
import { resolveEnvFile } from "../config.js";
import type { EnclaveEnvConfig } from "../types.js";

const require = createRequire(import.meta.url);
const dotenvxBin = path.join(
	path.dirname(require.resolve("@dotenvx/dotenvx/package.json")),
	"src/cli/dotenvx.js",
);

export function encryptEnv(config: EnclaveEnvConfig, env: string): void {
	if (config.mode !== "single") {
		throw new Error(`Mode "${config.mode}" is not yet supported`);
	}
	const filePath = resolveEnvFile(config, env);
	execSync(`node "${dotenvxBin}" encrypt -f "${filePath}"`, {
		stdio: "inherit",
	});
}
