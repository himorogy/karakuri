#!/usr/bin/env bash
#
# Tests for karakuri.sh.
#
# docker daemon なしで走る（dev container に docker socket は無い）。
# `docker` と `ssh` を PATH 先頭のフェイクスクリプトへ差し替え、karakuri.sh が
# 呼ぶ prod-run.sh / dev-inject.sh / broker もフェイクへ差し替えて、
# karakuri.sh 自身のロジック（引数の解決・compose project 名・sh -c を挟む
# 条件・コンテナ特定の失敗系・digest の照合）だけを検証する。実際の
# docker compose / ssh / prod-run.sh の挙動はここでは見ない。
#
# フェイクの置き方: karakuri.sh は「自分自身が置かれているディレクトリ」から
# 隣のスクリプトを探すので、フェイクを詰めたディレクトリへ karakuri.sh の
# symlink を張り、そこから source する。karakuri.sh の実物をそのまま
# 読ませつつ、呼び先だけを差し替えられる。
#
# 同じ検査を bash と zsh の両方で回す（source される関数ファイルなので、
# 利用者のログインシェルがどちらでも同じに動く必要がある）。zsh がこの環境に
# 無ければ zsh 側は skip する。
#
set -uo pipefail

PASS=0
FAIL=0
SKIP=0

ok() {
	PASS=$((PASS + 1))
	printf '  ok   %s\n' "$1"
}

ng() {
	FAIL=$((FAIL + 1))
	printf '  FAIL %s\n' "$1" >&2
}

skip() {
	SKIP=$((SKIP + 1))
	printf '  skip %s\n' "$1"
}

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
KARAKURI_SH_REAL="$TEST_DIR/../host/karakuri.sh"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

FAKE_BIN_DIR="$WORKDIR/bin"
mkdir -p "$FAKE_BIN_DIR"

ln -s "$KARAKURI_SH_REAL" "$FAKE_BIN_DIR/karakuri.sh"

# --- フェイク prod-run.sh / dev-inject.sh ---------------------------------------
# 受け取った引数を 1 行 1 引数で、環境をまるごと別ファイルへ記録する
# （printf '%s\n' "$@" は各引数をそのまま 1 行にするので、空白を含む引数が
# 誤って分割されていないかを行の内容そのもので確認できる）。
cat >"$FAKE_BIN_DIR/prod-run.sh" <<'FAKE_PROD_RUN'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${FAKE_ARGV_FILE:?}"
env >"${FAKE_ENV_FILE:?}"
exit "${FAKE_PROD_RUN_EXIT_CODE:-0}"
FAKE_PROD_RUN
chmod +x "$FAKE_BIN_DIR/prod-run.sh"

cat >"$FAKE_BIN_DIR/dev-inject.sh" <<'FAKE_DEV_INJECT'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${FAKE_ARGV_FILE:?}"
env >"${FAKE_ENV_FILE:?}"
exit "${FAKE_DEV_INJECT_EXIT_CODE:-0}"
FAKE_DEV_INJECT
chmod +x "$FAKE_BIN_DIR/dev-inject.sh"

# broker は「実行可能な何かがそこにある」ことだけが要る（karakuri.sh は
# パスを組み立てて prod-run.sh / dev-inject.sh へ渡すだけで、自分では
# 呼ばない）。
cat >"$FAKE_BIN_DIR/broker-bitwarden.sh" <<'FAKE_BROKER'
#!/usr/bin/env bash
echo "fake broker should not be executed by karakuri.sh" >&2
exit 70
FAKE_BROKER
chmod +x "$FAKE_BIN_DIR/broker-bitwarden.sh"

# --- フェイク docker -----------------------------------------------------------
# karakuri.sh が docker を呼ぶのは 3 箇所: コンテナ特定 (ps -q --filter
# label=...)、土台へ入る (exec)、digest 解決 (buildx imagetools inspect)。
# compose ファイルの変数展開に巻き込まれないよう、コンテナ特定は
# `docker compose ps` ではなく素の `docker ps` をラベルで絞る形にしてある
# （実機で GIT_REPO/GIT_REF 未設定のまま `docker compose ps` が
# interpolation error で落ちた不具合の修正）。サブコマンドで分岐して、
# それぞれ引数を記録する。
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
exec)
	printf '%s\n' "$@" >"${FAKE_EXEC_ARGV_FILE:?}"
	exit "${FAKE_EXEC_EXIT_CODE:-0}"
	;;
buildx)
	printf '%s\n' "$@" >"${FAKE_BUILDX_ARGV_FILE:?}"
	if [ -n "${FAKE_DIGEST:-}" ]; then
		printf '%s\n' "$FAKE_DIGEST"
	fi
	exit "${FAKE_BUILDX_EXIT_CODE:-0}"
	;;
*)
	echo "fake docker: unexpected subcommand: ${1:-}" >&2
	exit 63
	;;
esac
FAKE_DOCKER
chmod +x "$FAKE_BIN_DIR/docker"

# --- フェイク ssh ---------------------------------------------------------------
# 呼ばれた引数を追記していく（port forwarding は「落としてから張る」ので
# 1 回の操作で複数回呼ばれる。順序も見たい）。
cat >"$FAKE_BIN_DIR/ssh" <<'FAKE_SSH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_SSH_LOG:?}"
exit "${FAKE_SSH_EXIT_CODE:-0}"
FAKE_SSH
chmod +x "$FAKE_BIN_DIR/ssh"

# --- 検査対象の compose ファイル -------------------------------------------------
# コメント行の image: を無視できているかも同時に見たいので 1 行入れてある。
BASE_DIGEST="sha256:1111111111111111111111111111111111111111111111111111111111111111"
OTHER_DIGEST="sha256:2222222222222222222222222222222222222222222222222222222222222222"
BASE_IMAGE="ghcr.io/acme/runtime-base"

COMPOSE_PINNED="$WORKDIR/compose.pinned.yaml"
cat >"$COMPOSE_PINNED" <<EOF
services:
  prod:
    # image: ghcr.io/acme/decoy@${OTHER_DIGEST}
    image: ${BASE_IMAGE}@${BASE_DIGEST}
EOF

COMPOSE_PLACEHOLDER="$WORKDIR/compose.placeholder.yaml"
cat >"$COMPOSE_PLACEHOLDER" <<EOF
services:
  prod:
    image: ${BASE_IMAGE}@sha256:REPLACE_WITH_ACTUAL_DIGEST
EOF

# 実機で踏んだ形そのもの: karakuri-image-digest はコメントを付けないが、
# 利用者が版を手でメモする運用がある。行末コメントが digest の一部として
# 読み込まれないことを見るための fixture。
COMPOSE_PINNED_COMMENTED="$WORKDIR/compose.pinned-commented.yaml"
cat >"$COMPOSE_PINNED_COMMENTED" <<EOF
services:
  prod:
    image: ${BASE_IMAGE}@${BASE_DIGEST} # v1.2.2
EOF

BASE_SHA="1234567890abcdef1234567890abcdef12345678"
BASE_CID="cafe0123deadbeef"

FAKE_HOME="$WORKDIR/home"

# --- 走らせる --------------------------------------------------------------------

SHELL_UNDER_TEST=bash

# 正常系の環境をまとめて張る。個々のテストで一部だけ上書き/unset する。
reset_env() {
	export KARAKURI_SH="$FAKE_BIN_DIR/karakuri.sh"
	export KARAKURI_PROD_COMPOSE="$COMPOSE_PINNED"
	unset KARAKURI_ORG KARAKURI_PROD_INSTALL KARAKURI_PROD_RUN KARAKURI_BW_BIN KARAKURI_TOOL_DIR

	export FAKE_ARGV_FILE="$WORKDIR/argv.$$.$RANDOM"
	export FAKE_ENV_FILE="$WORKDIR/env.$$.$RANDOM"
	export FAKE_PS_ARGV_FILE="$WORKDIR/ps-argv.$$.$RANDOM"
	export FAKE_EXEC_ARGV_FILE="$WORKDIR/exec-argv.$$.$RANDOM"
	export FAKE_BUILDX_ARGV_FILE="$WORKDIR/buildx-argv.$$.$RANDOM"
	export FAKE_SSH_LOG="$WORKDIR/ssh-log.$$.$RANDOM"

	export FAKE_PS_STDOUT="$BASE_CID"
	export FAKE_PS_EXIT_CODE=0
	export FAKE_EXEC_EXIT_CODE=0
	export FAKE_DIGEST="$BASE_DIGEST"
	export FAKE_BUILDX_EXIT_CODE=0

	rm -rf "$FAKE_HOME"
	mkdir -p "$FAKE_HOME/.ssh"
}

# run_case <function> [args...] — karakuri.sh を source して、渡した関数を
# 1 回呼ぶ。HOME はフェイクへ差し替える（port forwarding の後始末が
# ~/.ssh を触るため。ついでに zsh の起動ファイルの影響も受けない）。
# 結果は CASE_RC / CASE_STDOUT / CASE_STDERR に残す。
CASE_RC=0
CASE_STDOUT=""
CASE_STDERR=""
run_case() {
	local out err
	out="$(mktemp)"
	err="$(mktemp)"
	# 単一引用符は意図的。この文字列を展開するのは検査対象のシェルであって、
	# ここではない（$KARAKURI_SH も "$@" も向こうで解決される）。
	# shellcheck disable=SC2016
	if PATH="$FAKE_BIN_DIR:$PATH" HOME="$FAKE_HOME" \
		"$SHELL_UNDER_TEST" -c '. "$KARAKURI_SH" || exit 90; "$@"' \
		karakuri-test "$@" >"$out" 2>"$err"; then
		CASE_RC=0
	else
		CASE_RC=$?
	fi
	CASE_STDOUT="$(cat "$out")"
	CASE_STDERR="$(cat "$err")"
	rm -f "$out" "$err"
}

# --- アサーション ----------------------------------------------------------------

# `--` は grep への必須引数。"-p" や "-c" のように先頭が "-" の期待値を
# パターンではなくオプションとして誤解釈させないため。
has_line() { [ -f "$1" ] && grep -qxF -- "$2" "$1"; }

assert_rc_zero() {
	if [ "$CASE_RC" -eq 0 ]; then
		ok "$1"
	else
		ng "$1 (rc=$CASE_RC, stderr: $CASE_STDERR)"
	fi
}

assert_rc_nonzero() {
	if [ "$CASE_RC" -ne 0 ]; then
		ok "$1"
	else
		ng "$1 (rc=0, stdout: $CASE_STDOUT)"
	fi
}

assert_stderr_has() {
	case "$CASE_STDERR" in
	*"$1"*) ok "$2" ;;
	*) ng "$2 (stderr: $CASE_STDERR)" ;;
	esac
}

assert_stdout_is() {
	if [ "$CASE_STDOUT" = "$1" ]; then
		ok "$2"
	else
		ng "$2 (stdout: $CASE_STDOUT)"
	fi
}

assert_argv_has() {
	if has_line "$FAKE_ARGV_FILE" "$1"; then
		ok "$2"
	else
		ng "$2 (argv: $(cat "$FAKE_ARGV_FILE" 2>/dev/null))"
	fi
}

assert_argv_lacks() {
	if has_line "$FAKE_ARGV_FILE" "$1"; then
		ng "$2 (argv: $(cat "$FAKE_ARGV_FILE" 2>/dev/null))"
	else
		ok "$2"
	fi
}

assert_env_has() {
	if has_line "$FAKE_ENV_FILE" "$1"; then
		ok "$2"
	else
		ng "$2 (env had: $(grep -E '^(GIT_|PROD_|COMPOSE_|DEV_|BROKER_)' "$FAKE_ENV_FILE" 2>/dev/null | tr '\n' ' '))"
	fi
}

assert_not_invoked() {
	if [ -f "$1" ]; then
		ng "$2"
	else
		ok "$2"
	fi
}

# --- 検査本体（bash と zsh で 2 回回す） ------------------------------------------

run_suite() {
	local s="$SHELL_UNDER_TEST"

	# --- <org/repo> の解決 -------------------------------------------------------
	echo "[$s] repository spec is resolved from one argument"
	reset_env
	run_case karakuri-prod-run acme/app "$BASE_SHA" deploy

	assert_rc_zero "[$s] <org>/<repo> form succeeds"
	assert_env_has "GIT_REPO=https://github.com/acme/app.git" "[$s] <org>/<repo> becomes the clone URL"
	assert_env_has "GIT_REF=$BASE_SHA" "[$s] the sha is passed through as GIT_REF"

	reset_env
	export KARAKURI_ORG=acme
	run_case karakuri-prod-run app "$BASE_SHA" deploy

	assert_rc_zero "[$s] bare <repo> succeeds when KARAKURI_ORG is set"
	assert_env_has "GIT_REPO=https://github.com/acme/app.git" "[$s] KARAKURI_ORG fills in the missing org"

	reset_env
	run_case karakuri-prod-run app "$BASE_SHA" deploy

	assert_rc_nonzero "[$s] bare <repo> without KARAKURI_ORG fails"
	assert_stderr_has "KARAKURI_ORG" "[$s] the error names KARAKURI_ORG"
	assert_not_invoked "$FAKE_ARGV_FILE" "[$s] prod-run.sh is not invoked when the org cannot be resolved"

	reset_env
	run_case karakuri-prod-run acme/team/app "$BASE_SHA" deploy

	assert_rc_nonzero "[$s] more than one '/' in the spec fails"
	assert_not_invoked "$FAKE_ARGV_FILE" "[$s] prod-run.sh is not invoked for a malformed spec"

	# --- compose project 名 ------------------------------------------------------
	echo "[$s] COMPOSE_PROJECT_NAME is per repository"
	reset_env
	run_case karakuri-prod-run acme/app "$BASE_SHA" deploy
	assert_env_has "COMPOSE_PROJECT_NAME=prod-app" "[$s] prod-run sets COMPOSE_PROJECT_NAME=prod-<repo>"

	reset_env
	run_case karakuri-prod-exec acme/app "$BASE_SHA" ls
	assert_env_has "COMPOSE_PROJECT_NAME=prod-app" "[$s] prod-exec sets COMPOSE_PROJECT_NAME=prod-<repo>"

	reset_env
	run_case karakuri-prod-base acme/app "$BASE_SHA"
	assert_env_has "COMPOSE_PROJECT_NAME=prod-app" "[$s] prod-base sets COMPOSE_PROJECT_NAME=prod-<repo>"
	assert_argv_has "sleep" "[$s] prod-base runs sleep as the base command"

	# --- prod-run: install 段と sh -c ---------------------------------------------
	echo "[$s] the install stage decides whether sh -c is used"
	reset_env
	run_case karakuri-prod-run acme/app "$BASE_SHA" deploy

	assert_argv_has "sh" "[$s] the default install stage goes through sh -c"
	assert_argv_has "-c" "[$s] sh is given -c"
	assert_argv_has "pnpm install --frozen-lockfile && pnpm 'deploy'" "[$s] install and task are joined with &&"

	reset_env
	export KARAKURI_PROD_INSTALL=""
	run_case karakuri-prod-run acme/app "$BASE_SHA" deploy "a b"

	assert_rc_zero "[$s] an empty KARAKURI_PROD_INSTALL still runs"
	assert_argv_lacks "-c" "[$s] an empty KARAKURI_PROD_INSTALL does not go through sh -c"
	assert_argv_has "pnpm" "[$s] the runner is passed as its own argument"
	assert_argv_has "deploy" "[$s] the task is passed as its own argument"
	assert_argv_has "a b" "[$s] an argument containing a space stays one argument"

	reset_env
	export KARAKURI_PROD_INSTALL=""
	export KARAKURI_PROD_RUN="npm run"
	run_case karakuri-prod-run acme/app "$BASE_SHA" deploy

	assert_argv_has "npm" "[$s] a two-word KARAKURI_PROD_RUN becomes two arguments (first)"
	assert_argv_has "run" "[$s] a two-word KARAKURI_PROD_RUN becomes two arguments (second)"

	reset_env
	run_case karakuri-prod-run acme/app "$BASE_SHA" deploy "a b"
	assert_argv_has "pnpm install --frozen-lockfile && pnpm 'deploy' 'a b'" \
		"[$s] arguments are quoted before being concatenated for sh -c"

	# --- prod-exec: 常に配列のまま --------------------------------------------------
	echo "[$s] prod-exec never builds a command string"
	reset_env
	run_case karakuri-prod-exec acme/app "$BASE_SHA" dotenvx run -f .env.prod -- pnpm deploy

	assert_rc_zero "[$s] prod-exec succeeds"
	assert_argv_lacks "-c" "[$s] prod-exec does not go through sh -c even with the default install set"
	assert_argv_has "dotenvx" "[$s] prod-exec passes the command through verbatim"
	assert_argv_has "--" "[$s] prod-exec passes '--' through verbatim"

	# --- broker 依存部 ------------------------------------------------------------
	echo "[$s] broker-specific environment is built in one place"
	reset_env
	export KARAKURI_BW_BIN="/opt/bw"
	run_case karakuri-prod-run acme/app "$BASE_SHA" deploy

	assert_env_has "BROKER_BW_ITEM=env/app/shared/prod,env/app/prod" "[$s] prod broker items follow the naming convention"
	assert_env_has "BROKER_BW_BIN=/opt/bw" "[$s] KARAKURI_BW_BIN reaches the broker"
	assert_env_has "PROD_BROKER=$FAKE_BIN_DIR/broker-bitwarden.sh" "[$s] the broker next to karakuri.sh is used"

	reset_env
	run_case karakuri-prod-run acme/app "$BASE_SHA" deploy
	if grep -q '^BROKER_BW_BIN=' "$FAKE_ENV_FILE" 2>/dev/null; then
		ng "[$s] BROKER_BW_BIN is left unset when KARAKURI_BW_BIN is unset"
	else
		ok "[$s] BROKER_BW_BIN is left unset when KARAKURI_BW_BIN is unset"
	fi

	# 差し替え点であることの確認: 同名の関数を後から定義すると、そちらが使われる。
	# 関数を再定義してから呼ぶ必要があるので、run_case は使わずに直接回す。
	reset_env
	local out err
	out="$(mktemp)"
	err="$(mktemp)"
	# shellcheck disable=SC2016 # 展開するのは検査対象のシェル側
	if PATH="$FAKE_BIN_DIR:$PATH" HOME="$FAKE_HOME" \
		"$SHELL_UNDER_TEST" -c '. "$KARAKURI_SH" || exit 90
karakuri-broker-env() { printf "OTHER_BROKER_REF=%s/%s\n" "$1" "$2"; }
karakuri-broker-command() { printf "/opt/other-broker\n"; }
karakuri-prod-run acme/app "$1" deploy' karakuri-test "$BASE_SHA" >"$out" 2>"$err"; then
		ok "[$s] a replaced broker implementation still runs"
	else
		ng "[$s] a replaced broker implementation still runs (stderr: $(cat "$err"))"
	fi
	rm -f "$out" "$err"

	assert_env_has "OTHER_BROKER_REF=prod/app" "[$s] the replaced karakuri-broker-env decides the broker environment"
	assert_env_has "PROD_BROKER=/opt/other-broker" "[$s] the replaced karakuri-broker-command decides the broker path"
	if grep -q '^BROKER_BW_ITEM=' "$FAKE_ENV_FILE" 2>/dev/null; then
		ng "[$s] the Bitwarden-specific variables are gone once the broker is replaced"
	else
		ok "[$s] the Bitwarden-specific variables are gone once the broker is replaced"
	fi

	# --- dev-inject ---------------------------------------------------------------
	echo "[$s] dev-inject builds the item list and the compose project name"
	reset_env
	run_case karakuri-dev-inject dotfiles

	assert_rc_zero "[$s] dev-inject succeeds"
	assert_env_has "DEV_COMPOSE_PROJECT=dotfiles-dev" "[$s] the dev compose project name is <project>-dev"
	assert_env_has "BROKER_BW_ITEM=env/dotfiles/shared/dev,env/_common/dev,env/dotfiles/dev" \
		"[$s] dev broker items are ordered shared, common, personal"
	if [ -n "$(cat "$FAKE_ARGV_FILE" 2>/dev/null)" ]; then
		ng "[$s] dev-inject.sh is called without arguments"
	else
		ok "[$s] dev-inject.sh is called without arguments"
	fi

	reset_env
	run_case karakuri-dev-inject acme/dotfiles
	assert_rc_nonzero "[$s] dev-inject rejects a project name containing '/'"
	assert_not_invoked "$FAKE_ARGV_FILE" "[$s] dev-inject.sh is not invoked for a malformed project name"

	# --- prod-shell: コンテナ特定を推測でやらない -------------------------------------
	echo "[$s] prod-shell refuses to guess which container to enter"
	reset_env
	run_case karakuri-prod-shell app

	assert_rc_zero "[$s] prod-shell succeeds when exactly one container matches"
	if has_line "$FAKE_PS_ARGV_FILE" "label=com.docker.compose.project=prod-app"; then
		ok "[$s] the container is looked up through the compose project label 'prod-<repo>'"
	else
		ng "[$s] the container is looked up through the compose project label 'prod-<repo>' (argv: $(cat "$FAKE_PS_ARGV_FILE" 2>/dev/null))"
	fi
	if has_line "$FAKE_PS_ARGV_FILE" "label=com.docker.compose.service=prod"; then
		ok "[$s] the container is looked up through the compose service label 'prod'"
	else
		ng "[$s] the container is looked up through the compose service label 'prod' (argv: $(cat "$FAKE_PS_ARGV_FILE" 2>/dev/null))"
	fi
	for expected in exec -it -w /src "$BASE_CID" bash; do
		if has_line "$FAKE_EXEC_ARGV_FILE" "$expected"; then
			ok "[$s] docker exec argv contains '$expected'"
		else
			ng "[$s] docker exec argv is missing '$expected'"
		fi
	done

	reset_env
	export FAKE_PS_STDOUT=""
	run_case karakuri-prod-shell app

	assert_rc_nonzero "[$s] prod-shell fails when no container matches"
	assert_stderr_has "not up" "[$s] the error says the base is not up"
	assert_not_invoked "$FAKE_EXEC_ARGV_FILE" "[$s] docker exec is not invoked when no container matches"

	reset_env
	FAKE_PS_STDOUT="$(printf 'cid-one\ncid-two')"
	export FAKE_PS_STDOUT
	run_case karakuri-prod-shell app

	assert_rc_nonzero "[$s] prod-shell fails when more than one container matches"
	assert_stderr_has "multiple containers" "[$s] the error identifies the ambiguity"
	assert_not_invoked "$FAKE_EXEC_ARGV_FILE" "[$s] docker exec is not invoked when the target is ambiguous"

	reset_env
	run_case karakuri-prod-shell acme/app
	assert_rc_nonzero "[$s] prod-shell rejects a repo name containing '/'"

	# 実機で踏んだ不具合そのもの: 別の端末から prod-shell だけを叩くとき、
	# 土台を起動した端末で渡した GIT_REPO / GIT_REF はそこには無い。以前の
	# 実装は `docker compose ps` で compose ファイルを読ませていたため、
	# environment 節の `${GIT_REPO:?...}` がここで展開されて落ちていた。
	# 素の `docker ps --filter label=...` はこの展開を経由しないので、
	# これらが未設定でも成功する。
	echo "[$s] prod-shell does not need GIT_REPO/GIT_REF, unlike the compose-based lookup it replaced"
	reset_env
	unset GIT_REPO GIT_REF
	run_case karakuri-prod-shell app
	assert_rc_zero "[$s] prod-shell succeeds with GIT_REPO/GIT_REF unset"

	# --- KARAKURI_PROD_COMPOSE の欠落 ------------------------------------------------
	echo "[$s] KARAKURI_PROD_COMPOSE is required by the prod functions that actually run compose"
	reset_env
	unset KARAKURI_PROD_COMPOSE
	run_case karakuri-prod-run acme/app "$BASE_SHA" deploy

	assert_rc_nonzero "[$s] prod-run fails without KARAKURI_PROD_COMPOSE"
	assert_stderr_has "KARAKURI_PROD_COMPOSE" "[$s] the error names KARAKURI_PROD_COMPOSE"
	assert_not_invoked "$FAKE_ARGV_FILE" "[$s] prod-run.sh is not invoked without a compose file"

	# prod-shell は compose ファイルを読まずコンテナのラベルだけで引くので、
	# KARAKURI_PROD_COMPOSE が無くても成功する（これも実機の不具合の一部:
	# 別端末では KARAKURI_PROD_COMPOSE 自体を張っていないこともある）。
	reset_env
	unset KARAKURI_PROD_COMPOSE
	run_case karakuri-prod-shell app
	assert_rc_zero "[$s] prod-shell succeeds without KARAKURI_PROD_COMPOSE"

	# --- 引数の個数 ------------------------------------------------------------------
	echo "[$s] usage is printed when the argument count is wrong"
	reset_env
	run_case karakuri-prod-run acme/app "$BASE_SHA"
	assert_rc_nonzero "[$s] prod-run without a task fails"
	assert_stderr_has "Usage:" "[$s] prod-run without a task prints usage"

	reset_env
	run_case karakuri-prod-base acme/app
	assert_rc_nonzero "[$s] prod-base without a sha fails"
	assert_stderr_has "Usage:" "[$s] prod-base without a sha prints usage"

	# --- image digest ---------------------------------------------------------------
	echo "[$s] image digests are resolved and compared, never written"
	reset_env
	local compose_before
	compose_before="$(cksum <"$COMPOSE_PINNED")"
	run_case karakuri-image-digest 1.2.2

	assert_rc_zero "[$s] image-digest succeeds"
	assert_stdout_is "image: ${BASE_IMAGE}@${BASE_DIGEST}" "[$s] image-digest prints a complete image: line"
	if has_line "$FAKE_BUILDX_ARGV_FILE" "${BASE_IMAGE}:1.2.2"; then
		ok "[$s] the tag is resolved against the image named in the compose file"
	else
		ng "[$s] the tag is resolved against the image named in the compose file (argv: $(cat "$FAKE_BUILDX_ARGV_FILE" 2>/dev/null))"
	fi
	if [ "$(cksum <"$COMPOSE_PINNED")" = "$compose_before" ]; then
		ok "[$s] image-digest leaves the compose file untouched"
	else
		ng "[$s] image-digest leaves the compose file untouched"
	fi

	reset_env
	run_case karakuri-check-image 1.2.2
	assert_rc_zero "[$s] check-image succeeds when the pinned digest matches"

	reset_env
	export FAKE_DIGEST="$OTHER_DIGEST"
	run_case karakuri-check-image 1.2.2
	assert_rc_nonzero "[$s] check-image fails when the pinned digest is stale"
	assert_stderr_has "mismatch" "[$s] the error says the digests do not match"

	reset_env
	export KARAKURI_PROD_COMPOSE="$COMPOSE_PLACEHOLDER"
	run_case karakuri-check-image 1.2.2
	assert_rc_nonzero "[$s] check-image fails while the compose file still holds the placeholder"
	assert_stderr_has "karakuri-image-digest" "[$s] the placeholder error says which command produces the line to paste"
	assert_not_invoked "$FAKE_BUILDX_ARGV_FILE" "[$s] no registry lookup happens when the compose file pins nothing"

	reset_env
	export FAKE_BUILDX_EXIT_CODE=1
	export FAKE_DIGEST=""
	run_case karakuri-image-digest 1.2.2
	assert_rc_nonzero "[$s] image-digest fails when the registry lookup fails"

	# --- image 行の行末コメント -------------------------------------------------------
	# 実機で踏んだ不具合そのもの: 利用者が版を手でメモした
	# `image: ...@sha256:... # v1.2.2` 形式の行末コメントが digest 文字列の
	# 一部として読み込まれ、正しく pin されているのに「digest が入っていない」
	# と誤診断されていた。
	echo "[$s] a trailing YAML comment on the image: line is stripped, not read as part of the digest"
	reset_env
	export KARAKURI_PROD_COMPOSE="$COMPOSE_PINNED_COMMENTED"
	run_case karakuri-check-image 1.2.2
	assert_rc_zero "[$s] check-image succeeds when the image: line has a trailing '# v1.2.2' comment"

	reset_env
	export KARAKURI_PROD_COMPOSE="$COMPOSE_PINNED_COMMENTED"
	run_case karakuri-image-digest 1.2.2
	assert_stdout_is "image: ${BASE_IMAGE}@${BASE_DIGEST}" \
		"[$s] image-digest resolves against the image name even when the current line has a trailing comment"

	# コメントが無い場合（COMPOSE_PINNED）も従来どおり読めることの確認。
	# 上の「image-digest / check-image」ブロックの各アサーションが
	# COMPOSE_PINNED に対して既に検査しているので、ここでは崩れていないこと
	# だけを重ねて確認する。
	reset_env
	run_case karakuri-check-image 1.2.2
	assert_rc_zero "[$s] check-image still succeeds without a trailing comment"

	# --- port forwarding -------------------------------------------------------------
	echo "[$s] port forwarding is torn down before it is set up"
	reset_env
	: >"$FAKE_HOME/.ssh/cm-devc-app"
	run_case karakuri-pf app

	assert_rc_zero "[$s] pf succeeds"
	if [ -f "$FAKE_SSH_LOG" ] && [ "$(head -1 "$FAKE_SSH_LOG")" = "-n -O exit devc-app" ]; then
		ok "[$s] pf closes the existing master first"
	else
		ng "[$s] pf closes the existing master first (log: $(tr '\n' '/' <"$FAKE_SSH_LOG" 2>/dev/null))"
	fi
	if [ -f "$FAKE_SSH_LOG" ] && grep -qxF -- "-fN devc-app" "$FAKE_SSH_LOG"; then
		ok "[$s] pf then starts a new forwarding session"
	else
		ng "[$s] pf then starts a new forwarding session"
	fi

	reset_env
	: >"$FAKE_HOME/.ssh/cm-devc-one"
	: >"$FAKE_HOME/.ssh/cm-devc-two"
	: >"$FAKE_HOME/.ssh/cm-unrelated"
	run_case karakuri-clean-pf

	assert_rc_zero "[$s] clean-pf without arguments succeeds"
	if [ ! -e "$FAKE_HOME/.ssh/cm-devc-one" ] && [ ! -e "$FAKE_HOME/.ssh/cm-devc-two" ]; then
		ok "[$s] clean-pf removes the sockets it owns"
	else
		ng "[$s] clean-pf removes the sockets it owns"
	fi
	if [ -e "$FAKE_HOME/.ssh/cm-unrelated" ]; then
		ok "[$s] clean-pf leaves unrelated control sockets alone"
	else
		ng "[$s] clean-pf leaves unrelated control sockets alone"
	fi

	reset_env
	run_case karakuri-clean-pf
	assert_rc_zero "[$s] clean-pf succeeds when there is nothing to clean up"

	reset_env
	: >"$FAKE_HOME/.ssh/cm-devc-one"
	run_case karakuri-clean-pf one
	if [ ! -e "$FAKE_HOME/.ssh/cm-devc-one" ]; then
		ok "[$s] clean-pf <name> removes just that socket"
	else
		ng "[$s] clean-pf <name> removes just that socket"
	fi

	# --- 関数が全部定義されていること --------------------------------------------------
	echo "[$s] every documented function is defined"
	reset_env
	for fn in karakuri-pf karakuri-clean-pf karakuri-dev-inject karakuri-prod-run \
		karakuri-prod-exec karakuri-prod-base karakuri-prod-shell \
		karakuri-image-digest karakuri-check-image \
		karakuri-broker-command karakuri-broker-env; do
		# shellcheck disable=SC2016 # 展開するのは検査対象のシェル側
		if PATH="$FAKE_BIN_DIR:$PATH" HOME="$FAKE_HOME" \
			"$SHELL_UNDER_TEST" -c '. "$KARAKURI_SH" || exit 90; command -v "$1" >/dev/null' \
			karakuri-test "$fn" 2>/dev/null; then
			ok "[$s] $fn is defined"
		else
			ng "[$s] $fn is not defined"
		fi
	done
}

SHELL_UNDER_TEST=bash
run_suite

if command -v zsh >/dev/null 2>&1; then
	SHELL_UNDER_TEST=zsh
	run_suite
else
	skip "zsh is not installed here — the zsh half of the suite did not run"
fi

# --- 結果 -----------------------------------------------------------------------

printf '\n%s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
