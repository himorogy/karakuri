#!/usr/bin/env bash
#
# Tests for dock.sh.
#
# docker daemon なしで走る（dev container に docker socket は無い）。`docker`
# を PATH 先頭のフェイクスクリプトへ差し替え、dock.sh 自身のロジック
# （引数の解決・コンテナ特定の失敗系・モードの排他・secrets-ok の判定・
# --stdio の fail closed）だけを検証する。実際の docker の挙動はここでは
# 見ない。
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
DOCK_SH="$TEST_DIR/../host/dock.sh"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

FAKE_BIN_DIR="$WORKDIR/bin"
mkdir -p "$FAKE_BIN_DIR"

# --- フェイク docker -----------------------------------------------------------
# dock.sh が docker を呼ぶのは 4 箇所: コンテナ特定 (ps -a -q --filter
# label=...)、起動状態の確認 (inspect -f '{{.State.Running}}')、起動
# (start)、secrets の判定・sshd の起動・対話シェル (exec) の 3 用途。
#
# 各サブコマンドの呼び出しは、そのテストケース内で高々 1 回しか起きない
# ので、記録先は都度 reset_env が作り直す 1 ファイルずつでよい。
cat >"$FAKE_BIN_DIR/docker" <<'FAKE_DOCKER'
#!/usr/bin/env bash
case "${1:-}" in
ps)
	printf '%s\n' "$@" >"${FAKE_PS_ARGV_FILE:?}"
	if [ -n "${FAKE_PS_STDOUT:-}" ]; then
		printf '%s\n' "$FAKE_PS_STDOUT"
	fi
	exit "${FAKE_PS_EXIT_CODE:-0}"
	;;
inspect)
	printf '%s\n' "$@" >"${FAKE_INSPECT_ARGV_FILE:?}"
	printf '%s\n' "${FAKE_RUNNING:-true}"
	exit "${FAKE_INSPECT_EXIT_CODE:-0}"
	;;
start)
	printf '%s\n' "$*" >"${FAKE_START_ARGV_FILE:?}"
	if [ -n "${FAKE_START_STDOUT:-}" ]; then
		printf '%s\n' "$FAKE_START_STDOUT"
	fi
	exit "${FAKE_START_EXIT_CODE:-0}"
	;;
exec)
	shift
	case " $* " in
	*" test -f /run/secrets/SSH_AUTHORIZED_KEYS "*)
		printf '%s\n' "$*" >"${FAKE_SECRETS_CHECK_ARGV_FILE:?}"
		if [ -n "${FAKE_SECRETS_CHECK_STDOUT:-}" ]; then
			printf '%s\n' "$FAKE_SECRETS_CHECK_STDOUT"
		fi
		if [ -n "${FAKE_SECRETS_CHECK_STDERR:-}" ]; then
			printf '%s\n' "$FAKE_SECRETS_CHECK_STDERR" >&2
		fi
		exit "${FAKE_SECRETS_EXIT_CODE:-0}"
		;;
	*)
		printf '%s\n' "$*" >"${FAKE_EXEC_ARGV_FILE:?}"
		if [ -n "${FAKE_EXEC_STDOUT:-}" ]; then
			printf '%s\n' "$FAKE_EXEC_STDOUT"
		fi
		exit "${FAKE_EXEC_EXIT_CODE:-0}"
		;;
	esac
	;;
*)
	echo "fake docker: unexpected subcommand: ${1:-}" >&2
	exit 63
	;;
esac
FAKE_DOCKER
chmod +x "$FAKE_BIN_DIR/docker"

BASE_CID="cafe0123deadbeef"

# --- 走らせる --------------------------------------------------------------------

reset_env() {
	export FAKE_PS_ARGV_FILE="$WORKDIR/ps-argv.$$.$RANDOM"
	export FAKE_INSPECT_ARGV_FILE="$WORKDIR/inspect-argv.$$.$RANDOM"
	export FAKE_START_ARGV_FILE="$WORKDIR/start-argv.$$.$RANDOM"
	export FAKE_EXEC_ARGV_FILE="$WORKDIR/exec-argv.$$.$RANDOM"
	export FAKE_SECRETS_CHECK_ARGV_FILE="$WORKDIR/secrets-check-argv.$$.$RANDOM"

	export FAKE_PS_STDOUT="$BASE_CID"
	export FAKE_PS_EXIT_CODE=0
	export FAKE_INSPECT_EXIT_CODE=0
	export FAKE_RUNNING=true
	export FAKE_START_EXIT_CODE=0
	unset FAKE_START_STDOUT
	export FAKE_SECRETS_EXIT_CODE=0
	unset FAKE_SECRETS_CHECK_STDOUT FAKE_SECRETS_CHECK_STDERR
	export FAKE_EXEC_EXIT_CODE=0
	unset FAKE_EXEC_STDOUT
}

# run_case <args...> — dock.sh を実行する。結果は CASE_RC / CASE_STDOUT /
# CASE_STDERR に残す。
CASE_RC=0
CASE_STDOUT=""
CASE_STDERR=""
run_case() {
	local out err
	out="$(mktemp)"
	err="$(mktemp)"
	if PATH="$FAKE_BIN_DIR:$PATH" bash "$DOCK_SH" "$@" >"$out" 2>"$err"; then
		CASE_RC=0
	else
		CASE_RC=$?
	fi
	CASE_STDOUT="$(cat "$out")"
	CASE_STDERR="$(cat "$err")"
	rm -f "$out" "$err"
}

# --- アサーション ----------------------------------------------------------------

has_line() { [ -f "$1" ] && grep -qxF -- "$2" "$1"; }

assert_rc_zero() {
	if [ "$CASE_RC" -eq 0 ]; then
		ok "$1"
	else
		ng "$1 (rc=$CASE_RC, stderr: $CASE_STDERR)"
	fi
}

assert_rc_eq() {
	if [ "$CASE_RC" -eq "$1" ]; then
		ok "$2"
	else
		ng "$2 (rc=$CASE_RC, expected $1, stderr: $CASE_STDERR)"
	fi
}

assert_rc_nonzero() {
	if [ "$CASE_RC" -ne 0 ]; then
		ok "$1"
	else
		ng "$1 (rc=0, stdout: $CASE_STDOUT)"
	fi
}

assert_stdout_empty() {
	if [ -z "$CASE_STDOUT" ]; then
		ok "$1"
	else
		ng "$1 (stdout: $CASE_STDOUT)"
	fi
}

assert_stderr_empty() {
	if [ -z "$CASE_STDERR" ]; then
		ok "$1"
	else
		ng "$1 (stderr: $CASE_STDERR)"
	fi
}

assert_stderr_has() {
	case "$CASE_STDERR" in
	*"$1"*) ok "$2" ;;
	*) ng "$2 (stderr: $CASE_STDERR)" ;;
	esac
}

not_invoked() {
	[ ! -s "$1" ]
}

assert_not_invoked() {
	if not_invoked "$1"; then
		ok "$2"
	else
		ng "$2 (recorded: $(cat "$1" 2>/dev/null))"
	fi
}

# --- --secrets-ok ------------------------------------------------------------
echo "--secrets-ok reports whether secrets are injected without side effects"

reset_env
export FAKE_SECRETS_EXIT_CODE=0
run_case -p proj --secrets-ok

assert_rc_zero "--secrets-ok exits 0 when secrets are injected"
assert_stdout_empty "--secrets-ok prints nothing on stdout when secrets are injected"
assert_stderr_empty "--secrets-ok prints nothing on stderr when secrets are injected"
assert_not_invoked "$FAKE_START_ARGV_FILE" "--secrets-ok never starts the container"

reset_env
export FAKE_SECRETS_EXIT_CODE=1
run_case -p proj --secrets-ok

assert_rc_eq 1 "--secrets-ok exits 1 when secrets are missing"
assert_stdout_empty "--secrets-ok prints nothing on stdout when secrets are missing"
assert_stderr_empty "--secrets-ok prints nothing on stderr when secrets are missing"
assert_not_invoked "$FAKE_START_ARGV_FILE" "--secrets-ok does not start a running container to check it"

reset_env
export FAKE_RUNNING=false
run_case -p proj --secrets-ok

assert_rc_eq 1 "--secrets-ok exits 1 when the container is not running (secrets cannot survive a stop)"
assert_stdout_empty "--secrets-ok prints nothing on stdout when the container is stopped"
assert_stderr_empty "--secrets-ok prints nothing on stderr when the container is stopped"
assert_not_invoked "$FAKE_START_ARGV_FILE" "--secrets-ok does not start a stopped container"
assert_not_invoked "$FAKE_EXEC_ARGV_FILE" "--secrets-ok does not exec into a stopped container"

# 上の「stdout/stderr が空」は、フェイクの secrets 判定がそもそも何も
# 吐かない作りだと、dock.sh 側が `>/dev/null 2>&1` を落としても検出できない
# （空振りする検査になる）。判定コマンドに実際に吐かせて、dock.sh がそれを
# 握り込んでいることを見る。
reset_env
export FAKE_SECRETS_EXIT_CODE=0
export FAKE_SECRETS_CHECK_STDOUT="unexpected stdout from the secrets check"
export FAKE_SECRETS_CHECK_STDERR="unexpected stderr from the secrets check"
run_case -p proj --secrets-ok

assert_rc_zero "--secrets-ok still exits 0 when the underlying check itself prints something"
assert_stdout_empty "--secrets-ok swallows stdout that the secrets check itself produces"
assert_stderr_empty "--secrets-ok swallows stderr that the secrets check itself produces"

reset_env
export FAKE_SECRETS_EXIT_CODE=1
export FAKE_SECRETS_CHECK_STDOUT="unexpected stdout from the secrets check"
export FAKE_SECRETS_CHECK_STDERR="unexpected stderr from the secrets check"
run_case -p proj --secrets-ok

assert_rc_eq 1 "--secrets-ok still exits 1 when the underlying check itself prints something"
assert_stdout_empty "--secrets-ok swallows stdout even when the check fails and prints"
assert_stderr_empty "--secrets-ok swallows stderr even when the check fails and prints"

# --- --ensure-running ---------------------------------------------------------
echo "--ensure-running starts the container if needed and prints nothing"

reset_env
export FAKE_RUNNING=false
run_case -p proj --ensure-running

assert_rc_zero "--ensure-running succeeds when the container was stopped"
assert_stdout_empty "--ensure-running prints nothing on stdout when it starts the container"
if has_line "$FAKE_START_ARGV_FILE" "start ${BASE_CID}"; then
	ok "--ensure-running starts the stopped container"
else
	ng "--ensure-running starts the stopped container (recorded: $(cat "$FAKE_START_ARGV_FILE" 2>/dev/null))"
fi

reset_env
export FAKE_RUNNING=true
run_case -p proj --ensure-running

assert_rc_zero "--ensure-running succeeds when the container is already running"
assert_stdout_empty "--ensure-running prints nothing on stdout when the container is already running"
assert_not_invoked "$FAKE_START_ARGV_FILE" "--ensure-running does not start an already-running container"

# --- --stdio: fail closed -------------------------------------------------------
echo "--stdio fails closed when secrets are not injected"

reset_env
export FAKE_SECRETS_EXIT_CODE=1
run_case -p proj --stdio

assert_rc_eq 1 "--stdio exits 1 when secrets are not injected"
assert_stdout_empty "--stdio prints nothing on stdout when it fails closed"
assert_stderr_has "karakuri-dock up" "--stdio tells the caller to run karakuri-dock up on the host"
assert_not_invoked "$FAKE_EXEC_ARGV_FILE" "--stdio does not exec sshd-inetd when secrets are missing"

reset_env
export FAKE_SECRETS_EXIT_CODE=0
run_case -p proj --stdio

assert_rc_zero "--stdio exits 0 (via the fake sshd-inetd) when secrets are injected"
assert_stdout_empty "--stdio prints nothing on stdout when it succeeds"
if has_line "$FAKE_EXEC_ARGV_FILE" "-i -u root ${BASE_CID} /usr/local/sbin/sshd-inetd"; then
	ok "--stdio execs the sshd-inetd wrapper by absolute path"
else
	ng "--stdio execs the sshd-inetd wrapper by absolute path (recorded: $(cat "$FAKE_EXEC_ARGV_FILE" 2>/dev/null))"
fi

reset_env
export FAKE_RUNNING=false
export FAKE_SECRETS_EXIT_CODE=0
export FAKE_START_STDOUT="$BASE_CID"
run_case -p proj --stdio

assert_rc_zero "--stdio starts a stopped container before checking secrets"
assert_stdout_empty "--stdio does not leak the 'docker start' stdout of a stopped container"
if has_line "$FAKE_START_ARGV_FILE" "start ${BASE_CID}"; then
	ok "--stdio really did start the container"
else
	ng "--stdio really did start the container (recorded: $(cat "$FAKE_START_ARGV_FILE" 2>/dev/null))"
fi

# --- モードの排他 -----------------------------------------------------------------
echo "modes are mutually exclusive"

reset_env
run_case -p proj --stdio --secrets-ok

assert_rc_nonzero "combining --stdio and --secrets-ok fails"
assert_stderr_has "--stdio" "the error names --stdio"
assert_stderr_has "--secrets-ok" "the error names --secrets-ok"
assert_not_invoked "$FAKE_PS_ARGV_FILE" "a mode conflict is caught before any container lookup"

reset_env
run_case -p proj --ensure-running --stdio

assert_rc_nonzero "combining --ensure-running and --stdio fails"
assert_stderr_has "--ensure-running" "the error names --ensure-running"
assert_stderr_has "--stdio" "the error names --stdio"

# --- コンテナ特定 -----------------------------------------------------------------
echo "container lookup fails explicitly on 0 or multiple matches"

reset_env
export FAKE_PS_STDOUT=""
run_case -p proj --ensure-running

assert_rc_nonzero "no matching container fails"
assert_stderr_has "no container" "the error says no container matched"
assert_not_invoked "$FAKE_INSPECT_ARGV_FILE" "no matching container skips the running-state check"

reset_env
FAKE_PS_STDOUT="$(printf 'cid-one\ncid-two')"
export FAKE_PS_STDOUT
run_case -p proj --ensure-running

assert_rc_nonzero "more than one matching container fails"
assert_stderr_has "multiple containers" "the error says the match is ambiguous"
assert_not_invoked "$FAKE_INSPECT_ARGV_FILE" "an ambiguous match skips the running-state check"

if has_line "$FAKE_PS_ARGV_FILE" "label=com.docker.compose.project=proj"; then
	ok "the container is looked up through the compose project label passed to -p"
else
	ng "the container is looked up through the compose project label passed to -p (recorded: $(cat "$FAKE_PS_ARGV_FILE" 2>/dev/null))"
fi

reset_env
run_case -p proj -s worker --ensure-running
if has_line "$FAKE_PS_ARGV_FILE" "label=com.docker.compose.service=worker"; then
	ok "-s overrides the default service label"
else
	ng "-s overrides the default service label (recorded: $(cat "$FAKE_PS_ARGV_FILE" 2>/dev/null))"
fi

reset_env
run_case -p proj --ensure-running
if has_line "$FAKE_PS_ARGV_FILE" "label=com.docker.compose.service=dev"; then
	ok "the service label defaults to 'dev' when -s is omitted"
else
	ng "the service label defaults to 'dev' when -s is omitted (recorded: $(cat "$FAKE_PS_ARGV_FILE" 2>/dev/null))"
fi

# --- workspace ---------------------------------------------------------------
echo "-w is only used by the default (shell) mode"

reset_env
run_case -p proj -w /workspaces/proj
if has_line "$FAKE_EXEC_ARGV_FILE" "-it -w /workspaces/proj ${BASE_CID} zsh"; then
	ok "the default mode passes -w through to docker exec"
else
	ng "the default mode passes -w through to docker exec (recorded: $(cat "$FAKE_EXEC_ARGV_FILE" 2>/dev/null))"
fi

reset_env
run_case -p proj
if has_line "$FAKE_EXEC_ARGV_FILE" "-it ${BASE_CID} zsh"; then
	ok "omitting -w leaves docker exec without -w (falls back to the container's WORKDIR)"
else
	ng "omitting -w leaves docker exec without -w (recorded: $(cat "$FAKE_EXEC_ARGV_FILE" 2>/dev/null))"
fi

# --- 引数の誤り -------------------------------------------------------------------
echo "argument errors print usage and nothing on stdout"

reset_env
run_case
assert_rc_nonzero "no arguments fails"
assert_stdout_empty "no arguments prints nothing on stdout"
assert_stderr_has "Usage:" "no arguments prints usage"

reset_env
run_case --bogus
assert_rc_nonzero "an unknown option fails"
assert_stdout_empty "an unknown option prints nothing on stdout"
assert_stderr_has "Usage:" "an unknown option prints usage"

# 廃止した位置引数形式（`dock.sh <project>`）。`-*` ではなく素の語なので、
# `-*` 分岐ではなく「Unexpected argument」側（`*)` 分岐）を通る。この形は
# もう受け付けないことが「廃止する保証」の中心なので、その分岐自体を通す
# ケースを別に持つ。
reset_env
run_case -p proj myproj
assert_rc_nonzero "a bare positional argument (the retired 'dock.sh <project>' form) fails"
assert_stdout_empty "a bare positional argument prints nothing on stdout"
assert_stderr_has "Unexpected argument" "the error identifies it as an unexpected argument, not an unknown option"
assert_stderr_has "Usage:" "a bare positional argument prints usage"
assert_not_invoked "$FAKE_PS_ARGV_FILE" "a bare positional argument is rejected before any container lookup"

reset_env
run_case -p proj --help
assert_rc_zero "--help succeeds"
assert_stdout_empty "--help prints nothing on stdout (usage goes to stderr)"
assert_stderr_has "Usage:" "--help prints usage on stderr"
assert_not_invoked "$FAKE_PS_ARGV_FILE" "--help does not look up any container"

reset_env
run_case --secrets-ok
assert_rc_nonzero "a mode without -p fails"
assert_stderr_has "-p" "the error names -p as required"
assert_not_invoked "$FAKE_PS_ARGV_FILE" "a missing -p is caught before any container lookup"

# --- 結果 -----------------------------------------------------------------------

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
