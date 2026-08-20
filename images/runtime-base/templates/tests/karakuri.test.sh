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
#
# `ssh -G` だけは別のファイルへ記録する。あれは接続も転送もせず設定を解決
# するだけの呼び出しで、karakuri-pf が「張る／落とす」ために呼ぶ ssh とは
# 役目が違う。同じログに混ぜると、既存の「1 本目は -O exit である」「-fN が
# 出た」という検査が呼ばれ方の変化で崩れ、逆に「検査そのものが走っていない」
# ことを見たい側は -G の行を数え直す羽目になる。
#
# FAKE_SSH_STDERR は `ssh -fN` が背面へ回った後に吐く転送エラーの代役。
# karakuri-pf はこれをログファイルへ逃がすので、端末に出ないことと、
# ログに残ることの両方をこれで見る。
cat >"$FAKE_BIN_DIR/ssh" <<'FAKE_SSH'
#!/usr/bin/env bash
if [ "${1:-}" = "-G" ]; then
	printf '%s\n' "$*" >>"${FAKE_SSH_G_LOG:?}"
	if [ -n "${FAKE_SSH_G_STDOUT:-}" ]; then
		printf '%s\n' "$FAKE_SSH_G_STDOUT"
	fi
	exit "${FAKE_SSH_G_EXIT_CODE:-0}"
fi
printf '%s\n' "$*" >>"${FAKE_SSH_LOG:?}"
if [ -n "${FAKE_SSH_STDERR:-}" ]; then
	printf '%s\n' "$FAKE_SSH_STDERR" >&2
fi
exit "${FAKE_SSH_EXIT_CODE:-0}"
FAKE_SSH
chmod +x "$FAKE_BIN_DIR/ssh"

# --- フェイク uname / ifconfig ----------------------------------------------------
# loopback alias の事前検査が働くのは macOS だけである（Linux は 127.0.0.0/8 の
# 全体が最初から bind でき、alias を足す作業自体が無い）。テストが走るのは
# Linux の dev container なので、uname を差し替えないと検査の中身は 1 行も
# 通らない。ifconfig も同じ理由で差し替える（ここに lo0 は無い）。
#
# karakuri.sh は uname も ifconfig も絶対パスでは呼ばないので、PATH 先頭への
# 差し替えがそのまま効く。
cat >"$FAKE_BIN_DIR/uname" <<'FAKE_UNAME'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_UNAME_S:-Linux}"
FAKE_UNAME
chmod +x "$FAKE_BIN_DIR/uname"

cat >"$FAKE_BIN_DIR/ifconfig" <<'FAKE_IFCONFIG'
#!/usr/bin/env bash
if [ -n "${FAKE_IFCONFIG_STDOUT:-}" ]; then
	printf '%s\n' "$FAKE_IFCONFIG_STDOUT"
fi
exit "${FAKE_IFCONFIG_EXIT_CODE:-0}"
FAKE_IFCONFIG
chmod +x "$FAKE_BIN_DIR/ifconfig"

# --- フェイク dock.sh / loopback-setup.sh -------------------------------------------
# karakuri-dock / karakuri-loopback は引数を素通しするだけの薄いラッパーなので、
# 見るべきものは「どの引数がそのまま届いたか」と「環境変数を足していないか」の
# 2 つだけ。記録の仕方は dev-inject.sh のフェイクと同じにしてある。
cat >"$FAKE_BIN_DIR/dock.sh" <<'FAKE_DOCK'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${FAKE_ARGV_FILE:?}"
env >"${FAKE_ENV_FILE:?}"
exit "${FAKE_DOCK_EXIT_CODE:-0}"
FAKE_DOCK
chmod +x "$FAKE_BIN_DIR/dock.sh"

cat >"$FAKE_BIN_DIR/loopback-setup.sh" <<'FAKE_LOOPBACK_SETUP'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${FAKE_ARGV_FILE:?}"
env >"${FAKE_ENV_FILE:?}"
exit "${FAKE_LOOPBACK_SETUP_EXIT_CODE:-0}"
FAKE_LOOPBACK_SETUP
chmod +x "$FAKE_BIN_DIR/loopback-setup.sh"

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

# --- 検査対象の compose ディレクトリ ------------------------------------------------
# プロジェクトごとに 1 枚の compose ファイルを持つ運用の fixture。ファイル名が
# repo 名になる（karakuri.sh はそれ以外の手掛かりでファイルを選ばない）ので、
# ここのファイル名はそのままテストで打つ repo 名でもある。
#
# ディレクトリを 1 つで済ませず 4 つに分けてあるのは、karakuri-check-image が
# ディレクトリの中を全部見るため。曖昧な組み合わせやイメージ名の食い違いを
# 同じディレクトリに同居させると、それらが他のテストの掃引結果に混ざる。
OTHER_IMAGE="ghcr.io/acme/other-runtime"

# write_compose <path> <image ref> — 1 サービスだけの compose ファイルを書く。
write_compose() {
	mkdir -p "$(dirname "$1")"
	cat >"$1" <<EOF
services:
  prod:
    image: $2
EOF
}

# 正常系。.yaml と .yml が 1 つずつあり、どちらも同じイメージを pin している。
COMPOSE_DIR_OK="$WORKDIR/compose-dir"
write_compose "$COMPOSE_DIR_OK/app.yaml" "${BASE_IMAGE}@${BASE_DIGEST}"
write_compose "$COMPOSE_DIR_OK/legacy.yml" "${BASE_IMAGE}@${BASE_DIGEST}"

# 同じ repo に .yaml と .yml が両方ある。どちらを使うかは推測しない。
COMPOSE_DIR_BOTH="$WORKDIR/compose-dir-both"
write_compose "$COMPOSE_DIR_BOTH/dup.yaml" "${BASE_IMAGE}@${BASE_DIGEST}"
write_compose "$COMPOSE_DIR_BOTH/dup.yml" "${BASE_IMAGE}@${BASE_DIGEST}"

# 掃引の結果が混ざるディレクトリ。ファイル名を意図的にこの並びにしてある:
# 掃引は名前順なので、問題のある 2 枚（古い digest・digest 未記入）の後ろに
# 正常な 1 枚を置いておかないと、「最初の問題で打ち切る」実装との差が出ない
# （打ち切っても、最後尾の問題までは同じ出力になってしまう）。
COMPOSE_DIR_MIXED="$WORKDIR/compose-dir-mixed"
write_compose "$COMPOSE_DIR_MIXED/app.yaml" "${BASE_IMAGE}@${BASE_DIGEST}"
write_compose "$COMPOSE_DIR_MIXED/billing.yaml" "${BASE_IMAGE}@${OTHER_DIGEST}"
write_compose "$COMPOSE_DIR_MIXED/notes.yml" "${BASE_IMAGE}:1.2.2"
write_compose "$COMPOSE_DIR_MIXED/zeta.yaml" "${BASE_IMAGE}@${BASE_DIGEST}"

# イメージ名が揃っていない。裸のタグからは参照を組み立てられない。
COMPOSE_DIR_DIVERGE="$WORKDIR/compose-dir-diverge"
write_compose "$COMPOSE_DIR_DIVERGE/app.yaml" "${BASE_IMAGE}@${BASE_DIGEST}"
write_compose "$COMPOSE_DIR_DIVERGE/other.yaml" "${OTHER_IMAGE}@${BASE_DIGEST}"

BASE_SHA="1234567890abcdef1234567890abcdef12345678"
BASE_CID="cafe0123deadbeef"

FAKE_HOME="$WORKDIR/home"
# ログの置き場所。XDG_STATE_HOME をここへ向けて、実際の ~/.local/state を
# 汚さない（reset_env が FAKE_HOME ごと作り直すので、テストの間で残らない）。
FAKE_STATE_HOME="$FAKE_HOME/state"

# --- 検査対象の ifconfig lo0 の出力 -------------------------------------------------
# macOS の `ifconfig lo0` の形をそのまま写したもの。karakuri.sh は「inet <addr>
# の後ろに空白がある」で照合するので、行の前後の空白まで含めて実物に寄せる。
LO0_BASE_LINE='lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384'

# 127.0.0.1 だけ。alias を 1 本も足していない素の状態。
LO0_BARE="$(printf '%s\n\tinet 127.0.0.1 netmask 0xff000000' "$LO0_BASE_LINE")"

# 転送が bind したい 127.0.1.1 が alias として載っている状態。
LO0_WITH_ALIAS="$(printf '%s\n\tinet 127.0.0.1 netmask 0xff000000\n\tinet 127.0.1.1 netmask 0xff000000' "$LO0_BASE_LINE")"

# 前方一致で誤って通さないことを見るための fixture。127.0.1.10 は載っているが
# 127.0.1.1 は載っていない（文字列としては前者が後者を含む）。
LO0_NEAR_MISS="$(printf '%s\n\tinet 127.0.0.1 netmask 0xff000000\n\tinet 127.0.1.10 netmask 0xff000000' "$LO0_BASE_LINE")"

# --- 走らせる --------------------------------------------------------------------

SHELL_UNDER_TEST=bash

# 正常系の環境をまとめて張る。個々のテストで一部だけ上書き/unset する。
reset_env() {
	export KARAKURI_SH="$FAKE_BIN_DIR/karakuri.sh"
	export KARAKURI_PROD_COMPOSE="$COMPOSE_PINNED"
	unset KARAKURI_ORG KARAKURI_PROD_INSTALL KARAKURI_PROD_RUN KARAKURI_BW_BIN KARAKURI_TOOL_DIR
	# 既定は単一ファイル運用（上で KARAKURI_PROD_COMPOSE を張っている）。
	# ディレクトリ運用を見るテストが個別に張る。
	unset KARAKURI_PROD_COMPOSE_DIR

	export FAKE_ARGV_FILE="$WORKDIR/argv.$$.$RANDOM"
	export FAKE_ENV_FILE="$WORKDIR/env.$$.$RANDOM"
	export FAKE_PS_ARGV_FILE="$WORKDIR/ps-argv.$$.$RANDOM"
	export FAKE_EXEC_ARGV_FILE="$WORKDIR/exec-argv.$$.$RANDOM"
	export FAKE_BUILDX_ARGV_FILE="$WORKDIR/buildx-argv.$$.$RANDOM"
	export FAKE_SSH_LOG="$WORKDIR/ssh-log.$$.$RANDOM"
	export FAKE_SSH_G_LOG="$WORKDIR/ssh-g-log.$$.$RANDOM"

	export FAKE_PS_STDOUT="$BASE_CID"
	export FAKE_PS_EXIT_CODE=0
	export FAKE_EXEC_EXIT_CODE=0
	export FAKE_DIGEST="$BASE_DIGEST"
	export FAKE_BUILDX_EXIT_CODE=0

	# 既定は「Linux・ssh は全部成功・端末へ何も吐かない」。loopback alias の
	# 検査とログ分離を見るテストが、必要なものだけを個別に張る。
	export FAKE_UNAME_S=Linux
	unset FAKE_SSH_EXIT_CODE FAKE_SSH_STDERR
	unset FAKE_SSH_G_STDOUT FAKE_SSH_G_EXIT_CODE
	unset FAKE_IFCONFIG_STDOUT FAKE_IFCONFIG_EXIT_CODE

	rm -rf "$FAKE_HOME"
	mkdir -p "$FAKE_HOME/.ssh"

	# karakuri-pf の転送エラーログの置き場所。実際の ~/.local/state を
	# 触らせないために、毎回 FAKE_HOME の下へ向け直す（未設定時の既定を見る
	# テストだけがこれを unset する）。
	export XDG_STATE_HOME="$FAKE_STATE_HOME"
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

assert_stdout_has() {
	case "$CASE_STDOUT" in
	*"$1"*) ok "$2" ;;
	*) ng "$2 (stdout: $CASE_STDOUT)" ;;
	esac
}

assert_stdout_lacks() {
	case "$CASE_STDOUT" in
	*"$1"*) ng "$2 (stdout: $CASE_STDOUT)" ;;
	*) ok "$2" ;;
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

	# --- 薄いラッパー（dock / loopback） ------------------------------------------
	# この 2 つは _karakuri_tool でスクリプトを引き、引数をそのまま渡すだけ。
	# 引数の検査も usage もスクリプト側の仕事なので、ここで見るのは「素通しで
	# あること」と「余計な環境変数を足していないこと」の 2 点になる。
	echo "[$s] dock and loopback pass their arguments straight through"
	reset_env
	run_case karakuri-dock foo

	assert_rc_zero "[$s] dock succeeds"
	assert_argv_has "foo" "[$s] dock.sh receives the project name verbatim"
	if [ "$(wc -l <"$FAKE_ARGV_FILE" 2>/dev/null)" = "1" ]; then
		ok "[$s] dock.sh receives exactly one argument"
	else
		ng "[$s] dock.sh receives exactly one argument (argv: $(cat "$FAKE_ARGV_FILE" 2>/dev/null))"
	fi
	# broker も compose も関与しない。dev-inject と違って BROKER_* を組み立てて
	# いないことを、フェイクが記録した環境そのもので見る。
	if grep -qE '^(BROKER_|DEV_|PROD_)' "$FAKE_ENV_FILE" 2>/dev/null; then
		ng "[$s] dock.sh is called without any broker or compose environment"
	else
		ok "[$s] dock.sh is called without any broker or compose environment"
	fi

	reset_env
	run_case karakuri-loopback add 127.0.1.1 foo.test

	assert_rc_zero "[$s] loopback succeeds"
	assert_argv_has "add" "[$s] loopback-setup.sh receives the subcommand"
	assert_argv_has "127.0.1.1" "[$s] loopback-setup.sh receives the address"
	assert_argv_has "foo.test" "[$s] loopback-setup.sh receives the host name"
	if [ "$(wc -l <"$FAKE_ARGV_FILE" 2>/dev/null)" = "3" ]; then
		ok "[$s] loopback-setup.sh receives exactly three arguments"
	else
		ng "[$s] loopback-setup.sh receives exactly three arguments (argv: $(cat "$FAKE_ARGV_FILE" 2>/dev/null))"
	fi
	if grep -qE '^(BROKER_|DEV_|PROD_)' "$FAKE_ENV_FILE" 2>/dev/null; then
		ng "[$s] loopback-setup.sh is called without any broker or compose environment"
	else
		ok "[$s] loopback-setup.sh is called without any broker or compose environment"
	fi

	# 引数 0 個でも止めずに渡す。usage を出すのはスクリプト側で、同じ規則を
	# 関数にも持たせると片方だけが古くなる。
	reset_env
	run_case karakuri-loopback

	assert_rc_zero "[$s] loopback with no arguments still reaches the script"
	if [ -n "$(cat "$FAKE_ARGV_FILE" 2>/dev/null)" ]; then
		ng "[$s] loopback-setup.sh is called without arguments, leaving usage to the script"
	else
		ok "[$s] loopback-setup.sh is called without arguments, leaving usage to the script"
	fi

	# スクリプトが無いときは _karakuri_tool のエラーで止まる。実行ビットを
	# 落とすだけでは足りない（PATH を引く側は、シェルによっては実行ビットの
	# 無いファイルも見つけてくる）ので、ファイルごと退避する。これで
	# KARAKURI_TOOL_DIR 側と PATH 側の両方から同時に外れる。
	reset_env
	mv "$FAKE_BIN_DIR/dock.sh" "$WORKDIR/dock.sh.hidden"
	run_case karakuri-dock foo
	mv "$WORKDIR/dock.sh.hidden" "$FAKE_BIN_DIR/dock.sh"

	assert_rc_nonzero "[$s] dock fails when dock.sh cannot be found"
	assert_stderr_has "cannot find 'dock.sh'" "[$s] the error names dock.sh as the missing script"
	assert_not_invoked "$FAKE_ARGV_FILE" "[$s] nothing is executed when dock.sh cannot be found"

	reset_env
	mv "$FAKE_BIN_DIR/loopback-setup.sh" "$WORKDIR/loopback-setup.sh.hidden"
	run_case karakuri-loopback list
	mv "$WORKDIR/loopback-setup.sh.hidden" "$FAKE_BIN_DIR/loopback-setup.sh"

	assert_rc_nonzero "[$s] loopback fails when loopback-setup.sh cannot be found"
	assert_stderr_has "cannot find 'loopback-setup.sh'" "[$s] the error names loopback-setup.sh as the missing script"
	assert_not_invoked "$FAKE_ARGV_FILE" "[$s] nothing is executed when loopback-setup.sh cannot be found"

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

	# --- プロジェクトごとの compose ファイル -------------------------------------------
	# compose ファイルはプロジェクトごとに 1 枚持ち、置き場所ごと、どの dev
	# container にも mount しないホスト上の git repo に置く。karakuri.sh 側は
	# repo 名から使うファイルを引く（引けなければ止める）。
	echo "[$s] the compose file is resolved from the repository name"
	reset_env
	export KARAKURI_PROD_COMPOSE_DIR="$COMPOSE_DIR_OK"
	run_case karakuri-prod-run acme/app "$BASE_SHA" deploy

	assert_rc_zero "[$s] prod-run succeeds with KARAKURI_PROD_COMPOSE_DIR"
	assert_env_has "PROD_COMPOSE_FILE=$COMPOSE_DIR_OK/app.yaml" \
		"[$s] <repo>.yaml under the directory is the compose file"

	reset_env
	export KARAKURI_PROD_COMPOSE_DIR="$COMPOSE_DIR_OK"
	run_case karakuri-prod-exec acme/legacy "$BASE_SHA" ls

	assert_rc_zero "[$s] prod-exec succeeds when only <repo>.yml exists"
	assert_env_has "PROD_COMPOSE_FILE=$COMPOSE_DIR_OK/legacy.yml" \
		"[$s] <repo>.yml is used when <repo>.yaml is absent"

	# reset_env は単一ファイル運用を張ったままなので、上の 2 件も実は
	# 「両方設定された状態」を通っている。優先順位が意図であることを名前で
	# 残しておかないと、あれは偶然だったのかが後から読めない。
	reset_env
	export KARAKURI_PROD_COMPOSE="$COMPOSE_PINNED"
	export KARAKURI_PROD_COMPOSE_DIR="$COMPOSE_DIR_OK"
	run_case karakuri-prod-base acme/app "$BASE_SHA"

	assert_rc_zero "[$s] prod-base succeeds when both settings are present"
	assert_env_has "PROD_COMPOSE_FILE=$COMPOSE_DIR_OK/app.yaml" \
		"[$s] the directory wins over the single shared file when both are set"

	echo "[$s] an ambiguous or missing compose file stops the run"
	reset_env
	export KARAKURI_PROD_COMPOSE_DIR="$COMPOSE_DIR_BOTH"
	run_case karakuri-prod-run acme/dup "$BASE_SHA" deploy

	assert_rc_nonzero "[$s] a repository with both .yaml and .yml fails"
	assert_stderr_has "$COMPOSE_DIR_BOTH/dup.yaml" "[$s] the ambiguity error names the .yaml candidate"
	assert_stderr_has "$COMPOSE_DIR_BOTH/dup.yml" "[$s] the ambiguity error names the .yml candidate"
	assert_not_invoked "$FAKE_ARGV_FILE" "[$s] prod-run.sh is not invoked when two candidates exist"

	reset_env
	export KARAKURI_PROD_COMPOSE_DIR="$COMPOSE_DIR_OK"
	run_case karakuri-prod-run acme/absent "$BASE_SHA" deploy

	assert_rc_nonzero "[$s] a repository with no compose file in the directory fails"
	assert_stderr_has "$COMPOSE_DIR_OK/absent.yaml" "[$s] the error names the .yaml path it looked for"
	assert_stderr_has "$COMPOSE_DIR_OK/absent.yml" "[$s] the error names the .yml path it looked for"
	assert_not_invoked "$FAKE_ARGV_FILE" "[$s] prod-run.sh is not invoked when neither candidate exists"

	reset_env
	unset KARAKURI_PROD_COMPOSE
	run_case karakuri-prod-run acme/app "$BASE_SHA" deploy

	assert_rc_nonzero "[$s] prod-run fails when neither the directory nor the single file is set"
	assert_stderr_has "KARAKURI_PROD_COMPOSE_DIR" "[$s] the error names KARAKURI_PROD_COMPOSE_DIR as one of the two ways out"

	# --- ディレクトリ運用の digest 照合 --------------------------------------------
	# 引数に repo を取らずディレクトリを丸ごと掃引するのが狙い: 貼り忘れた
	# プロジェクトを見つけるのに、どれを貼り忘れたかを先に知っている必要がない。
	echo "[$s] check-image sweeps every compose file in the directory"
	reset_env
	export KARAKURI_PROD_COMPOSE_DIR="$COMPOSE_DIR_OK"
	run_case karakuri-check-image 1.2.2

	assert_rc_zero "[$s] check-image succeeds when every file in the directory matches"
	assert_stdout_has "$COMPOSE_DIR_OK/app.yaml" "[$s] each .yaml file is reported by name"
	assert_stdout_has "$COMPOSE_DIR_OK/legacy.yml" "[$s] .yml files are swept as well"

	reset_env
	export KARAKURI_PROD_COMPOSE_DIR="$COMPOSE_DIR_MIXED"
	run_case karakuri-check-image 1.2.2

	assert_rc_nonzero "[$s] check-image fails when one of the files pins a stale digest"
	assert_stderr_has "mismatch" "[$s] the stale file is reported as a mismatch"
	assert_stderr_has "$COMPOSE_DIR_MIXED/billing.yaml" "[$s] the mismatch names the file that is behind"
	assert_stderr_has "$COMPOSE_DIR_MIXED/notes.yml" "[$s] a file that pins no digest at all is reported separately"
	assert_stdout_has "$COMPOSE_DIR_MIXED/app.yaml" "[$s] the files that do match are still listed"
	assert_stdout_has "matches" "[$s] the matching file is reported as a match"
	# ここが「打ち切らない」ことの本体。zeta.yaml は問題のある 2 枚より後ろに
	# あるので、最初の問題で止める実装ではこの行が出ない。
	assert_stdout_has "$COMPOSE_DIR_MIXED/zeta.yaml" \
		"[$s] the sweep continues past a problem and still reports the files behind it"

	echo "[$s] image-digest needs the directory to agree on one image name"
	reset_env
	export KARAKURI_PROD_COMPOSE_DIR="$COMPOSE_DIR_OK"
	run_case karakuri-image-digest 1.2.2

	assert_rc_zero "[$s] image-digest succeeds when every file names the same image"
	assert_stdout_is "image: ${BASE_IMAGE}@${BASE_DIGEST}" \
		"[$s] the shared image name is used to resolve the bare tag"

	reset_env
	export KARAKURI_PROD_COMPOSE_DIR="$COMPOSE_DIR_DIVERGE"
	run_case karakuri-image-digest 1.2.2

	assert_rc_nonzero "[$s] image-digest fails when the files name different images"
	assert_stderr_has "$COMPOSE_DIR_DIVERGE/other.yaml" "[$s] the error names a file that disagrees"
	assert_not_invoked "$FAKE_BUILDX_ARGV_FILE" \
		"[$s] no registry lookup happens while the image name is ambiguous"

	# 完全な参照を渡す道は残っている（スラッシュを含むなら compose を読まない、
	# という既存の判定則がそのまま逃げ道になる）。
	reset_env
	export KARAKURI_PROD_COMPOSE_DIR="$COMPOSE_DIR_DIVERGE"
	run_case karakuri-image-digest "${OTHER_IMAGE}:1.2.2"

	assert_rc_zero "[$s] a full reference still works when the directory's image names disagree"
	assert_stdout_is "image: ${OTHER_IMAGE}@${BASE_DIGEST}" \
		"[$s] the full reference decides the image name without reading any compose file"

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

	# --- 転送エラーをログへ逃がす --------------------------------------------------
	# `ssh -fN` は背面へ回った後も端末の stderr を掴み続けるので、転送先の dev
	# サーバが落ちていると `connect_to ...: failed.` が端末に出続ける。転送
	# そのものは壊れていないため畳むのは過剰で、出力先を端末から外すしかない。
	# ただし黙らせきると失敗の理由まで消えるので、失敗時だけは末尾を見せる。
	echo "[$s] pf keeps the ssh -fN stderr in a per-host log file"
	local pf_log
	pf_log="$FAKE_STATE_HOME/karakuri/pf-devc-app.log"

	# 成功したときは端末に何も出さない。実機で困るのは「ssh -fN は成功した
	# のに、背面へ回った後の転送エラーが端末に出続ける」という形なので、
	# 成功側でも stderr を吐かせて黙ることを見る。
	reset_env
	export FAKE_SSH_STDERR="connect_to localhost port 4301: failed."
	run_case karakuri-pf app

	assert_rc_zero "[$s] pf succeeds when ssh -fN succeeds"
	assert_stdout_is "" "[$s] a successful pf prints nothing on stdout"
	if [ -z "$CASE_STDERR" ]; then
		ok "[$s] a successful pf prints nothing on stderr"
	else
		ng "[$s] a successful pf prints nothing on stderr (stderr: $CASE_STDERR)"
	fi
	if has_line "$pf_log" "$FAKE_SSH_STDERR"; then
		ok "[$s] the stderr of a successful forward is kept in the log instead"
	else
		ng "[$s] the stderr of a successful forward is kept in the log instead (log: $(cat "$pf_log" 2>/dev/null))"
	fi

	reset_env
	export FAKE_SSH_EXIT_CODE=1
	export FAKE_SSH_STDERR="connect_to localhost port 4301: failed."
	run_case karakuri-pf app

	assert_rc_nonzero "[$s] pf fails when ssh -fN fails"
	if has_line "$pf_log" "$FAKE_SSH_STDERR"; then
		ok "[$s] the ssh -fN stderr lands in the per-host log file"
	else
		ng "[$s] the ssh -fN stderr lands in the per-host log file (log: $(cat "$pf_log" 2>/dev/null))"
	fi
	assert_stderr_has "connect_to localhost port 4301: failed." \
		"[$s] the tail of the log is shown to the caller on failure"
	assert_stderr_has "karakuri-pf: 'ssh -fN devc-app' failed." \
		"[$s] the general error message is printed after the log tail"

	# 2 回目は追記であること。上書きだと、転送が転び続けている間の経緯
	# （どのポートが何回失敗したか）が毎回消える。reset_env は FAKE_HOME ごと
	# 作り直すので、ここでは意図的に挟まない。
	run_case karakuri-pf app
	if [ "$(grep -cF -- "$FAKE_SSH_STDERR" "$pf_log" 2>/dev/null)" = "2" ]; then
		ok "[$s] a second failure is appended to the log, not written over it"
	else
		ng "[$s] a second failure is appended to the log, not written over it (log: $(cat "$pf_log" 2>/dev/null))"
	fi

	# XDG_STATE_HOME が無い環境では XDG の既定（~/.local/state）へ落とす。
	reset_env
	unset XDG_STATE_HOME
	export FAKE_SSH_EXIT_CODE=1
	export FAKE_SSH_STDERR="bind: Can't assign requested address"
	run_case karakuri-pf app

	if has_line "$FAKE_HOME/.local/state/karakuri/pf-devc-app.log" "$FAKE_SSH_STDERR"; then
		ok "[$s] the log falls back to \$HOME/.local/state when XDG_STATE_HOME is unset"
	else
		ng "[$s] the log falls back to \$HOME/.local/state when XDG_STATE_HOME is unset"
	fi

	# --- loopback alias の事前検査 ---------------------------------------------------
	# macOS は 127.0.0.1 以外の loopback アドレスを alias で明示的に足さないと
	# bind できず、その状態で出る ssh のメッセージからは何を直せばよいかが
	# 分からない。足りない alias を名指しするのがこの検査で、外し方（fail
	# open）まで含めて見る。
	echo "[$s] pf checks the loopback aliases before it tears anything down"
	reset_env
	run_case karakuri-pf app

	assert_rc_zero "[$s] pf succeeds on a non-Darwin host"
	assert_not_invoked "$FAKE_SSH_G_LOG" "[$s] the loopback check does not even run 'ssh -G' outside Darwin"
	if has_line "$FAKE_SSH_LOG" "-fN devc-app"; then
		ok "[$s] the forward is started on a non-Darwin host"
	else
		ng "[$s] the forward is started on a non-Darwin host"
	fi

	reset_env
	export FAKE_UNAME_S=Darwin
	export FAKE_SSH_G_STDOUT="localforward [127.0.1.1]:4519 [localhost]:4519"
	export FAKE_IFCONFIG_STDOUT="$LO0_WITH_ALIAS"
	run_case karakuri-pf app

	assert_rc_zero "[$s] pf succeeds on Darwin when the alias is on lo0"
	if has_line "$FAKE_SSH_LOG" "-fN devc-app"; then
		ok "[$s] the forward is started once every bind address is present"
	else
		ng "[$s] the forward is started once every bind address is present"
	fi

	# 足りないときは失敗する。合わせて「落としてから失敗していない」ことも
	# 見る: 検査を後ろに置くと、張り直しに失敗しただけのつもりが、それまで
	# 生きていた転送まで巻き添えで消える。
	reset_env
	: >"$FAKE_HOME/.ssh/cm-devc-app"
	export FAKE_UNAME_S=Darwin
	export FAKE_SSH_G_STDOUT="localforward [127.0.1.1]:4519 [localhost]:4519"
	export FAKE_IFCONFIG_STDOUT="$LO0_BARE"
	run_case karakuri-pf app

	assert_rc_nonzero "[$s] pf fails on Darwin when the bind address is missing from lo0"
	assert_stderr_has "127.0.1.1" "[$s] the error names the address that is missing"
	assert_stderr_has "karakuri-loopback add 127.0.1.1" "[$s] the error says how to add it"
	# ssh はこの経路では 1 度も呼ばれない（-G は別ファイルに記録している）。
	# これが「-fN が走っていない」と「-O exit で古い master を落としていない」を
	# 同時に押さえる。
	assert_not_invoked "$FAKE_SSH_LOG" "[$s] neither 'ssh -fN' nor 'ssh -O exit' runs when the check fails"
	if [ -e "$FAKE_HOME/.ssh/cm-devc-app" ]; then
		ok "[$s] the existing control socket is left in place when the check fails"
	else
		ng "[$s] the existing control socket is left in place when the check fails"
	fi

	# 前方一致で通してしまわないこと。127.0.1.10 が載っていても 127.0.1.1 の
	# 代わりにはならない。
	reset_env
	export FAKE_UNAME_S=Darwin
	export FAKE_SSH_G_STDOUT="localforward [127.0.1.1]:4519 [localhost]:4519"
	export FAKE_IFCONFIG_STDOUT="$LO0_NEAR_MISS"
	run_case karakuri-pf app

	assert_rc_nonzero "[$s] an address that is only a prefix of one on lo0 counts as missing"
	assert_stderr_has "127.0.1.1 is not on lo0" "[$s] the near-miss error still names the address that is missing"

	# fail open その 1: `ssh -G` が失敗したら黙って先へ進む。出力の綴りは
	# OpenSSH の版に依存しうるので、読み取れないことを転送の可否に繋げない。
	reset_env
	export FAKE_UNAME_S=Darwin
	export FAKE_SSH_G_EXIT_CODE=1
	export FAKE_IFCONFIG_STDOUT="$LO0_BARE"
	run_case karakuri-pf app

	assert_rc_zero "[$s] a failing 'ssh -G' lets the forward through"
	if [ -z "$CASE_STDERR" ]; then
		ok "[$s] a failing 'ssh -G' says nothing"
	else
		ng "[$s] a failing 'ssh -G' says nothing (stderr: $CASE_STDERR)"
	fi

	# fail open その 2: localforward の行が 1 つも無いとき。
	reset_env
	export FAKE_UNAME_S=Darwin
	FAKE_SSH_G_STDOUT="$(printf 'user someone\nport 22')"
	export FAKE_SSH_G_STDOUT
	export FAKE_IFCONFIG_STDOUT="$LO0_BARE"
	run_case karakuri-pf app

	assert_rc_zero "[$s] a config with no localforward lets the forward through"
	if has_line "$FAKE_SSH_LOG" "-fN devc-app"; then
		ok "[$s] the forward is started when there is nothing to check"
	else
		ng "[$s] the forward is started when there is nothing to check"
	fi

	# bind 側が 127. で始まらないものは検査対象にならない。lo0 には 127.0.0.1
	# しか載せていないので、もしこれらを拾っていれば「載っていない」と言って
	# 失敗する（fail open で素通りしたのではないことが、これで分かる）。
	reset_env
	export FAKE_UNAME_S=Darwin
	FAKE_SSH_G_STDOUT="$(printf 'localforward localhost:4519 localhost:4519\nlocalforward [::1]:4520 localhost:4520')"
	export FAKE_SSH_G_STDOUT
	export FAKE_IFCONFIG_STDOUT="$LO0_BARE"
	run_case karakuri-pf app

	assert_rc_zero "[$s] a bind address that is not 127.x is not checked against lo0"
	if [ -z "$CASE_STDERR" ]; then
		ok "[$s] neither 'localhost' nor an IPv6 bind address is reported as missing"
	else
		ng "[$s] neither 'localhost' nor an IPv6 bind address is reported as missing (stderr: $CASE_STDERR)"
	fi

	# --- karakuri-help ---------------------------------------------------------------
	echo "[$s] karakuri-help lists functions and env vars, and reflects current values"
	reset_env
	export KARAKURI_ORG=acme
	export KARAKURI_BW_BIN=/opt/bw
	run_case karakuri-help

	assert_rc_zero "[$s] karakuri-help succeeds"
	assert_not_invoked "$FAKE_ARGV_FILE" "[$s] karakuri-help does not call prod-run.sh / dev-inject.sh / broker"

	for fn in karakuri-pf karakuri-clean-pf karakuri-loopback karakuri-dev-inject \
		karakuri-dock karakuri-prod-run \
		karakuri-prod-exec karakuri-prod-base karakuri-prod-shell \
		karakuri-image-digest karakuri-check-image karakuri-help; do
		assert_stdout_has "$fn" "[$s] karakuri-help output mentions $fn"
	done

	assert_stdout_has "KARAKURI_ORG" "[$s] karakuri-help lists KARAKURI_ORG"
	assert_stdout_has "acme" "[$s] karakuri-help shows the current value of KARAKURI_ORG"
	assert_stdout_has "/opt/bw" "[$s] karakuri-help shows the current value of KARAKURI_BW_BIN"

	# KARAKURI_PROD_INSTALL / KARAKURI_PROD_RUN は reset_env が unset している。
	# 既定値だけを見せる誤りではなく「今は未設定」を見せていることを確認する。
	assert_stdout_has "KARAKURI_PROD_INSTALL (任意): (unset" \
		"[$s] karakuri-help marks unset KARAKURI_PROD_INSTALL as unset, not just its default"
	assert_stdout_has "KARAKURI_PROD_RUN (任意): (unset" \
		"[$s] karakuri-help marks unset KARAKURI_PROD_RUN as unset, not just its default"

	assert_stdout_lacks "BROKER_BW_ITEM" \
		"[$s] karakuri-help never prints BROKER_BW_ITEM (that is the broker's business, not this function's)"

	reset_env
	export KARAKURI_PROD_INSTALL=""
	export KARAKURI_PROD_RUN="npm run"
	run_case karakuri-help

	assert_stdout_has "KARAKURI_PROD_INSTALL (任意): (empty" \
		"[$s] karakuri-help distinguishes an empty KARAKURI_PROD_INSTALL from unset"
	assert_stdout_has "KARAKURI_PROD_RUN (任意): npm run" \
		"[$s] karakuri-help shows a multi-word KARAKURI_PROD_RUN as set"

	# 「どちらか一方が要る」関係の 2 つは、両方が一覧に出て現在値も見えること。
	# 片方だけを見て「未設定だから壊れている」と読む誤りを避けるための表示。
	reset_env
	export KARAKURI_PROD_COMPOSE_DIR="$COMPOSE_DIR_OK"
	run_case karakuri-help

	assert_stdout_has "KARAKURI_PROD_COMPOSE_DIR" "[$s] karakuri-help lists KARAKURI_PROD_COMPOSE_DIR"
	assert_stdout_has "$COMPOSE_DIR_OK" "[$s] karakuri-help shows the current value of KARAKURI_PROD_COMPOSE_DIR"
	assert_stdout_has "$COMPOSE_PINNED" "[$s] karakuri-help still shows KARAKURI_PROD_COMPOSE alongside it"

	reset_env
	unset KARAKURI_PROD_COMPOSE
	run_case karakuri-help

	assert_stdout_has "KARAKURI_PROD_COMPOSE_DIR" "[$s] karakuri-help lists KARAKURI_PROD_COMPOSE_DIR even when it is unset"
	assert_stdout_has "(unset)" "[$s] karakuri-help marks the unset compose settings as unset"

	# --- 関数が全部定義されていること --------------------------------------------------
	echo "[$s] every documented function is defined"
	reset_env
	for fn in karakuri-pf karakuri-clean-pf karakuri-loopback karakuri-dev-inject \
		karakuri-dock karakuri-prod-run \
		karakuri-prod-exec karakuri-prod-base karakuri-prod-shell \
		karakuri-image-digest karakuri-check-image \
		karakuri-broker-command karakuri-broker-env karakuri-help; do
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
