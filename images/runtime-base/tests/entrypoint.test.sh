#!/usr/bin/env bash
#
# bin/prod-entrypoint.sh のパーサ堅牢化とワークスペース復元を docker なしで
# 検証する。
#
# entrypoint は /run/secrets と /src を絶対パスでハードコードしているため、
# shim.test.sh と同じ考え方で、テストごとに一意な tmpdir へ sed で
# 書き換えたコピーを使う。git 操作 (fetch/checkout/clean) はローカルの
# bare repository を mktemp -d に作って検証する: git が使えない環境では
# その部分だけスキップし、スキップした旨を明示する。
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENTRYPOINT_SRC="$SCRIPT_DIR/bin/prod-entrypoint.sh"

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

# make_entrypoint <tmpdir> -> $tmpdir/entrypoint.sh に、/run/secrets と /src
# を tmpdir 配下へ差し替えたコピーを作る。
make_entrypoint() {
	local dir="$1"
	mkdir -p "$dir/secrets" "$dir/src"
	sed \
		-e "s#/run/secrets#$dir/secrets#g" \
		-e "s#/src#$dir/src#g" \
		"$ENTRYPOINT_SRC" >"$dir/entrypoint.sh"
	chmod +x "$dir/entrypoint.sh"
}

HAVE_GIT=0
if command -v git >/dev/null 2>&1; then
	HAVE_GIT=1
fi

# --- ローカル bare repo の準備 (git 操作を伴うテスト用) -------------------------
#
# GIT_REPO に file:// URL を渡すことで、ネットワークにもトークンにも
# 依存せず fetch/checkout/clean の経路を実際に走らせられる。
BARE_REPO=""
COMMIT_SHA=""
if [ "$HAVE_GIT" -eq 1 ]; then
	BARE_ROOT="$(mktemp -d)"
	BARE_REPO="$BARE_ROOT/upstream.git"
	WORK_ROOT="$(mktemp -d)"
	if git init -q --bare "$BARE_REPO" &&
		git init -q "$WORK_ROOT" &&
		git -C "$WORK_ROOT" config user.email "test@example.com" &&
		git -C "$WORK_ROOT" config user.name "test" &&
		printf 'hello\n' >"$WORK_ROOT/file.txt" &&
		git -C "$WORK_ROOT" add file.txt &&
		git -C "$WORK_ROOT" commit -q -m init &&
		git -C "$WORK_ROOT" remote add origin "$BARE_REPO" &&
		git -C "$WORK_ROOT" push -q origin HEAD:refs/heads/main; then
		COMMIT_SHA="$(git -C "$WORK_ROOT" rev-parse HEAD)"
	else
		ng "ローカル bare repo の準備に失敗した (git 操作テストは実行できない)"
		HAVE_GIT=0
	fi
fi

# --- 1. stdin 空 -> 非ゼロ終了 --------------------------------------------------
t="$(mktemp -d)"
make_entrypoint "$t"
out="$(printf '' | env GIT_REPO=unused GIT_REF=unused "$t/entrypoint.sh" true 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q "no secrets received on stdin"; then
	ok "stdin 空 -> 非ゼロ終了"
else
	ng "stdin 空 -> 非ゼロ終了 (rc=$rc out=$out)"
fi
rm -rf "$t"

# --- 2. KEY="" -> 非ゼロ終了 -----------------------------------------------------
t="$(mktemp -d)"
make_entrypoint "$t"
out="$(printf 'FOO=""\n' | env GIT_REPO=unused GIT_REF=unused "$t/entrypoint.sh" true 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q "empty secret"; then
	ok 'KEY="" -> 非ゼロ終了'
else
	ng "KEY=\"\" -> 非ゼロ終了 (rc=$rc out=$out)"
fi
rm -rf "$t"

# --- 3. '=' 無し行 -> 非ゼロ終了 -------------------------------------------------
t="$(mktemp -d)"
make_entrypoint "$t"
out="$(printf 'not-a-kv-line\n' | env GIT_REPO=unused GIT_REF=unused "$t/entrypoint.sh" true 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q "missing '='"; then
	ok "'=' 無し行 -> 非ゼロ終了"
else
	ng "'=' 無し行 -> 非ゼロ終了 (rc=$rc out=$out)"
fi
rm -rf "$t"

# --- 4. 不正な鍵名 -> 非ゼロ終了 (パストラバーサル対策込み) ---------------------
for bad_key_line in '../etc/passwd=x' 'A/B=x' '1FOO=x' 'FOO-BAR=x'; do
	t="$(mktemp -d)"
	make_entrypoint "$t"
	out="$(printf '%s\n' "$bad_key_line" | env GIT_REPO=unused GIT_REF=unused "$t/entrypoint.sh" true 2>&1)"
	rc=$?
	if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q "invalid"; then
		ok "不正な鍵名 -> 非ゼロ終了: $bad_key_line"
	else
		ng "不正な鍵名 -> 非ゼロ終了: $bad_key_line (rc=$rc out=$out)"
	fi
	rm -rf "$t"
done

# --- 4b. パース失敗メッセージに入力行が出ない (regression: rev.4 §4.6) ----------
#     '=' を含まない目印文字列だけの行を与え、stderr にその文字列そのものが
#     現れないことを確認する。broker の出力が壊れて secret 本体がそのまま
#     この行に来た場合でも、値を stderr へ反射しないことを保証する。
t="$(mktemp -d)"
make_entrypoint "$t"
marker="SUPERSECRETVALUE_NO_EQUALS_$$"
out="$(printf '%s\n' "$marker" | env GIT_REPO=unused GIT_REF=unused "$t/entrypoint.sh" true 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && ! printf '%s\n' "$out" | grep -q "$marker"; then
	ok "パース失敗メッセージに入力行 (目印文字列) が出ない"
else
	ng "パース失敗メッセージに入力行 (目印文字列) が出ない (rc=$rc out=$out)"
fi
rm -rf "$t"

# --- 4c. 不正な鍵名のメッセージに鍵名が出ない (regression: rev.4 §4.6) ----------
#     不正な鍵名 (数字始まり) に目印文字列を含めて与え、stderr にその
#     文字列が現れないことを確認する。
t="$(mktemp -d)"
make_entrypoint "$t"
marker="SUPERSECRETKEYVALUE_$$"
out="$(printf '1%s=x\n' "$marker" | env GIT_REPO=unused GIT_REF=unused "$t/entrypoint.sh" true 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && ! printf '%s\n' "$out" | grep -q "$marker"; then
	ok "不正な鍵名のメッセージに鍵名 (目印文字列) が出ない"
else
	ng "不正な鍵名のメッセージに鍵名 (目印文字列) が出ない (rc=$rc out=$out)"
fi
rm -rf "$t"

# --- 5. 引数なし -> 非ゼロ終了 (git 操作を伴わずに検証可能な範囲だけ確認) -------
#     GIT_REPO/GIT_REF が実在しないとこのテストは git fetch の段で失敗して
#     しまい「引数なし」の検証にならないため、bare repo が使えるときだけ
#     実施する。
if [ "$HAVE_GIT" -eq 1 ]; then
	t="$(mktemp -d)"
	make_entrypoint "$t"
	out="$(printf 'FOO=bar\n' | env GIT_REPO="$BARE_REPO" GIT_REF="$COMMIT_SHA" "$t/entrypoint.sh" 2>&1)"
	rc=$?
	if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q "no command given"; then
		ok "引数なし -> 非ゼロ終了 (no command given)"
	else
		ng "引数なし -> 非ゼロ終了 (no command given) (rc=$rc out=$out)"
	fi
	rm -rf "$t"
else
	skip "引数なし -> 非ゼロ終了 (git 不在のため checkout まで到達できず未検証)"
fi

# --- 6〜10: git 操作を伴う一連のテスト -------------------------------------------
if [ "$HAVE_GIT" -eq 1 ]; then
	# 6. 正常系: secret ファイルが mode 600 で書かれ、GH_TOKEN は checkout 後に
	#    削除され、/src が指定 ref へ復元される。
	t="$(mktemp -d)"
	make_entrypoint "$t"
	out="$(printf 'FOO=bar\nGH_TOKEN=dummy-token\n' |
		env GIT_REPO="$BARE_REPO" GIT_REF="$COMMIT_SHA" "$t/entrypoint.sh" true 2>&1)"
	rc=$?
	if [ "$rc" -eq 0 ]; then
		ok "正常系: entrypoint が exit 0 で完走する"
	else
		ng "正常系: entrypoint が exit 0 で完走する (rc=$rc out=$out)"
	fi

	if [ -f "$t/secrets/FOO" ] && [ "$(cat "$t/secrets/FOO")" = "bar" ]; then
		ok "正常系: secret ファイルの中身が保存される"
	else
		ng "正常系: secret ファイルの中身が保存される"
	fi

	if [ -f "$t/secrets/FOO" ]; then
		mode="$(stat -c '%a' "$t/secrets/FOO" 2>/dev/null || stat -f '%Lp' "$t/secrets/FOO" 2>/dev/null)"
		if [ "$mode" = "600" ]; then
			ok "正常系: 生成された secret ファイルが mode 600"
		else
			ng "正常系: 生成された secret ファイルが mode 600 (mode=$mode)"
		fi
	else
		ng "正常系: 生成された secret ファイルが mode 600 (ファイルが無い)"
	fi

	if [ ! -e "$t/secrets/GH_TOKEN" ]; then
		ok "正常系: checkout 後に GH_TOKEN が削除されている"
	else
		ng "正常系: checkout 後に GH_TOKEN が削除されている"
	fi

	if [ -f "$t/src/file.txt" ] && [ "$(cat "$t/src/file.txt")" = "hello" ]; then
		ok "正常系: /src が指定 ref のコミット内容へ復元されている"
	else
		ng "正常系: /src が指定 ref のコミット内容へ復元されている"
	fi
	rm -rf "$t"

	# 7. 値に '=' を含むケースが壊れない
	t="$(mktemp -d)"
	make_entrypoint "$t"
	printf 'DATABASE_URL=postgres://u:p@h/db?a=b\n' |
		env GIT_REPO="$BARE_REPO" GIT_REF="$COMMIT_SHA" "$t/entrypoint.sh" true >/dev/null 2>&1
	if [ -f "$t/secrets/DATABASE_URL" ] &&
		[ "$(cat "$t/secrets/DATABASE_URL")" = "postgres://u:p@h/db?a=b" ]; then
		ok "値に '=' を含む行が壊れない"
	else
		ng "値に '=' を含む行が壊れない (got: $(cat "$t/secrets/DATABASE_URL" 2>/dev/null))"
	fi
	rm -rf "$t"

	# 8. CRLF 行 -> 値末尾に \r が残らない
	t="$(mktemp -d)"
	make_entrypoint "$t"
	printf 'FOO=bar\r\n' |
		env GIT_REPO="$BARE_REPO" GIT_REF="$COMMIT_SHA" "$t/entrypoint.sh" true >/dev/null 2>&1
	if [ -f "$t/secrets/FOO" ]; then
		got="$(cat "$t/secrets/FOO")"
		got_hex="$(printf '%s' "$got" | od -An -tx1 | tr -d ' \n')"
		bar_hex="$(printf 'bar' | od -An -tx1 | tr -d ' \n')"
		if [ "$got_hex" = "$bar_hex" ]; then
			ok "CRLF 行 -> 値末尾に \\r が残らない"
		else
			ng "CRLF 行 -> 値末尾に \\r が残らない (hex got=$got_hex want=$bar_hex)"
		fi
	else
		ng "CRLF 行 -> 値末尾に \\r が残らない (ファイルが無い)"
	fi
	rm -rf "$t"

	# 9. ダブルクォート / シングルクォートの剥がし
	t="$(mktemp -d)"
	make_entrypoint "$t"
	printf 'DQ="double"\nSQ='"'"'single'"'"'\n' |
		env GIT_REPO="$BARE_REPO" GIT_REF="$COMMIT_SHA" "$t/entrypoint.sh" true >/dev/null 2>&1
	if [ "$(cat "$t/secrets/DQ" 2>/dev/null)" = "double" ]; then
		ok "ダブルクォートの値が剥がされる"
	else
		ng "ダブルクォートの値が剥がされる (got: $(cat "$t/secrets/DQ" 2>/dev/null))"
	fi
	if [ "$(cat "$t/secrets/SQ" 2>/dev/null)" = "single" ]; then
		ok "シングルクォートの値が剥がされる"
	else
		ng "シングルクォートの値が剥がされる (got: $(cat "$t/secrets/SQ" 2>/dev/null))"
	fi
	rm -rf "$t"

	# 10. /src が非空・.git 無しの状態 (前回失敗の残骸) から復帰できる
	t="$(mktemp -d)"
	make_entrypoint "$t"
	mkdir -p "$t/src/leftover-dir"
	printf 'leftover\n' >"$t/src/leftover-file"
	out="$(printf 'FOO=bar\n' |
		env GIT_REPO="$BARE_REPO" GIT_REF="$COMMIT_SHA" "$t/entrypoint.sh" true 2>&1)"
	rc=$?
	if [ "$rc" -eq 0 ] && [ -f "$t/src/file.txt" ]; then
		ok "/src 非空・.git 無しの残骸からでも復帰できる"
	else
		ng "/src 非空・.git 無しの残骸からでも復帰できる (rc=$rc out=$out)"
	fi
	rm -rf "$t"

	# 11. remote 再実行時の冪等性 (volume 再利用): 二回連続で実行しても
	#     成功し、remote origin の URL が指定どおりであること。
	t="$(mktemp -d)"
	make_entrypoint "$t"
	printf 'FOO=bar\n' |
		env GIT_REPO="$BARE_REPO" GIT_REF="$COMMIT_SHA" "$t/entrypoint.sh" true >/dev/null 2>&1
	out="$(printf 'FOO=bar\n' |
		env GIT_REPO="$BARE_REPO" GIT_REF="$COMMIT_SHA" "$t/entrypoint.sh" true 2>&1)"
	rc=$?
	url="$(git -C "$t/src" remote get-url origin 2>/dev/null)"
	if [ "$rc" -eq 0 ] && [ "$url" = "$BARE_REPO" ]; then
		ok "volume 再利用 (二回目の実行) でも remote が冪等に設定される"
	else
		ng "volume 再利用 (二回目の実行) でも remote が冪等に設定される (rc=$rc url=$url out=$out)"
	fi
	rm -rf "$t"

	# 12. named volume 再利用時に tracked file の改変が復元される
	#     (regression: rev.4 §4.6 / §10)。一度 entrypoint を走らせた後、
	#     /src 内の tracked file を書き換え、同じ GIT_REF で再実行し、
	#     内容が ref のものへ戻っていることを確認する。`checkout --detach`
	#     単体では HEAD が既に同じ commit を指していると working tree を
	#     復元しないため、`reset --hard` を欠くとこのテストは落ちる。
	t="$(mktemp -d)"
	make_entrypoint "$t"
	printf 'FOO=bar\n' |
		env GIT_REPO="$BARE_REPO" GIT_REF="$COMMIT_SHA" "$t/entrypoint.sh" true >/dev/null 2>&1
	# prod で走ったコードが自分のソースを書き換えたことを模す。
	printf 'tampered-by-prod-code\n' >"$t/src/file.txt"
	out="$(printf 'FOO=bar\n' |
		env GIT_REPO="$BARE_REPO" GIT_REF="$COMMIT_SHA" "$t/entrypoint.sh" true 2>&1)"
	rc=$?
	if [ "$rc" -eq 0 ] && [ "$(cat "$t/src/file.txt" 2>/dev/null)" = "hello" ]; then
		ok "named volume 再利用時に tracked file の改変が復元される"
	else
		ng "named volume 再利用時に tracked file の改変が復元される (rc=$rc content=$(cat "$t/src/file.txt" 2>/dev/null) out=$out)"
	fi
	rm -rf "$t"

	# 13. 存在しない ref -> 非ゼロ終了、かつ原因の読み取れるメッセージが出る
	#     (regression: バグ4)。修正前は GIT_REF が commit として解決
	#     できないとき、`git checkout --detach --force "$GIT_REF"` が
	#     ref 解決に失敗した結果 $GIT_REF をパス引数と解釈し、
	#     "fatal: git checkout: --detach does not take a path argument
	#     '<ref>'" という、原因 (指定 ref が存在しない) の読み取れない
	#     メッセージで落ちていた。fetch 直後に `rev-parse --verify` で
	#     解決可能性を検証し、"does not resolve" という明示的なメッセージ
	#     で落ちるようにした。
	t="$(mktemp -d)"
	make_entrypoint "$t"
	out="$(printf 'FOO=bar\n' |
		env GIT_REPO="$BARE_REPO" GIT_REF="v9.9.9-does-not-exist" "$t/entrypoint.sh" true 2>&1)"
	rc=$?
	if [ "$rc" -ne 0 ] &&
		printf '%s\n' "$out" | grep -q "does not resolve" &&
		! printf '%s\n' "$out" | grep -q -- "--detach does not take a path argument"; then
		ok "存在しない ref -> 'does not resolve' で非ゼロ終了 (--detach のパス引数エラーではない)"
	else
		ng "存在しない ref -> 'does not resolve' で非ゼロ終了 (--detach のパス引数エラーではない) (rc=$rc out=$out)"
	fi
	rm -rf "$t"
else
	skip "正常系 (secret 保存 / mode 600 / GH_TOKEN 削除 / checkout 復元): git 不在のため未検証"
	skip "値に '=' を含む行が壊れない: git 不在のため未検証 (checkout まで到達できない)"
	skip "CRLF 行の \\r 除去: git 不在のため未検証"
	skip "クォート剥がし: git 不在のため未検証"
	skip "/src 残骸からの復帰: git 不在のため未検証"
	skip "remote 冪等性: git 不在のため未検証"
	skip "named volume 再利用時に tracked file の改変が復元される: git 不在のため未検証"
	skip "存在しない ref -> 明示的なエラーメッセージ: git 不在のため未検証"
fi

# --- 後始末 ----------------------------------------------------------------------
if [ "$HAVE_GIT" -eq 1 ]; then
	rm -rf "$BARE_ROOT" "$WORK_ROOT"
fi

# --- result ------------------------------------------------------------------

printf '\n%s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
