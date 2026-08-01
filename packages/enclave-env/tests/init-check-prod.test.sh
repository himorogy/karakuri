#!/bin/sh
# Tests for scripts/init-check-prod.sh
#
# init-check-prod.sh は prod コンテナ起動時に dev コンテナが稼働していないかを確認する。
# docker ps の呼び出しを fake binary（PATH 先頭に挿入）でモックすることで
# Docker デーモンなしにコンテナ稼働・未稼働の両ケースをテストできる。

SCRIPT_DIR=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$SCRIPT_DIR/scripts/init-check-prod.sh"

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

# fake_bin を PATH 先頭に挿入して run する。
# fake_bin が空文字のときは通常の PATH でそのまま実行する（docker 不使用のケース）。
run() {
  dir=$1
  fake_bin=$2
  if [ -n "$fake_bin" ]; then
    (cd "$dir" && PATH="$fake_bin:$PATH" sh "$SCRIPT" >/dev/null 2>&1)
  else
    (cd "$dir" && sh "$SCRIPT" >/dev/null 2>&1)
  fi
}

# 指定した出力を返す fake docker binary を一時ディレクトリに作成して返す。
# output が空のとき docker ps は何も出力しない（コンテナ未稼働を再現）。
# output が文字列のとき docker ps はその名前を出力する（コンテナ稼働を再現）。
make_fake_docker() {
  output=$1
  dir=$(mktemp -d)
  if [ -n "$output" ]; then
    printf '#!/bin/sh\necho "%s"\n' "$output" > "$dir/docker"
  else
    printf '#!/bin/sh\n' > "$dir/docker"
  fi
  chmod +x "$dir/docker"
  echo "$dir"
}

# enclave-env 未設定のプロジェクトで誤ってブロックしないことを確認。
WORK=$(mktemp -d)
run "$WORK"
assert_exit "no enclave-env → exit 0" 0 $?
rm -rf "$WORK"

# DEV_CONTAINER_NAME が設定されていなければ docker チェック自体をスキップする。
# 2層 devcontainer を使わない構成では相互排他チェック不要。
WORK=$(mktemp -d)
printf 'MODE=single\n' > "$WORK/enclave-env"
run "$WORK"
assert_exit "DEV_CONTAINER_NAME not set → exit 0" 0 $?
rm -rf "$WORK"

# dev コンテナが停止していれば prod コンテナを起動してよい（正常系）。
WORK=$(mktemp -d)
printf 'MODE=single\nDEV_CONTAINER_NAME=my-dev\n' > "$WORK/enclave-env"
FAKE=$(make_fake_docker "")
run "$WORK" "$FAKE"
assert_exit "dev container not running → exit 0" 0 $?
rm -rf "$WORK" "$FAKE"

# dev コンテナが稼働中なら prod コンテナの起動をブロックする（主要な脅威）。
# dev コンテナが動いたまま prod 操作を行うと、復号した平文を LLM が参照できてしまう。
WORK=$(mktemp -d)
printf 'MODE=single\nDEV_CONTAINER_NAME=my-dev\n' > "$WORK/enclave-env"
FAKE=$(make_fake_docker "my-dev")
run "$WORK" "$FAKE"
assert_exit "dev container running → exit 1" 1 $?
rm -rf "$WORK" "$FAKE"

echo ""
echo "init-check-prod.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
