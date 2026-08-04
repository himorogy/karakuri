#!/bin/sh
# Tests for scripts/check.sh
#
# check.sh は git diff --cached でステージ済みファイルを検査する。
# 本物の git リポジトリが必要なため、mktemp -d 内で git init する。
# --allow-empty で空コミットを作っておくのは、最初のコミット前だと
# git add / git restore --staged の挙動が変わるリポジトリ状態になるため。

SCRIPT_DIR=$(cd "$(dirname "$0")/.." && pwd)
CHECK_SH="$SCRIPT_DIR/scripts/check.sh"

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

WORK=$(mktemp -d)
cd "$WORK" || exit 1
git init -q
git config user.email "test@test.com"
git config user.name "Test"
git commit --allow-empty -m "initial" -q

# hook が不要に開発を妨げないことを確認。
# ステージが空のときは常に通過しなければならない。
sh "$CHECK_SH" >/dev/null 2>&1
assert_exit "no staged env files → exit 0" 0 $?

# 暗号化済みファイルは通過する（正常系）。
# 値がすべて "encrypted:" プレフィックスを持てば問題なし。
printf 'DOTENV_PUBLIC_KEY=abc\nKEY=encrypted:abc\n' > .env.production
git add .env.production
sh "$CHECK_SH" >/dev/null 2>&1
assert_exit "encrypted .env.production → exit 0" 0 $?
# 各テスト後にステージをリセットして次のケースに影響させない。
git restore --staged .env.production

# 平文の値を含む .env.production はコミットをブロックする（主要な脅威）。
# LLM が bind mount 経由で本番秘密情報を読み取るリスクを防ぐ。
printf 'DOTENV_PUBLIC_KEY=abc\nDATABASE_URL=postgres://localhost\n' > .env.production
git add .env.production
sh "$CHECK_SH" >/dev/null 2>&1
assert_exit "unencrypted .env.production → exit 1" 1 $?
git restore --staged .env.production

# dotenvx の秘密鍵ファイル自体のコミットをブロックする。
# .env.keys がリポジトリに入ると暗号化の意味がなくなる。
printf 'DOTENV_PRIVATE_KEY=secret\n' > .env.keys
git add .env.keys
sh "$CHECK_SH" >/dev/null 2>&1
assert_exit ".env.keys staged → exit 1" 1 $?
git restore --staged .env.keys

# ".env" で始まらなくても ".env.production" で終われば検査対象になることを確認。
# ファイル名のプレフィックスではなくサフィックスでマッチしている。
printf 'DOTENV_PUBLIC_KEY=abc\nKEY=encrypted:abc\n' > secret.env.production
git add secret.env.production
sh "$CHECK_SH" >/dev/null 2>&1
assert_exit "encrypted secret.env.production → exit 0" 0 $?
git restore --staged secret.env.production

# コメント行や空行が暗号化判定に誤反応しないことを確認。
# "#" で始まる行や空行を平文の値として誤検知するとフォールスポジティブになる。
printf '# comment\nDOTENV_PUBLIC_KEY=abc\n\nKEY=encrypted:abc\n' > .env.production
git add .env.production
sh "$CHECK_SH" >/dev/null 2>&1
assert_exit "comments and empty lines in encrypted file → exit 0" 0 $?
git restore --staged .env.production

# ".example" ファイルはテンプレートなので検査をスキップする必要がある。
# プレースホルダー値が平文でも誤ってブロックしてはならない。
mkdir -p .devcontainer/dev
printf 'API_KEY=your-key-here\n' > .devcontainer/dev/.env.container.example
git add .devcontainer/dev/.env.container.example
sh "$CHECK_SH" >/dev/null 2>&1
assert_exit ".env.container.example skipped → exit 0" 0 $?
git restore --staged .devcontainer/dev/.env.container.example

# cd してから削除するとカレントディレクトリが消えてエラーになる環境があるため先に移動。
cd / && rm -rf "$WORK"

echo ""
echo "check.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
