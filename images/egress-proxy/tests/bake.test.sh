#!/usr/bin/env bash
#
# images/egress-proxy/bin/egress-proxy-bake を docker なしで検証する。
#
# egress-proxy-bake は PATH 上の init-project-firewall.sh を呼ぶだけなので、
# PATH の先頭に packages/egress-guard/scripts/ を置いて本物を使う。出力先
# 2ファイルはテストごとに一意な tmpdir へ EGRESS_PROXY_SQUID_DIR で向ける。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

BAKE="$SCRIPT_DIR/bin/egress-proxy-bake"
SQUID_CONF_SRC="$SCRIPT_DIR/squid.conf"
FIREWALL_SCRIPTS="$REPO_ROOT/packages/egress-guard/scripts"

export PATH="$FIREWALL_SCRIPTS:$PATH"

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

# make_squid_dir -> tmpdir に squid.conf のコピーだけを置いた作業ディレクトリを作る。
# allowed-domains.txt は egress-proxy-bake 自身が作る (Dockerfile では
# touch 済みだが、ここでは無い状態から書けることも兼ねて確かめる)。
make_squid_dir() {
    local dir="$1"
    cp "$SQUID_CONF_SRC" "$dir/squid.conf"
}

# --- (a) enforce: ACL が --print-proxy-acl の出力と一致し、squid.conf は deny のまま ---
t="$(mktemp -d)"
make_squid_dir "$t"
out="$(EGRESS_PROXY_SQUID_DIR="$t" "$BAKE" "$REPO_ROOT/packages/egress-guard/templates/firewall.json" 2>&1)"
rc=$?
expected_acl="$(init-project-firewall.sh --print-proxy-acl --config "$REPO_ROOT/packages/egress-guard/templates/firewall.json" 2>/dev/null)"
if [ "$rc" -eq 0 ] &&
    [ "$(cat "$t/allowed-domains.txt" 2>/dev/null)" = "$expected_acl" ] &&
    grep -q '^http_access deny !allowed$' "$t/squid.conf" &&
    ! grep -q '^http_access allow !allowed$' "$t/squid.conf"; then
    ok "ACL は --print-proxy-acl の出力と一致する"
else
    ng "ACL は --print-proxy-acl の出力と一致する (rc=$rc out=$out)"
fi
if grep -q '^http_access deny !allowed$' "$t/squid.conf"; then
    ok "enforce では拒否のまま"
else
    ng "enforce では拒否のまま"
fi
rm -rf "$t"

# --- (b) audit: allowlist 外の宛先を通す設定になる (deny !allowed -> allow !allowed) ---
t="$(mktemp -d)"
make_squid_dir "$t"
out="$(EGRESS_PROXY_SQUID_DIR="$t" "$BAKE" "$REPO_ROOT/packages/egress-guard/templates/firewall.audit.json" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && grep -q '^http_access allow !allowed$' "$t/squid.conf" &&
    ! grep -q '^http_access deny !allowed$' "$t/squid.conf"; then
    ok "audit では allowlist 外を通す設定になる"
else
    ng "audit では allowlist 外を通す設定になる (rc=$rc out=$out)"
fi
rm -rf "$t"

# --- (c) 壊れた JSON -> 非ゼロ、ACL ファイルが作られない ---
t="$(mktemp -d)"
make_squid_dir "$t"
printf '{ not valid json' >"$t/firewall.json"
out="$(EGRESS_PROXY_SQUID_DIR="$t" "$BAKE" "$t/firewall.json" 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$t/allowed-domains.txt" ]; then
    ok "壊れた設定では非ゼロで終わり ACL を作らない"
else
    ng "壊れた設定では非ゼロで終わり ACL を作らない (rc=$rc out=$out)"
fi
rm -rf "$t"

# --- (d) 引数無し -> 非ゼロ ---
t="$(mktemp -d)"
make_squid_dir "$t"
out="$(EGRESS_PROXY_SQUID_DIR="$t" "$BAKE" 2>&1)"
rc=$?
if [ "$rc" -ne 0 ]; then
    ok "引数無しで非ゼロ"
else
    ng "引数無しで非ゼロ (rc=$rc out=$out)"
fi
rm -rf "$t"

# --- 否定対照: 存在しないファイルを渡しても非ゼロ (usage で弾く経路も通る) ---
t="$(mktemp -d)"
make_squid_dir "$t"
out="$(EGRESS_PROXY_SQUID_DIR="$t" "$BAKE" "$t/does-not-exist.json" 2>&1)"
rc=$?
if [ "$rc" -ne 0 ]; then
    ok "否定対照: 存在しない設定ファイルは非ゼロで終わる"
else
    ng "否定対照: 存在しない設定ファイルは非ゼロで終わる (rc=$rc out=$out)"
fi
rm -rf "$t"

# --- result ------------------------------------------------------------------

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
