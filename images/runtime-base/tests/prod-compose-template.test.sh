#!/usr/bin/env bash
#
# プレースホルダのままにしておくのは、差し替え忘れを pull の失敗として
# 顕在化させるためである（host-tools/compose.prod.yaml の image 行を参照）。
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../../.." && pwd)"

TEMPLATE="$REPO_ROOT/host-tools/compose.prod.yaml"

PASS=0
FAIL=0

ok() {
	PASS=$((PASS + 1))
	printf '  ok   %s\n' "$1"
}

ng() {
	FAIL=$((FAIL + 1))
	printf '  FAIL %s\n' "$1" >&2
}

is_placeholder() {
	grep -q '^[[:space:]]*image:.*REPLACE_WITH_ACTUAL_DIGEST' "$1"
}

echo "テンプレートの image はプレースホルダのまま"

if [ ! -f "$TEMPLATE" ]; then
	ng "$TEMPLATE が無い"
	echo
	echo "${PASS} passed, ${FAIL} failed"
	exit 1
fi

if is_placeholder "$TEMPLATE"; then
	ok "テンプレートの image はプレースホルダのまま"
else
	ng "テンプレートの image がプレースホルダではない（差し替え忘れが起動失敗として現れなくなる）"
fi

# 否定対照。上の検査が本当に実 digest を検出するかを、既知の違反を
# その場で作って確かめる。検査が常に緑を返すだけの状態になっていないことの
# 確認である。
probe="$(mktemp)"
trap 'rm -f "$probe"' EXIT
sed 's/REPLACE_WITH_ACTUAL_DIGEST/0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcd/' \
	"$TEMPLATE" >"$probe"

if is_placeholder "$probe"; then
	ng "否定対照: 実 digest を持つ版をプレースホルダと判定した（検査が機能していない）"
else
	ok "否定対照: 実 digest を持つ版は非プレースホルダとして検出される"
fi

echo
echo "${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
