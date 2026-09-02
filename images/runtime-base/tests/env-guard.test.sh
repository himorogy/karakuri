#!/usr/bin/env bash
#
# 共有スキャナ packages/env-guard/bin/env-guard-scan の検証。
#
# 一番大事なのは「平文を実際に検出できること」である。緑になる検査より
# 先に、赤くなるべき入力で赤くなることを確かめる。このリポジトリでは過去に
# 「意図した経路を一度も通らないまま緑になっていた」偽の合格を 2 度踏んで
# おり、破棄した `dotenvx precommit` 案（クリーン checkout では平文 .env を
# 見つけても緑を返す）も同型だった。
#
# 二番目に大事なのが、コミット時の hook と CI が**同じ判定**を返すこと。
# 以前は hook が `dotenvx precommit`、CI が workflow 内のインライン走査で、
# 実装が 2 つあった。パターンだけ揃えても判定が別なら「hook は通るのに CI
# で落ちる」は残る。今は両者とも packages/env-guard/bin/env-guard-scan を
# 呼び、違うのは与えるファイル一覧の作り方（staged か tracked か）だけで
# ある。同じ fixture を両方の入口から通して、終了コードだけでなく出力まで
# 一致することを確かめる。
#
# スキャナと hook はイメージではなく packages/env-guard の持ち物である
# （イメージへは named build context 経由で焼き込む）。テストはリポジトリ
# ルートから辿って、その 1 本を直接叩く。
#
# fixture の git リポジトリは `git init` + `git add` だけで作る。
# 「tracked」= index に載っていることなので commit は不要であり、
# user.email 等の設定も要らない。全ファイルを stage した状態にすると
# staged の一覧と tracked の一覧が一致するので、hook と CI に同じ一覧を
# 与えたことになる。

set -uo pipefail

GUARD_DIR="$(cd "$(dirname "$0")/../../../packages/env-guard" && pwd)"
SCANNER="$GUARD_DIR/bin/env-guard-scan"
HOOK="$GUARD_DIR/hooks/pre-commit"

TMPDIR_TEST="$(mktemp -d)"
trap 'chmod -R u+rwX "$TMPDIR_TEST" 2>/dev/null; rm -rf "$TMPDIR_TEST"' EXIT

OUT="$TMPDIR_TEST/out.txt"
OUT_B="$TMPDIR_TEST/out-b.txt"

PASS=0
FAIL=0
SKIP=0

pass() {
	PASS=$((PASS + 1))
	printf '  ok   — %s\n' "$1"
}

fail() {
	FAIL=$((FAIL + 1))
	printf '  FAIL — %s\n' "$1" >&2
	if [ -n "${2:-}" ]; then
		printf '         %s\n' "$2" >&2
	fi
}

skip() {
	SKIP=$((SKIP + 1))
	printf '  skip — %s\n' "$1"
}

# root で走ると mode 000 のファイルも読めてしまい、「設定ファイルが読め
# ない」状況が作れない。hook.test.sh と同じ流儀で skip して明示する。
IS_ROOT=0
if [ "$(id -u)" -eq 0 ]; then
	IS_ROOT=1
fi

# 実際に dotenvx (2.19.2) が出力した暗号化済み .env をそのまま fixture に
# している。CI で dotenvx を入れずに済ませるためのベタ書きであり、引用符の
# 有無が行ごとに違う点（元ファイル由来でどちらもありうる）も実物のままに
# してある。判定側の正規表現 '^[A-Z0-9_]+="?encrypted:' の `"?` はこの
# 両方を通すためのもので、fixture がその両方を含んでいないと片方しか
# 検査できない。
encrypted_env() {
	cat <<'ENCRYPTED_ENV'
#/-------------------[DOTENV_PUBLIC_KEY]--------------------/
#/            public-key encryption for .env files          /
#/       [how it works](https://dotenvx.com/encryption)     /
#/----------------------------------------------------------/
DOTENV_PUBLIC_KEY="025c1ca8858081e39bcd2aac79ee0999a1a3f3d74e2f982c5ee7021a7c32e3a870"

# .env
# comment
A=encrypted:BOkaMMkIJeoHBjHzD5BBZHyP0ngva7nahuEYJJpEt0T18ecJrPQ+lZdEegg/K0op1kCn1yKPkaSx5HK70WDvYiE2CRLH+1fQR18Jyqcz0vVH5RtUmxbKahWF7J2XEPixqN8eXvWq
B="encrypted:BOv8Zic4Gcc4HwQsQsxOZ+5+LWlzeDaQT26xTMDpkZpjpOnd4QqGbjUq/LjOAYrlldeVHEN+GVtiXi4aQxx3PYRfi+0nCCYfkn1CxAv+8OgtWgz3c6BCa4J7ibu5XJclmEaoUkUof39bXNcuTw=="
ENCRYPTED_ENV
}

# ---------------------------------------------------------------------------
# 0. 前提
# ---------------------------------------------------------------------------

echo "== preconditions"

if [ -x "$SCANNER" ]; then
	pass "the shared scanner exists and is executable ($SCANNER)"
else
	echo "FATAL: scanner not found or not executable: $SCANNER" >&2
	exit 1
fi

if [ -x "$HOOK" ]; then
	pass "the pre-commit hook exists and is executable"
else
	echo "FATAL: hook not found or not executable: $HOOK" >&2
	exit 1
fi

# hook が自前で判定を持っていないこと。ここが崩れると「同じ判定」の前提が
# 静かに壊れる。
if grep -q 'env-guard-scan' "$HOOK"; then
	pass "the hook delegates to the shared scanner"
else
	fail "the hook delegates to the shared scanner" "no reference to env-guard-scan in $HOOK"
fi

# コメント行は除いて見る。hook には「なぜ外したか」の説明が書いてあり、
# それに一致してしまうと、実際に呼び戻されても気づけない。
if grep -vE '^[[:space:]]*#' "$HOOK" | grep -q 'dotenvx'; then
	fail "the hook no longer runs 'dotenvx precommit'" \
		"it has its own uncontrollable file filter, which reintroduces hook/CI divergence"
else
	pass "the hook no longer runs 'dotenvx precommit'"
fi

# ---------------------------------------------------------------------------
# 1. fixture
# ---------------------------------------------------------------------------

# new_repo <name> — 空の git repo を作ってパスを返す。
new_repo() {
	local dir="$TMPDIR_TEST/repos/$1"
	mkdir -p "$dir"
	git -C "$dir" init -q
	echo "$dir"
}

# track_all <repo> — 置いたファイルを index に載せる（= tracked かつ
# staged にする）。-f はホスト側のグローバル gitignore に .env が入って
# いても確実に載せるため。commit はしない。
track_all() {
	git -C "$1" add -f -A
}

RC=0

# run_ci <repo> [outfile] — CI 側の入口。tracked の一覧をスキャナへ流す。
run_ci() {
	local out="${2:-$OUT}"
	RC=0
	(cd "$1" && git ls-files | "$SCANNER") >"$out" 2>&1 || RC=$?
}

# run_hook <repo> [outfile] — コミット時の入口。hook は staged の一覧を
# 自分で作ってスキャナへ流す。
run_hook() {
	local out="${2:-$OUT}"
	RC=0
	(cd "$1" && "$HOOK") >"$out" 2>&1 || RC=$?
}

expect_rc() {
	if [ "$RC" = "$2" ]; then
		pass "$1 (rc=$RC)"
	else
		fail "$1" "expected rc=$2, got rc=$RC; output: $(tr '\n' ' ' <"$OUT")"
	fi
}

expect_out() {
	if grep -qF -- "$2" "$OUT"; then
		pass "$1"
	else
		fail "$1" "expected output to contain: $2 (got: $(tr '\n' ' ' <"$OUT"))"
	fi
}

expect_no_out() {
	if grep -qF -- "$2" "$OUT"; then
		fail "$1" "output unexpectedly contains: $2"
	else
		pass "$1"
	fi
}

echo "== fixtures"

plain=$(new_repo plain)
printf 'A=hello\nB="world"\n' >"$plain/.env"
track_all "$plain"

encrypted=$(new_repo encrypted)
encrypted_env >"$encrypted/.env"
track_all "$encrypted"

keys=$(new_repo keys)
encrypted_env >"$keys/.env"
printf 'DOTENV_PRIVATE_KEY="7ba1d3e0b1d0f0e4b9c9f6d1a7c3b5e2d4f6a8c0e2b4d6f8a0c2e4b6d8f0a2c4"\n' \
	>"$keys/.env.keys"
track_all "$keys"

# 既定の許可リストのパターンは `*.env.container.example`。既定の検査対象
# パターンが `(^|/)\.env` である以上、これに当たるのは
# `.env.container.example`（ディレクトリ配下も含む）であって
# `app.env.container.example` ではない。後者はそもそも検査対象の名前に
# 当たらず、許可リストまで到達しない。
allowed=$(new_repo allowed)
printf 'A=hello\n' >"$allowed/.env.container.example"
track_all "$allowed"

nested=$(new_repo nested)
mkdir -p "$nested/packages/api" "$nested/packages/web"
printf 'A=hello\n' >"$nested/packages/api/.env"
encrypted_env >"$nested/packages/web/.env"
track_all "$nested"

secret_named=$(new_repo secret-named)
printf 'TOKEN=ghp_plaintext\n' >"$secret_named/secret.env.production"
track_all "$secret_named"

no_newline=$(new_repo no-newline)
printf 'A=hello' >"$no_newline/.env"
track_all "$no_newline"

# 出力に値を反射しないことの回帰テスト用。値そのものと、`=` を含まない行
# （壊れた行は secret 本体でありうる）の両方に目印文字列を仕込む。書き方は
# entrypoint.test.sh の「パース失敗メッセージに入力行が出ない」と同じ形。
VALUE_MARKER="PLAINTEXTVALUEMARKER_$$"
NOEQ_MARKER="NOEQUALSLINEMARKER_$$"

reflect=$(new_repo reflect)
printf 'A=%s\n%s\n' "$VALUE_MARKER" "$NOEQ_MARKER" >"$reflect/.env"
track_all "$reflect"

untracked=$(new_repo untracked)
printf 'README\n' >"$untracked/README.md"
track_all "$untracked"
# tracked にしない平文。CI の一覧 (tracked) には出ないので拾われない。
printf 'A=hello\n' >"$untracked/.env"

# git リポジトリですらない場所。一覧が取れないまま「0 件検査して合格」と
# 緑になる経路が無いことを確かめる。
not_a_repo="$TMPDIR_TEST/repos/not-a-repo"
mkdir -p "$not_a_repo"
printf 'A=hello\n' >"$not_a_repo/.env"

# --- 設定ファイル (env-guard.conf) の fixture --------------------------------

# basename が `.env` で始まらない `production.env` は既定のパターンでは
# 検査対象外。pattern の上書きで拾えるようになること。
conf_pattern=$(new_repo conf-pattern)
printf 'A=hello\n' >"$conf_pattern/production.env"
{
	printf '# project-specific patterns\n'
	printf 'pattern (^|/)\\.env\n'
	printf 'pattern (^|/)secret\\.env\\.\n'
	printf 'pattern (^|/)[^/]*\\.env$\n'
} >"$conf_pattern/env-guard.conf"
track_all "$conf_pattern"

# 同じ内容で設定ファイルだけ無いもの。上書きが効いたのか、そもそも既定で
# 拾えていたのかを区別するための対照。
conf_pattern_off=$(new_repo conf-pattern-off)
printf 'A=hello\n' >"$conf_pattern_off/production.env"
track_all "$conf_pattern_off"

# allow の上書き。既定なら落ちる平文 .env を、設定ファイルで外せること。
conf_allow=$(new_repo conf-allow)
mkdir -p "$conf_allow/docs"
printf 'A=hello\n' >"$conf_allow/docs/.env.sample"
printf 'allow docs/.env.*\n' >"$conf_allow/env-guard.conf"
track_all "$conf_allow"

conf_allow_off=$(new_repo conf-allow-off)
mkdir -p "$conf_allow_off/docs"
printf 'A=hello\n' >"$conf_allow_off/docs/.env.sample"
track_all "$conf_allow_off"

# 壊れた設定。既定へ黙って倒れないこと。
conf_unknown=$(new_repo conf-unknown)
encrypted_env >"$conf_unknown/.env"
printf 'patern (^|/)\\.env\n' >"$conf_unknown/env-guard.conf"
track_all "$conf_unknown"

conf_novalue=$(new_repo conf-novalue)
encrypted_env >"$conf_novalue/.env"
printf 'allow\n' >"$conf_novalue/env-guard.conf"
track_all "$conf_novalue"

conf_unreadable=$(new_repo conf-unreadable)
encrypted_env >"$conf_unreadable/.env"
printf 'allow *.env.container.example\n' >"$conf_unreadable/env-guard.conf"
track_all "$conf_unreadable"
chmod 000 "$conf_unreadable/env-guard.conf"

# 設定ファイル自身が検査されないこと。pattern を「全部拾う」に上書きして
# なお、env-guard.conf は検査対象にならない（中身は KEY=encrypted: の形を
# していないので、検査されたら必ず落ちる）。
conf_self=$(new_repo conf-self)
printf 'pattern .\n' >"$conf_self/env-guard.conf"
track_all "$conf_self"

# ---------------------------------------------------------------------------
# 2. 検知能力 (CI 側の入口から)
# ---------------------------------------------------------------------------

echo "== detection"

run_ci "$plain"
expect_rc "plaintext .env fails the scan" 1
expect_out "plaintext .env is named with its line and key" ".env line 1: A is not encrypted"
expect_out "the failure is summarised" "env-guard: FAILED"

run_ci "$encrypted"
expect_rc "encrypted .env passes the scan" 0
expect_out "the encrypted file is counted as inspected" "inspected 1 file(s)"

run_ci "$keys"
expect_rc "a .env.keys in the working tree fails the scan" 1
expect_out "the .env.keys path is reported" ".env.keys found:"

run_ci "$allowed"
expect_rc ".env.container.example is skipped by the default allow list" 0
expect_out "the skip is visible in the output" "skipped by allow list: .env.container.example"
expect_out "a skip-only run says nothing was inspected" "nothing to inspect"

run_ci "$nested"
expect_rc "a nested plaintext .env fails the scan" 1
expect_out "the nested plaintext .env is named" "packages/api/.env line 1"
expect_no_out "the nested encrypted .env is not reported" "packages/web/.env line"

run_ci "$secret_named"
expect_rc "a plaintext secret.env.* fails the scan" 1
expect_out "the plaintext secret.env.* is named" "secret.env.production line 1"

run_ci "$no_newline"
expect_rc "a plaintext .env without a trailing newline fails" 1

run_ci "$untracked"
expect_rc "an untracked plaintext .env is not in the tracked list" 0
expect_out "a 0-file run says so explicitly" "nothing to inspect"

run_ci "$not_a_repo"
expect_rc "a directory that is not a git repo fails instead of passing" 1
expect_out "the failure explains that nothing was inspected" "Nothing was inspected"

# ---------------------------------------------------------------------------
# 3. 値を出力しないこと
# ---------------------------------------------------------------------------

echo "== the log never gets the values"

run_ci "$reflect"
expect_rc "plaintext values are still detected" 1
expect_out "the key name and location are reported" ".env line 1: A is not encrypted"
expect_no_out "the plaintext value is not echoed to the log" "$VALUE_MARKER"
expect_out "a line without '=' is reported by line number" ".env line 2 is not an encrypted assignment"
expect_no_out "a line without '=' is not echoed to the log" "$NOEQ_MARKER"

# ---------------------------------------------------------------------------
# 4. 設定ファイル
# ---------------------------------------------------------------------------

echo "== env-guard.conf"

run_ci "$conf_pattern_off"
expect_rc "production.env is out of scope with the default patterns" 0
expect_out "the default-pattern run inspected nothing" "nothing to inspect"

run_ci "$conf_pattern"
expect_rc "a pattern override brings production.env into scope" 1
expect_out "the overridden pattern names the file" "production.env line 1: A is not encrypted"

run_ci "$conf_allow_off"
expect_rc "docs/.env.sample fails without an allow override" 1

run_ci "$conf_allow"
expect_rc "an allow override skips docs/.env.sample" 0
expect_out "the allow override skip is visible" "skipped by allow list: docs/.env.sample"

run_ci "$conf_unknown"
expect_rc "an unknown directive fails instead of falling back to the defaults" 1
expect_out "the unknown directive is named with its line number" "line 1: unknown directive"

run_ci "$conf_novalue"
expect_rc "a directive without a value fails" 1
expect_out "the valueless directive is named with its line number" "line 1: 'allow' needs a value"

if [ "$IS_ROOT" -eq 1 ]; then
	skip "an unreadable env-guard.conf fails instead of falling back (root can read mode 000)"
else
	run_ci "$conf_unreadable"
	expect_rc "an unreadable env-guard.conf fails instead of falling back" 1
	expect_out "the unreadable config failure explains itself" "could not be read"
fi

run_ci "$conf_self"
expect_rc "env-guard.conf is never inspected as an env file" 0
expect_out "env-guard.conf is not counted as inspected" "nothing to inspect"

# ---------------------------------------------------------------------------
# 5. hook と CI が同じ判定を返すこと
# ---------------------------------------------------------------------------
#
# 今回の作り直しの本題。fixture は全ファイルが staged なので、hook が作る
# 一覧 (staged) と CI が作る一覧 (tracked) は同じ内容になる。したがって
# 終了コードだけでなく出力まで一致しなければならない。片方だけが検出する、
# 片方だけが許可リストを読む、といったずれはここで赤くなる。

echo "== the hook and CI agree"

# equal_verdict <label> <repo>
equal_verdict() {
	local label="$1" repo="$2"
	local ci_rc hook_rc

	run_ci "$repo" "$OUT"
	ci_rc=$RC
	run_hook "$repo" "$OUT_B"
	hook_rc=$RC

	if [ "$ci_rc" != "$hook_rc" ]; then
		fail "$label: same exit code from both entry points" \
			"CI rc=$ci_rc, hook rc=$hook_rc"
		return
	fi
	pass "$label: same exit code from both entry points (rc=$ci_rc)"

	if diff -u "$OUT" "$OUT_B" >"$TMPDIR_TEST/diff.txt" 2>&1; then
		pass "$label: byte-identical output from both entry points"
	else
		fail "$label: byte-identical output from both entry points" \
			"$(tr '\n' ' ' <"$TMPDIR_TEST/diff.txt")"
	fi
}

equal_verdict "plaintext .env" "$plain"
equal_verdict "encrypted .env" "$encrypted"
equal_verdict "plaintext secret.env.*" "$secret_named"
equal_verdict "nested mixture" "$nested"
equal_verdict "default allow list" "$allowed"
equal_verdict "pattern override in env-guard.conf" "$conf_pattern"
equal_verdict "allow override in env-guard.conf" "$conf_allow"
equal_verdict "broken env-guard.conf" "$conf_unknown"
equal_verdict ".env.keys in the working tree" "$keys"

# 上の一致だけでは「両方とも何も検査していない」ときも一致してしまう。
# 設定ファイルの上書きが hook 側でも本当に効いていること (= 既定では
# 拾わないものを拾い、既定では落ちるものを許している) を、hook の出力
# そのもので確かめる。
run_hook "$conf_pattern"
expect_rc "the hook applies the pattern override" 1
expect_out "the hook names the file the override brought into scope" \
	"production.env line 1: A is not encrypted"

run_hook "$conf_pattern_off"
expect_rc "the hook leaves production.env alone without the override" 0

run_hook "$conf_allow"
expect_rc "the hook applies the allow override" 0
expect_out "the hook shows the allow-override skip" "skipped by allow list: docs/.env.sample"

run_hook "$conf_allow_off"
expect_rc "the hook still fails on docs/.env.sample without the override" 1

# ---------------------------------------------------------------------------
# 6. hook は判定を自分で持たない
# ---------------------------------------------------------------------------

echo "== the hook owns no verdict of its own"

# 前提の節で見た grep は「hook のソースに env-guard-scan と書いてある」
# ことしか言えない。判定が本当に呼び先にあるかは、呼び先を差し替えて結果が
# 追随することでしか外から見えない。hook は自分の隣 (../bin/) を先に見て
# から /usr/local/bin へ落ちるので、コピーしたツリーの bin へ置いた代役が
# 必ず選ばれる (イメージが焼いたスキャナは見られない)。

# fake_scanner_hook <name> <rc> — hook のコピーと、標準入力を捨てて rc を
# 返すだけの代役を並べたツリーを作り、その hook のパスを返す。
fake_scanner_hook() {
	local name="$1" rc="$2"
	local dir="$TMPDIR_TEST/delegate/$name"
	mkdir -p "$dir/hooks" "$dir/bin"
	cp "$HOOK" "$dir/hooks/pre-commit"
	chmod +x "$dir/hooks/pre-commit"
	cat >"$dir/bin/env-guard-scan" <<FAKE
#!/bin/sh
cat >/dev/null
echo "FAKE-SCANNER-WAS-HERE"
exit $rc
FAKE
	chmod +x "$dir/bin/env-guard-scan"
	printf '%s\n' "$dir/hooks/pre-commit"
}

# run_hook_at <hook> <repo> — 指定した hook を repo の中で実行する。
run_hook_at() {
	RC=0
	(cd "$2" && "$1") >"$OUT" 2>&1 || RC=$?
}

# 代役が 0 を返すなら、平文の .env が staged でも hook は通る。hook が
# 自前の判定を持っていれば、ここは落ちるはずである (否定対照)。
run_hook_at "$(fake_scanner_hook pass 0)" "$plain"
expect_rc "the hook passes plaintext when the scanner it calls passes" 0
expect_out "the hook ran the stand-in scanner (pass)" "FAKE-SCANNER-WAS-HERE"

# 逆向き。代役が 42 を返すなら、本来は通る暗号化済みの入力でも hook は 42 を
# そのまま返す。合否も終了コードも hook ではなく呼び先のものである。
run_hook_at "$(fake_scanner_hook fail 42)" "$encrypted"
expect_rc "the hook returns the stand-in scanner's own exit code" 42
expect_out "the hook ran the stand-in scanner (fail)" "FAKE-SCANNER-WAS-HERE"

# ---------------------------------------------------------------------------

printf '\n%s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
