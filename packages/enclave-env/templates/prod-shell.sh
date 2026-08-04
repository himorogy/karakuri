#!/bin/sh
# scripts/prod-shell.sh
#
# Starts a prod shell with prod keys loaded from outside the workspace.
# Reads container names from enclave-env and performs mutual exclusion check.
#
# Setup:
#   1. Set DEV_CONTAINER_NAME (and optionally PROD_CONTAINER_NAME) in enclave-env
#   2. Place prod keys at PROD_KEY_FILE (gitignored, outside workspace)
#   3. Copy this file to scripts/prod-shell.sh in your project

if [ ! -f "./enclave-env" ]; then
  echo "❌ enclave-env not found. Run from project root."
  exit 1
fi

# shellcheck disable=SC1091
. ./enclave-env

PROD_KEY_FILE="${HOME}/.config/<your-project>/.env.container"
IMAGE="<your-project>-devcontainer"

if docker ps --filter "name=${DEV_CONTAINER_NAME}" --format "{{.Names}}" | grep -q .; then
  echo "❌ Dev container '${DEV_CONTAINER_NAME}' is running."
  echo "   Stop it first before entering the prod shell."
  exit 1
fi

if [ ! -f "${PROD_KEY_FILE}" ]; then
  echo "❌ Prod key file not found: ${PROD_KEY_FILE}"
  exit 1
fi

docker run --rm -it \
  --name "${PROD_CONTAINER_NAME:-<your-project>-prod-shell}" \
  -v "$(pwd):/workspace" \
  -w /workspace \
  --env-file "${PROD_KEY_FILE}" \
  "${IMAGE}" \
  bash
