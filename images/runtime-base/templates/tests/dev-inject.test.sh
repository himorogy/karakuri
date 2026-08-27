#!/usr/bin/env bash
#
# Tests for dev-inject.sh.
#
# docker daemon なしで走る（dev container に docker socket は無い）。
# `docker` を PATH 先頭のフェイクスクリプトへ差し替え、broker もフェイクの
# 実行ファイルへ差し替えて、dev-inject.sh 自身のロジック（引数拒否・必須
# 環境変数の検査・コンテナ特定の失敗系・pipefail の実効性・stdin の中継・
# 失敗原因の切り分け）だけを検証する。実際の docker compose / exec や
# コンテナ内の取込スクリプトの挙動はここでは見ない。
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
DEV_INJECT_SH="$TEST_DIR/../host/dev-inject.sh"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

FAKE_BIN_DIR="$WORKDIR/bin"
mkdir -p "$FAKE_BIN_DIR"

# --- フェイク docker -----------------------------------------------------------
# dev-inject.sh は docker を 2 回呼ぶ: `docker compose -p <p> ps -q <svc>`
# （コンテナ特定）と `docker exec -i <cid> ...`（注入）。サブコマンドで
# 分岐し、それぞれ引数を 1 行 1 引数で記録する。ps の出力（コンテナ id）は
# FAKE_COMPOSE_PS_STDOUT、終了コードは FAKE_COMPOSE_EXIT_CODE /
# FAKE_EXEC_EXIT_CODE で制御する。exec 側は標準入力をまるごとファイルへ
# 落とす。実 docker には一切触れない。
cat >"$FAKE_BIN_DIR/docker" <<'FAKE_DOCKER'
#!/usr/bin/env bash
case "${1:-}" in
compose)
	printf '%s\n' "$@" >"${FAKE_COMPOSE_ARGV_FILE:?}"
	if [ -n "${FAKE_COMPOSE_PS_STDOUT:-}" ]; then
		printf '%s\n' "$FAKE_COMPOSE_PS_STDOUT"
	fi
	exit "${FAKE_COMPOSE_EXIT_CODE:-0}"
	;;
exec)
	printf '%s\n' "$@" >"${FAKE_EXEC_ARGV_FILE:?}"
	printf 'MSYS_NO_PATHCONV=%s\n' "${MSYS_NO_PATHCONV:-<unset>}" >"${FAKE_EXEC_ENV_FILE:?}"
	cat >"${FAKE_EXEC_STDIN_FILE:?}"
	exit "${FAKE_EXEC_EXIT_CODE:-0}"
	;;
*)
	echo "fake docker: unexpected subcommand: ${1:-}" >&2
	exit 63
	;;
esac
FAKE_DOCKER
chmod +x "$FAKE_BIN_DIR/docker"

# --- フェイク broker ------------------------------------------------------------
# 成功ケース: 決まった dotenv ペイロードを出力して 0 で終了する。
BROKER_OK="$WORKDIR/broker-ok"
cat >"$BROKER_OK" <<'FAKE_BROKER_OK'
#!/usr/bin/env bash
printf 'FOO=bar\nBAZ=qux\n'
FAKE_BROKER_OK
chmod +x "$BROKER_OK"

# 失敗ケース: 認可拒否を模して非ゼロで終了する。stdout には何も出さない。
BROKER_FAIL="$WORKDIR/broker-fail"
cat >"$BROKER_FAIL" <<'FAKE_BROKER_FAIL'
#!/usr/bin/env bash
echo "fake broker: authorization denied" >&2
exit 7
FAKE_BROKER_FAIL
chmod +x "$BROKER_FAIL"

# SIGPIPE ケース: docker が先に stdin を閉じたことで broker が SIGPIPE
# (141) を受けたことを模す。実際に SIGPIPE を起こす必要はなく、dev-inject.sh
# は PIPESTATUS の値 (= 141) だけを見て分岐するため、直接 exit 141 する
# フェイクで十分。
BROKER_141="$WORKDIR/broker-141"
cat >"$BROKER_141" <<'FAKE_BROKER_141'
#!/usr/bin/env bash
echo "fake broker: killed by SIGPIPE (simulated)" >&2
exit 141
FAKE_BROKER_141
chmod +x "$BROKER_141"

BASE_CID="cafe0123deadbeef"

# 正常系の環境をまとめて張る。個々のテストで一部だけ上書き/unset する。
reset_env() {
	export DEV_BROKER="$BROKER_OK"
	export DEV_COMPOSE_PROJECT="acme"
	unset DEV_SERVICE 2>/dev/null || true
	export FAKE_COMPOSE_PS_STDOUT="$BASE_CID"
	export FAKE_COMPOSE_EXIT_CODE=0
	export FAKE_EXEC_EXIT_CODE=0
	export FAKE_COMPOSE_ARGV_FILE="$WORKDIR/compose-argv.$$.$RANDOM"
	export FAKE_EXEC_ARGV_FILE="$WORKDIR/exec-argv.$$.$RANDOM"
	export FAKE_EXEC_STDIN_FILE="$WORKDIR/exec-stdin.$$.$RANDOM"
	export FAKE_EXEC_ENV_FILE="$WORKDIR/exec-env.$$.$RANDOM"
}

# run_case <argv...> — 現在 export 済みの環境と、PATH 先頭のフェイク docker
# で dev-inject.sh を走らせる。結果は CASE_RC / CASE_STDOUT / CASE_STDERR に
# 残す。CASE_STDOUT は現状どのアサーションも見ないが、失敗時に手で調べる
# 用途のために残す。
CASE_RC=0
CASE_STDOUT=""
CASE_STDERR=""
run_case() {
	local out err
	out="$(mktemp)"
	err="$(mktemp)"
	if PATH="$FAKE_BIN_DIR:$PATH" bash "$DEV_INJECT_SH" "$@" >"$out" 2>"$err"; then
		CASE_RC=0
	else
		CASE_RC=$?
	fi
	# shellcheck disable=SC2034 # kept for manual debugging; no assertion reads it
	CASE_STDOUT="$(cat "$out")"
	CASE_STDERR="$(cat "$err")"
	rm -f "$out" "$err"
}

# --- 引数を渡すと usage + 非ゼロ終了（引数は取らない仕様） ---------------------
echo "arguments are rejected"
reset_env
run_case some-argument

if [ "$CASE_RC" -ne 0 ]; then
	ok "passing an argument causes non-zero exit"
else
	ng "passing an argument did not cause non-zero exit"
fi

case "$CASE_STDERR" in
*"Usage:"*) ok "passing an argument prints usage" ;;
*) ng "passing an argument did not print usage (stderr: $CASE_STDERR)" ;;
esac

if [ ! -f "$FAKE_COMPOSE_ARGV_FILE" ] && [ ! -f "$FAKE_EXEC_ARGV_FILE" ]; then
	ok "docker is not invoked when arguments are rejected"
else
	ng "docker was invoked even though the arguments were rejected"
fi

# --- 必須環境変数が欠けたとき非ゼロ終了する（2 種それぞれ） -------------------
echo "missing required environment variables"
for var in DEV_BROKER DEV_COMPOSE_PROJECT; do
	reset_env
	unset "$var"

	run_case

	if [ "$CASE_RC" -ne 0 ]; then
		ok "missing $var causes non-zero exit"
	else
		ng "missing $var did not cause non-zero exit"
	fi

	case "$CASE_STDERR" in
	*"$var"*) ok "missing $var is named in the error message" ;;
	*) ng "missing $var: error message did not name it (stderr: $CASE_STDERR)" ;;
	esac

	case "$CASE_STDERR" in
	*"Usage:"*) ok "missing $var prints usage" ;;
	*) ng "missing $var did not print usage (stderr: $CASE_STDERR)" ;;
	esac
done

# --- コンテナ不在 (ps -q が空) → 非ゼロ終了、broker/exec は呼ばれない ----------
echo "container not running"
reset_env
export FAKE_COMPOSE_PS_STDOUT=""

run_case

if [ "$CASE_RC" -ne 0 ]; then
	ok "empty ps output (container not up) causes non-zero exit"
else
	ng "empty ps output did not cause non-zero exit"
fi

case "$CASE_STDERR" in
*"not up"*) ok "error message says the container is not up" ;;
*) ng "error message did not say the container is not up (stderr: $CASE_STDERR)" ;;
esac

if [ ! -f "$FAKE_EXEC_ARGV_FILE" ]; then
	ok "docker exec is not invoked when no container is found"
else
	ng "docker exec was invoked even though no container was found"
fi

# --- コンテナ複数 (ps -q が複数行) → 曖昧としてエラー ---------------------------
echo "multiple containers match"
reset_env
FAKE_COMPOSE_PS_STDOUT="$(printf 'cid-one\ncid-two')"
export FAKE_COMPOSE_PS_STDOUT

run_case

if [ "$CASE_RC" -ne 0 ]; then
	ok "multiple ps lines cause non-zero exit"
else
	ng "multiple ps lines did not cause non-zero exit"
fi

case "$CASE_STDERR" in
*"multiple containers"*) ok "error message identifies the ambiguity (multiple containers)" ;;
*) ng "error message did not identify the ambiguity (stderr: $CASE_STDERR)" ;;
esac

if [ ! -f "$FAKE_EXEC_ARGV_FILE" ]; then
	ok "docker exec is not invoked when the target is ambiguous"
else
	ng "docker exec was invoked even though the target was ambiguous"
fi

# --- 成功時: compose/exec への引数と stdin 中継の確認 ---------------------------
echo "success path: argv and stdin reach the fake docker"
reset_env
run_case

if [ "$CASE_RC" -eq 0 ]; then
	ok "dev-inject exits zero when broker and docker both succeed"
else
	ng "dev-inject exited $CASE_RC on the success path (stderr: $CASE_STDERR)"
fi

if [ -f "$FAKE_COMPOSE_ARGV_FILE" ]; then
	# `--` は grep への必須引数。"-p" や "-q" のように先頭が "-" の期待値を
	# パターンではなくオプションとして誤解釈させないため。
	for expected in compose -p acme ps -q dev; do
		if grep -qxF -- "$expected" "$FAKE_COMPOSE_ARGV_FILE"; then
			ok "fake docker compose argv contains '$expected'"
		else
			ng "fake docker compose argv is missing '$expected'"
		fi
	done
else
	ng "fake docker compose was never invoked (no argv file)"
fi

if [ -f "$FAKE_EXEC_ARGV_FILE" ]; then
	for expected in exec -i "$BASE_CID" /usr/local/bin/secrets-ingest.sh; do
		if grep -qxF -- "$expected" "$FAKE_EXEC_ARGV_FILE"; then
			ok "fake docker exec argv contains '$expected'"
		else
			ng "fake docker exec argv is missing '$expected'"
		fi
	done
else
	ng "fake docker exec was never invoked (no argv file)"
fi

if [ -f "$FAKE_EXEC_STDIN_FILE" ]; then
	expected_stdin="$(printf 'FOO=bar\nBAZ=qux\n')"
	actual_stdin="$(cat "$FAKE_EXEC_STDIN_FILE")"
	if [ "$actual_stdin" = "$expected_stdin" ]; then
		ok "fake docker exec's stdin matches the broker's output verbatim"
	else
		ng "fake docker exec's stdin did not match the broker's output (got: $actual_stdin)"
	fi
else
	ng "fake docker exec was never invoked (no stdin file)"
fi

# MSYS_NO_PATHCONV=1 が無いと、Git Bash(MSYS2) が /usr/local/bin/... を
# Windows パスへ変換してしまう（実機で踏んだ不具合）。
if [ -f "$FAKE_EXEC_ENV_FILE" ] && [ "$(cat "$FAKE_EXEC_ENV_FILE")" = "MSYS_NO_PATHCONV=1" ]; then
	ok "docker exec receives MSYS_NO_PATHCONV=1"
else
	ng "docker exec did not receive MSYS_NO_PATHCONV=1 (got: $(cat "$FAKE_EXEC_ENV_FILE" 2>/dev/null))"
fi

# --- DEV_SERVICE で service 名を差し替えられる（既定は dev） --------------------
echo "DEV_SERVICE overrides the service name"
reset_env
export DEV_SERVICE="workbench"

run_case

if [ -f "$FAKE_COMPOSE_ARGV_FILE" ] && grep -qxF -- "workbench" "$FAKE_COMPOSE_ARGV_FILE"; then
	ok "fake docker compose argv contains the overridden service name"
else
	ng "fake docker compose argv did not contain the overridden service name"
fi

# --- pipefail の実効確認: broker 失敗 + フェイク docker 0 → 全体が非ゼロ ------
echo "pipefail: broker fails even though the pipeline's last command succeeds"
reset_env
export DEV_BROKER="$BROKER_FAIL"
export FAKE_EXEC_EXIT_CODE=0 # docker 側は「成功」を返す設定にしておく

run_case

if [ "$CASE_RC" -ne 0 ]; then
	ok "dev-inject exits non-zero when broker fails, even though the fake docker exits 0"
else
	ng "dev-inject exited 0 despite broker failure — pipefail is not effective"
fi

case "$CASE_STDERR" in
*"broker failed"*) ok "error message identifies the broker as the failing stage" ;;
*) ng "error message did not identify broker failure (stderr: $CASE_STDERR)" ;;
esac

# --- SIGPIPE regression: broker=141 (SIGPIPE) + docker 非ゼロ -----------------
#     docker が先に失敗して stdin を閉じると broker は SIGPIPE (141) で
#     落ちる。真の原因は docker であり、broker の 141 はその症状に過ぎない
#     ため、docker の終了コードで終了し、メッセージも docker を原因として
#     示すべき (regression)。
echo "broker 141 (SIGPIPE) + docker non-zero: docker is reported as the cause"
reset_env
export DEV_BROKER="$BROKER_141"
export FAKE_EXEC_EXIT_CODE=5

run_case

if [ "$CASE_RC" -eq 5 ]; then
	ok "exit code is docker's (5), not broker's SIGPIPE (141)"
else
	ng "exit code was $CASE_RC, expected docker's 5 (broker's 141 must not win)"
fi

case "$CASE_STDERR" in
*docker*) ok "error message identifies docker as the root cause" ;;
*) ng "error message did not identify docker as the cause (stderr: $CASE_STDERR)" ;;
esac

case "$CASE_STDERR" in
*141*) ok "error message mentions broker's 141 (SIGPIPE) as a symptom, not the cause" ;;
*) ng "error message did not mention 141 (stderr: $CASE_STDERR)" ;;
esac

# --- 両方非ゼロ (141 以外) regression: 両方の終了コードが出る ------------------
#     broker が (SIGPIPE 以外の理由で) 非ゼロ、かつ docker も非ゼロのとき、
#     どちらが「本当の」原因かは機械的に決められないため、両方の終了コード
#     をメッセージに出す (regression)。
echo "broker non-zero (not 141) + docker non-zero: both exit codes are shown"
reset_env
export DEV_BROKER="$BROKER_FAIL" # exit 7
export FAKE_EXEC_EXIT_CODE=5

run_case

if [ "$CASE_RC" -eq 7 ]; then
	ok "exit code is broker's (7) when both fail and broker isn't 141"
else
	ng "exit code was $CASE_RC, expected broker's 7"
fi

if printf '%s' "$CASE_STDERR" | grep -q "exit 7" && printf '%s' "$CASE_STDERR" | grep -q "exit 5"; then
	ok "error message shows both exit codes (broker 7, docker 5)"
else
	ng "error message did not show both exit codes (stderr: $CASE_STDERR)"
fi

# --- 結果 -----------------------------------------------------------------------

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
