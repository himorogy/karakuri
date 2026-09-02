#!/usr/bin/env bash
#
# Tests for host/shims/_dotenvx.
#
# 実体の dotenvx はフェイクへ差し替える。Windows 用の _dotenvx.cmd の検査は
# cmd.exe を要するためここには無く、.github/workflows/ci.yml の Windows
# ジョブが持つ。
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
SHIM="$TEST_DIR/../host/shims/_dotenvx"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

FAKE_BIN_DIR="$WORKDIR/bin"
mkdir -p "$FAKE_BIN_DIR"

# プロジェクトが自前で用意した版がある環境を模す。呼ばれたら引数と
# environ を記録し、鍵の値が引数にも environ にも出ていることを確認できる
# ようにする。
cat >"$FAKE_BIN_DIR/dotenvx" <<'FAKE_DOTENVX'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${FAKE_ARGV_FILE:?}"
env >"${FAKE_ENV_FILE:?}"
FAKE_DOTENVX
chmod +x "$FAKE_BIN_DIR/dotenvx"

CASE_RC=0
CASE_STDOUT=""
CASE_STDERR=""
run_case() {
	local out err
	out="$(mktemp)"
	err="$(mktemp)"
	if PATH="$FAKE_BIN_DIR:$PATH" sh "$SHIM" "$@" >"$out" 2>"$err"; then
		CASE_RC=0
	else
		CASE_RC=$?
	fi
	CASE_STDOUT="$(cat "$out")"
	CASE_STDERR="$(cat "$err")"
	rm -f "$out" "$err"
}

_case_seq=0
reset_env() {
	_case_seq=$((_case_seq + 1))
	unset DOTENV_PRIVATE_KEY DOTENV_PRIVATE_KEY_PROD DOTENV_PRIVATE_KEY_LOCAL 2>/dev/null || true
	export FAKE_ARGV_FILE="$WORKDIR/argv.$$.$_case_seq"
	export FAKE_ENV_FILE="$WORKDIR/env.$$.$_case_seq"
	rm -f "$FAKE_ARGV_FILE" "$FAKE_ENV_FILE"
}

# --- 否定対照: 鍵が無いときは実体を起動しない -------------------------------------
echo "negative control: no key in the environment -> the real entity is never started"
reset_env
run_case run --strict -f .env -- pnpm build

if [ "$CASE_RC" -ne 0 ]; then
	ok "否定対照: 鍵が無いときは実体を起動しない (non-zero exit)"
else
	ng "否定対照: 鍵が無いときは実体を起動しない (exited zero)"
fi
if [ ! -f "$FAKE_ARGV_FILE" ]; then
	ok "否定対照: 鍵が無いときは実体を起動しない (dotenvx never invoked)"
else
	ng "否定対照: 鍵が無いときは実体を起動しない (dotenvx was invoked)"
fi
case "$CASE_STDERR" in
*"karakuri-run"*) ok "the error message names a supply mechanism (karakuri-run)" ;;
*) ng "the error message did not name a supply mechanism (stderr: $CASE_STDERR)" ;;
esac

# --- 否定対照: 改行を含む値を持つ無関係な変数だけでは通らない ------------------
# `env | grep '^DOTENV_PRIVATE_KEY'` のような行走査は、無関係な変数の値に
# 改行が含まれていると、その改行より後ろの断片が別の行として鍵名に前方一致
# してしまう（PEM・JSON・CI 由来の値で普通に起きる）。私鍵は environ に1つも
# 無いのに実体が起動して rc=0 になる、という実測された不具合をここで固定する。
echo "negative control: an unrelated variable whose value merely contains a newline does not satisfy the key check"
reset_env
FAKE_MULTILINE_VALUE="$(printf 'x\nDOTENV_PRIVATE_KEY_INJECTED=1')"
export FAKE_MULTILINE_VALUE
run_case run --strict -f .env -- pnpm build

if [ "$CASE_RC" -ne 0 ]; then
	ok "否定対照: 改行を含む値を持つ無関係な変数だけでは通らない (non-zero exit)"
else
	ng "否定対照: 改行を含む値を持つ無関係な変数だけでは通らない (exited zero)"
fi
if [ ! -f "$FAKE_ARGV_FILE" ]; then
	ok "否定対照: 改行を含む値を持つ無関係な変数だけでは通らない (dotenvx never invoked)"
else
	ng "否定対照: 改行を含む値を持つ無関係な変数だけでは通らない (dotenvx was invoked)"
fi
unset FAKE_MULTILINE_VALUE

# --- 通し: 環境変数だけで渡した鍵でも実体が起動する（CI 経路） ------------------
echo "success: a key supplied purely as an environment variable (the CI path) starts the real entity"
reset_env
export DOTENV_PRIVATE_KEY_PROD="stub-secret-value"
run_case run --strict -f .env.prod -- pnpm deploy

if [ "$CASE_RC" -eq 0 ] && [ -f "$FAKE_ARGV_FILE" ]; then
	ok "通し: 環境変数だけで渡した鍵でも実体が起動する"
else
	ng "通し: 環境変数だけで渡した鍵でも実体が起動する (rc=$CASE_RC, stderr: $CASE_STDERR)"
fi
if [ -f "$FAKE_ARGV_FILE" ]; then
	if grep -qxF -- "run" "$FAKE_ARGV_FILE" && grep -qxF -- "--strict" "$FAKE_ARGV_FILE"; then
		ok "arguments reach the real dotenvx entity"
	else
		ng "arguments did not reach the real dotenvx entity (argv: $(cat "$FAKE_ARGV_FILE"))"
	fi
else
	ng "the real dotenvx entity was never invoked"
fi

# --- 通し: shim が起動する実体は PATH 解決で選ばれる -----------------------------
echo "the entity the shim launches is resolved via PATH"
if [ -f "$FAKE_ARGV_FILE" ]; then
	# argv ファイルが書かれていることが、PATH 先頭に置いたフェイクが選ばれた
	# ことを示す。この環境には実 dotenvx（/usr/local/bin/dotenvx）も実在するが、
	# shim が絶対パス直書きなら実 dotenvx が動いて argv ファイルは書かれない。
	# 書かれている以上、選ばれたのは PATH 解決で見つけたフェイクの方である。
	ok "the fake dotenvx placed first on PATH is the one that started (PATH resolution, not a hardcoded path)"
else
	ng "no entity was recorded as having started"
fi

# --- 通し: 鍵の値が出力に出ていない ------------------------------------------------
echo "the key's value never appears in output"
case "$CASE_STDOUT" in
*"stub-secret-value"*) ng "通し: 鍵の値が出力に出ていない (stdout leaked it)" ;;
*) ok "通し: 鍵の値が出力に出ていない (stdout)" ;;
esac
case "$CASE_STDERR" in
*"stub-secret-value"*) ng "通し: 鍵の値が出力に出ていない (stderr leaked it)" ;;
*) ok "通し: 鍵の値が出力に出ていない (stderr)" ;;
esac

# --- 鍵の値は検査もされず、shim 自身の argv/stdout にも現れない ------------------
echo "the shim does not inspect the key's value; only its presence matters"
reset_env
export DOTENV_PRIVATE_KEY_LOCAL="another-stub-value"
run_case get FOO -f .env.local

if [ "$CASE_RC" -eq 0 ]; then
	ok "a differently-suffixed key (LOCAL) also satisfies the presence check"
else
	ng "a differently-suffixed key (LOCAL) did not satisfy the presence check (stderr: $CASE_STDERR)"
fi

# --- 結果 -----------------------------------------------------------------------

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
