#!/bin/sh
# Tests for scripts/init-check-dev.sh
#
# init-check-dev.sh は devcontainer.json の initializeCommand としてホスト側で実行され、
# "./enclave-env" を source する。そのため run() はサブシェルで cd してから呼び出す。
# git に依存しないため、テストごとに mktemp -d を作って rm -rf で完全に隔離する。

SCRIPT_DIR=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$SCRIPT_DIR/scripts/init-check-dev.sh"

PASS=0
FAIL=0

assert_exit() {
  name=$1
  expected=$2
  actual=$3
  if [ "$actual" -eq "$expected" ]; then
    echo "  ✅ $name"
    PASS=$((PASS + 1))
  else
    echo "  ❌ $name (expected exit $expected, got $actual)"
    FAIL=$((FAIL + 1))
  fi
}

# サブシェル ( ) で cd するのはカレントディレクトリの変更をテスト本体に漏らさないため。
run() {
  dir=$1
  (cd "$dir" && sh "$SCRIPT" >/dev/null 2>&1)
}

# enclave-env 未設定のプロジェクトで誤ってブロックしないことを確認。
# このパッケージを導入していない環境でも initializeCommand が無害に通過する必要がある。
WORK=$(mktemp -d)
run "$WORK"
assert_exit "no enclave-env → exit 0" 0 $?
rm -rf "$WORK"

# 問題のないワークスペースは通過する（正常系）。
WORK=$(mktemp -d)
printf 'MODE=single\n' > "$WORK/enclave-env"
run "$WORK"
assert_exit "clean workspace → exit 0" 0 $?
rm -rf "$WORK"

# Check 1: 暗号化済みの .env.production は通過する。
# "encrypted:" プレフィックスがあれば bind mount 経由で LLM に平文が渡らない。
WORK=$(mktemp -d)
printf 'MODE=single\n' > "$WORK/enclave-env"
printf 'DOTENV_PUBLIC_KEY=abc\nKEY=encrypted:abc\n' > "$WORK/.env.production"
run "$WORK"
assert_exit "encrypted .env.production → exit 0" 0 $?
rm -rf "$WORK"

# Check 1: 平文の .env.production があればコンテナ起動をブロックする。
# 復号済みファイルがワークスペースに残った状態で dev コンテナが起動すると LLM に露出する。
WORK=$(mktemp -d)
printf 'MODE=single\n' > "$WORK/enclave-env"
printf 'DOTENV_PUBLIC_KEY=abc\nDATABASE_URL=postgres://localhost\n' > "$WORK/.env.production"
run "$WORK"
assert_exit "unencrypted .env.production → exit 1" 1 $?
rm -rf "$WORK"

# Check 1: ".env" で始まらない "secret.env.production" も検査対象になることを確認。
# ファイル名のサフィックスで判定しているため、プレフィックスは問わない。
WORK=$(mktemp -d)
printf 'MODE=single\n' > "$WORK/enclave-env"
printf 'DOTENV_PUBLIC_KEY=abc\nSECRET_KEY=plaintext\n' > "$WORK/secret.env.production"
run "$WORK"
assert_exit "unencrypted secret.env.production → exit 1" 1 $?
rm -rf "$WORK"

# Check 2: .env.container に prod の秘密鍵が含まれていればブロックする。
# devcontainer の --env-file 経由でコンテナに prod キーが渡る構成ミスを起動前に検出する。
WORK=$(mktemp -d)
printf 'MODE=single\n' > "$WORK/enclave-env"
mkdir -p "$WORK/.devcontainer/dev"
printf 'DOTENV_PRIVATE_KEY_PRODUCTION=secret\n' > "$WORK/.devcontainer/dev/.env.container"
run "$WORK"
assert_exit ".env.container with prod key → exit 1" 1 $?
rm -rf "$WORK"

# Check 3: .env.keys がワークスペース内に存在すればブロックする。
# dotenvx が生成する秘密鍵ファイルが残っていると bind mount 経由で LLM に渡るリスクがある。
WORK=$(mktemp -d)
printf 'MODE=single\n' > "$WORK/enclave-env"
printf 'DOTENV_PRIVATE_KEY=secret\n' > "$WORK/.env.keys"
run "$WORK"
assert_exit ".env.keys in workspace → exit 1" 1 $?
rm -rf "$WORK"

# Check 1: コメント行・空行を平文の値と誤検知しないことを確認。
# フォールスポジティブは正常な開発フローを妨げる。
WORK=$(mktemp -d)
printf 'MODE=single\n' > "$WORK/enclave-env"
printf '# comment\nDOTENV_PUBLIC_KEY=abc\n\nKEY=encrypted:abc\n' > "$WORK/.env.production"
run "$WORK"
assert_exit "comments and empty lines in encrypted file → exit 0" 0 $?
rm -rf "$WORK"

echo ""
echo "init-check-dev.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
