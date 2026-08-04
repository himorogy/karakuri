import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import type {
	EnclaveEnvConfig,
	EnvironmentConfig,
	SecurityConfig,
} from "./types.js";

export function loadConfig(cwd = process.cwd()): EnclaveEnvConfig {
	const configPath = resolve(cwd, "enclave-env");
	let raw: string;
	try {
		raw = readFileSync(configPath, "utf-8");
	} catch {
		throw new Error(
			"enclave-env not found. Run from project root or create enclave-env.",
		);
	}

	const vars: Record<string, string> = {};
	for (const line of raw.split("\n")) {
		const trimmed = line.trim();
		if (!trimmed || trimmed.startsWith("#")) continue;
		const eqIdx = trimmed.indexOf("=");
		if (eqIdx < 0) continue;
		vars[trimmed.slice(0, eqIdx).trim()] = trimmed.slice(eqIdx + 1).trim();
	}

	const mode = (vars.MODE ?? "single") as EnclaveEnvConfig["mode"];

	const environments: Record<string, EnvironmentConfig> = {};
	for (const [key, value] of Object.entries(vars)) {
		const fileMatch = key.match(/^ENV_([A-Z0-9]+)_FILE$/);
		if (fileMatch) {
			const name = fileMatch[1].toLowerCase();
			environments[name] ??= {};
			environments[name].file = value;
		}
		const protectedMatch = key.match(/^ENV_([A-Z0-9]+)_PROTECTED$/);
		if (protectedMatch) {
			const name = protectedMatch[1].toLowerCase();
			environments[name] ??= {};
			environments[name].protected = value === "true";
		}
	}

	const security: SecurityConfig = {};
	if (vars.DEV_CONTAINER_NAME)
		security.devContainerName = vars.DEV_CONTAINER_NAME;
	if (vars.PROD_CONTAINER_NAME)
		security.prodContainerName = vars.PROD_CONTAINER_NAME;

	return {
		mode,
		environments,
		...(Object.keys(security).length > 0 ? { security } : {}),
	};
}

export function resolveEnvFile(
	config: EnclaveEnvConfig,
	env: string,
	cwd = process.cwd(),
): string {
	const envConfig: EnvironmentConfig | undefined = config.environments[env];
	if (!envConfig) {
		const available = Object.keys(config.environments).join(", ");
		throw new Error(
			`Environment "${env}" not found in enclave-env. Available: ${available}`,
		);
	}
	if (!envConfig.file) {
		throw new Error(
			`Environment "${env}" has no FILE setting. Check enclave-env.`,
		);
	}
	return resolve(cwd, envConfig.file);
}
