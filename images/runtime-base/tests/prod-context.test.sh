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
		-e "s#/usr/local/bin/git-auth-check#$dir/git-auth-check#g" \
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

# --- 3b. /run/secrets が「存在して空」でも glob エラーで途中終了しない ------------
#     以前は `for f in "$secrets_dir"/*` で列挙していた。ディレクトリが存在
#     して中身がゼロのとき、zsh の既定 (nomatch) ではループ本体へ入る前の
#     単語展開の時点で "no matches found" となり、サブシェルごと非ゼロ終了
#     する (ループ本体の `[ -e "$f" ] || continue` は展開後の話なので防御に
#     ならない)。外側の `|| true` があるため rc は 0 のままだが、stderr に
#     エラーが出て、以降の /run/prod-ref 行が失われる。エラーが出ないこと
#     と、後続の出力まで到達することの両方を見る。
for sh_bin in bash zsh; do
	if [ "$sh_bin" = zsh ] && [ "$HAVE_ZSH" -eq 0 ]; then
		printf '  skip %s\n' "/run/secrets が存在して空でも glob エラーにならない (zsh): zsh 不在のため未検証"
		continue
	fi
	t="$(mktemp -d)"
	make_prod_context "$t"
	# secrets ディレクトリは作るが中身は置かない (mkdir は make_prod_context 済み)
	printf 'GIT_REF=main\nGIT_COMMIT=4f3a9c2b00112233445566778899aabbccddeeff\nMUTABLE_REF=0\n' >"$t/prod-ref"
	err_file="$t/stderr.log"
	out="$("$sh_bin" -i -c ". $t/prod-context" 2>"$err_file")"
	rc=$?
	err="$(cat "$err_file")"
	if [ "$rc" -eq 0 ] && ! printf '%s\n' "$err" | grep -qi "no matches found"; then
		ok "/run/secrets が存在して空でも glob エラーが出ない ($sh_bin -i)"
	else
		ng "/run/secrets が存在して空でも glob エラーが出ない ($sh_bin -i) (rc=$rc err=$err)"
	fi
	if printf '%s\n' "$out" | grep -qi "無い" && printf '%s\n' "$out" | grep -q "GIT_REF=main"; then
		ok "/run/secrets が存在して空でも後続の /run/prod-ref 行まで到達する ($sh_bin -i)"
	else
		ng "/run/secrets が存在して空でも後続の /run/prod-ref 行まで到達する ($sh_bin -i) (out=$out)"
	fi
	rm -rf "$t"
done

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

# --- 4c. git-auth-check への配線 ---------------------------------------------------
#     git の認証経路の検査は別ファイル (bin/git-auth-check) にあり、対話シェルの
#     起動ごとに一度走る場所として prod-context から呼んでいる。検査の中身は
#     git-credential.test.sh が見るので、ここで見るのは「呼ばれること」と
#     「その失敗が対話シェルへ漏れないこと」の 2 点だけ。
t="$(mktemp -d)"
make_prod_context "$t"
printf '#!/bin/sh\necho AUTH_CHECK_RAN\n' >"$t/git-auth-check"
chmod +x "$t/git-auth-check"
out="$(bash -i -c ". $t/prod-context" 2>/dev/null)"
if printf '%s\n' "$out" | grep -q "AUTH_CHECK_RAN"; then
	ok "対話シェルの起動で git-auth-check が呼ばれる"
else
	ng "対話シェルの起動で git-auth-check が呼ばれる (out=$out)"
fi
rm -rf "$t"

# 否定対照: 実行可能な検査が置かれていなければ呼ばない (置き場が変わったときに
# 上の ok が「たまたま何も出ない」で緑にならないことの裏取り)。
t="$(mktemp -d)"
make_prod_context "$t"
printf '#!/bin/sh\necho AUTH_CHECK_RAN\n' >"$t/git-auth-check"
chmod -x "$t/git-auth-check"
out="$(bash -i -c ". $t/prod-context" 2>/dev/null)"
if ! printf '%s\n' "$out" | grep -q "AUTH_CHECK_RAN"; then
	ok "否定対照: 実行可能でなければ git-auth-check は呼ばれない"
else
	ng "否定対照: 実行可能でなければ git-auth-check は呼ばれない (out=$out)"
fi
rm -rf "$t"

# 検査が落ちても、対話シェルの起動と prod-context 本来の出力は止まらない。
t="$(mktemp -d)"
make_prod_context "$t"
printf 'x\n' >"$t/secrets/FOO"
printf '#!/bin/sh\necho boom >&2\nexit 1\n' >"$t/git-auth-check"
chmod +x "$t/git-auth-check"
out="$(bash -i -c "set -e; . $t/prod-context; echo AFTER_SOURCE_OK" 2>/dev/null)"
rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q "AFTER_SOURCE_OK" &&
	printf '%s\n' "$out" | grep -q "FOO"; then
	ok "git-auth-check が非ゼロで終わってもシェルと本来の出力を壊さない"
else
	ng "git-auth-check が非ゼロで終わってもシェルと本来の出力を壊さない (rc=$rc out=$out)"
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
