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

# --- result --------------------------------------------------------------------

printf '\n%s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
