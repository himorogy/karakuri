#!/usr/bin/env bash
#
# Tests for host-run.sh.
#
# broker はフェイクの実行ファイルへ差し替える。host-run.sh 自身のロジック
# （必須環境変数の検査・古い鍵の削除・broker の呼び出しと終了コードの検査・
# dotenv パースの失敗報告・逐語での exec）だけを検証する。実際の broker の
# 認可プロセスはここでは見ない。
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
HOST_RUN_SH="$TEST_DIR/../host/host-run.sh"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# --- フェイク broker ------------------------------------------------------------

BROKER_OK="$WORKDIR/broker-ok"
cat >"$BROKER_OK" <<'FAKE_BROKER_OK'
#!/usr/bin/env bash
# 呼ばれるたびに1行追記する。broker が1回だけ呼ばれることを見るため
# （呼び出し回数は認可プロンプト・vault sync の回数として利用者に見える）。
[ -z "${BROKER_CALL_LOG:-}" ] || printf 'call\n' >>"$BROKER_CALL_LOG"
printf 'DOTENV_PRIVATE_KEY_PROD=newval\nFOO=bar\n'
FAKE_BROKER_OK
chmod +x "$BROKER_OK"

BROKER_FAIL="$WORKDIR/broker-fail"
cat >"$BROKER_FAIL" <<'FAKE_BROKER_FAIL'
#!/usr/bin/env bash
echo "fake broker: authorization denied" >&2
exit 7
FAKE_BROKER_FAIL
chmod +x "$BROKER_FAIL"

BROKER_EMPTY="$WORKDIR/broker-empty"
cat >"$BROKER_EMPTY" <<'FAKE_BROKER_EMPTY'
#!/usr/bin/env bash
true
FAKE_BROKER_EMPTY
chmod +x "$BROKER_EMPTY"

# 1 行目は正常、2 行目が壊れている（'=' を持たない）。壊れた行の内容
# ("supersecretvalue-should-not-appear") が出力へ一切反射されないことを
# 見るための fixture。
BROKER_BAD_LINE="$WORKDIR/broker-bad-line"
cat >"$BROKER_BAD_LINE" <<'FAKE_BROKER_BAD_LINE'
#!/usr/bin/env bash
printf 'FOO=bar\nsupersecretvalue-should-not-appear\n'
FAKE_BROKER_BAD_LINE
chmod +x "$BROKER_BAD_LINE"

# --- フェイクコマンド（exec される側） -------------------------------------------
# host-run.sh は最後に "$@" を exec するので、フェイクコマンド自身のプロセスが
# 検査対象になる。呼ばれたら必ずマーカーファイルを作る（「一度も起動しない」を
# 見るため）。引数は 1 行 1 引数、environ は丸ごと別ファイルへ記録する。
RECORD_CMD="$WORKDIR/record-cmd"
cat >"$RECORD_CMD" <<'RECORD_CMD_EOF'
#!/usr/bin/env bash
touch "${MARKER_FILE:?}"
printf '%s\n' "$@" >"${MARKER_ARGV_FILE:?}"
env >"${MARKER_ENV_FILE:?}"
RECORD_CMD_EOF
chmod +x "$RECORD_CMD"

# run_case <env assignments...> -- <argv...> — 現在 export 済みの環境で
# host-run.sh を走らせる。結果は CASE_RC / CASE_STDOUT / CASE_STDERR に残す。
CASE_RC=0
CASE_STDOUT=""
CASE_STDERR=""
run_case() {
	local out err
	out="$(mktemp)"
	err="$(mktemp)"
	if bash "$HOST_RUN_SH" "$@" >"$out" 2>"$err"; then
		CASE_RC=0
	else
		CASE_RC=$?
	fi
	CASE_STDOUT="$(cat "$out")"
	CASE_STDERR="$(cat "$err")"
	rm -f "$out" "$err"
}

# reset_env — 正常系の環境をまとめて張る。個々のテストで上書き/unset する。
_case_seq=0
reset_env() {
	_case_seq=$((_case_seq + 1))
	export HOST_BROKER="$BROKER_OK"
	unset DOTENV_PRIVATE_KEY DOTENV_PRIVATE_KEY_PROD DOTENV_PRIVATE_KEY_STALE 2>/dev/null || true
	export MARKER_FILE="$WORKDIR/marker.$$.$_case_seq"
	export MARKER_ARGV_FILE="$WORKDIR/marker-argv.$$.$_case_seq"
	export MARKER_ENV_FILE="$WORKDIR/marker-env.$$.$_case_seq"
	export BROKER_CALL_LOG="$WORKDIR/broker-calls.$$.$_case_seq"
	rm -f "$MARKER_FILE" "$MARKER_ARGV_FILE" "$MARKER_ENV_FILE" "$BROKER_CALL_LOG"
}

# --- 必須環境変数: HOST_BROKER が未設定 ------------------------------------------
echo "HOST_BROKER is unset"
reset_env
unset HOST_BROKER
run_case "$RECORD_CMD"

if [ "$CASE_RC" -ne 0 ]; then
	ok "missing HOST_BROKER causes non-zero exit"
else
	ng "missing HOST_BROKER did not cause non-zero exit"
fi
case "$CASE_STDERR" in
*HOST_BROKER*) ok "the error message names HOST_BROKER" ;;
*) ng "the error message did not name HOST_BROKER (stderr: $CASE_STDERR)" ;;
esac
if [ ! -f "$MARKER_FILE" ]; then
	ok "the command is never invoked when HOST_BROKER is unset"
else
	ng "the command was invoked even though HOST_BROKER was unset"
fi

# --- コマンド未指定 ---------------------------------------------------------------
echo "no command given"
reset_env
run_case

if [ "$CASE_RC" -ne 0 ]; then
	ok "no command given causes non-zero exit"
else
	ng "no command given did not cause non-zero exit"
fi
case "$CASE_STDERR" in
*"Usage:"*) ok "no command given prints usage" ;;
*) ng "no command given did not print usage (stderr: $CASE_STDERR)" ;;
esac

# --- broker が非ゼロ終了 ----------------------------------------------------------
echo "broker exits non-zero"
reset_env
export HOST_BROKER="$BROKER_FAIL"
run_case "$RECORD_CMD"

if [ "$CASE_RC" -ne 0 ]; then
	ok "broker failing causes non-zero exit"
else
	ng "broker failing did not cause non-zero exit"
fi
if [ ! -f "$MARKER_FILE" ]; then
	ok "the command is never invoked when the broker fails"
else
	ng "the command was invoked even though the broker failed"
fi

# --- broker の出力が空 ------------------------------------------------------------
echo "broker produces no output"
reset_env
export HOST_BROKER="$BROKER_EMPTY"
run_case "$RECORD_CMD"

if [ "$CASE_RC" -ne 0 ]; then
	ok "empty broker output causes non-zero exit"
else
	ng "empty broker output did not cause non-zero exit"
fi
if [ ! -f "$MARKER_FILE" ]; then
	ok "the command is never invoked when the broker produces no output"
else
	ng "the command was invoked even though the broker produced no output"
fi

# --- 否定対照: broker が非ゼロで終わるとコマンドを一度も起動しない --------------
# 上の 4 ケース (HOST_BROKER 未設定・broker 非ゼロ・broker 空出力・コマンド
# 未指定) をまとめて見る対照。個々のケースは上で確認済みなので、ここでは
# 「一度も起動しない」という結論だけをまとめて確かめる。
echo "negative control: none of the four rejection cases ever invokes the command"
for case_setup in "unset:HOST_BROKER" "broker:$BROKER_FAIL" "broker:$BROKER_EMPTY" "nocommand:"; do
	reset_env
	kind="${case_setup%%:*}"
	value="${case_setup#*:}"
	case "$kind" in
	unset) unset HOST_BROKER ;;
	broker) export HOST_BROKER="$value" ;;
	esac
	if [ "$kind" = "nocommand" ]; then
		run_case
	else
		run_case "$RECORD_CMD"
	fi
	if [ "$CASE_RC" -ne 0 ] && [ ! -f "$MARKER_FILE" ]; then
		ok "否定対照: broker が非ゼロで終わるとコマンドを一度も起動しない (case '$kind')"
	else
		ng "否定対照: broker が非ゼロで終わるとコマンドを一度も起動しない (case '$kind' failed: rc=$CASE_RC, marker exists: $([ -f "$MARKER_FILE" ] && echo yes || echo no))"
	fi
done

# --- 成功時: broker の出力が environ へ入り、古い鍵は削除される -----------------
echo "success path: broker output reaches the child's environ"
reset_env
export DOTENV_PRIVATE_KEY_STALE="old-unrelated-key"
run_case "$RECORD_CMD"

if [ "$CASE_RC" -eq 0 ]; then
	ok "host-run exits zero on the success path"
else
	ng "host-run exited $CASE_RC on the success path (stderr: $CASE_STDERR)"
fi

if [ -f "$MARKER_FILE" ]; then
	ok "the command is invoked on the success path"
else
	ng "the command was never invoked on the success path"
fi

if [ -f "$BROKER_CALL_LOG" ] && [ "$(wc -l <"$BROKER_CALL_LOG")" -eq 1 ]; then
	ok "the broker is called exactly once"
else
	ng "the broker was not called exactly once (calls: $(wc -l <"$BROKER_CALL_LOG" 2>/dev/null))"
fi

if [ -f "$MARKER_ENV_FILE" ]; then
	if grep -qxF "DOTENV_PRIVATE_KEY_PROD=newval" "$MARKER_ENV_FILE"; then
		ok "the broker's key reaches the child's environ"
	else
		ng "the broker's key did not reach the child's environ"
	fi
	if grep -qxF "FOO=bar" "$MARKER_ENV_FILE"; then
		ok "a non-key variable from the broker also reaches the child's environ"
	else
		ng "a non-key variable from the broker did not reach the child's environ"
	fi
	if grep -q '^DOTENV_PRIVATE_KEY_STALE=' "$MARKER_ENV_FILE"; then
		ng "否定対照: サフィックスが衝突しない既存の私鍵は子プロセスへ届かない"
	else
		ok "否定対照: サフィックスが衝突しない既存の私鍵は子プロセスへ届かない"
	fi
else
	ng "the child's environ was never recorded (command not invoked)"
fi

# --- dotenv パースに失敗した行: 行番号だけが報告され、内容は出ない ---------------
echo "an unparseable line is reported by line number only, never by content"
reset_env
export HOST_BROKER="$BROKER_BAD_LINE"
run_case "$RECORD_CMD"

if [ "$CASE_RC" -ne 0 ]; then
	ok "an unparseable broker line causes non-zero exit"
else
	ng "an unparseable broker line did not cause non-zero exit"
fi
if [ ! -f "$MARKER_FILE" ]; then
	ok "the command is never invoked when a broker line cannot be parsed"
else
	ng "the command was invoked even though a broker line could not be parsed"
fi
case "$CASE_STDERR" in
*"line 2"*) ok "通し: 取り込めない行は行番号だけが報告され、内容は出ない (line number present)" ;;
*) ng "the error message did not report the line number (stderr: $CASE_STDERR)" ;;
esac
case "$CASE_STDERR" in
*"supersecretvalue-should-not-appear"*)
	ng "通し: 取り込めない行は行番号だけが報告され、内容は出ない (content leaked)"
	;;
*)
	ok "通し: 取り込めない行は行番号だけが報告され、内容は出ない (content absent)"
	;;
esac
case "$CASE_STDOUT" in
*"supersecretvalue-should-not-appear"*)
	ng "the unparseable line's content did not leak to stdout either"
	;;
*)
	ok "the unparseable line's content did not leak to stdout either"
	;;
esac

# --- 引数は逐語で渡る（シェルを経由しない） --------------------------------------
# シングルクォートは意図的。$HOME や ; | が展開・解釈されずに 1 引数として
# 届くこと自体を見たいので、ここでは展開させない。
echo "arguments reach the command verbatim, without going through a shell"
reset_env
# shellcheck disable=SC2016
run_case "$RECORD_CMD" "hello world" 'has "quotes"' '$HOME' 'a;b|c'

if [ -f "$MARKER_ARGV_FILE" ]; then
	mapfile -t got_argv <"$MARKER_ARGV_FILE"
	# shellcheck disable=SC2016
	expected_argv=("hello world" 'has "quotes"' '$HOME' 'a;b|c')
	if [ "${#got_argv[@]}" -eq "${#expected_argv[@]}" ]; then
		ok "the argument count is preserved"
	else
		ng "the argument count changed (got ${#got_argv[@]}, expected ${#expected_argv[@]})"
	fi
	all_match=1
	for i in "${!expected_argv[@]}"; do
		if [ "${got_argv[$i]:-}" != "${expected_argv[$i]}" ]; then
			all_match=0
		fi
	done
	if [ "$all_match" -eq 1 ]; then
		ok "each argument (including one with embedded spaces) is passed through verbatim as a single argument"
	else
		ng "arguments did not match verbatim (got: ${got_argv[*]:-<none>})"
	fi
else
	ng "the command was never invoked (no argv file)"
fi

# --- 結果 -----------------------------------------------------------------------

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
