import { Command } from "commander";
import pkg from "../package.json" with { type: "json" };
import { check } from "./commands/check.js";
import { decryptEnv } from "./commands/decrypt.js";
import { encryptEnv } from "./commands/encrypt.js";
import { loadConfig } from "./config.js";

const program = new Command();

program
	.name("enclave-env")
	.description("Encrypted env management that keeps secrets out of LLM reach")
	.version(pkg.version);

program
	.command("encrypt")
	.description("Encrypt an env file in-place")
	.requiredOption(
		"--env <environment>",
		"Target environment (e.g. local, prod)",
	)
	.action((options: { env: string }) => {
		try {
			const config = loadConfig();
			encryptEnv(config, options.env);
		} catch (err) {
			console.error(`❌ ${err instanceof Error ? err.message : err}`);
			process.exit(1);
		}
	});

program
	.command("decrypt")
	.description("Decrypt an env file in-place")
	.requiredOption(
		"--env <environment>",
		"Target environment (e.g. local, prod)",
	)
	.action((options: { env: string }) => {
		try {
			const config = loadConfig();
			decryptEnv(config, options.env);
		} catch (err) {
			console.error(`❌ ${err instanceof Error ? err.message : err}`);
			process.exit(1);
		}
	});

program
	.command("check")
	.description(
		"Check staged .env files are encrypted (use as git pre-commit hook)",
	)
	.action(() => {
		try {
			check();
		} catch (err) {
			console.error(`❌ ${err instanceof Error ? err.message : err}`);
			process.exit(1);
		}
	});

program.parse();
