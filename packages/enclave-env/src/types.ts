export type Mode = "single" | "monorepo" | "monorepo-gen";

export interface EnvironmentConfig {
	file?: string;
	protected?: boolean;
}

export interface SecurityConfig {
	devContainerName?: string;
	prodContainerName?: string;
}

export interface EnclaveEnvConfig {
	mode: Mode;
	environments: Record<string, EnvironmentConfig>;
	services?: string[];
	secretsDir?: string;
	templatesDir?: string;
	security?: SecurityConfig;
}
