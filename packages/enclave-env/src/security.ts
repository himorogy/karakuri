import { execSync } from "node:child_process";

export function checkContainerNotRunning(
	containerName: string,
	errorMessage: string,
): void {
	try {
		const result = execSync(
			`docker ps --filter "name=${containerName}" --format "{{.Names}}"`,
			{ encoding: "utf-8" },
		).trim();
		if (result) {
			console.error(`❌ ERROR: ${errorMessage}`);
			process.exit(1);
		}
	} catch {
		// docker not available, skip check
	}
}

export function checkDevContainerNotRunning(containerName: string): void {
	if (process.env.DEVCONTAINER) return;
	checkContainerNotRunning(
		containerName,
		`Dev container is running (${containerName}). Stop it before running prod operations to prevent secrets from syncing via bind mount.`,
	);
}
