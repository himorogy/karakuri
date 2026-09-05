#!/usr/bin/env bash
#
# images/runtime-base のテスト一式を順に走らせる。個々のテストの中身は
# shim.test.sh / entrypoint.test.sh を参照。
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

bash "$SCRIPT_DIR/shim.test.sh"
bash "$SCRIPT_DIR/entrypoint.test.sh"
bash "$SCRIPT_DIR/secrets-ingest.test.sh"
bash "$SCRIPT_DIR/karakuri-context.test.sh"
bash "$SCRIPT_DIR/git-credential.test.sh"

# .github/workflows/env-guard.yml の検査ロジックが平文 env を実際に検出
# できることの自己検証。スキャナと pre-commit hook の実体は
# packages/env-guard にあるが、そこから焼き込まれた hook がこのイメージの
# 一部として動くため、テストもここに並べる。
bash "$SCRIPT_DIR/env-guard.test.sh"
bash "$SCRIPT_DIR/hook.test.sh"

# 出荷物 (イメージに COPY されるコード / templates / README) に、このリポジトリ
# の外では参照先が存在しない記号が残っていないことの検査。棚卸しを一度やっても
# 次に書けば戻るので、検査として置いている。
bash "$SCRIPT_DIR/shipped-symbols.test.sh"

# ホストへ配る templates/host のスクリプトが、実行できる mode で記録されて
# いることの検査。実行ビットが落ちた配布物は、利用側が最初のコマンドで
# 止まるため、着手すらできない。
bash "$SCRIPT_DIR/host-file-modes.test.sh"

# example/ の compose と配布テンプレートの compose が一致することの検査。
# 二枚が別々に存在するのは意図的だが、片方だけを直せてしまう。
bash "$SCRIPT_DIR/template-sync.test.sh"
