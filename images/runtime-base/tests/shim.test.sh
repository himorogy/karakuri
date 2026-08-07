#!/usr/bin/env bash
#
# shims/{wrangler,gh,dotenvx} の三値意味論 (存在→注入 / 空→エラー /
# 不在→素通し) を docker なしで検証する。
#
# shim は /run/secrets/<VAR> と /opt/tools/bin/<name> を絶対パスで
# ハードコードしているため、実際のコンテナ外でそのまま実行すると
# ホストの /run や /opt を触ってしまう。そこで shim を tmpdir へ
# sed でコピーし、両方のパスをテストごとに一意な tmpdir 配下へ
# 書き換えてから実行する。実体バイナリの代わりには、呼び出された
# ことと引き継いだ環境変数を可視化するだけのフェイクスクリプトを置く。
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SHIMS_DIR="$SCRIPT_DIR/shims"

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

# root で走ると chmod 000 でも読めてしまうため、mode 000 テストは root では
# 意味を失う。skip してその旨を明示する。
IS_ROOT=0
if [ "$(id -u)" -eq 0 ]; then
	IS_ROOT=1
fi

# make_shim <name> <tmpdir> -> $tmpdir/bin/<name> に、/run/secrets と
# /opt/tools/bin を tmpdir 配下へ差し替えたコピーを作る。
make_shim() {
	local name="$1" dir="$2"
	mkdir -p "$dir/bin" "$dir/secrets" "$dir/tools"
	sed \
		-e "s#/run/secrets#$dir/secrets#g" \
		-e "s#/opt/tools/bin#$dir/tools#g" \
		"$SHIMS_DIR/$name" >"$dir/bin/$name"
	chmod +x "$dir/bin/$name"
}

# fake_real <name> <tmpdir> -> $tmpdir/tools/<name> に、呼ばれたことと
# 引き継いだ環境を可視化するだけのフェイク実体を置く。実際の wrangler /
# gh / dotenvx を呼ぶ必要はなく、shim が何をどう注入したかだけが焦点。
fake_real() {
	local name="$1" dir="$2"
	mkdir -p "$dir/tools"
	{
		printf '#!/bin/sh\n'
		printf 'echo "REAL:%s"\n' "$name"
		printf 'env\n'
	} >"$dir/tools/$name"
	chmod +x "$dir/tools/$name"
}

# --- wrangler / gh: 共通パターンの三値意味論 ----------------------------------
# check_var_shim <shim名> <secret変数名>
check_var_shim() {
	local name="$1" var="$2" t out rc

	echo "$name shim"

	# 1. secret ファイルが存在する -> 対象変数が注入されて実体が呼ばれる
	t="$(mktemp -d)"
	make_shim "$name" "$t"
	fake_real "$name" "$t"
	printf 'injected-secret-value' >"$t/secrets/$var"
	out="$(env "$var=stale-value" "$t/bin/$name" 2>&1)"
	rc=$?
	if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -qx "$var=injected-secret-value"; then
		ok "$name: secret ファイル存在 -> $var が注入される"
	else
		ng "$name: secret ファイル存在 -> $var が注入される (rc=$rc out=$out)"
	fi
	rm -rf "$t"

	# 2. secret ファイルが空 -> 非ゼロ終了、stderr に empty secret
	t="$(mktemp -d)"
	make_shim "$name" "$t"
	fake_real "$name" "$t"
	: >"$t/secrets/$var"
	out="$("$t/bin/$name" 2>&1 1>/dev/null)"
	rc=$?
	if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q "empty secret"; then
		ok "$name: secret ファイルが空 -> 非ゼロ終了 + empty secret"
	else
		ng "$name: secret ファイルが空 -> 非ゼロ終了 + empty secret (rc=$rc out=$out)"
	fi
	# 実体が呼ばれていないこと (呼ばれていれば REAL: 行が出るはず)
	if ! printf '%s\n' "$out" | grep -q "^REAL:"; then
		ok "$name: secret ファイルが空のとき実体は呼ばれない"
	else
		ng "$name: secret ファイルが空のとき実体は呼ばれない (out=$out)"
	fi
	rm -rf "$t"

	# 3. secret ファイルが不在 -> 素通しし、呼び出し元の環境変数がそのまま
	#    引き継がれる (dev container の既存注入方式が env var でも壊れない)
	t="$(mktemp -d)"
	make_shim "$name" "$t"
	fake_real "$name" "$t"
	out="$(env "$var=already-set-by-dev-injection" "$t/bin/$name" 2>&1)"
	rc=$?
	if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -qx "$var=already-set-by-dev-injection"; then
		ok "$name: secret ファイル不在 -> 素通しで既存 $var を引き継ぐ"
	else
		ng "$name: secret ファイル不在 -> 素通しで既存 $var を引き継ぐ (rc=$rc out=$out)"
	fi
	rm -rf "$t"

	# 4. NODE_OPTIONS は両分岐 (注入あり / 素通し) で消えている
	t="$(mktemp -d)"
	make_shim "$name" "$t"
	fake_real "$name" "$t"
	printf 'injected-secret-value' >"$t/secrets/$var"
	out="$(env NODE_OPTIONS='--max-old-space-size=4096' "$t/bin/$name" 2>&1)"
	if ! printf '%s\n' "$out" | grep -q '^NODE_OPTIONS='; then
		ok "$name: 注入あり分岐で NODE_OPTIONS が消えている"
	else
		ng "$name: 注入あり分岐で NODE_OPTIONS が消えている (out=$out)"
	fi
	rm -rf "$t"

	t="$(mktemp -d)"
	make_shim "$name" "$t"
	fake_real "$name" "$t"
	out="$(env NODE_OPTIONS='--max-old-space-size=4096' "$t/bin/$name" 2>&1)"
	if ! printf '%s\n' "$out" | grep -q '^NODE_OPTIONS='; then
		ok "$name: 素通し分岐で NODE_OPTIONS が消えている"
	else
		ng "$name: 素通し分岐で NODE_OPTIONS が消えている (out=$out)"
	fi
	rm -rf "$t"

	# 5. secret ファイルが存在・非空だが読めない (mode 000) -> 空値注入で
	#    はなく非ゼロ終了する (regression: rev.4 §4.3)。`exec env
	#    VAR="$(cat "$f")" ...` の形だと cat の失敗が set -e に捕捉されず、
	#    空値が注入されたまま実体が呼ばれてしまう。root で走ると chmod 000
	#    でも読めてしまい検証にならないため skip する。
	if [ "$IS_ROOT" -eq 1 ]; then
		skip "$name: secret ファイルが読めない (mode 000) -> 非ゼロ終了 (root のため skip)"
	else
		t="$(mktemp -d)"
		make_shim "$name" "$t"
		fake_real "$name" "$t"
		printf 'unreadable-secret-value' >"$t/secrets/$var"
		chmod 000 "$t/secrets/$var"
		out="$("$t/bin/$name" 2>&1 1>/dev/null)"
		rc=$?
		if [ "$rc" -ne 0 ] && ! printf '%s\n' "$out" | grep -q "^REAL:"; then
			ok "$name: secret ファイルが読めない (mode 000) -> 非ゼロ終了 (空値注入ではない)"
		else
			ng "$name: secret ファイルが読めない (mode 000) -> 非ゼロ終了 (空値注入ではない) (rc=$rc out=$out)"
		fi
		rm -rf "$t"
	fi
}

check_var_shim wrangler CLOUDFLARE_API_TOKEN
check_var_shim gh GH_TOKEN

# --- dotenvx: DOTENV_PRIVATE_KEY_* の汎用ループ -------------------------------
echo "dotenvx shim"

# 5. DOTENV_PRIVATE_KEY_LOCAL と DOTENV_PRIVATE_KEY_DEVELOPMENT を同時に
#    置くと両方 export される (dev container で _LOCAL + _DEVELOPMENT が
#    同居する想定)
t="$(mktemp -d)"
make_shim dotenvx "$t"
fake_real dotenvx "$t"
printf 'key-local' >"$t/secrets/DOTENV_PRIVATE_KEY_LOCAL"
printf 'key-development' >"$t/secrets/DOTENV_PRIVATE_KEY_DEVELOPMENT"
out="$("$t/bin/dotenvx" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] &&
	printf '%s\n' "$out" | grep -qx "DOTENV_PRIVATE_KEY_LOCAL=key-local" &&
	printf '%s\n' "$out" | grep -qx "DOTENV_PRIVATE_KEY_DEVELOPMENT=key-development"; then
	ok "dotenvx: 複数の DOTENV_PRIVATE_KEY_* が同時に export される"
else
	ng "dotenvx: 複数の DOTENV_PRIVATE_KEY_* が同時に export される (rc=$rc out=$out)"
fi
rm -rf "$t"

# 6. glob 不一致 (該当ファイルなし) は素通し
t="$(mktemp -d)"
make_shim dotenvx "$t"
fake_real dotenvx "$t"
out="$(env SOME_OTHER_VAR=untouched "$t/bin/dotenvx" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -qx "SOME_OTHER_VAR=untouched"; then
	ok "dotenvx: DOTENV_PRIVATE_KEY_* が無いときは素通し"
else
	ng "dotenvx: DOTENV_PRIVATE_KEY_* が無いときは素通し (rc=$rc out=$out)"
fi
rm -rf "$t"

# 7. 空ファイルが一つでもあれば非ゼロ終了 + empty secret
t="$(mktemp -d)"
make_shim dotenvx "$t"
fake_real dotenvx "$t"
printf 'key-local' >"$t/secrets/DOTENV_PRIVATE_KEY_LOCAL"
: >"$t/secrets/DOTENV_PRIVATE_KEY_DEVELOPMENT"
out="$("$t/bin/dotenvx" 2>&1 1>/dev/null)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q "empty secret"; then
	ok "dotenvx: DOTENV_PRIVATE_KEY_* の一つが空なら非ゼロ終了"
else
	ng "dotenvx: DOTENV_PRIVATE_KEY_* の一つが空なら非ゼロ終了 (rc=$rc out=$out)"
fi
rm -rf "$t"

# 8. NODE_OPTIONS は dotenvx でも消える (素通し / 注入あり 両方)
t="$(mktemp -d)"
make_shim dotenvx "$t"
fake_real dotenvx "$t"
out="$(env NODE_OPTIONS='--max-old-space-size=4096' "$t/bin/dotenvx" 2>&1)"
if ! printf '%s\n' "$out" | grep -q '^NODE_OPTIONS='; then
	ok "dotenvx: 素通し分岐で NODE_OPTIONS が消えている"
else
	ng "dotenvx: 素通し分岐で NODE_OPTIONS が消えている (out=$out)"
fi
rm -rf "$t"

t="$(mktemp -d)"
make_shim dotenvx "$t"
fake_real dotenvx "$t"
printf 'key-local' >"$t/secrets/DOTENV_PRIVATE_KEY_LOCAL"
out="$(env NODE_OPTIONS='--max-old-space-size=4096' "$t/bin/dotenvx" 2>&1)"
if ! printf '%s\n' "$out" | grep -q '^NODE_OPTIONS='; then
	ok "dotenvx: 注入あり分岐で NODE_OPTIONS が消えている"
else
	ng "dotenvx: 注入あり分岐で NODE_OPTIONS が消えている (out=$out)"
fi
rm -rf "$t"

# 9. secret ファイルが存在・非空だが読めない (mode 000) -> 空値注入では
#    なく非ゼロ終了する (regression: rev.4 §4.3)。`export "NAME=$(cat
#    "$f")"` の形だと cat の失敗が set -e に捕捉されない。root で走ると
#    chmod 000 でも読めてしまい検証にならないため skip する。
if [ "$IS_ROOT" -eq 1 ]; then
	skip "dotenvx: secret ファイルが読めない (mode 000) -> 非ゼロ終了 (root のため skip)"
else
	t="$(mktemp -d)"
	make_shim dotenvx "$t"
	fake_real dotenvx "$t"
	printf 'unreadable-secret-value' >"$t/secrets/DOTENV_PRIVATE_KEY_PROD"
	chmod 000 "$t/secrets/DOTENV_PRIVATE_KEY_PROD"
	out="$("$t/bin/dotenvx" 2>&1 1>/dev/null)"
	rc=$?
	if [ "$rc" -ne 0 ] && ! printf '%s\n' "$out" | grep -q "^REAL:"; then
		ok "dotenvx: secret ファイルが読めない (mode 000) -> 非ゼロ終了 (空値注入ではない)"
	else
		ng "dotenvx: secret ファイルが読めない (mode 000) -> 非ゼロ終了 (空値注入ではない) (rc=$rc out=$out)"
	fi
	rm -rf "$t"
fi

# --- dotenvx: --strict 忘れの警告 ------------------------------------------------
#
# dotenvx は復号に失敗しても rc=0 で暗号文をそのまま値として注入する。
# イメージ側では `--strict` を強制しない (`--convention flow` のような正当な
# 重ね掛けを壊すため) が、prod 鍵が注入された状態で `--strict` 無しの run が
# 走ったときは黙らせない、というのがここの仕様。判定は「環境」ではなく
# 「prod 鍵ファイルが観測できるか」で行う。

# fake_real_argv <name> <tmpdir> -> 受け取った引数を1行1個で出力し、
# FAKE_REAL_RC で指定された終了コードで抜けるフェイク実体を置く。警告の有無で
# 実体への引数と rc が変わらないことを見るために使う。終了コードを環境変数で
# 渡すのは、shim の `exec env -u NODE_OPTIONS ...` が NODE_OPTIONS 以外の
# 環境をそのまま実体へ引き継ぐため。
fake_real_argv() {
	local name="$1" dir="$2"
	mkdir -p "$dir/tools"
	cat >"$dir/tools/$name" <<'FAKE_ARGV'
#!/bin/sh
for a in "$@"; do printf 'ARGV:%s\n' "$a"; done
exit "${FAKE_REAL_RC:-0}"
FAKE_ARGV
	chmod +x "$dir/tools/$name"
}

# 10. prod 鍵が注入済み + run + --strict 無し -> 警告が stderr に出る
t="$(mktemp -d)"
make_shim dotenvx "$t"
fake_real dotenvx "$t"
printf 'key-prod' >"$t/secrets/DOTENV_PRIVATE_KEY_PROD"
err="$("$t/bin/dotenvx" run -- node -e 1 2>&1 1>/dev/null)"
rc=$?
if [ "$rc" -eq 0 ] &&
	printf '%s\n' "$err" | grep -q "WARNING" &&
	printf '%s\n' "$err" | grep -q -- "--strict"; then
	ok "dotenvx: prod 鍵注入済み + run + --strict 無し -> 警告が出る"
else
	ng "dotenvx: prod 鍵注入済み + run + --strict 無し -> 警告が出る (rc=$rc err=$err)"
fi
# 警告文は設計書を読める人以外にも意味が通る必要がある。設計書内でしか通じ
# ない記号 (I6 / R12 / D15 / §4.3 のような) を混ぜないことの回帰確認。
if ! printf '%s\n' "$err" | grep -qE '§|\b[A-Z][0-9]+\b'; then
	ok "dotenvx: 警告文に設計書内でしか通じない記号が出ない"
else
	ng "dotenvx: 警告文に設計書内でしか通じない記号が出ない (err=$err)"
fi
rm -rf "$t"

# 11. prod 鍵が注入済み + run + --strict あり -> 警告は出ない
t="$(mktemp -d)"
make_shim dotenvx "$t"
fake_real dotenvx "$t"
printf 'key-prod' >"$t/secrets/DOTENV_PRIVATE_KEY_PROD"
err="$("$t/bin/dotenvx" run --strict -- node -e 1 2>&1 1>/dev/null)"
rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s\n' "$err" | grep -q "WARNING"; then
	ok "dotenvx: prod 鍵注入済み + run + --strict あり -> 警告は出ない"
else
	ng "dotenvx: prod 鍵注入済み + run + --strict あり -> 警告は出ない (rc=$rc err=$err)"
fi
rm -rf "$t"

# 12. prod 鍵が不在 (dev 相当) + run + --strict 無し -> 警告は出ない。
#     dev には prod 鍵が来ない設計なので、dev ではこの警告が一度も出ない
#     ことの確認でもある。
t="$(mktemp -d)"
make_shim dotenvx "$t"
fake_real dotenvx "$t"
printf 'key-development' >"$t/secrets/DOTENV_PRIVATE_KEY_DEVELOPMENT"
err="$("$t/bin/dotenvx" run -- node -e 1 2>&1 1>/dev/null)"
rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s\n' "$err" | grep -q "WARNING"; then
	ok "dotenvx: prod 鍵が不在 + run + --strict 無し -> 警告は出ない"
else
	ng "dotenvx: prod 鍵が不在 + run + --strict 無し -> 警告は出ない (rc=$rc err=$err)"
fi
rm -rf "$t"

# 12b. DOTENV_PRIVATE_KEY_PRODUCTION のみ存在 + run + --strict 無し -> 警告が
#      出る。dotenvx のファイル名規約は .env.prod → _PROD、.env.production →
#      _PRODUCTION であり、固定名 _PROD の判定では後者の命名を使うプロジェクト
#      で prod 鍵が注入されているのに警告が黙る (glob 化の回帰確認)。
#      否定対照は上の 12 が担う: glob を広げすぎて DOTENV_PRIVATE_KEY_* 全体に
#      一致するようになれば、_DEVELOPMENT のみの 12 が赤くなる。
t="$(mktemp -d)"
make_shim dotenvx "$t"
fake_real dotenvx "$t"
printf 'key-production' >"$t/secrets/DOTENV_PRIVATE_KEY_PRODUCTION"
err="$("$t/bin/dotenvx" run -- node -e 1 2>&1 1>/dev/null)"
rc=$?
if [ "$rc" -eq 0 ] &&
	printf '%s\n' "$err" | grep -q "WARNING" &&
	printf '%s\n' "$err" | grep -q -- "--strict"; then
	ok "dotenvx: _PRODUCTION のみ注入済み + run + --strict 無し -> 警告が出る"
else
	ng "dotenvx: _PRODUCTION のみ注入済み + run + --strict 無し -> 警告が出る (rc=$rc err=$err)"
fi
rm -rf "$t"

# 13. 警告は動作を変えない: 警告が出る条件でも出ない条件でも、実体が受け取る
#     引数と実体の終了コードが同一であること。
t="$(mktemp -d)"
make_shim dotenvx "$t"
fake_real_argv dotenvx "$t"
printf 'key-prod' >"$t/secrets/DOTENV_PRIVATE_KEY_PROD"
argv_warn="$(env FAKE_REAL_RC=7 "$t/bin/dotenvx" run -- node -e 1 2>/dev/null)"
rc_warn=$?
rm -f "$t/secrets/DOTENV_PRIVATE_KEY_PROD"
argv_quiet="$(env FAKE_REAL_RC=7 "$t/bin/dotenvx" run -- node -e 1 2>/dev/null)"
rc_quiet=$?
expected_argv="$(printf 'ARGV:run\nARGV:--\nARGV:node\nARGV:-e\nARGV:1')"
if [ "$argv_warn" = "$expected_argv" ] && [ "$argv_quiet" = "$expected_argv" ] &&
	[ "$rc_warn" -eq 7 ] && [ "$rc_quiet" -eq 7 ]; then
	ok "dotenvx: 警告の有無で実体への引数と rc が変わらない"
else
	ng "dotenvx: 警告の有無で実体への引数と rc が変わらない (rc_warn=$rc_warn rc_quiet=$rc_quiet argv_warn=$argv_warn argv_quiet=$argv_quiet)"
fi
rm -rf "$t"

# --- result --------------------------------------------------------------------

printf '\n%s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
