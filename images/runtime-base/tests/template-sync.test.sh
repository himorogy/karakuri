#!/usr/bin/env bash
#
# example/ に置いた compose と、配布テンプレートの compose が一致することの
# 検査。
#
# この二枚が別々に存在するのは意図的である — example/ は「読むもの」、
# templates/ は「コピーされて実行時に読まれるもの」で、役割が違う。ただし
# 中身が同じである以上、片方だけを直せる。実際 `init: true` は example/ に
# だけ入っていて、テンプレートからそのままコピーした人には届いていなかった。
# 対話二段構えで Ctrl-C も docker stop も効かなくなる差であり、起動は成功
# するので気付く契機が無い。
#
# 許される差分は image 行だけ。テンプレートはプレースホルダを持ち、
# example/ は実在する digest を持つ（テンプレートを実 digest で出荷すると、
# 差し替え忘れが「起動はするが古いイメージ」になる。プレースホルダなら
# pull に失敗して顕在化する）。
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../../.." && pwd)"

TEMPLATE="$REPO_ROOT/images/runtime-base/templates/host/compose.prod.yaml"
EXAMPLE="$REPO_ROOT/example/docker-compose.prod.yaml"

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

# image 行を落とした本文を stdout に出す。
body() {
	grep -v '^[[:space:]]*image:' "$1"
}

echo "テンプレートと example の compose が一致する"

for f in "$TEMPLATE" "$EXAMPLE"; do
	if [ ! -f "$f" ]; then
		ng "$f が無い"
		echo
		echo "${PASS} passed, ${FAIL} failed"
		exit 1
	fi
done

if diff_out="$(diff -u <(body "$TEMPLATE") <(body "$EXAMPLE"))"; then
	ok "image 行を除く全行が一致する"
else
	ng "image 行以外に差分がある。どちらか片方だけを直していないか確認すること"
	printf '%s\n' "$diff_out" >&2
fi

# 許された差分の側も、意図した形になっていることを見る。テンプレートが実
# digest を持ってしまうと差し替え忘れが顕在化しなくなり、example が
# プレースホルダのままだと読んだ人がそれを写して起動に失敗する。
if grep -q '^[[:space:]]*image:.*REPLACE_WITH_ACTUAL_DIGEST' "$TEMPLATE"; then
	ok "テンプレートの image はプレースホルダのまま"
else
	ng "テンプレートの image がプレースホルダではない（差し替え忘れが起動失敗として現れなくなる）"
fi

if grep -qE '^[[:space:]]*image:.*@sha256:[0-9a-f]{64}' "$EXAMPLE"; then
	ok "example の image は解決済みの digest"
else
	ng "example の image が解決済みの digest ではない"
fi

# 否定対照。上の一致検査が本当に差分を見つけるかを、既知の違反を作って
# 確かめる。検査が常に緑を返すだけの状態になっていないことの確認である。
probe="$(mktemp)"
trap 'rm -f "$probe"' EXIT
{
	body "$TEMPLATE"
	echo "    init: true"
} >"$probe"

if diff -q <(body "$TEMPLATE") "$probe" >/dev/null 2>&1; then
	ng "否定対照: 行を 1 つ足した版を同一と判定した（検査が機能していない）"
else
	ok "否定対照: 行を 1 つ足した版は差分として検出される"
fi

echo
echo "${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
