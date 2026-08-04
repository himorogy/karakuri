// TODO: Implement for monorepo-gen mode.
// Reads secrets/secret.env.* (decrypted master secret),
// applies per-service templates, and writes encrypted .env files under apps/*/
export function genEnvs(_env: string): never {
	throw new Error(
		"gen-envs is only available in monorepo-gen mode (not yet implemented)",
	);
}
