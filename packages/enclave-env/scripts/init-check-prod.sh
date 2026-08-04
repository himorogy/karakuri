#!/bin/sh
# prod コンテナ起動時の相互排他チェック（devcontainer.json の initializeCommand 用）
# ホスト側で実行されるため、exit 1 でコンテナ起動を中断できる。

if [ ! -f "./enclave-env" ]; then
  echo "⚠️  enclave-env not found, skipping check"
  exit 0
fi

# shellcheck disable=SC1091
. ./enclave-env

if [ -n "$DEV_CONTAINER_NAME" ]; then
  if docker ps --filter "name=$DEV_CONTAINER_NAME" --format "{{.Names}}" 2>/dev/null | grep -q .; then
    echo "❌ ERROR: Dev container is already running ($DEV_CONTAINER_NAME)."
    echo "   Stop it before starting the prod container."
    exit 1
  fi
fi

echo "✅ enclave-env - mutual exclusion check passed"
