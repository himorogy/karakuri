#!/usr/bin/env bash
#
# packages/env-guard/hooks/pre-commit の .env.keys 検査を docker なしで
# 検証する。
#
# 本番では core.hooksPath 経由でイメージから効かせる hook だが、ここでは
# hook スクリプトそのものを、mktemp -d に作ったローカル repo の中で直接
# 実行する。検査対象のルートは hook 自身が `git rev-parse --show-toplevel`
# で決めるため、cd した先の repo がそのまま対象になり、パスの書き換え
# (shim.test.sh 等の sed) は要らない。
#
# hook は検査そのものを共有スキャナ (packages/env-guard/bin/env-guard-scan)
# へ委ねており、
# .env.keys の探索もそちらにある。ここで見るのは「hook 経由でその検査が
# 効いていること」であり、hook と CI の判定が一致することは
# env-guard.test.sh が見る。以前ここに置いていたフェイクの dotenvx は、
# hook が `dotenvx precommit` を呼ばなくなったので外した。
#
set -uo pipefail

HOOK_SRC="$(cd "$(dirname "$0")/../../../packages/env-guard" && pwd)/hooks/pre-commit"

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

HAVE_GIT=0
if command -v git >/dev/null 2>&1; then
	HAVE_GIT=1
fi

# root で走ると mode 000 のディレクトリも読めてしまい、「find 自体が失敗
# する」状況が作れない。shim.test.sh の mode 000 テストと同じ流儀で skip
# してその旨を明示する。
IS_ROOT=0
if [ "$(id -u)" -eq 0 ]; then
	IS_ROOT=1
fi

# make_repo <tmpdir> -> $tmpdir/repo に空の git repo を作る。
make_repo() {
	local dir="$1"
	mkdir -p "$dir/repo"
	git init -q "$dir/repo"
}

# run_hook <repo> -> repo の中で hook を実行し、stdout/stderr をまとめて返す。
run_hook() {
	local repo="$1"
	(cd "$repo" && "$HOOK_SRC" 2>&1)
}

if [ "$HAVE_GIT" -eq 1 ]; then
	# --- 1. repo ルートの .env.keys を弾く (従来からの挙動の回帰) ----------------
	t="$(mktemp -d)"
	make_repo "$t"
	printf 'DOTENV_PRIVATE_KEY_PROD="dummy"\n' >"$t/repo/.env.keys"
	out="$(run_hook "$t/repo")"
	rc=$?
	if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q ".env.keys"; then
		ok "repo ルートの .env.keys -> 非ゼロ終了"
	else
		ng "repo ルートの .env.keys -> 非ゼロ終了 (rc=$rc out=$out)"
	fi
	rm -rf "$t"

	# --- 2. サブディレクトリの .env.keys を弾く ----------------------------------
	#     dotenvx の自動フォールバックは .env ファイルに「隣接する」.env.keys を
	#     拾うため、monorepo の apps/backend/.env.keys は実際に効いてしまう。
	#     ルート直下しか見ない実装ではここが素通りしていた。
	t="$(mktemp -d)"
	make_repo "$t"
	mkdir -p "$t/repo/apps/backend"
	printf 'DOTENV_PRIVATE_KEY_PROD="dummy"\n' >"$t/repo/apps/backend/.env.keys"
	out="$(run_hook "$t/repo")"
	rc=$?
	if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q "apps/backend/.env.keys"; then
		ok "サブディレクトリの .env.keys -> 非ゼロ終了 (検出したパスが出る)"
	else
		ng "サブディレクトリの .env.keys -> 非ゼロ終了 (検出したパスが出る) (rc=$rc out=$out)"
	fi
	rm -rf "$t"

	# --- 3. node_modules 配下の .env.keys は無視する -----------------------------
	#     依存パッケージが同梱する fixture 等での誤検知を避けるため。コミット
	#     対象でもない。
	t="$(mktemp -d)"
	make_repo "$t"
	mkdir -p "$t/repo/node_modules/some-pkg/test"
	printf 'DOTENV_PRIVATE_KEY_PROD="dummy"\n' >"$t/repo/node_modules/some-pkg/test/.env.keys"
	out="$(run_hook "$t/repo")"
	rc=$?
	if [ "$rc" -eq 0 ]; then
		ok "node_modules 配下の .env.keys は無視される"
	else
		ng "node_modules 配下の .env.keys は無視される (rc=$rc out=$out)"
	fi
	rm -rf "$t"

	# --- 4. .env.keys が一つも無ければ通る (正常系) ------------------------------
	t="$(mktemp -d)"
	make_repo "$t"
	mkdir -p "$t/repo/apps/backend"
	printf 'FOO="encrypted"\n' >"$t/repo/apps/backend/.env.prod"
	out="$(run_hook "$t/repo")"
	rc=$?
	if [ "$rc" -eq 0 ]; then
		ok ".env.keys が無ければ hook は通る"
	else
		ng ".env.keys が無ければ hook は通る (rc=$rc out=$out)"
	fi
	rm -rf "$t"

	# --- 5. 検査を完走できないときは理由付きで非ゼロ終了する ---------------------
	#     読めないディレクトリ (mode 000) を掘って find の walk を失敗させる。
	#     find が非ゼロで終わったことを「.env.keys が1件も無かった」と取り
	#     違えず、かつ「何も言わずに落ちる」でもなく、検査を完走できなかった
	#     ことが stderr から読み取れる形で止まること (fail-closed) を見る。
	if [ "$IS_ROOT" -eq 1 ]; then
		skip "検査を完走できないときは理由付きで非ゼロ終了する (root では mode 000 でも読めるため skip)"
	else
		t="$(mktemp -d)"
		make_repo "$t"
		mkdir -p "$t/repo/unreadable"
		chmod 000 "$t/repo/unreadable"
		out="$(run_hook "$t/repo")"
		rc=$?
		if [ "$rc" -ne 0 ] &&
			printf '%s\n' "$out" | grep -q "could not finish scanning" &&
			printf '%s\n' "$out" | grep -q ".env.keys"; then
			ok "find が失敗したら理由 (検査を完走できなかった) が読み取れる形で非ゼロ終了する"
		else
			ng "find が失敗したら理由 (検査を完走できなかった) が読み取れる形で非ゼロ終了する (rc=$rc out=$out)"
		fi
		# rm -rf のために読み書き権限を戻す。
		chmod 755 "$t/repo/unreadable"
		rm -rf "$t"
	fi
else
	skip "repo ルートの .env.keys -> 非ゼロ終了: git 不在のため未検証"
	skip "サブディレクトリの .env.keys -> 非ゼロ終了: git 不在のため未検証"
	skip "node_modules 配下の .env.keys は無視される: git 不在のため未検証"
	skip ".env.keys が無ければ hook は通る: git 不在のため未検証"
	skip "検査を完走できないときは理由付きで非ゼロ終了する: git 不在のため未検証"
fi

# --- result ----------------------------------------------------------------------

printf '\n%s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
