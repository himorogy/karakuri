#!/usr/bin/env bash
#
# bin/secrets-ingest.sh (stdin の dotenv 取込) を docker なしで検証する。
#
# 取込スクリプトは /run/secrets を絶対パスでハードコードしているため、
# shim.test.sh と同じ考え方で、テストごとに一意な tmpdir へ sed で
# 書き換えたコピーを使う。方言の正常系 (値中の '='、引用符剥がし、CRLF、
# 空行・コメント無視) と異常系 ('=' 無し行、不正鍵名、export 接頭辞、
# 空値、取込 0 件)、および「エラー時に入力行の内容が stderr に反射され
# ない」ことを見る。
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INGEST_SRC="$SCRIPT_DIR/bin/secrets-ingest.sh"

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

# make_ingest <tmpdir> -> $tmpdir/secrets-ingest.sh に、/run/secrets を
# tmpdir 配下へ差し替えたコピーを作る。
make_ingest() {
	local dir="$1"
	mkdir -p "$dir/secrets"
	sed \
		-e "s#/run/secrets#$dir/secrets#g" \
		"$INGEST_SRC" >"$dir/secrets-ingest.sh"
	chmod +x "$dir/secrets-ingest.sh"
}

# --- 1. 正常系: 複数鍵の取込、mode 600、鍵名だけの stderr 出力 -------------------
t="$(mktemp -d)"
make_ingest "$t"
err="$(printf 'GH_TOKEN=tok-value\nCLOUDFLARE_API_TOKEN=cf-value\n' |
	"$t/secrets-ingest.sh" 2>&1 1>/dev/null)"
rc=$?
if [ "$rc" -eq 0 ] &&
	[ "$(cat "$t/secrets/GH_TOKEN" 2>/dev/null)" = "tok-value" ] &&
	[ "$(cat "$t/secrets/CLOUDFLARE_API_TOKEN" 2>/dev/null)" = "cf-value" ]; then
	ok "正常系: 複数鍵が /run/secrets 相当へ書かれる"
else
	ng "正常系: 複数鍵が /run/secrets 相当へ書かれる (rc=$rc err=$err)"
fi

mode="$(stat -c '%a' "$t/secrets/GH_TOKEN" 2>/dev/null || stat -f '%Lp' "$t/secrets/GH_TOKEN" 2>/dev/null)"
if [ "$mode" = "600" ]; then
	ok "正常系: 生成された secret ファイルが mode 600"
else
	ng "正常系: 生成された secret ファイルが mode 600 (mode=$mode)"
fi

if printf '%s\n' "$err" | grep -q "^secrets-ingest: injected: GH_TOKEN CLOUDFLARE_API_TOKEN$"; then
	ok "正常系: 取込完了時に鍵名だけの 1 行が stderr に出る"
else
	ng "正常系: 取込完了時に鍵名だけの 1 行が stderr に出る (err=$err)"
fi

# 否定対照 (値の非漏えい): 鍵名は出るが、値は stderr のどこにも出ない。
# 値の目印文字列がファイルには書かれている (= 目印がパーサを実際に通過
# した) ことを併せて確かめ、「grep 対象の取り違えで緑」を防ぐ。
if printf '%s\n' "$err" | grep -q "tok-value\|cf-value"; then
	ng "正常系: stderr に値が出ない (err=$err)"
else
	ok "正常系: stderr に値が出ない (鍵名のみ)"
fi
rm -rf "$t"

# --- 2. 値中の '=' が壊れない ----------------------------------------------------
t="$(mktemp -d)"
make_ingest "$t"
printf 'DATABASE_URL=postgres://u:p@h/db?a=b\n' | "$t/secrets-ingest.sh" 2>/dev/null
if [ "$(cat "$t/secrets/DATABASE_URL" 2>/dev/null)" = "postgres://u:p@h/db?a=b" ]; then
	ok "値に '=' を含む行が壊れない"
else
	ng "値に '=' を含む行が壊れない (got: $(cat "$t/secrets/DATABASE_URL" 2>/dev/null))"
fi
rm -rf "$t"

# --- 3. ダブルクォート / シングルクォートの剥がし --------------------------------
t="$(mktemp -d)"
make_ingest "$t"
printf 'DQ="double"\nSQ='"'"'single'"'"'\n' | "$t/secrets-ingest.sh" 2>/dev/null
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

# --- 4. CRLF 行 -> 値末尾に \r が残らない ----------------------------------------
t="$(mktemp -d)"
make_ingest "$t"
printf 'FOO=bar\r\n' | "$t/secrets-ingest.sh" 2>/dev/null
got_hex="$(od -An -tx1 <"$t/secrets/FOO" 2>/dev/null | tr -d ' \n')"
bar_hex="$(printf 'bar' | od -An -tx1 | tr -d ' \n')"
if [ "$got_hex" = "$bar_hex" ]; then
	ok "CRLF 行 -> 値末尾に \\r が残らない"
else
	ng "CRLF 行 -> 値末尾に \\r が残らない (hex got=$got_hex want=$bar_hex)"
fi
rm -rf "$t"

# --- 5. 空行と '#' コメント行は無視される (取込件数にも入らない) -----------------
t="$(mktemp -d)"
make_ingest "$t"
err="$(printf '\n# comment line\nFOO=bar\n\n# another\n' |
	"$t/secrets-ingest.sh" 2>&1 1>/dev/null)"
rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat "$t/secrets/FOO" 2>/dev/null)" = "bar" ] &&
	printf '%s\n' "$err" | grep -q "^secrets-ingest: injected: FOO$"; then
	ok "空行・コメント行は無視され、取込一覧にも現れない"
else
	ng "空行・コメント行は無視され、取込一覧にも現れない (rc=$rc err=$err)"
fi
rm -rf "$t"

# --- 6. '=' 無し行 -> 非ゼロ終了 -------------------------------------------------
t="$(mktemp -d)"
make_ingest "$t"
err="$(printf 'not-a-kv-line\n' | "$t/secrets-ingest.sh" 2>&1 1>/dev/null)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$err" | grep -q "missing '='"; then
	ok "'=' 無し行 -> 非ゼロ終了"
else
	ng "'=' 無し行 -> 非ゼロ終了 (rc=$rc err=$err)"
fi
rm -rf "$t"

# --- 7. 不正な鍵名 -> 非ゼロ終了 (パストラバーサル対策込み) ----------------------
for bad_key_line in '../etc/passwd=x' 'A/B=x' '1FOO=x' 'FOO-BAR=x'; do
	t="$(mktemp -d)"
	make_ingest "$t"
	err="$(printf '%s\n' "$bad_key_line" | "$t/secrets-ingest.sh" 2>&1 1>/dev/null)"
	rc=$?
	if [ "$rc" -ne 0 ] && printf '%s\n' "$err" | grep -q "invalid"; then
		ok "不正な鍵名 -> 非ゼロ終了: $bad_key_line"
	else
		ng "不正な鍵名 -> 非ゼロ終了: $bad_key_line (rc=$rc err=$err)"
	fi
	rm -rf "$t"
done

# --- 8. 'export ' 接頭辞は非対応 -> 非ゼロ終了 -----------------------------------
#     方言は 1 行 1 変数の KEY=value のみ。"export FOO=bar" は鍵名が
#     "export FOO" (空白を含む) になり、鍵名検査で弾かれる。
t="$(mktemp -d)"
make_ingest "$t"
err="$(printf 'export FOO=bar\n' | "$t/secrets-ingest.sh" 2>&1 1>/dev/null)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$err" | grep -q "invalid" &&
	[ ! -e "$t/secrets/FOO" ]; then
	ok "'export ' 接頭辞 -> 非ゼロ終了 (ファイルも書かれない)"
else
	ng "'export ' 接頭辞 -> 非ゼロ終了 (rc=$rc err=$err)"
fi
rm -rf "$t"

# --- 9. 空値 (KEY=) -> 非ゼロ終了 ------------------------------------------------
t="$(mktemp -d)"
make_ingest "$t"
err="$(printf 'FOO=\n' | "$t/secrets-ingest.sh" 2>&1 1>/dev/null)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$err" | grep -q "empty secret"; then
	ok "空値 (KEY=) -> 非ゼロ終了"
else
	ng "空値 (KEY=) -> 非ゼロ終了 (rc=$rc err=$err)"
fi
rm -rf "$t"

# --- 10. 取込 0 件 (stdin 空) -> 非ゼロ終了、injected 行も出ない -----------------
t="$(mktemp -d)"
make_ingest "$t"
err="$(printf '' | "$t/secrets-ingest.sh" 2>&1 1>/dev/null)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$err" | grep -q "no secrets received on stdin" &&
	! printf '%s\n' "$err" | grep -q "injected"; then
	ok "取込 0 件 -> 非ゼロ終了 (injected 行も出ない)"
else
	ng "取込 0 件 -> 非ゼロ終了 (rc=$rc err=$err)"
fi
rm -rf "$t"

# コメントだけで 1 件も来ない場合も同じ扱い。
t="$(mktemp -d)"
make_ingest "$t"
err="$(printf '# only comments\n\n' | "$t/secrets-ingest.sh" 2>&1 1>/dev/null)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$err" | grep -q "no secrets received on stdin"; then
	ok "コメントと空行のみ (実質 0 件) -> 非ゼロ終了"
else
	ng "コメントと空行のみ (実質 0 件) -> 非ゼロ終了 (rc=$rc err=$err)"
fi
rm -rf "$t"

# --- 11. エラー時に入力行の内容が stderr に反射されない --------------------------
#     broker の出力が壊れて "KEY=" の形になっていない場合、その行は secret
#     本体そのものでありうる。目印文字列を含む壊れた行を与え、stderr に
#     その文字列そのものが現れないことを確認する。
t="$(mktemp -d)"
make_ingest "$t"
marker="SUPERSECRETVALUE_NO_EQUALS_$$"
err="$(printf '%s\n' "$marker" | "$t/secrets-ingest.sh" 2>&1 1>/dev/null)"
rc=$?
if [ "$rc" -ne 0 ] && ! printf '%s\n' "$err" | grep -q "$marker"; then
	ok "パース失敗メッセージに入力行 (目印文字列) が出ない"
else
	ng "パース失敗メッセージに入力行 (目印文字列) が出ない (rc=$rc err=$err)"
fi
rm -rf "$t"

# 不正な鍵名の場合も同様に、鍵名 (これも壊れた入力の断片) を反射しない。
t="$(mktemp -d)"
make_ingest "$t"
marker="SUPERSECRETKEYVALUE_$$"
err="$(printf '1%s=x\n' "$marker" | "$t/secrets-ingest.sh" 2>&1 1>/dev/null)"
rc=$?
if [ "$rc" -ne 0 ] && ! printf '%s\n' "$err" | grep -q "$marker"; then
	ok "不正な鍵名のメッセージに鍵名 (目印文字列) が出ない"
else
	ng "不正な鍵名のメッセージに鍵名 (目印文字列) が出ない (rc=$rc err=$err)"
fi
rm -rf "$t"

# --- 12. 再実行は上書き (冪等) ---------------------------------------------------
#     dev への注入はコンテナを起動するたびに打ち直す運用であり、二回目の
#     実行が「既にある」で失敗したり古い値を残したりしないこと。
t="$(mktemp -d)"
make_ingest "$t"
printf 'FOO=first\n' | "$t/secrets-ingest.sh" 2>/dev/null
printf 'FOO=second\n' | "$t/secrets-ingest.sh" 2>/dev/null
rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat "$t/secrets/FOO" 2>/dev/null)" = "second" ]; then
	ok "再実行で同名の鍵が上書きされる (冪等)"
else
	ng "再実行で同名の鍵が上書きされる (rc=$rc got: $(cat "$t/secrets/FOO" 2>/dev/null))"
fi
rm -rf "$t"

# --- result --------------------------------------------------------------------

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
