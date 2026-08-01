import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { loadConfig, resolveEnvFile } from "../src/config.js";

function withTempDir(fn: (dir: string) => void): void {
	const dir = mkdtempSync(join(tmpdir(), "enclave-env-test-"));
	try {
		fn(dir);
	} finally {
		rmSync(dir, { recursive: true });
	}
}

function writeConfig(dir: string, content: string): void {
	writeFileSync(join(dir, "enclave-env"), `${content.trim()}\n`);
}

// loadConfig

test("loadConfig: parses all fields correctly", () => {
	withTempDir((dir) => {
		writeConfig(
			dir,
			`
MODE=single
ENV_LOCAL_FILE=.env
ENV_PROD_FILE=.env.production
ENV_PROD_PROTECTED=true
DEV_CONTAINER_NAME=my-dev
PROD_CONTAINER_NAME=my-prod
    `,
		);
		const config = loadConfig(dir);
		assert.equal(config.mode, "single");
		assert.equal(config.environments.local?.file, ".env");
		assert.equal(config.environments.prod?.file, ".env.production");
		assert.equal(config.environments.prod?.protected, true);
		assert.equal(config.security?.devContainerName, "my-dev");
		assert.equal(config.security?.prodContainerName, "my-prod");
	});
});

test("loadConfig: ignores comments and empty lines", () => {
	withTempDir((dir) => {
		writeConfig(
			dir,
			`
# comment
MODE=single

ENV_LOCAL_FILE=.env
# another comment
ENV_PROD_FILE=.env.production
    `,
		);
		const config = loadConfig(dir);
		assert.equal(config.environments.local?.file, ".env");
		assert.equal(config.environments.prod?.file, ".env.production");
	});
});

test("loadConfig: protected defaults to false when omitted", () => {
	withTempDir((dir) => {
		writeConfig(
			dir,
			`
MODE=single
ENV_PROD_FILE=.env.production
    `,
		);
		const config = loadConfig(dir);
		assert.equal(config.environments.prod?.protected, undefined);
	});
});

test("loadConfig: security is undefined when no container names", () => {
	withTempDir((dir) => {
		writeConfig(dir, "MODE=single\nENV_LOCAL_FILE=.env");
		const config = loadConfig(dir);
		assert.equal(config.security, undefined);
	});
});

test("loadConfig: PROD_CONTAINER_NAME alone sets security", () => {
	withTempDir((dir) => {
		writeConfig(dir, "MODE=single\nPROD_CONTAINER_NAME=my-prod");
		const config = loadConfig(dir);
		assert.equal(config.security?.prodContainerName, "my-prod");
		assert.equal(config.security?.devContainerName, undefined);
	});
});

test("loadConfig: throws when file not found", () => {
	withTempDir((dir) => {
		assert.throws(() => loadConfig(dir), /enclave-env not found/);
	});
});

// resolveEnvFile

test("resolveEnvFile: resolves path relative to cwd", () => {
	withTempDir((dir) => {
		writeConfig(dir, "MODE=single\nENV_PROD_FILE=.env.production");
		const config = loadConfig(dir);
		const result = resolveEnvFile(config, "prod", dir);
		assert.equal(result, join(dir, ".env.production"));
	});
});

test("resolveEnvFile: throws for unknown environment", () => {
	withTempDir((dir) => {
		writeConfig(dir, "MODE=single\nENV_LOCAL_FILE=.env");
		const config = loadConfig(dir);
		assert.throws(
			() => resolveEnvFile(config, "staging", dir),
			/not found in enclave-env/,
		);
	});
});

test("resolveEnvFile: throws when environment has no FILE setting", () => {
	withTempDir((dir) => {
		writeConfig(dir, "MODE=single\nENV_PROD_PROTECTED=true");
		const config = loadConfig(dir);
		assert.throws(() => resolveEnvFile(config, "prod", dir), /no FILE setting/);
	});
});
