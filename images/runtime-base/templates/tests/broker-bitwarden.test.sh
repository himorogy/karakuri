#!/usr/bin/env bash
#
# Tests for broker-bitwarden.sh.
#
# bw CLI なしで走る。`bw` を BROKER_BW_BIN 経由でフェイクスクリプトへ
# 差し替え、broker 自身のロジック（必須環境変数の検査・複数項目のマージと
# 並び順・項目単位の失敗の名指し・空 note の検出・セッション鍵が stdout に
# 混ざらないこと・終了時の lock）だけを検証する。実際の Bitwarden vault の
# 挙動はここでは見ない。
#
set -uo pipefail

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

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
BROKER_SH="$TEST_DIR/../host/broker-bitwarden.sh"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

export BW_STUB_LOG="$WORKDIR/bw-calls.log"

# フェイク bw。unlock はセッション鍵らしき文字列を返し、get notes は項目名で
# 応答を切り替える。lock / get の呼び出しと、そのとき BW_SESSION が渡って
# いたかをログに記録する。
cat >"$WORKDIR/bw" <<'STUB'
#!/usr/bin/env bash
cmd="${1:-}"
case "$cmd" in
unlock)
	printf 'stub-session-token\n'
	;;
lock)
	echo "lock session=${BW_SESSION:-unset}" >>"$BW_STUB_LOG"
	;;
get)
	item="${3:-}"
	echo "get session=${BW_SESSION:-unset} item=$item" >>"$BW_STUB_LOG"
	case "$item" in
	# 末尾改行なし: broker 側の改行継ぎ足しの検査を兼ねる
	shared) printf 'A=from-shared\nGH_TOKEN=shared-token' ;;
	personal) printf 'GH_TOKEN=personal-token\n' ;;
	empty-note) ;;
	*)
		echo "Not found." >&2
		exit 1
		;;
	esac
	;;
esac
STUB
chmod +x "$WORKDIR/bw"

run_broker() {
	# BROKER_BW_ITEM は呼び出し元が環境で与える
	BROKER_BW_BIN="$WORKDIR/bw" bash "$BROKER_SH"
}

# --- 必須環境変数 ---------------------------------------------------------------

echo "BROKER_BW_ITEM が無ければ usage エラー"
: >"$BW_STUB_LOG"
out="$(unset BROKER_BW_ITEM; run_broker 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "BROKER_BW_ITEM is required"; then
	ok "rc=$rc, 変数名を名指しして落ちる"
else
	ng "rc=$rc out=$out"
fi

# --- 単一項目 -------------------------------------------------------------------

echo "単一項目: note がそのまま dotenv として出る"
: >"$BW_STUB_LOG"
out="$(BROKER_BW_ITEM=personal run_broker 2>/dev/null)"
rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "GH_TOKEN=personal-token" ]; then
	ok "stdout が note の中身と一致する"
else
	ng "rc=$rc out=$out"
fi

echo "セッション鍵が stdout に混ざらない"
if ! printf '%s' "$out" | grep -q "stub-session-token"; then
	ok "stdout に stub-session-token が現れない"
else
	ng "stdout にセッション鍵が漏れている: $out"
fi

echo "取得後に lock が 1 回だけ呼ばれ、セッションが渡っている"
locks="$(grep -c '^lock session=stub-session-token$' "$BW_STUB_LOG")"
if [ "$locks" -eq 1 ]; then
	ok "lock 1 回・セッション付き"
else
	ng "lock 記録: $(grep '^lock' "$BW_STUB_LOG" || echo none)"
fi

# --- 複数項目のマージ -----------------------------------------------------------

echo "複数項目: 並び順のまま連結され、末尾改行なしの note でも境界が保たれる"
: >"$BW_STUB_LOG"
out="$(BROKER_BW_ITEM=shared,personal run_broker 2>/dev/null)"
rc=$?
expected="$(printf 'A=from-shared\nGH_TOKEN=shared-token\nGH_TOKEN=personal-token')"
if [ "$rc" -eq 0 ] && [ "$out" = "$expected" ]; then
	ok "shared → personal の順で 3 行"
else
	ng "rc=$rc out=$(printf '%s' "$out" | tr '\n' '|')"
fi

echo "複数項目でも unlock/lock は 1 回ずつ（プロンプトは増えない）"
locks="$(grep -c '^lock ' "$BW_STUB_LOG")"
gets="$(grep -c '^get ' "$BW_STUB_LOG")"
if [ "$locks" -eq 1 ] && [ "$gets" -eq 2 ]; then
	ok "get 2 回・lock 1 回"
else
	ng "get=$gets lock=$locks"
fi

echo "get に毎回セッションが渡っている"
if [ "$(grep -c '^get session=stub-session-token ' "$BW_STUB_LOG")" -eq 2 ]; then
	ok "2 回とも BW_SESSION 付き"
else
	ng "get 記録: $(grep '^get' "$BW_STUB_LOG")"
fi

# --- 失敗系 ---------------------------------------------------------------------

echo "存在しない項目: 非ゼロ終了し、どの項目かを名指しし、lock は呼ばれる"
: >"$BW_STUB_LOG"
out="$(BROKER_BW_ITEM=shared,no-such-item run_broker 2>&1 >/dev/null)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "for item 'no-such-item'"; then
	ok "rc=$rc, 失敗した項目名が stderr に出る"
else
	ng "rc=$rc out=$out"
fi
if grep -q '^lock ' "$BW_STUB_LOG"; then
	ok "失敗時も lock が呼ばれる"
else
	ng "失敗時に lock が呼ばれていない"
fi

echo "空 note: 非ゼロ終了し、どの項目かを名指しする"
out="$(BROKER_BW_ITEM=empty-note run_broker 2>&1 >/dev/null)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "'empty-note' returned an empty note"; then
	ok "rc=$rc"
else
	ng "rc=$rc out=$out"
fi

echo "はぐれカンマ（空の項目名）: 非ゼロ終了する"
out="$(BROKER_BW_ITEM=shared, run_broker 2>&1 >/dev/null)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "empty item name"; then
	ok "rc=$rc"
else
	ng "rc=$rc out=$out"
fi

# --- 結果 -----------------------------------------------------------------------

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
