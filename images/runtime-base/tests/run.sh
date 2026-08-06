#!/usr/bin/env bash
#
# images/runtime-base のテスト一式を順に走らせる。個々のテストの中身は
# shim.test.sh / entrypoint.test.sh を参照。
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

bash "$SCRIPT_DIR/shim.test.sh"
bash "$SCRIPT_DIR/entrypoint.test.sh"
bash "$SCRIPT_DIR/prod-context.test.sh"
