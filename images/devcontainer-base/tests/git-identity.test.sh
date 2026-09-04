#!/usr/bin/env bash
#
# bin/git-identity-setup の identity 導出を docker なしで検証する。
#
# fetch_account_json は GIT_IDENTITY_SETUP_FETCH_CMD が指す実行ファイルの
# 出力に差し替えられるので、gh api や /run/secrets を使わずに組み立て側
# (apply_identity) だけを固定できる。git config の読み書きは GIT_CONFIG_GLOBAL
# で一時ファイルへ隔離し、実行環境の ~/.gitconfig に触れない。
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SETUP_SRC="$SCRIPT_DIR/bin/git-identity-setup"

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

# make_fetch <tmpdir> <出力> -> gh api user の代役を作り、そのパスを返す。
# rc=1 を渡すと非ゼロ終了する代役になる。ヒアドキュメントの区切り語は
# クォートする ('JSON')。クォートしないと展開を受け、出力の $ や \ を
# 含むペイロード (バックスラッシュ入り表示名のケース) を書けない。
make_fetch() {
    local dir="$1" out="$2" rc="${3:-0}"
    {
        printf '#!/bin/sh\n'
        printf "cat <<'JSON'\n%s\nJSON\n" "$out"
        printf 'exit %s\n' "$rc"
    } >"$dir/fetch.sh"
    chmod +x "$dir/fetch.sh"
    printf '%s' "$dir/fetch.sh"
}

# run_setup <tmpdir> <fetch> -> $dir/global.gitconfig を GIT_CONFIG_GLOBAL に
# 据えて git-identity-setup を実行する。
run_setup() {
    local dir="$1" fetch="$2"
    GIT_CONFIG_GLOBAL="$dir/global.gitconfig" \
        GIT_IDENTITY_SETUP_FETCH_CMD="$fetch" \
        sh "$SETUP_SRC"
}

# --- 1. アカウント情報から name と noreply email が設定される --------------------
t="$(mktemp -d)"
: >"$t/global.gitconfig"
fetch="$(make_fetch "$t" '{"login":"octocat","id":583231,"name":"The Octocat","email":"octocat@example.com"}')"
out="$(run_setup "$t" "$fetch" 2>&1)"
rc=$?
name="$(git config --file "$t/global.gitconfig" user.name 2>/dev/null || true)"
email="$(git config --file "$t/global.gitconfig" user.email 2>/dev/null || true)"
if [ "$rc" -eq 0 ] && [ "$name" = "The Octocat" ] && [ "$email" = "583231+octocat@users.noreply.github.com" ]; then
    ok "アカウント情報から name と noreply email が設定される"
else
    ng "アカウント情報から name と noreply email が設定される (rc=$rc name=$name email=$email out=$out)"
fi
rm -rf "$t"

# 表示名が無いアカウントではログイン名へ落ちる。
t="$(mktemp -d)"
: >"$t/global.gitconfig"
fetch="$(make_fetch "$t" '{"login":"octocat","id":583231,"name":null,"email":null}')"
run_setup "$t" "$fetch" >/dev/null 2>&1
name="$(git config --file "$t/global.gitconfig" user.name 2>/dev/null || true)"
if [ "$name" = "octocat" ]; then
    ok "表示名が未設定のときはログイン名へ落ちる"
else
    ng "表示名が未設定のときはログイン名へ落ちる (name=$name)"
fi
rm -rf "$t"

# 表示名の \ がそのまま author 名になる。jq の抽出を @tsv にすると値中の
# \ がエスケープされ、位置で取り出す側 (cut) はそれを復元しないため
# user.name に \\ が残る回帰があった (¯\_(ツ)_/¯ は GitHub の
# プロフィール名として珍しくない)。
t="$(mktemp -d)"
: >"$t/global.gitconfig"
fetch="$(make_fetch "$t" '{"login":"octocat","id":583231,"name":"¯\\_(ツ)_/¯"}')"
run_setup "$t" "$fetch" >/dev/null 2>&1
name="$(git config --file "$t/global.gitconfig" user.name 2>/dev/null || true)"
if [ "$name" = '¯\_(ツ)_/¯' ]; then
    ok "表示名の \\ がそのまま author 名になる"
else
    ng "表示名の \\ がそのまま author 名になる (name=$name)"
fi
rm -rf "$t"

# --- 2. 登録メールアドレスは author に現れない ------------------------------------
t="$(mktemp -d)"
: >"$t/global.gitconfig"
fetch="$(make_fetch "$t" '{"login":"octocat","id":583231,"name":"The Octocat","email":"private-registered@example.com"}')"
run_setup "$t" "$fetch" >/dev/null 2>&1
email="$(git config --file "$t/global.gitconfig" user.email 2>/dev/null || true)"
if [ "$email" = "583231+octocat@users.noreply.github.com" ] && [ "$email" != "private-registered@example.com" ]; then
    ok "登録メールアドレスは author に現れない"
else
    ng "登録メールアドレスは author に現れない (email=$email)"
fi
rm -rf "$t"

# --- 3. 既存の identity と食い違うときは警告して上書きする ------------------------
t="$(mktemp -d)"
git config --file "$t/global.gitconfig" user.name "Someone Else"
git config --file "$t/global.gitconfig" user.email "someone@example.com"
fetch="$(make_fetch "$t" '{"login":"octocat","id":583231,"name":"The Octocat","email":null}')"
out="$(run_setup "$t" "$fetch" 2>&1)"
name="$(git config --file "$t/global.gitconfig" user.name 2>/dev/null || true)"
email="$(git config --file "$t/global.gitconfig" user.email 2>/dev/null || true)"
if [ "$name" = "The Octocat" ] && [ "$email" = "583231+octocat@users.noreply.github.com" ] &&
    printf '%s\n' "$out" | grep -q "Someone Else" && printf '%s\n' "$out" | grep -q "The Octocat"; then
    ok "既存の identity と食い違うときは警告して上書きする"
else
    ng "既存の identity と食い違うときは警告して上書きする (name=$name email=$email out=$out)"
fi
rm -rf "$t"

# 否定対照: 既存値が導出値と一致していれば警告は出ない。
t="$(mktemp -d)"
git config --file "$t/global.gitconfig" user.name "The Octocat"
git config --file "$t/global.gitconfig" user.email "583231+octocat@users.noreply.github.com"
fetch="$(make_fetch "$t" '{"login":"octocat","id":583231,"name":"The Octocat","email":null}')"
out="$(run_setup "$t" "$fetch" 2>&1)"
if [ -z "$out" ]; then
    ok "否定対照: 既存値が導出値と一致していれば警告しない"
else
    ng "否定対照: 既存値が導出値と一致していれば警告しない (out=$out)"
fi
rm -rf "$t"

# --- 4. 取得に失敗しても identity を触らず 0 で終わる -----------------------------
t="$(mktemp -d)"
git config --file "$t/global.gitconfig" user.name "Untouched"
git config --file "$t/global.gitconfig" user.email "untouched@example.com"
fetch="$(make_fetch "$t" '' 1)"
out="$(run_setup "$t" "$fetch" 2>&1)"
rc=$?
name="$(git config --file "$t/global.gitconfig" user.name 2>/dev/null || true)"
email="$(git config --file "$t/global.gitconfig" user.email 2>/dev/null || true)"
if [ "$rc" -eq 0 ] && [ "$name" = "Untouched" ] && [ "$email" = "untouched@example.com" ] && [ -n "$out" ]; then
    ok "取得に失敗しても identity を触らず 0 で終わる"
else
    ng "取得に失敗しても identity を触らず 0 で終わる (rc=$rc name=$name email=$email out=$out)"
fi
rm -rf "$t"

# scope 不足などで 403 が返るケースも同じ経路 (非ゼロ終了) で表現される。
t="$(mktemp -d)"
git config --file "$t/global.gitconfig" user.name "Untouched"
git config --file "$t/global.gitconfig" user.email "untouched@example.com"
fetch="$(make_fetch "$t" 'HTTP 403: Forbidden' 1)"
run_setup "$t" "$fetch" >/dev/null 2>&1
rc=$?
name="$(git config --file "$t/global.gitconfig" user.name 2>/dev/null || true)"
email="$(git config --file "$t/global.gitconfig" user.email 2>/dev/null || true)"
if [ "$rc" -eq 0 ] && [ "$name" = "Untouched" ] && [ "$email" = "untouched@example.com" ]; then
    ok "アカウント情報を取得できない (403 相当) ときも identity を触らず 0 で終わる"
else
    ng "アカウント情報を取得できない (403 相当) ときも identity を触らず 0 で終わる (rc=$rc name=$name email=$email)"
fi
rm -rf "$t"

# --- 4b. 取得は成功したが、中身がアカウント情報として読めない -----------------------
#     jq が非 JSON を渡されると parse error で非ゼロ終了する (実測: rc=4)。抽出を
#     1 箇所にまとめて拾わないと、この分岐を経ずに理由の1行も出さず落ちる回帰。
#     login/id を欠く JSON、空出力も identity 不変・rc=0 という同じ結果になる
#     ことを併せて見る。
for payload in 'not json at all' '{}' ''; do
    t="$(mktemp -d)"
    git config --file "$t/global.gitconfig" user.name "Untouched"
    git config --file "$t/global.gitconfig" user.email "untouched@example.com"
    fetch="$(make_fetch "$t" "$payload" 0)"
    out="$(run_setup "$t" "$fetch" 2>&1)"
    rc=$?
    name="$(git config --file "$t/global.gitconfig" user.name 2>/dev/null || true)"
    email="$(git config --file "$t/global.gitconfig" user.email 2>/dev/null || true)"
    label="取得が成功しても中身がアカウント情報でないときは identity を触らず 0 で終わる"
    if [ "$rc" -eq 0 ] && [ "$name" = "Untouched" ] && [ "$email" = "untouched@example.com" ]; then
        ok "$label"
    else
        ng "$label (payload='${payload:-空}' rc=$rc name=$name email=$email out=$out)"
    fi
    rm -rf "$t"
done

# --- 5. 取得部を差し替えた状態で導出結果が固定される ------------------------------
#     同じ差し替え出力で 2 回実行しても、書き込まれる identity は 1 バイトも
#     変わらない。apply_identity は既存の user.name / user.email
#     (cur_name / cur_email) も入力に取り、1 回目の実行でそれが変わるため、
#     ここで固定しているのは冪等性 (同じ応答なら 2 回目も同じ値へ落ち着く)
#     であって純粋性ではない。
t="$(mktemp -d)"
: >"$t/global.gitconfig"
fetch="$(make_fetch "$t" '{"login":"hubot","id":1,"name":"Hubot","email":"hubot@example.com"}')"
run_setup "$t" "$fetch" >/dev/null 2>&1
first="$(cat "$t/global.gitconfig")"
run_setup "$t" "$fetch" >/dev/null 2>&1
second="$(cat "$t/global.gitconfig")"
if [ "$first" = "$second" ] && printf '%s\n' "$first" | grep -q "Hubot"; then
    ok "取得部を差し替えた状態で導出結果が固定される"
else
    ng "取得部を差し替えた状態で導出結果が固定される (first=$first second=$second)"
fi
rm -rf "$t"

# --- result ------------------------------------------------------------------

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
