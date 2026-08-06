#!/usr/bin/env bash
#
# bin/prod-context の対話ガード・三値表示・シェル非破壊性を docker なしで
# 検証する。
#
# prod-context は /run/secrets と /run/prod-ref を絶対パスでハードコード
# しているため、entrypoint.test.sh / shim.test.sh と同じ考え方で、
# テストごとに一意な tmpdir へ sed で書き換えたコピーを使う。
#
# 「対話シェル相当」を作るには、bash/zsh とも `set -i` のような対話
# フラグの後付け設定はできない (bash は `set -i` 自体が invalid option)
# ため、`bash -i` / `zsh -i` の子プロセスとして起動することで
# `case $- in *i*)` が真になる状態を作る。`-i` は「ジョブ制御を持てない」
# 旨の警告を stderr に出すが、これはテストの対象ではないので無視する。
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROD_CONTEXT_SRC="$SCRIPT_DIR/bin/prod-context"

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

# make_prod_context <tmpdir> -> $tmpdir/prod-context に、/run/secrets と
# /run/prod-ref を tmpdir 配下へ差し替えたコピーを作る。
make_prod_context() {
	local dir="$1"
	mkdir -p "$dir/secrets"
	sed \
		-e "s#/run/secrets#$dir/secrets#g" \
		-e "s#/run/prod-ref#$dir/prod-ref#g" \
		"$PROD_CONTEXT_SRC" >"$dir/prod-context"
	chmod +x "$dir/prod-context"
}

HAVE_ZSH=0
if command -v zsh >/dev/null 2>&1; then
	HAVE_ZSH=1
fi

# --- 1. 非対話で source しても何も出力しない ------------------------------------
t="$(mktemp -d)"
make_prod_context "$t"
mkdir -p "$t/secrets"
printf 'x\n' >"$t/secrets/FOO"
out="$(bash -c ". $t/prod-context" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
	ok "非対話 (bash) で source しても何も出力しない"
else
	ng "非対話 (bash) で source しても何も出力しない (rc=$rc out=$out)"
fi
rm -rf "$t"

if [ "$HAVE_ZSH" -eq 1 ]; then
	t="$(mktemp -d)"
	make_prod_context "$t"
	mkdir -p "$t/secrets"
	printf 'x\n' >"$t/secrets/FOO"
	out="$(zsh -c ". $t/prod-context" 2>&1)"
	rc=$?
	if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
		ok "非対話 (zsh) で source しても何も出力しない"
	else
		ng "非対話 (zsh) で source しても何も出力しない (rc=$rc out=$out)"
	fi
	rm -rf "$t"
else
	printf '  skip %s\n' "非対話 (zsh) で source しても何も出力しない: zsh 不在のため未検証"
fi

# --- 2. 対話相当で、ファイル名だけが出て値は出ない -------------------------------
#     値に目印文字列を入れ、出力にその文字列が現れないことを確認する。
t="$(mktemp -d)"
make_prod_context "$t"
marker="SUPERSECRETVALUE_MARKER_$$"
printf '%s\n' "$marker" >"$t/secrets/DOTENV_PRIVATE_KEY_LOCAL"
printf 'not-a-secret-value\n' >"$t/secrets/GH_TOKEN"
out="$(bash -i -c ". $t/prod-context" 2>/dev/null)"
rc=$?
if [ "$rc" -eq 0 ] &&
	printf '%s\n' "$out" | grep -q "DOTENV_PRIVATE_KEY_LOCAL" &&
	printf '%s\n' "$out" | grep -q "GH_TOKEN"; then
	ok "対話相当 (bash -i) でファイル名が出る"
else
	ng "対話相当 (bash -i) でファイル名が出る (rc=$rc out=$out)"
fi
if ! printf '%s\n' "$out" | grep -q "$marker"; then
	ok "対話相当 (bash -i) で値 (目印文字列) は出ない"
else
	ng "対話相当 (bash -i) で値 (目印文字列) は出ない (out=$out)"
fi
rm -rf "$t"

if [ "$HAVE_ZSH" -eq 1 ]; then
	t="$(mktemp -d)"
	make_prod_context "$t"
	marker="SUPERSECRETVALUE_MARKER_ZSH_$$"
	printf '%s\n' "$marker" >"$t/secrets/DOTENV_PRIVATE_KEY_LOCAL"
	out="$(zsh -i -c ". $t/prod-context" 2>/dev/null)"
	rc=$?
	if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q "DOTENV_PRIVATE_KEY_LOCAL"; then
		ok "対話相当 (zsh -i) でファイル名が出る"
	else
		ng "対話相当 (zsh -i) でファイル名が出る (rc=$rc out=$out)"
	fi
	if ! printf '%s\n' "$out" | grep -q "$marker"; then
		ok "対話相当 (zsh -i) で値 (目印文字列) は出ない"
	else
		ng "対話相当 (zsh -i) で値 (目印文字列) は出ない (out=$out)"
	fi
	rm -rf "$t"
else
	printf '  skip %s\n' "対話相当 (zsh -i) でファイル名だけが出る: zsh 不在のため未検証"
fi

# --- 3. /run/secrets が空 / 不在のとき専用の1行が出る ----------------------------
t="$(mktemp -d)"
make_prod_context "$t"
# 空ディレクトリ
out="$(bash -i -c ". $t/prod-context" 2>/dev/null)"
if printf '%s\n' "$out" | grep -q "prod-context:" && printf '%s\n' "$out" | grep -qi "無い"; then
	ok "/run/secrets が空のとき専用の1行が出る"
else
	ng "/run/secrets が空のとき専用の1行が出る (out=$out)"
fi
rm -rf "$t/secrets"
out="$(bash -i -c ". $t/prod-context" 2>/dev/null)"
if printf '%s\n' "$out" | grep -q "prod-context:" && printf '%s\n' "$out" | grep -qi "無い"; then
	ok "/run/secrets が不在のとき専用の1行が出る"
else
	ng "/run/secrets が不在のとき専用の1行が出る (out=$out)"
fi
rm -rf "$t"

# --- 4. /run/prod-ref があれば内容が出る -----------------------------------------
t="$(mktemp -d)"
make_prod_context "$t"
printf 'GIT_REF=main\nGIT_COMMIT=4f3a9c2b00112233445566778899aabbccddeeff\nMUTABLE_REF=1\n' >"$t/prod-ref"
out="$(bash -i -c ". $t/prod-context" 2>/dev/null)"
if printf '%s\n' "$out" | grep -q "GIT_REF=main" &&
	printf '%s\n' "$out" | grep -q "4f3a9c2b00112233445566778899aabbccddeeff" &&
	printf '%s\n' "$out" | grep -q "mutable ref"; then
	ok "/run/prod-ref があれば内容が出る (mutable ref の注記込み)"
else
	ng "/run/prod-ref があれば内容が出る (out=$out)"
fi
rm -rf "$t"

# --- 4b. /run/prod-ref が無ければ、その旨の出力もない -----------------------------
t="$(mktemp -d)"
make_prod_context "$t"
out="$(bash -i -c ". $t/prod-context" 2>/dev/null)"
if ! printf '%s\n' "$out" | grep -qi "GIT_REF"; then
	ok "/run/prod-ref が無ければ GIT_REF 行は出ない"
else
	ng "/run/prod-ref が無ければ GIT_REF 行は出ない (out=$out)"
fi
rm -rf "$t"

# --- 5. set -e なシェルで source されてもシェルを壊さない -------------------------
#     source 対象のディレクトリを壊れた状態 (secrets が存在しない) にした
#     うえで、set -e 下で source し、後続のコマンドまで到達することを確認
#     する。prod-context 内部での失敗が外へ伝播して呼び出し元を落とさない
#     ことの回帰確認 (仕様: エラーを外へ漏らさない)。
t="$(mktemp -d)"
make_prod_context "$t"
rm -rf "$t/secrets"
out="$(bash -i -c "set -e; . $t/prod-context; echo AFTER_SOURCE_OK" 2>/dev/null)"
rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q "AFTER_SOURCE_OK"; then
	ok "set -e なシェルで source してもシェルを壊さず後続コマンドまで到達する"
else
	ng "set -e なシェルで source してもシェルを壊さず後続コマンドまで到達する (rc=$rc out=$out)"
fi
rm -rf "$t"

# --- result ------------------------------------------------------------------

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
