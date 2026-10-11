#!/usr/bin/env bash
#
# bin/personal-setup を docker なしで検証する。
#
# PERSONAL_SETUP_HOOK でフックのパスを差し替え、git-identity.test.sh と同様に
# 実 /personal/setup.sh に触れずに固定する。
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SETUP_SRC="$SCRIPT_DIR/bin/personal-setup"

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

die() {
    printf 'FATAL %s\n' "$1" >&2
    exit 1
}

[ -f "$SETUP_SRC" ] || die "検査対象のファイルが無い: $SETUP_SRC"

# --- 1. フックがあれば呼び出し元のユーザーで実行して終了コードを返す --------------
t="$(mktemp -d)"
{
    printf '#!/bin/sh\n'
    printf 'id -u > "%s/hook-ran-as-uid"\n' "$t"
    printf 'exit 7\n'
} >"$t/hook.sh"
chmod +x "$t/hook.sh"
PERSONAL_SETUP_HOOK="$t/hook.sh" sh "$SETUP_SRC"
rc=$?
ran_uid="$(cat "$t/hook-ran-as-uid" 2>/dev/null || true)"
want_uid="$(id -u)"
if [ "$rc" -eq 7 ] && [ "$ran_uid" = "$want_uid" ]; then
    ok "フックがあれば呼び出し元のユーザーで実行して終了コードを返す"
else
    ng "フックがあれば呼び出し元のユーザーで実行して終了コードを返す (rc=$rc ran_uid=$ran_uid want=$want_uid)"
fi
rm -rf "$t"

# --- 2. フックが無ければ何もせず 0 で終わる -------------------------------------
t="$(mktemp -d)"
PERSONAL_SETUP_HOOK="$t/no-such-hook.sh" sh "$SETUP_SRC"
rc=$?
if [ "$rc" -eq 0 ]; then
    ok "フックが無ければ何もせず 0 で終わる"
else
    ng "フックが無ければ何もせず 0 で終わる (rc=$rc)"
fi
rm -rf "$t"

# --- 3. 実行可能でないフックは実行せず 0 で終わる -------------------------------
t="$(mktemp -d)"
{
    printf '#!/bin/sh\n'
    printf 'touch "%s/hook-ran"\n' "$t"
} >"$t/hook.sh"
# 実行ビットは付けない。
PERSONAL_SETUP_HOOK="$t/hook.sh" sh "$SETUP_SRC"
rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$t/hook-ran" ]; then
    ok "実行可能でないフックは実行せず 0 で終わる"
else
    hook_ran="no"
    [ -e "$t/hook-ran" ] && hook_ran="yes"
    ng "実行可能でないフックは実行せず 0 で終わる (rc=$rc hook-ran=$hook_ran)"
fi
rm -rf "$t"

# --- result ------------------------------------------------------------------

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
