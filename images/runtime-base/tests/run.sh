#!/usr/bin/env bash
#
# images/runtime-base のテスト一式を順に走らせる。個々のテストの中身は
# shim.test.sh / entrypoint.test.sh を参照。
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

bash "$SCRIPT_DIR/shim.test.sh"
bash "$SCRIPT_DIR/entrypoint.test.sh"
bash "$SCRIPT_DIR/prod-context.test.sh"

# .github/workflows/env-guard.yml の検査ロジックが平文 env を実際に検出
# できることの自己検証。イメージそのものではなく CI 側の検査を対象にする
# が、対になる pre-commit hook がこのイメージに入っている（hooks/pre-commit）
# ため、テストもここに並べる。
bash "$SCRIPT_DIR/env-guard.test.sh"
bash "$SCRIPT_DIR/hook.test.sh"
