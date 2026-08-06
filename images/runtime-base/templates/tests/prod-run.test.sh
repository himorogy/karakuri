#!/usr/bin/env bash
#
# Tests for prod-run.sh.
#
# docker daemon なしで走る（dev container に docker socket は無い）。
# `docker` を PATH 先頭のフェイクスクリプトへ差し替え、broker もフェイクの
# 実行ファイルへ差し替えて、prod-run.sh 自身のロジック（必須環境変数の
# 検査・usage・pipefail の実効性・引数の受け渡し・stdin の中継）だけを
# 検証する。実際の docker compose / entrypoint の挙動はここでは見ない。
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
PROD_RUN_SH="$TEST_DIR/../prod-run.sh"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

FAKE_BIN_DIR="$WORKDIR/bin"
mkdir -p "$FAKE_BIN_DIR"

# --- フェイク docker -----------------------------------------------------------
# 呼ばれた引数を 1 行 1 引数で記録する（printf '%s\n' "$@" は各引数を
# そのまま 1 行にするので、スペースを含む引数が誤って分割されていないかを
# 行の内容そのもので確認できる）。標準入力はまるごとファイルへ落とす。
# 終了コードは FAKE_DOCKER_EXIT_CODE で制御する。実 docker には一切触れない。
cat >"$FAKE_BIN_DIR/docker" <<'FAKE_DOCKER'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${FAKE_DOCKER_ARGV_FILE:?}"
cat >"${FAKE_DOCKER_STDIN_FILE:?}"
exit "${FAKE_DOCKER_EXIT_CODE:-0}"
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
# (141) を受けたことを模す。実際に SIGPIPE を起こす必要はなく、prod-run.sh
# は PIPESTATUS の値 (= 141) だけを見て分岐するため、直接 exit 141 する
# フェイクで十分。
BROKER_141="$WORKDIR/broker-141"
cat >"$BROKER_141" <<'FAKE_BROKER_141'
#!/usr/bin/env bash
echo "fake broker: killed by SIGPIPE (simulated)" >&2
exit 141
FAKE_BROKER_141
chmod +x "$BROKER_141"

BASE_COMPOSE_FILE="$WORKDIR/compose.prod.yaml" # 中身は読まれないので実在しなくてよい
BASE_GIT_REPO="https://github.com/acme/app.git"
BASE_GIT_REF="1234567890abcdef1234567890abcdef12345678" # 40 桁 hex

# 正常系の環境をまとめて張る。個々のテストで一部だけ上書き/unset する。
reset_env() {
	export PROD_COMPOSE_FILE="$BASE_COMPOSE_FILE"
	export PROD_BROKER="$BROKER_OK"
	export GIT_REPO="$BASE_GIT_REPO"
	export GIT_REF="$BASE_GIT_REF"
	export FAKE_DOCKER_EXIT_CODE=0
	export FAKE_DOCKER_ARGV_FILE="$WORKDIR/argv.$$.$RANDOM"
	export FAKE_DOCKER_STDIN_FILE="$WORKDIR/stdin.$$.$RANDOM"
}

# run_case <argv...> — 現在 export 済みの環境と、PATH 先頭のフェイク docker
# で prod-run.sh を走らせる。結果は CASE_RC / CASE_STDOUT / CASE_STDERR に
# 残す。CASE_STDOUT は現状どのアサーションも見ないが、失敗時に手で調べる
# 用途のために残す。
CASE_RC=0
CASE_STDOUT=""
CASE_STDERR=""
run_case() {
	local out err
	out="$(mktemp)"
	err="$(mktemp)"
	if PATH="$FAKE_BIN_DIR:$PATH" bash "$PROD_RUN_SH" "$@" >"$out" 2>"$err"; then
		CASE_RC=0
	else
		CASE_RC=$?
	fi
	# shellcheck disable=SC2034 # kept for manual debugging; no assertion reads it
	CASE_STDOUT="$(cat "$out")"
	CASE_STDERR="$(cat "$err")"
	rm -f "$out" "$err"
}

# --- 必須環境変数が欠けたとき非ゼロ終了する（4 種それぞれ） -------------------
echo "missing required environment variables"
for var in PROD_COMPOSE_FILE PROD_BROKER GIT_REPO GIT_REF; do
	reset_env
	unset "$var"

	run_case true

	if [ "$CASE_RC" -ne 0 ]; then
		ok "missing $var causes non-zero exit"
	else
		ng "missing $var did not cause non-zero exit"
	fi

	case "$CASE_STDERR" in
	*"$var"*) ok "missing $var is named in the error message" ;;
	*) ng "missing $var: error message did not name it (stderr: $CASE_STDERR)" ;;
	esac
done

# --- 引数なしで usage + 非ゼロ終了 ---------------------------------------------
echo "no arguments"
reset_env
run_case

if [ "$CASE_RC" -ne 0 ]; then
	ok "no arguments causes non-zero exit"
else
	ng "no arguments did not cause non-zero exit"
fi

case "$CASE_STDERR" in
*"Usage:"*) ok "no arguments prints usage" ;;
*) ng "no arguments did not print usage (stderr: $CASE_STDERR)" ;;
esac

# --- pipefail の実効確認: broker 失敗 + フェイク docker 0 → 全体が非ゼロ ------
echo "pipefail: broker fails even though the pipeline's last command succeeds"
reset_env
export PROD_BROKER="$BROKER_FAIL"
export FAKE_DOCKER_EXIT_CODE=0 # docker 側は「成功」を返す設定にしておく

run_case true

if [ "$CASE_RC" -ne 0 ]; then
	ok "wrapper exits non-zero when broker fails, even though the fake docker exits 0"
else
	ng "wrapper exited 0 despite broker failure — pipefail is not effective"
fi

case "$CASE_STDERR" in
*"broker failed"*) ok "error message identifies the broker as the failing stage" ;;
*) ng "error message did not identify broker failure (stderr: $CASE_STDERR)" ;;
esac

# --- SIGPIPE regression: broker=141 (SIGPIPE) + docker 非ゼロ -----------------
#     docker が先に失敗して stdin を閉じると broker は SIGPIPE (141) で
#     落ちる。真の原因は docker であり、broker の 141 はその症状に過ぎない
#     ため、docker の終了コードで終了し、メッセージも docker を原因として
#     示すべき (regression: 設計書 §4.1 rev.4)。
echo "broker 141 (SIGPIPE) + docker non-zero: docker is reported as the cause"
reset_env
export PROD_BROKER="$BROKER_141"
export FAKE_DOCKER_EXIT_CODE=5

run_case true

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
#     をメッセージに出す (regression: 設計書 §4.1 rev.4)。
echo "broker non-zero (not 141) + docker non-zero: both exit codes are shown"
reset_env
export PROD_BROKER="$BROKER_FAIL" # exit 7
export FAKE_DOCKER_EXIT_CODE=5

run_case true

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

# --- 成功時: 引数・-T・run --rm prod・stdin 中継の確認 -------------------------
echo "success path: argv and stdin reach the fake docker"
reset_env
run_case sh -c "echo hi there"

if [ "$CASE_RC" -eq 0 ]; then
	ok "wrapper exits zero when broker and docker both succeed"
else
	ng "wrapper exited $CASE_RC on the success path (stderr: $CASE_STDERR)"
fi

if [ -f "$FAKE_DOCKER_ARGV_FILE" ]; then
	# `--` は grep への必須引数。"-T" や "--rm" のように先頭が "-" の
	# 期待値をパターンではなくオプションとして誤解釈させないため。
	for expected in compose -T run --rm prod "echo hi there"; do
		if grep -qxF -- "$expected" "$FAKE_DOCKER_ARGV_FILE"; then
			ok "fake docker argv contains '$expected'"
		else
			ng "fake docker argv is missing '$expected'"
		fi
	done
else
	ng "fake docker was never invoked (no argv file)"
fi

if [ -f "$FAKE_DOCKER_STDIN_FILE" ]; then
	expected_stdin="$(printf 'FOO=bar\nBAZ=qux\n')"
	actual_stdin="$(cat "$FAKE_DOCKER_STDIN_FILE")"
	if [ "$actual_stdin" = "$expected_stdin" ]; then
		ok "fake docker's stdin matches the broker's output verbatim"
	else
		ng "fake docker's stdin did not match the broker's output (got: $actual_stdin)"
	fi
else
	ng "fake docker was never invoked (no stdin file)"
fi

# --- GIT_REF が 40 桁 hex でない (既定): 早期に拒否される (rev.6 / D21) --------
#     entrypoint 側が権威であり拒否するようになったため、ラッパー側も
#     docker を起動する前に同じ既定で早期に落とす。
echo "non-sha GIT_REF is rejected by default (rev.6 / D21)"
reset_env
export GIT_REF="main"

run_case true

if [ "$CASE_RC" -ne 0 ]; then
	ok "non-sha GIT_REF causes non-zero exit by default"
else
	ng "non-sha GIT_REF did not block the run by default (exit $CASE_RC)"
fi

case "$CASE_STDERR" in
*"PROD_ALLOW_MUTABLE_REF"*) ok "rejection message mentions the PROD_ALLOW_MUTABLE_REF escape hatch" ;;
*) ng "rejection message did not mention PROD_ALLOW_MUTABLE_REF (stderr: $CASE_STDERR)" ;;
esac

if [ -f "$FAKE_DOCKER_ARGV_FILE" ]; then
	ng "docker was invoked even though GIT_REF was rejected before launch"
else
	ok "docker was not invoked when GIT_REF was rejected before launch"
fi

# --- GIT_REF が 40 桁 hex でない + PROD_ALLOW_MUTABLE_REF=1: 警告付きで続行 -----
echo "non-sha GIT_REF with PROD_ALLOW_MUTABLE_REF=1 warns but does not block execution"
reset_env
export GIT_REF="main"
export PROD_ALLOW_MUTABLE_REF=1

run_case true

case "$CASE_STDERR" in
*"WARNING"*"GIT_REF"*) ok "non-sha GIT_REF prints a warning mentioning GIT_REF" ;;
*) ng "non-sha GIT_REF did not print the expected warning (stderr: $CASE_STDERR)" ;;
esac

if [ "$CASE_RC" -eq 0 ]; then
	ok "non-sha GIT_REF with PROD_ALLOW_MUTABLE_REF=1 still lets the run complete"
else
	ng "non-sha GIT_REF with PROD_ALLOW_MUTABLE_REF=1 blocked the run (exit $CASE_RC), but it should only warn"
fi
unset PROD_ALLOW_MUTABLE_REF

# --- 結果 -----------------------------------------------------------------------

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
