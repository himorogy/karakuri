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
# を tmpdir 配下へ差し替えたコピーを作る。/run/prod-ref も同様に差し替える。
# 実 /run/prod-ref (root 所有が普通) へ書きに行かせないための必須の
# 差し替えで、対象パスが単なる文字列 "/run/prod-ref" を含む唯一の行
# (echo の説明文言も含む) すべてに対して機械的に効く。
make_entrypoint() {
	local dir="$1"
	mkdir -p "$dir/secrets" "$dir/src"
	sed \
		-e "s#/run/secrets#$dir/secrets#g" \
		-e "s#/run/prod-ref#$dir/prod-ref#g" \
		-e "s#/src#$dir/src#g" \
		"$ENTRYPOINT_SRC" >"$dir/entrypoint.sh"
	chmod +x "$dir/entrypoint.sh"
}

HAVE_GIT=0
if command -v git >/dev/null 2>&1; then
	HAVE_GIT=1
fi

# --- $HOME をテスト用に退避する --------------------------------------------------
# entrypoint は起動時に $HOME/.config/pnpm への書き込み可否を自己検査する
# ようになった (codex 指摘 #4)。テスト実行中の実ユーザーの $HOME を触ら
# ないよう、このテストスクリプト全体で HOME を tmpdir に差し替える。
# 以降の `env GIT_REPO=... GIT_REF=... "$t/entrypoint.sh" ...` 呼び出しは
# 明示的に HOME を渡していないため、`env` はここで export した HOME を
# そのまま子プロセスへ引き継ぐ。
TEST_HOME="$(mktemp -d)"
export HOME="$TEST_HOME"

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

# --- フェイク pnpm ---------------------------------------------------------------
#
# entrypoint は checkout 後に `pnpm config set store-dir /src/.pnpm-store`
# を呼ぶ (rev.5 / D19)。この環境には実 pnpm が存在するため、フェイクを
# 挟まなければテスト実行のたびに実ユーザーの pnpm グローバル設定
# (~/.config/pnpm/config.yaml) が書き換わってしまう — 実際にこの変更を
# 加えた直後の初回実行で踏んだ (store-dir が消えた tmpdir を指したまま
# 残留した)。PATH の先頭にフェイク pnpm を置いて実 pnpm を素通りさせず、
# 呼び出された引数だけを FAKE_PNPM_ARGV_FILE に記録する。この環境の実際の
# pnpm 設定には一切触れない。
FAKE_PNPM_DIR="$(mktemp -d)"
FAKE_PNPM_ARGV_FILE="$FAKE_PNPM_DIR/pnpm-argv.log"
cat >"$FAKE_PNPM_DIR/pnpm" <<'FAKE_PNPM'
#!/bin/sh
printf '%s\n' "$@" >>"${FAKE_PNPM_ARGV_FILE:?}"
exit 0
FAKE_PNPM
chmod +x "$FAKE_PNPM_DIR/pnpm"
export FAKE_PNPM_ARGV_FILE
export PATH="$FAKE_PNPM_DIR:$PATH"

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

# --- 4d. GIT_REPO に資格情報を埋めた URL -> 非ゼロ終了、トークンは出力しない ----
#     URL に埋めた資格情報は remote set-url により .git/config へ残り、
#     exec 後の信頼しないコードから `git config remote.origin.url` で読める。
#     この拒否は remote 設定より前 (git 操作より前) に置いているため、git の
#     有無に関わらず検証できる。
t="$(mktemp -d)"
make_entrypoint "$t"
token_marker="ghp_TOKENMARKER_$$"
out="$(printf 'FOO=bar\n' |
	env GIT_REPO="https://user:$token_marker@example.invalid/owner/repo.git" GIT_REF=unused \
		"$t/entrypoint.sh" true 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] &&
	printf '%s\n' "$out" | grep -q "must not embed credentials" &&
	! printf '%s\n' "$out" | grep -q "$token_marker"; then
	ok "GIT_REPO への資格情報埋め込み -> 非ゼロ終了、stderr にトークンが出ない"
else
	ng "GIT_REPO への資格情報埋め込み -> 非ゼロ終了、stderr にトークンが出ない (rc=$rc out=$out)"
fi
rm -rf "$t"

# --- 4e. ssh 形式の GIT_REPO は資格情報チェックに引っかからない -----------------
#     git@github.com:owner/repo.git は "://" を含まないため *://*@* に一致
#     しない。ここでは fetch できない URL なので最終的には失敗するが、その
#     失敗が「資格情報が埋まっている」ではないことだけを確認する。
#     GIT_SSH_COMMAND=/bin/false を渡して、テストが実際に ssh (名前解決や
#     ホスト鍵の確認) を試みないようにする。
t="$(mktemp -d)"
make_entrypoint "$t"
out="$(printf 'FOO=bar\n' |
	env GIT_REPO="git@example.invalid:owner/repo.git" GIT_REF=unused GIT_SSH_COMMAND=/bin/false \
		"$t/entrypoint.sh" true 2>&1)"
if ! printf '%s\n' "$out" | grep -q "must not embed credentials"; then
	ok "ssh 形式の GIT_REPO は資格情報チェックで拒否されない"
else
	ng "ssh 形式の GIT_REPO は資格情報チェックで拒否されない (out=$out)"
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
	#     40 桁 hex 形式 (rev.6 / D21 の書式検査を通過する値) だが repo に
	#     存在しない sha を使う。書式検査 (下の 15〜18) とは別の経路
	#     (rev-parse --verify の解決失敗) を切り分けて検証するため。
	t="$(mktemp -d)"
	make_entrypoint "$t"
	out="$(printf 'FOO=bar\n' |
		env GIT_REPO="$BARE_REPO" GIT_REF="abcdef0123abcdef0123abcdef0123abcdef0123" "$t/entrypoint.sh" true 2>&1)"
	rc=$?
	if [ "$rc" -ne 0 ] &&
		printf '%s\n' "$out" | grep -q "does not resolve" &&
		! printf '%s\n' "$out" | grep -q -- "--detach does not take a path argument"; then
		ok "存在しない ref -> 'does not resolve' で非ゼロ終了 (--detach のパス引数エラーではない)"
	else
		ng "存在しない ref -> 'does not resolve' で非ゼロ終了 (--detach のパス引数エラーではない) (rc=$rc out=$out)"
	fi
	rm -rf "$t"

	# 14. entrypoint が pnpm の store を /src (node_modules と同一の
	#     tmpfs) へ向けている (regression: rev.5 / D19)。フェイク pnpm が
	#     受け取った引数を検証する。store がこの sed 置換後の /src の下に
	#     あることまで確認することで、「同一 tmpfs に置く」という要件
	#     (別マウントだとハードリンクが張れず RAM が倍になる) を、パス
	#     文字列のレベルで裏付ける。
	t="$(mktemp -d)"
	make_entrypoint "$t"
	: >"$FAKE_PNPM_ARGV_FILE"
	printf 'FOO=bar\n' |
		env GIT_REPO="$BARE_REPO" GIT_REF="$COMMIT_SHA" "$t/entrypoint.sh" true >/dev/null 2>&1
	expected_pnpm_argv="$(printf 'config\nset\nstore-dir\n%s\n' "$t/src/.pnpm-store")"
	actual_pnpm_argv="$(cat "$FAKE_PNPM_ARGV_FILE" 2>/dev/null)"
	if [ "$actual_pnpm_argv" = "$expected_pnpm_argv" ]; then
		ok "entrypoint が pnpm config set store-dir <tmpfs 上の /src> を呼ぶ"
	else
		ng "entrypoint が pnpm config set store-dir <tmpfs 上の /src> を呼ぶ (got: $actual_pnpm_argv)"
	fi
	rm -rf "$t"

	# 15〜16 は "origin/main" を可変 ref の例として使う。ローカル repo に
	# は remote-tracking ref (refs/remotes/origin/main) しか無く、単なる
	# "main" は `git rev-parse --verify` の探索順に一致しないため解決
	# できない。16 は警告後に rev-parse まで到達する経路を検証したいので、
	# 実際に解決できる非 sha ref を使う必要がある。

	# 15. 40 桁 hex でない GIT_REF は既定で非ゼロ終了し、
	#     PROD_ALLOW_MUTABLE_REF に言及したメッセージが出る (rev.6 / D21)。
	t="$(mktemp -d)"
	make_entrypoint "$t"
	out="$(printf 'FOO=bar\n' |
		env GIT_REPO="$BARE_REPO" GIT_REF="origin/main" "$t/entrypoint.sh" true 2>&1)"
	rc=$?
	if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q "PROD_ALLOW_MUTABLE_REF"; then
		ok "40 桁 hex でない GIT_REF -> 既定で非ゼロ終了 (PROD_ALLOW_MUTABLE_REF に言及)"
	else
		ng "40 桁 hex でない GIT_REF -> 既定で非ゼロ終了 (PROD_ALLOW_MUTABLE_REF に言及) (rc=$rc out=$out)"
	fi
	# この検査は fetch 後・checkout 前に置く設計 (設計書 §4.6) なので、
	# 拒否された時点で /src/.git 自体は既に (init + fetch により) 存在
	# する。ここで検証しているのは「拒否されること」であって「git 操作が
	# 一切走らないこと」ではない。
	if [ ! -e "$t/prod-ref" ]; then
		ok "40 桁 hex でない GIT_REF が拒否されたとき /run/prod-ref は書かれない (拒否は記録より前)"
	else
		ng "40 桁 hex でない GIT_REF が拒否されたとき /run/prod-ref は書かれない (拒否は記録より前)"
	fi
	rm -rf "$t"

	# 16. PROD_ALLOW_MUTABLE_REF=1 なら、40 桁 hex でない GIT_REF でも
	#     警告付きで続行する (rev.6 / D21)。
	t="$(mktemp -d)"
	make_entrypoint "$t"
	out="$(printf 'FOO=bar\n' |
		env GIT_REPO="$BARE_REPO" GIT_REF="origin/main" PROD_ALLOW_MUTABLE_REF=1 \
			"$t/entrypoint.sh" true 2>&1)"
	rc=$?
	# grep 対象を "WARNING: GIT_REF" に限定する: tmpfs 自己検査も
	# WARNING を出しうる (テスト環境では /proc/mounts に該当行が無いため
	# 必ず出る) ので、単なる "WARNING" では可変 ref の警告を検証できない。
	if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q "WARNING: GIT_REF"; then
		ok "PROD_ALLOW_MUTABLE_REF=1 -> 警告付きで続行する (exit 0)"
	else
		ng "PROD_ALLOW_MUTABLE_REF=1 -> 警告付きで続行する (exit 0) (rc=$rc out=$out)"
	fi
	rm -rf "$t"

	# 17. 40 桁 hex の GIT_REF は脱出口 (PROD_ALLOW_MUTABLE_REF) なしで通る。
	#     既存の正常系 (6 番) は同じ COMMIT_SHA を使っているが、ここでは
	#     「可変 ref の警告が出ない」ことまで明示的に確認する
	#     (tmpfs 自己検査の WARNING とは別物なので、16 と同様に
	#     "WARNING: GIT_REF" に限定して見る)。
	t="$(mktemp -d)"
	make_entrypoint "$t"
	out="$(printf 'FOO=bar\n' |
		env GIT_REPO="$BARE_REPO" GIT_REF="$COMMIT_SHA" "$t/entrypoint.sh" true 2>&1)"
	rc=$?
	if [ "$rc" -eq 0 ] && ! printf '%s\n' "$out" | grep -q "WARNING: GIT_REF"; then
		ok "40 桁 hex の GIT_REF は脱出口なしで通る (警告なし)"
	else
		ng "40 桁 hex の GIT_REF は脱出口なしで通る (警告なし) (rc=$rc out=$out)"
	fi
	rm -rf "$t"

	# 18. /run/prod-ref (相当のファイル) が作られ、GIT_REF / GIT_COMMIT /
	#     MUTABLE_REF の3行が書かれ、mode 644 であること。stderr に
	#     "resolved to <sha>" が出ること (rev.6 / §4.6)。
	t="$(mktemp -d)"
	make_entrypoint "$t"
	out="$(printf 'FOO=bar\n' |
		env GIT_REPO="$BARE_REPO" GIT_REF="$COMMIT_SHA" "$t/entrypoint.sh" true 2>&1)"
	rc=$?
	if [ "$rc" -eq 0 ] && [ -f "$t/prod-ref" ]; then
		ok "/run/prod-ref 相当のファイルが作られる"
	else
		ng "/run/prod-ref 相当のファイルが作られる (rc=$rc out=$out)"
	fi

	prod_ref_content="$(cat "$t/prod-ref" 2>/dev/null)"
	expected_prod_ref="$(printf 'GIT_REF=%s\nGIT_COMMIT=%s\nMUTABLE_REF=0\n' "$COMMIT_SHA" "$COMMIT_SHA")"
	if [ "$prod_ref_content" = "$expected_prod_ref" ]; then
		ok "/run/prod-ref に GIT_REF= / GIT_COMMIT=<解決済み sha> / MUTABLE_REF=0 の3行が書かれる"
	else
		ng "/run/prod-ref の中身が期待どおり (got: $prod_ref_content)"
	fi

	if [ -f "$t/prod-ref" ]; then
		mode="$(stat -c '%a' "$t/prod-ref" 2>/dev/null || stat -f '%Lp' "$t/prod-ref" 2>/dev/null)"
		if [ "$mode" = "644" ]; then
			ok "/run/prod-ref が mode 644 (umask 077 の影響を受けず chmod で緩めている)"
		else
			ng "/run/prod-ref が mode 644 (mode=$mode)"
		fi
	else
		ng "/run/prod-ref が mode 644 (ファイルが無い)"
	fi

	if printf '%s\n' "$out" | grep -q "resolved to $COMMIT_SHA"; then
		ok "stderr に 'resolved to <sha>' が出る"
	else
		ng "stderr に 'resolved to <sha>' が出る (out=$out)"
	fi
	rm -rf "$t"

	# 19. 40 桁 hex を「名前」とする ref があっても、それが sha として実行
	#     されない。dev (信頼しない側) は 40 桁 hex を名前とするブランチ/
	#     タグを push でき、その hex に対応するオブジェクトは存在しない、
	#     という状態を作れる。書式検査は通る (mutable=0) ので、もし
	#     rev-parse が ref 側へフォールバックして解決すると、可変 ref の
	#     内容が immutable として実行され /run/prod-ref にも MUTABLE_REF=0
	#     と記録されてしまう。
	#
	#     git 2.39 では 40 桁 hex の refname は rev-parse 側が無視する
	#     ("refname ... is ambiguous" の警告付きで解決失敗) ため、この
	#     入力は entrypoint 側の一致検査ではなく "does not resolve" で
	#     落ちる。どちらの経路で落ちるかは git の版に依存するので、ここで
	#     固定するのは「非ゼロ終了し、記録も残らない」ことにする。
	HEX_ROOT="$(mktemp -d)"
	HEX_REPO="$HEX_ROOT/upstream.git"
	HEX_REF="0123456789abcdef0123456789abcdef01234567"
	if git init -q --bare "$HEX_REPO" &&
		printf 'second\n' >"$WORK_ROOT/file.txt" &&
		git -C "$WORK_ROOT" commit -q -am second &&
		git -C "$WORK_ROOT" push -q "$HEX_REPO" HEAD~1:refs/heads/main &&
		git -C "$WORK_ROOT" push -q "$HEX_REPO" "HEAD:refs/heads/$HEX_REF" &&
		git -C "$WORK_ROOT" push -q "$HEX_REPO" "HEAD:refs/tags/$HEX_REF"; then
		t="$(mktemp -d)"
		make_entrypoint "$t"
		out="$(printf 'FOO=bar\n' |
			env GIT_REPO="$HEX_REPO" GIT_REF="$HEX_REF" "$t/entrypoint.sh" true 2>&1)"
		rc=$?
		if [ "$rc" -ne 0 ] && [ ! -e "$t/prod-ref" ]; then
			ok "40 桁 hex を名前とする ref -> 非ゼロ終了し /run/prod-ref も書かれない"
		else
			ng "40 桁 hex を名前とする ref -> 非ゼロ終了し /run/prod-ref も書かれない (rc=$rc out=$out)"
		fi
		rm -rf "$t"
	else
		ng "40 桁 hex を名前とする ref のテスト用 repo を準備できなかった"
	fi
	rm -rf "$HEX_ROOT"

	# 20. 大文字混じりの完全 commit sha が誤って拒否されない。書式検査は
	#     [0-9a-fA-F] を許すため大文字の sha が渡されうる一方、git が返す
	#     sha は常に小文字であり、19 で入れた一致検査を素朴に書くとここで
	#     偽陽性になる (小文字へ畳んでから比較している)。
	UPPER_SHA="$(printf '%s' "$COMMIT_SHA" | tr 'a-f' 'A-F')"
	t="$(mktemp -d)"
	make_entrypoint "$t"
	out="$(printf 'FOO=bar\n' |
		env GIT_REPO="$BARE_REPO" GIT_REF="$UPPER_SHA" "$t/entrypoint.sh" true 2>&1)"
	rc=$?
	if [ "$rc" -eq 0 ] && ! printf '%s\n' "$out" | grep -q "resolved to a different object"; then
		ok "大文字の完全 commit sha でも通る (sha 一致検査が小文字へ畳んで比較している)"
	else
		ng "大文字の完全 commit sha でも通る (rc=$rc out=$out)"
	fi
	rm -rf "$t"

	# 21. tmpfs 自己検査: /proc/mounts に該当行が無い状況 (テスト環境その
	#     もの。entrypoint のコピーは /src を tmpdir 配下へ書き換えてある
	#     ため、どんなホストでも mountpoint には一致しない) で、WARNING を
	#     出しつつ続行すること。黙ってスキップしないことがこの検査の要件。
	#
	#     secret 側の検査対象が "/run" 直書きではなく secret の置き場
	#     (sed 置換対象) の親として導出されていることも、ここで一緒に
	#     押さえる: 直書きに戻ると、/run が非 tmpfs の mountpoint として
	#     現れるホストでこのテストが実行環境依存で落ちる。
	t="$(mktemp -d)"
	make_entrypoint "$t"
	out="$(printf 'FOO=bar\n' |
		env GIT_REPO="$BARE_REPO" GIT_REF="$COMMIT_SHA" "$t/entrypoint.sh" true 2>&1)"
	rc=$?
	if [ "$rc" -eq 0 ] &&
		printf '%s\n' "$out" | grep -q "WARNING: cannot verify that $t/src is a tmpfs"; then
		ok "tmpfs 自己検査: mount 情報が見つからないときは WARNING を出して続行する"
	else
		ng "tmpfs 自己検査: mount 情報が見つからないときは WARNING を出して続行する (rc=$rc out=$out)"
	fi
	if printf '%s\n' "$out" | grep -q "WARNING: cannot verify that $t is a tmpfs"; then
		ok "tmpfs 自己検査: secret 側の対象が secret の置き場の親として導出されている (/run 直書きではない)"
	else
		ng "tmpfs 自己検査: secret 側の対象が secret の置き場の親として導出されている (/run 直書きではない) (out=$out)"
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
	skip "entrypoint が pnpm config set store-dir を呼ぶ: git 不在のため未検証"
	skip "40 桁 hex でない GIT_REF が既定で拒否される: git 不在のため未検証"
	skip "PROD_ALLOW_MUTABLE_REF=1 で警告付き続行: git 不在のため未検証"
	skip "40 桁 hex の GIT_REF は脱出口なしで通る: git 不在のため未検証"
	skip "/run/prod-ref の記録 (GIT_COMMIT / mode 644 / resolved to <sha>): git 不在のため未検証"
	skip "40 桁 hex を名前とする ref が sha として実行されない: git 不在のため未検証"
	skip "大文字の完全 commit sha でも通る: git 不在のため未検証"
	skip "tmpfs 自己検査の WARNING と続行: git 不在のため未検証 (完走まで到達できない)"
fi

# --- 後始末 ----------------------------------------------------------------------
if [ "$HAVE_GIT" -eq 1 ]; then
	rm -rf "$BARE_ROOT" "$WORK_ROOT"
fi
rm -rf "$FAKE_PNPM_DIR"
rm -rf "$TEST_HOME"

# --- result ------------------------------------------------------------------

printf '\n%s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
