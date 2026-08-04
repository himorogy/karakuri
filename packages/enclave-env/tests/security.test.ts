import assert from "node:assert/strict";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import {
	checkContainerNotRunning,
	checkDevContainerNotRunning,
} from "../src/security.js";

function withFakeDocker(containerName: string, fn: () => void): void {
	const dir = mkdtempSync(join(tmpdir(), "fake-docker-"));
	const originalPath = process.env.PATH;
	try {
		const script =
			containerName.length > 0
				? `#!/bin/sh\necho "${containerName}"\n`
				: "#!/bin/sh\n";
		writeFileSync(join(dir, "docker"), script);
		chmodSync(join(dir, "docker"), 0o755);
		process.env.PATH = `${dir}:${originalPath}`;
		fn();
	} finally {
		process.env.PATH = originalPath;
		rmSync(dir, { recursive: true });
	}
}

function withDockerUnavailable(fn: () => void): void {
	const dir = mkdtempSync(join(tmpdir(), "fake-docker-"));
	const originalPath = process.env.PATH;
	try {
		writeFileSync(join(dir, "docker"), "#!/bin/sh\nexit 1\n");
		chmodSync(join(dir, "docker"), 0o755);
		process.env.PATH = `${dir}:${originalPath}`;
		fn();
	} finally {
		process.env.PATH = originalPath;
		rmSync(dir, { recursive: true });
	}
}

function captureExit(fn: () => void): number | undefined {
	const originalExit = process.exit;
	let captured: number | undefined;
	process.exit = ((code?: number): never => {
		captured = code ?? 0;
		throw new Error("__process_exit__");
	}) as typeof process.exit;
	try {
		fn();
	} catch (e) {
		if (!(e instanceof Error && e.message === "__process_exit__")) throw e;
	} finally {
		process.exit = originalExit;
	}
	return captured;
}

// checkContainerNotRunning

test("checkContainerNotRunning: exits 1 when container is running", () => {
	withFakeDocker("my-container", () => {
		const code = captureExit(() =>
			checkContainerNotRunning("my-container", "container is running"),
		);
		assert.equal(code, 1);
	});
});

test("checkContainerNotRunning: passes when container is not running", () => {
	withFakeDocker("", () => {
		const code = captureExit(() =>
			checkContainerNotRunning("my-container", "container is running"),
		);
		assert.equal(code, undefined);
	});
});

test("checkContainerNotRunning: passes when docker is unavailable", () => {
	withDockerUnavailable(() => {
		const code = captureExit(() =>
			checkContainerNotRunning("my-container", "container is running"),
		);
		assert.equal(code, undefined);
	});
});

// checkDevContainerNotRunning

test("checkDevContainerNotRunning: skips check when DEVCONTAINER=true", () => {
	const original = process.env.DEVCONTAINER;
	process.env.DEVCONTAINER = "true";
	try {
		withFakeDocker("my-dev", () => {
			const code = captureExit(() => checkDevContainerNotRunning("my-dev"));
			assert.equal(code, undefined);
		});
	} finally {
		if (original === undefined) delete process.env.DEVCONTAINER;
		else process.env.DEVCONTAINER = original;
	}
});

test("checkDevContainerNotRunning: exits 1 when dev container is running", () => {
	const original = process.env.DEVCONTAINER;
	delete process.env.DEVCONTAINER;
	try {
		withFakeDocker("my-dev", () => {
			const code = captureExit(() => checkDevContainerNotRunning("my-dev"));
			assert.equal(code, 1);
		});
	} finally {
		if (original !== undefined) process.env.DEVCONTAINER = original;
	}
});
